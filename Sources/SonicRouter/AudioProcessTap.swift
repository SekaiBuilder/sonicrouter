import AudioToolbox
import CoreAudio
import Foundation
import OSLog
import Synchronization
import SonicRouterCore

private let tapLog = Logger(subsystem: "local.sonicrouter.app", category: "ProcessTap")

// MARK: - Errors

enum TapError: LocalizedError {
    case coreAudio(TapAction, OSStatus)
    /// The tap or output format is one `StereoRender` cannot copy verbatim;
    /// the engine stays off and the app keeps its native path (CAM-001-R05).
    case unsupportedFormat(RenderFormatCheck.Problem)

    var errorDescription: String? {
        switch self {
        case let .coreAudio(action, status):
            let code = FourCC.string(status)
            return L10n.text(
                "No se pudo \(action.spanish). CoreAudio devolvió \(code).",
                "Could not \(action.english). CoreAudio returned \(code).",
                "\(action.japanese)できませんでした。CoreAudioの応答: \(code)"
            )
        case .unsupportedFormat:
            return L10n.text(
                "Formato de audio no admitido: la app sigue sonando por su salida normal, sin control.",
                "Unsupported audio format: the app keeps playing on its normal output, without control.",
                "対応していない音声フォーマットです。アプリは通常の出力で再生を続けます（制御なし）。"
            )
        }
    }
}

/// The activation step that failed, so the error can be phrased in the user's
/// language instead of carrying a fixed Spanish string.
enum TapAction {
    case createMuteTap, createMuteDevice, prepareMute, startMute
    case createVolumeTap, createVolumeDevice, prepareVolume, startVolume

    var spanish: String {
        switch self {
        case .createMuteTap: "crear el tap de mute"
        case .createMuteDevice: "crear el dispositivo de mute"
        case .prepareMute: "preparar el mute"
        case .startMute: "arrancar el mute"
        case .createVolumeTap: "crear el tap de volumen"
        case .createVolumeDevice: "crear el dispositivo de volumen"
        case .prepareVolume: "preparar el volumen"
        case .startVolume: "arrancar el volumen"
        }
    }

    var english: String {
        switch self {
        case .createMuteTap: "create the mute tap"
        case .createMuteDevice: "create the mute device"
        case .prepareMute: "prepare the mute"
        case .startMute: "start the mute"
        case .createVolumeTap: "create the volume tap"
        case .createVolumeDevice: "create the volume device"
        case .prepareVolume: "prepare the volume control"
        case .startVolume: "start the volume control"
        }
    }

