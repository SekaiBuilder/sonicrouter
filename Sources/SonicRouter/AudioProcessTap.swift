import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

private let tapLog = Logger(subsystem: "local.sonicrouter.app", category: "ProcessTap")

// MARK: - Errors

enum TapError: LocalizedError {
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .coreAudio(action, status):
            return "No se pudo \(action). CoreAudio devolvió \(FourCC.string(status))."
        }
    }
}

enum FourCC {
    /// Render an OSStatus as a readable four-character code when printable.
    static func string(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }), let text = String(bytes: bytes, encoding: .ascii) {
            return "'\(text)'"
        }
        return "\(status)"
    }
}

// MARK: - Safety cleanup

enum SonicRouterAudioCleanup {
    static func destroyOwnedAudioObjects() {
        destroyOwnedTaps()
        destroyOwnedAggregates()
    }

    private static func destroyOwnedTaps() {
        guard #available(macOS 14.2, *) else { return }

        for tapID in objectIDs(kAudioHardwarePropertyTapList, objectID: AudioObjectID(kAudioObjectSystemObject)) {
            guard let description = tapDescription(tapID) else { continue }
            if description.name.localizedCaseInsensitiveContains("SonicRouter") {
                AudioHardwareDestroyProcessTap(tapID)
            }
        }
    }

    private static func destroyOwnedAggregates() {
        for deviceID in objectIDs(kAudioHardwarePropertyDevices, objectID: AudioObjectID(kAudioObjectSystemObject)) {
            guard classID(deviceID) == kAudioAggregateDeviceClassID else { continue }

            let name = stringProperty(kAudioObjectPropertyName, objectID: deviceID)
            let uid = stringProperty(kAudioDevicePropertyDeviceUID, objectID: deviceID)
            if name.localizedCaseInsensitiveContains("SonicRouter") || uid.hasPrefix("local.sonicrouter.agg.") {
                AudioHardwareDestroyAggregateDevice(deviceID)
            }
        }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objectIDs(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) -> [AudioObjectID] {
        var propertyAddress = address(selector)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }

        var ids = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, buffer.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    private static func classID(_ objectID: AudioObjectID) -> AudioClassID {
        var propertyAddress = address(kAudioObjectPropertyClass)
        var value: AudioClassID = 0
        var dataSize = UInt32(MemoryLayout<AudioClassID>.size)
        let status = AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, &value)
        return status == noErr ? value : 0
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> String {
        var propertyAddress = address(selector)
        guard AudioObjectHasProperty(objectID, &propertyAddress) else { return "" }

        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return "" }
        return value.takeUnretainedValue() as String
    }

    private static func tapDescription(_ tapID: AudioObjectID) -> CATapDescription? {
        var propertyAddress = address(kAudioTapPropertyDescription)
        guard AudioObjectHasProperty(tapID, &propertyAddress) else { return nil }

        var value: Unmanaged<CATapDescription>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(tapID, &propertyAddress, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue()
    }
}

// MARK: - Volume curve

/// Maps the 0–1 slider position to the linear gain applied to samples.
/// Hearing is roughly logarithmic: with a straight linear gain, 50% on the
/// slider sounds like "a bit quieter" and almost all the audible change is
/// crammed into the bottom quarter. A squared taper makes the slider feel
/// proportional — 50% sounds close to half as loud.
enum VolumeCurve {
    static func gain(forSlider value: Double) -> Float {
        let clamped = min(1, max(0, value))
        return Float(clamped * clamped)
    }
}

// MARK: - Gain box

/// Holds the current gain so the realtime IO block can read it lock-free.
/// A 32-bit aligned float is read/written atomically on Apple silicon, so a
/// plain property is safe here; `@unchecked Sendable` lets it cross into the block.
final class GainBox: @unchecked Sendable {
    var gain: Float
    /// Makeup gain that lifts the re-emitted signal back up to the app's original
    /// loudness (the capture→re-emit path comes out quieter). Live-adjustable.
    var makeup: Float
    init(_ gain: Float, makeup: Float = 1) {
        self.gain = gain
        self.makeup = makeup
    }
}

// MARK: - Permission

enum AudioCapturePermission {
    /// Creates and immediately destroys a private, *unmuted* global tap. On first
    /// run this triggers the system-audio-capture TCC prompt; afterwards it simply
    /// reports whether permission is granted. Unmuted means no audio is affected.
    static func probe() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "SonicRouter permission check"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else { return false }
        AudioHardwareDestroyProcessTap(tapID)
        return true
    }
}

// MARK: - Realtime stereo copy

