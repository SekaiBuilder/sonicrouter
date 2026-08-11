import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import OSLog
import Synchronization

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
            if description.name.lowercased().hasPrefix("sonicrouter") {
                AudioHardwareDestroyProcessTap(tapID)
            }
        }
    }

    private static func destroyOwnedAggregates() {
        for deviceID in objectIDs(kAudioHardwarePropertyDevices, objectID: AudioObjectID(kAudioObjectSystemObject)) {
            guard classID(deviceID) == kAudioAggregateDeviceClassID else { continue }

            let name = stringProperty(kAudioObjectPropertyName, objectID: deviceID)
            let uid = stringProperty(kAudioDevicePropertyDeviceUID, objectID: deviceID)
            if name.lowercased().hasPrefix("sonicrouter") || uid.hasPrefix("local.sonicrouter.agg.") {
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

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
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
        return value.takeRetainedValue() as String
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

/// Maps the 0–1 slider position straight to the gain applied to samples (1:1).
/// A squared/perceptual taper made the slider feel unrealistic near the top
/// (99% sounded far too quiet), so the mapping stays linear like the original.
enum VolumeCurve {
    static func gain(forSlider value: Double) -> Float {
        Float(min(1, max(0, value)))
    }
}

// MARK: - Gain box

/// Holds realtime parameters as atomic Float bit patterns. The UI can update
/// them without racing the Core Audio callback and the callback never takes a
/// lock or allocates memory.
final class GainBox: Sendable {
    private let gainBits: Atomic<UInt32>
    private let makeupBits: Atomic<UInt32>

    var gain: Float {
        get { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// Makeup gain that lifts the re-emitted signal back up to the app's original
    /// loudness (the capture→re-emit path comes out quieter). Live-adjustable.
    var makeup: Float {
        get { Float(bitPattern: makeupBits.load(ordering: .relaxed)) }
        set { makeupBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    init(_ gain: Float, makeup: Float = 1) {
        gainBits = Atomic(gain.bitPattern)
        makeupBits = Atomic(makeup.bitPattern)
    }
}

/// Mutable only from one Core Audio render thread. Only engages for makeup
/// boosts above unity: gain reduction there is immediate and recovery is
/// smoothed so speech peaks do not turn into clipping or pumping. At or below
/// unity the slider value passes through exactly — the volume control must be
/// a transparent 1:1 attenuation, never an AGC.
final class RealtimeGainLimiter: @unchecked Sendable {
    private var appliedGain: Float

    init(initialGain: Float) {
        appliedGain = max(0, initialGain)
    }

    func gain(requestedGain: Float, inputPeak: Float) -> Float {
        let requested = max(0, requestedGain)
        guard requested > 1 else {
            appliedGain = requested
            return requested
        }

        let target = AudioGainPolicy.headroomLimitedGain(
            requestedGain: requested,
            inputPeak: inputPeak
        )
        if target < appliedGain {
            appliedGain = target
        } else {
            appliedGain += (target - appliedGain) * 0.08
        }
        appliedGain = min(appliedGain, requested)
        return appliedGain
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
        requestedGain: Float,
        limiter: RealtimeGainLimiter
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard requestedGain > 0, !inList.isEmpty else { return }
        // The peak scan only matters for makeup boosts; at or below unity the
        // limiter passes the requested gain through untouched.
        let gain = limiter.gain(
            requestedGain: requestedGain,
            inputPeak: requestedGain > 1 ? peakMagnitude(inList) : 0
        )
        guard gain > 0 else { return }

        if fastCopy(inList: inList, outList: outList, gain: gain) {
            return
        }

        copyStereoFallback(inList: inList, outList: outList, gain: gain)
    }

    private static func peakMagnitude(_ list: UnsafeMutableAudioBufferListPointer) -> Float {
        var peak: Float = 0
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            guard count > 0 else { continue }
            var bufferPeak: Float = 0
            vDSP_maxmgv(
                data.assumingMemoryBound(to: Float.self),
                1,
                &bufferPeak,
                vDSP_Length(count)
            )
            peak = max(peak, bufferPeak)
        }
        return peak
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

    /// Allocation-free fallback for devices whose tap/output buffer layouts do
    /// not match. Only the first two channels are emitted; extra output channels
    /// stay silent instead of receiving duplicated left-channel audio.
    private static func copyStereoFallback(
        inList: UnsafeMutableAudioBufferListPointer,
        outList: UnsafeMutableAudioBufferListPointer,
        gain: Float
    ) {
        let inputChannels = inList.reduce(0) { $0 + max(1, Int($1.mNumberChannels)) }
        guard inputChannels > 0 else { return }

        var outputChannel = 0
        for buffer in outList {
            guard let data = buffer.mData else {
                outputChannel += max(1, Int(buffer.mNumberChannels))
                continue
            }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.stride * channels)
            let samples = data.assumingMemoryBound(to: Float.self)

            for channel in 0..<channels {
                let absoluteChannel = outputChannel + channel
                guard absoluteChannel < 2 else { continue }
                let sourceChannel = absoluteChannel < inputChannels ? absoluteChannel : 0
                for frame in 0..<frames {
                    samples[frame * channels + channel] = sample(
                        from: inList,
                        channel: sourceChannel,
                        frame: frame
                    ) * gain
                }
            }
            outputChannel += channels
        }
    }

    private static func sample(
        from list: UnsafeMutableAudioBufferListPointer,
        channel requestedChannel: Int,
        frame: Int
    ) -> Float {
        var remainingChannel = requestedChannel
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            guard remainingChannel < channels else {
                remainingChannel -= channels
                continue
            }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.stride * channels)
            guard frame < frames else { return 0 }
            return data.assumingMemoryBound(to: Float.self)[frame * channels + remainingChannel]
        }
        return 0
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
        return value.takeRetainedValue() as String
    }

    static func composition(
        name: String,
        uid: String,
        outputUID: String,
        tapUID: String,
        tapDriftCompensation: Bool = false
    ) -> CFDictionary {
        [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                tapDriftCompensation
                    ? [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
                    : [kAudioSubTapUIDKey: tapUID]
            ]
        ] as CFDictionary
    }

    /// Pins the aggregate's sample rate to the real output device's rate so the
    /// tap is delivered at the same rate the IOProc writes out. A rate mismatch
    /// (more likely after a macOS update changed tap defaults) means the render
    /// copies frames that don't line up — heard as noise/choppiness. Matching the
    /// rate keeps the path a clean, sample-aligned attenuation with no resampling.
    static func matchSampleRate(aggregateID: AudioObjectID, to outputDeviceID: AudioObjectID) {
        guard let rate = nominalSampleRate(outputDeviceID) else { return }
        setNominalSampleRate(rate, on: aggregateID)
    }

    private static func nominalSampleRate(_ deviceID: AudioObjectID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    private static func setNominalSampleRate(_ rate: Float64, on deviceID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        var value = rate
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    }
}

// MARK: - Mute engine

/// Mutes one app group. The tap uses `.muted` so the original hardware path is
/// never audible while SonicRouter owns it. The aggregate keeps the tap active;
/// destroying the private tap restores native playback immediately.
final class MuteEngine {
    let processObjectIDs: [AudioObjectID]
    let name: String
    private(set) var outputUID: String?
    private(set) var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
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
        description.muteBehavior = .muted

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
        TapAggregate.matchSampleRate(aggregateID: aggregateID, to: outputDeviceID)

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
        self.outputUID = outputUID
        self.outputDeviceID = outputDeviceID
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
        outputUID = nil
        outputDeviceID = kAudioObjectUnknown
    }
}

// MARK: - Volume engine

/// Per-app volume. The original process path is fully muted, leaving exactly one
/// audible copy: the signal re-emitted here. Drift compensation stays enabled
/// because the tap clock is not guaranteed to match the output clock.
final class AppVolumeTap {
    let pid: pid_t
    let processObjectIDs: [AudioObjectID]
    let gainBox: GainBox
    private(set) var outputUID: String
    let outputDeviceID: AudioObjectID

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(
        pid: pid_t,
        processObjectIDs: [AudioObjectID],
        gain: Float,
        makeup: Float,
        outputUID: String,
        outputDeviceID: AudioObjectID
    ) {
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
        description.muteBehavior = .muted

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
            tapUID: TapAggregate.tapUID(tapID, fallback: uuid),
            tapDriftCompensation: true
        )

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(composition, &newAggregate)
        guard aggStatus == noErr, newAggregate != kAudioObjectUnknown else {
            invalidate()
            throw TapError.coreAudio("crear el dispositivo de volumen", aggStatus)
        }
        aggregateID = newAggregate
        TapAggregate.matchSampleRate(aggregateID: aggregateID, to: outputDeviceID)

        let box = gainBox
        let limiter = RealtimeGainLimiter(initialGain: box.gain * box.makeup)
        let ioBlock: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            StereoRender.copy(
                input: inputData,
                output: outputData,
                requestedGain: box.gain * box.makeup,
                limiter: limiter
            )
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
        logStreamFormats()
    }

    /// Diagnostic: logs the real audio formats so a format change (e.g. after a
    /// macOS update) shows up as a tap↔output mismatch the render path can't
    /// handle. Safe to call off the realtime thread.
    private func logStreamFormats() {
        logFormat("tap", objectID: tapID, selector: kAudioTapPropertyFormat, scope: kAudioObjectPropertyScopeGlobal)
        logFormat("output", objectID: aggregateID, selector: kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeOutput)
    }

    private func logFormat(
        _ label: String,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(objectID, &address) else {
            tapLog.notice("format[\(label, privacy: .public)] pid \(self.pid): sin propiedad")
            return
        }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            tapLog.notice("format[\(label, privacy: .public)] pid \(self.pid): error \(FourCC.string(status), privacy: .public)")
            return
        }
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        tapLog.notice("""
        format[\(label, privacy: .public)] pid \(self.pid): \
        \(asbd.mSampleRate, privacy: .public)Hz \(asbd.mChannelsPerFrame, privacy: .public)ch \
        \(asbd.mBitsPerChannel, privacy: .public)bit \(isFloat ? "float" : "int", privacy: .public) \
        \(interleaved ? "interleaved" : "planar", privacy: .public) \
        bytesPerFrame=\(asbd.mBytesPerFrame, privacy: .public)
        """)
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