    var japanese: String {
        switch self {
        case .createMuteTap: "ミュート用タップを作成"
        case .createMuteDevice: "ミュート用デバイスを作成"
        case .prepareMute: "ミュートを準備"
        case .startMute: "ミュートを開始"
        case .createVolumeTap: "音量用タップを作成"
        case .createVolumeDevice: "音量用デバイスを作成"
        case .prepareVolume: "音量制御を準備"
        case .startVolume: "音量制御を開始"
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

    /// `outputs` are physical devices; the first one is the clock and every
    /// other one follows it with drift compensation. Compensation runs at
    /// maximum quality: the default resampler is audibly dull ("filtered").
    static func composition(
        name: String,
        uid: String,
        outputs: [PhysicalOutput],
        tapUID: String,
        tapDriftCompensation: Bool = false
    ) -> CFDictionary {
        let maxQuality = kAudioAggregateDriftCompensationMaxQuality
        let subDevices: [[String: Any]] = outputs.enumerated().map { index, output in
            index == 0
                ? [kAudioSubDeviceUIDKey: output.uid]
                : [
                    kAudioSubDeviceUIDKey: output.uid,
                    kAudioSubDeviceDriftCompensationKey: 1,
                    kAudioSubDeviceDriftCompensationQualityKey: maxQuality
                ]
        }
        let tap: [String: Any] = tapDriftCompensation
            ? [
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapDriftCompensationQualityKey: maxQuality
            ]
            : [kAudioSubTapUIDKey: tapUID]
        return [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: outputs.first?.uid ?? "",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [tap]
        ] as CFDictionary
    }

    struct PhysicalOutput {
        let uid: String
        let id: AudioObjectID
    }

    /// Aggregates cannot contain aggregates, so a multi-output device (ours or
    /// one from Audio MIDI Setup) is expanded into the devices it plays on.
    static func physicalOutputs(uid: String, id: AudioObjectID) -> [PhysicalOutput] {
        guard classID(id) == kAudioAggregateDeviceClassID else { return [PhysicalOutput(uid: uid, id: id)] }
        let members = objectIDs(kAudioAggregateDevicePropertyActiveSubDeviceList, objectID: id)
            .compactMap { memberID -> PhysicalOutput? in
                let memberUID = stringProperty(kAudioDevicePropertyDeviceUID, objectID: memberID)
                guard !memberUID.isEmpty, outputChannelCount(memberID) > 0 else { return nil }
                return PhysicalOutput(uid: memberUID, id: memberID)
            }
        return members.isEmpty ? [PhysicalOutput(uid: uid, id: id)] : members
    }

    static func outputChannelCount(_ deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Runs every output at the rate the app already plays at (the system
    /// output's), when the device supports it, so the tapped audio reaches
    /// the speakers without sample-rate conversion — only clock drift is
    /// corrected. The aggregate follows its clock device.
    static func alignSampleRates(aggregateID: AudioObjectID, outputs: [PhysicalOutput]) {
        if let sourceRate = systemOutputSampleRate() {
            for output in outputs where supports(sourceRate, deviceID: output.id) {
                if nominalSampleRate(output.id) != sourceRate {
                    setNominalSampleRate(sourceRate, on: output.id)
                }
            }
        }
        if let clock = outputs.first, let rate = nominalSampleRate(clock.id) {
            setNominalSampleRate(rate, on: aggregateID)
        }
    }

    private static func systemOutputSampleRate() -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return nominalSampleRate(deviceID)
    }

    private static func supports(_ rate: Float64, deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        let status = ranges.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr && ranges.contains { $0.mMinimum <= rate && rate <= $0.mMaximum }
    }

    private static func classID(_ objectID: AudioObjectID) -> AudioClassID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: AudioClassID = 0
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func objectIDs(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    /// Smaller IO buffers shorten the tap → output path. Clamped to the
    /// range the aggregate accepts.
    static func setBufferFrameSize(_ frames: UInt32, on deviceID: AudioObjectID) {
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        var value = frames
        if AudioObjectGetPropertyData(deviceID, &rangeAddress, 0, nil, &rangeSize, &range) == noErr {
            value = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(tapID, &address) else { return nil }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    /// The virtual format of each output stream, in IOProc buffer order, or
    /// nil when any of them cannot be read.
    static func outputStreamFormats(_ deviceID: AudioObjectID) -> [AudioStreamBasicDescription]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = streams.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { return nil }

        var formats: [AudioStreamBasicDescription] = []
        for stream in streams {
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &format) == noErr else { return nil }
            formats.append(format)
        }
        return formats
    }

    static func nominalSampleRate(_ deviceID: AudioObjectID) -> Float64? {
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
            throw TapError.coreAudio(.createMuteTap, tapStatus)
        }
        tapID = newTap

        // Mute emits silence, so its clock only needs one physical device.
        let clock = Array(TapAggregate.physicalOutputs(uid: outputUID, id: outputDeviceID).prefix(1))
        let composition = TapAggregate.composition(
            name: "SonicRouter Mute \(name)",
            uid: "local.sonicrouter.agg.mute.\(uuid.uuidString)",
            outputs: clock,
            tapUID: TapAggregate.tapUID(tapID, fallback: uuid)
        )

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(composition, &newAggregate)
        guard aggStatus == noErr, newAggregate != kAudioObjectUnknown else {
            invalidate()
            throw TapError.coreAudio(.createMuteDevice, aggStatus)
        }
        aggregateID = newAggregate
        TapAggregate.alignSampleRates(aggregateID: aggregateID, outputs: clock)

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
            throw TapError.coreAudio(.prepareMute, procStatus)
        }
        ioProcID = newProcID

        let startStatus = AudioDeviceStart(aggregateID, newProcID)
        guard startStatus == noErr else {
            invalidate()
            throw TapError.coreAudio(.startMute, startStatus)
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

/// Per-app volume, route and equalizer. The original process path is fully
/// muted, leaving exactly one audible copy: the signal re-emitted here. Drift
/// compensation stays enabled because the tap clock is not guaranteed to match
/// the output clock.
final class AppVolumeTap {
    let pid: pid_t
    let processObjectIDs: [AudioObjectID]
    private(set) var outputUID: String
    let outputDeviceID: AudioObjectID

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    /// C++ render state (`SonicRouterDSP`) that the C IOProc reads. Released
    /// only after the IOProc has been stopped and destroyed.
    private var renderer: RealtimeRenderer?
    private var storedGain: Float
    private var storedMakeup: Float
    private var storedEqualizer: AudioEqualizerSettings

    init(
        pid: pid_t,
        processObjectIDs: [AudioObjectID],
        gain: Float,
        makeup: Float,
        equalizer: AudioEqualizerSettings,
        outputUID: String,
        outputDeviceID: AudioObjectID
    ) {
        self.pid = pid
        self.processObjectIDs = processObjectIDs
        self.storedGain = max(0, min(1, gain))
        self.storedMakeup = max(0.5, min(8, makeup))
        self.storedEqualizer = equalizer
        self.outputUID = outputUID
        self.outputDeviceID = outputDeviceID
    }

    deinit { invalidate() }

    var gain: Float {
        get { storedGain }
        set {
            storedGain = max(0, min(1, newValue))
            renderer?.setGain(storedGain)
        }
    }

    var makeup: Float {
        get { storedMakeup }
        set {
            storedMakeup = max(0.5, min(8, newValue))
            renderer?.setMakeup(storedMakeup)
        }
    }

    /// Live-adjustable: the render thread glides to the new gains.
    var equalizer: AudioEqualizerSettings {
        get { storedEqualizer }
        set {
            storedEqualizer = newValue
            renderer?.setEqualizer(newValue)
        }
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
            throw TapError.coreAudio(.createVolumeTap, tapStatus)
        }
        tapID = newTap

        let outputs = TapAggregate.physicalOutputs(uid: outputUID, id: outputDeviceID)
        let composition = TapAggregate.composition(
            name: "SonicRouter Volume \(pid)",
            uid: "local.sonicrouter.agg.vol.\(uuid.uuidString)",
            outputs: outputs,
            tapUID: TapAggregate.tapUID(tapID, fallback: uuid),
            tapDriftCompensation: true
        )

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(composition, &newAggregate)
        guard aggStatus == noErr, newAggregate != kAudioObjectUnknown else {
            invalidate()
            throw TapError.coreAudio(.createVolumeDevice, aggStatus)
        }
        aggregateID = newAggregate
        TapAggregate.alignSampleRates(aggregateID: aggregateID, outputs: outputs)
        // 256 frames (~5 ms) cut the measured tap → speaker delay from ~66 ms
        // to ~50 ms; 128 gained only a few ms more at a higher CPU cost.
        TapAggregate.setBufferFrameSize(256, on: aggregateID)
        // The renderer copies raw Float32: refuse to start on anything else
        // rather than play it as noise. Destroying the tap gives the app its
        // native path back. A format that cannot be read is logged and allowed,
        // as before this check existed.
        if let tapFormat = TapAggregate.tapFormat(tapID),
           let outputFormats = TapAggregate.outputStreamFormats(aggregateID),
           let problem = RenderFormatCheck.problem(tap: tapFormat, outputs: outputFormats) {
            tapLog.error("Volume engine refused for pid \(self.pid): unsupported format \(String(describing: problem), privacy: .public)")
            logStreamFormats()
            invalidate()
            throw TapError.unsupportedFormat(problem)
        }
        let channelMap = OutputChannelMap(deviceChannelCounts: outputs.map { TapAggregate.outputChannelCount($0.id) })
        // The equalizer's filters are designed for the rate the IOProc runs at.
        let sampleRate = TapAggregate.nominalSampleRate(aggregateID)
            ?? TapAggregate.nominalSampleRate(outputDeviceID)
            ?? 48_000

        // The IOProc is a C function over C++ state: the render thread never
        // enters the Swift runtime (CAM-003).
        guard let renderer = RealtimeRenderer(
            sampleRate: sampleRate,
            gain: storedGain,
            makeup: storedMakeup,
            equalizer: storedEqualizer,
            channelMap: channelMap
        ) else {
            invalidate()
            throw TapError.coreAudio(.prepareVolume, kAudioHardwareUnspecifiedError)
        }
        self.renderer = renderer

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcID(aggregateID, RealtimeRenderer.ioProc, renderer.clientData, &newProcID)
        guard procStatus == noErr, let newProcID else {
            invalidate()
            throw TapError.coreAudio(.prepareVolume, procStatus)
        }
        ioProcID = newProcID

        let startStatus = AudioDeviceStart(aggregateID, newProcID)
        guard startStatus == noErr else {
            invalidate()
            throw TapError.coreAudio(.startVolume, startStatus)
        }
        tapLog.notice("Volume engine active for pid \(self.pid) on \(outputs.count) device(s) at \(sampleRate) Hz")
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
        // Only now, with the IOProc gone, may the C++ state it reads be freed.
        renderer = nil
    }
}
