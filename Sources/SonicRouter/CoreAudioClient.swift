import Foundation
import CoreAudio
import AudioToolbox

enum CoreAudioClient {
    static func devices() -> [AudioDevice] {
        let ids = objectIDs(
            selector: kAudioHardwarePropertyDevices,
            objectID: AudioObjectID(kAudioObjectSystemObject)
        )
        let defaultOutput = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let defaultInput = defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        let defaultSystemOutput = defaultDevice(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)

        return ids.compactMap { id in
            let hasOutput = streamCount(for: id, scope: kAudioDevicePropertyScopeOutput) > 0
            let hasInput = streamCount(for: id, scope: kAudioDevicePropertyScopeInput) > 0

            guard hasOutput || hasInput else { return nil }

            return AudioDevice(
                id: id,
                name: stringProperty(kAudioObjectPropertyName, objectID: id),
                uid: stringProperty(kAudioDevicePropertyDeviceUID, objectID: id),
                hasInput: hasInput,
                hasOutput: hasOutput,
                outputVolume: hasOutput ? volume(for: id, scope: kAudioDevicePropertyScopeOutput) : nil,
                inputVolume: hasInput ? volume(for: id, scope: kAudioDevicePropertyScopeInput) : nil,
                isDefaultOutput: id == defaultOutput,
                isDefaultInput: id == defaultInput,
                isDefaultSystemOutput: id == defaultSystemOutput
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefaultOutput != rhs.isDefaultOutput {
                return lhs.isDefaultOutput
            }
            if lhs.hasOutput != rhs.hasOutput {
                return lhs.hasOutput
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func setDefaultOutput(_ deviceID: AudioObjectID) throws {
        try setDefaultDevice(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try setDefaultDevice(deviceID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    static func setDefaultInput(_ deviceID: AudioObjectID) throws {
        try setDefaultDevice(deviceID, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    static func setOutputVolume(_ volume: Double, for deviceID: AudioObjectID) throws {
        try setVolume(volume, for: deviceID, scope: kAudioDevicePropertyScopeOutput, allowsVirtualMain: true)
    }

    static func setInputVolume(_ volume: Double, for deviceID: AudioObjectID) throws {
        try setVolume(volume, for: deviceID, scope: kAudioDevicePropertyScopeInput, allowsVirtualMain: false)
    }

    /// UID of the current default output device. Needed to build the private
    /// aggregate device that re-emits a tapped app's audio.
    static func defaultOutputDeviceUID() -> String? {
        let id = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard id != 0 else { return nil }
        let uid = stringProperty(kAudioDevicePropertyDeviceUID, objectID: id)
        return uid.isEmpty ? nil : uid
    }

    /// AudioObjectID of the current default output device. Needed to install
    /// the playback IOProc that mixes scaled app audio back into the real output.
    static func defaultOutputDeviceID() -> AudioObjectID? {
        let id = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        return id == 0 ? nil : id
    }
}

private extension CoreAudioClient {
    static func address(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func objectIDs(selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> [AudioObjectID] {
        var propertyAddress = address(selector: selector)
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let dataStatus = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard dataStatus == noErr else { return [] }
        return ids
    }

    static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioObjectID {
        var propertyAddress = address(selector: selector)
        var deviceID: AudioObjectID = 0
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    static func setDefaultDevice(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) throws {
        var propertyAddress = address(selector: selector)
        var mutableDeviceID = deviceID
        let dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            dataSize,
            &mutableDeviceID
        )
        try throwIfNeeded(status, action: "cambiar el dispositivo predeterminado")
    }

    static func streamCount(for deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var propertyAddress = address(selector: kAudioDevicePropertyStreamConfiguration, scope: scope)
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPointer.deallocate() }

        let dataStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, rawPointer)
        guard dataStatus == noErr else { return 0 }

        let bufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { total, buffer in
            total + Int(buffer.mNumberChannels)
        }
    }

    static func stringProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> String {
        var propertyAddress = address(selector: selector)
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return "Audio Device \(objectID)" }
        return value.takeUnretainedValue() as String
    }

    static func volume(for deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Double? {
        if scope == kAudioDevicePropertyScopeOutput,
           let virtualMain = virtualMainVolume(for: deviceID) {
            return virtualMain
        }

        if let master = scalarVolume(for: deviceID, scope: scope, element: kAudioObjectPropertyElementMain) {
            return master
        }

        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
        let values = channels.compactMap { scalarVolume(for: deviceID, scope: scope, element: $0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func scalarVolume(
        for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Double? {
        var propertyAddress = address(selector: kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return nil }

        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &volume)
        guard status == noErr else { return nil }
        return Double(volume)
    }

    static func setVolume(
        _ volume: Double,
        for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        allowsVirtualMain: Bool
    ) throws {
        let clampedVolume = Float32(max(0, min(1, volume)))
        if allowsVirtualMain, try setVirtualMainVolume(clampedVolume, for: deviceID) {
            return
        }

        if try setScalarVolume(clampedVolume, for: deviceID, scope: scope, element: kAudioObjectPropertyElementMain) {
            return
        }

        var didSetChannel = false
        for channel in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            didSetChannel = try setScalarVolume(clampedVolume, for: deviceID, scope: scope, element: channel) || didSetChannel
        }

        if !didSetChannel {
            throw AudioControlError.operationFailed("Este dispositivo no expone control de volumen por software.")
        }
    }

    static func setScalarVolume(
        _ volume: Float32,
        for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) throws -> Bool {
        var propertyAddress = address(selector: kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return false }

        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &propertyAddress, &isSettable)
        guard settableStatus == noErr, isSettable.boolValue else { return false }

        var mutableVolume = volume
        let dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, dataSize, &mutableVolume)
        try throwIfNeeded(status, action: "cambiar volumen")
        return true
    }

    static func virtualMainVolume(for deviceID: AudioObjectID) -> Double? {
        var propertyAddress = address(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return nil }

        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &volume)
        guard status == noErr else { return nil }
        return Double(volume)
    }

    static func setVirtualMainVolume(_ volume: Float32, for deviceID: AudioObjectID) throws -> Bool {
        var propertyAddress = address(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return false }

        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &propertyAddress, &isSettable)
        guard settableStatus == noErr, isSettable.boolValue else { return false }

        var mutableVolume = volume
        let dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, dataSize, &mutableVolume)
        try throwIfNeeded(status, action: "cambiar volumen principal")
        return true
    }

    static func throwIfNeeded(_ status: OSStatus, action: String) throws {
        guard status != noErr else { return }
        throw AudioControlError.operationFailed("No se pudo \(action). CoreAudio devolvió \(fourCharacterCode(status)).")
    }

    static func fourCharacterCode(_ status: OSStatus) -> String {
        let unsigned = UInt32(bitPattern: status)
        let chars = [
            UInt8((unsigned >> 24) & 0xff),
            UInt8((unsigned >> 16) & 0xff),
            UInt8((unsigned >> 8) & 0xff),
            UInt8(unsigned & 0xff)
        ]

        if chars.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return "'\(String(bytes: chars, encoding: .macOSRoman) ?? "\(status)")'"
        }
        return "\(status)"
    }
}

enum AudioControlError: LocalizedError {
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let message):
            return message
        }
    }
}