/// Copies an app's tapped audio into the output device buffers, scaled by gain.
/// Handles interleaved and planar Float32 layouts so it works across output
/// devices. The fast path (matching layouts) does a straight vDSP scale with no
/// allocation; the fallback downmixes to L/R for mismatched layouts.
enum StereoRender {
    static func copy(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gain: Float
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard gain > 0, !inList.isEmpty else { return }

        if fastCopy(inList: inList, outList: outList, gain: gain) {
            clampOutputs(outList)
            return
        }

        var frames = 0
        for buffer in inList {
            let channels = max(1, Int(buffer.mNumberChannels))
            frames = max(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.stride * channels))
        }
        frames = min(frames, 8192)
        guard frames > 0 else { return }

        withUnsafeTemporaryAllocation(of: Float.self, capacity: frames * 2) { scratch in
            scratch.update(repeating: 0)
            let left = scratch.baseAddress!
            let right = left + frames
            extract(from: inList, frames: frames, left: left, right: right)

            var scalar = gain
            vDSP_vsmul(left, 1, &scalar, left, 1, vDSP_Length(frames))
            vDSP_vsmul(right, 1, &scalar, right, 1, vDSP_Length(frames))

            write(to: outList, frames: frames, left: left, right: right)
        }
        clampOutputs(outList)
    }

    /// Hard-limit output to [-1, 1] so the makeup gain can lift quiet re-emission
    /// up to the original level without letting loud peaks clip into distortion.
    private static func clampOutputs(_ outList: UnsafeMutableAudioBufferListPointer) {
        var low: Float = -1
        var high: Float = 1
        for buffer in outList {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            guard count > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            vDSP_vclip(samples, 1, &low, &high, samples, 1, vDSP_Length(count))
        }
    }

    /// Straight scaled copy when input and output share the same buffer layout.
    private static func fastCopy(
        inList: UnsafeMutableAudioBufferListPointer,
        outList: UnsafeMutableAudioBufferListPointer,
        gain: Float
    ) -> Bool {
        guard inList.count == outList.count else { return false }
        for index in 0..<outList.count where inList[index].mNumberChannels != outList[index].mNumberChannels {
            return false
        }

        var scalar = gain
        for index in 0..<outList.count {
            guard let inData = inList[index].mData, let outData = outList[index].mData else { continue }
            let count = min(Int(inList[index].mDataByteSize), Int(outList[index].mDataByteSize)) / MemoryLayout<Float>.stride
            guard count > 0 else { continue }
            vDSP_vsmul(
                inData.assumingMemoryBound(to: Float.self), 1,
                &scalar,
                outData.assumingMemoryBound(to: Float.self), 1,
                vDSP_Length(count)
            )
        }
        return true
    }

    private static func extract(
        from list: UnsafeMutableAudioBufferListPointer,
        frames: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        var channelIndex = 0
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = data.assumingMemoryBound(to: Float.self)
            let bufferFrames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.stride * channels))
            for channel in 0..<channels {
                let destination: UnsafeMutablePointer<Float>?
                switch channelIndex + channel {
                case 0: destination = left
                case 1: destination = right
                default: destination = nil
                }
                if let destination {
                    for frame in 0..<bufferFrames {
                        destination[frame] = samples[frame * channels + channel]
                    }
                }
            }
            channelIndex += channels
        }
        if channelIndex == 1 {
            for frame in 0..<frames { right[frame] = left[frame] }
        }
    }

    private static func write(
        to list: UnsafeMutableAudioBufferListPointer,
        frames: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        var channelIndex = 0
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = data.assumingMemoryBound(to: Float.self)
            let bufferFrames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.stride * channels))
            for channel in 0..<channels {
                let source = (channelIndex + channel) == 1 ? right : left
                for frame in 0..<bufferFrames {
                    samples[frame * channels + channel] = source[frame]
                }
            }
            channelIndex += channels
        }
    }
}

// MARK: - Aggregate helpers shared by both engines

private enum TapAggregate {
    static func tapUID(_ tapID: AudioObjectID, fallback: UUID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(tapID, &propertyAddress) else { return fallback.uuidString }

        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(tapID, &propertyAddress, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return fallback.uuidString }
        return value.takeUnretainedValue() as String
    }

    static func composition(name: String, uid: String, outputUID: String, tapUID: String) -> CFDictionary {
        [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]]
        ] as CFDictionary
    }
}

// MARK: - Mute engine

/// Mutes one app group. A `.mutedWhenTapped` tap only silences an app while it
/// is actively read, so the tap must live inside a running aggregate device with
/// an IOProc pulling it. This engine builds that private aggregate and runs an
/// IOProc that discards the tapped audio and emits silence — immediate, no
/// latency, and audio returns the instant the engine stops.
final class MuteEngine {
    let processObjectIDs: [AudioObjectID]
    let name: String
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(processObjectIDs: [AudioObjectID], name: String) {
        self.processObjectIDs = processObjectIDs
        self.name = name
    }

    deinit { invalidate() }

    func activate(outputUID: String, outputDeviceID: AudioObjectID) throws {
        let uuid = UUID()
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = uuid
        description.name = "SonicRouter mute · \(name)"
        description.isPrivate = true
        description.isExclusive = false
        description.isMixdown = true
        description.muteBehavior = .mutedWhenTapped

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
            throw TapError.coreAudio("crear el tap de mute", tapStatus)
        }
        tapID = newTap

        let composition = TapAggregate.composition(
            name: "SonicRouter Mute \(name)",
            uid: "local.sonicrouter.agg.mute.\(uuid.uuidString)",
            outputUID: outputUID,
            tapUID: TapAggregate.tapUID(tapID, fallback: uuid)
        )

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(composition, &newAggregate)
        guard aggStatus == noErr, newAggregate != kAudioObjectUnknown else {
            invalidate()
            throw TapError.coreAudio("crear el dispositivo de mute", aggStatus)
        }
        aggregateID = newAggregate

        let ioBlock: AudioDeviceIOBlock = { _, _, _, outputData, _ in
            let outList = UnsafeMutableAudioBufferListPointer(outputData)
            for buffer in outList {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil, ioBlock)
        guard procStatus == noErr, let newProcID else {
            invalidate()
            throw TapError.coreAudio("preparar el mute", procStatus)
        }
        ioProcID = newProcID

        let startStatus = AudioDeviceStart(aggregateID, newProcID)
        guard startStatus == noErr else {
            invalidate()
            throw TapError.coreAudio("arrancar el mute", startStatus)
        }
        tapLog.debug("Mute engine active for \(self.name, privacy: .public)")
    }

    func invalidate() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }
}

// MARK: - Volume engine

/// Per-app volume. Same private aggregate as the mute engine (real output device
/// as clock + the app's `.mutedWhenTapped` tap), but the single IOProc re-emits
/// the captured audio scaled by gain instead of discarding it. One clock domain,
/// one IOProc — no ring buffer or drift, so the only added cost is a couple of
/// milliseconds of latency on that one app.
final class AppVolumeTap {
    let pid: pid_t
    let processObjectIDs: [AudioObjectID]
    let gainBox: GainBox
    private(set) var outputUID: String
    private let outputDeviceID: AudioObjectID

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(pid: pid_t, processObjectIDs: [AudioObjectID], gain: Float, makeup: Float, outputUID: String, outputDeviceID: AudioObjectID) {
        self.pid = pid
        self.processObjectIDs = processObjectIDs
        self.gainBox = GainBox(max(0, min(1, gain)), makeup: max(0.5, min(8, makeup)))
        self.outputUID = outputUID
        self.outputDeviceID = outputDeviceID
    }

    deinit { invalidate() }

    var gain: Float {
        get { gainBox.gain }
        set { gainBox.gain = max(0, min(1, newValue)) }
    }

    var makeup: Float {
        get { gainBox.makeup }
        set { gainBox.makeup = max(0.5, min(8, newValue)) }
    }

    func activate() throws {
        let uuid = UUID()
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = uuid
        description.name = "SonicRouter volume · \(pid)"
        description.isPrivate = true
        description.isExclusive = false
        description.isMixdown = true
        description.muteBehavior = .mutedWhenTapped

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
            throw TapError.coreAudio("crear el tap de volumen", tapStatus)
        }
        tapID = newTap

        let composition = TapAggregate.composition(
            name: "SonicRouter Volume \(pid)",
            uid: "local.sonicrouter.agg.vol.\(uuid.uuidString)",
            outputUID: outputUID,
            tapUID: TapAggregate.tapUID(tapID, fallback: uuid)
        )

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(composition, &newAggregate)
        guard aggStatus == noErr, newAggregate != kAudioObjectUnknown else {
            invalidate()
            throw TapError.coreAudio("crear el dispositivo de volumen", aggStatus)
        }
        aggregateID = newAggregate

        let box = gainBox
        let ioBlock: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            StereoRender.copy(input: inputData, output: outputData, gain: box.gain * box.makeup)
        }

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil, ioBlock)
        guard procStatus == noErr, let newProcID else {
            invalidate()
            throw TapError.coreAudio("preparar el volumen", procStatus)
        }
        ioProcID = newProcID

        let startStatus = AudioDeviceStart(aggregateID, newProcID)
        guard startStatus == noErr else {
            invalidate()
            throw TapError.coreAudio("arrancar el volumen", startStatus)
        }
        tapLog.debug("Volume engine active for pid \(self.pid) at gain \(self.gain)")
    }

    func invalidate() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }
}
