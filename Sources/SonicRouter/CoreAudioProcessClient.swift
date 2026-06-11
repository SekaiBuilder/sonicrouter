import AppKit
import CoreAudio
import Foundation

enum CoreAudioProcessClient {
    static func audioProcesses() -> [CoreAudioProcessInfo] {
        objectIDs(
            selector: kAudioHardwarePropertyProcessObjectList,
            objectID: AudioObjectID(kAudioObjectSystemObject)
        )
        .compactMap(processInfo(for:))
    }

    static func runningOutputProcessByPID() -> [pid_t: CoreAudioProcessInfo] {
        audioProcesses()
            .filter(\.isRunningOutput)
            .reduce(into: [pid_t: CoreAudioProcessInfo]()) { result, process in
                result[process.processIdentifier] = process
            }
    }

    /// Every process that owns a CoreAudio audio object, keyed by PID — including
    /// ones that are momentarily silent. Used to keep per-app taps alive while the
    /// app still holds audio, and to tear them down only when it really goes away.
    static func allProcessesByPID() -> [pid_t: CoreAudioProcessInfo] {
        audioProcesses()
            .reduce(into: [pid_t: CoreAudioProcessInfo]()) { result, process in
                result[process.processIdentifier] = process
            }
    }

    static func deviceNames(for ids: [AudioObjectID]) -> [String] {
        ids.map { stringProperty(kAudioObjectPropertyName, objectID: $0, retained: false) }
            .filter { !$0.isEmpty }
    }
}

private extension CoreAudioProcessClient {
    static func processInfo(for objectID: AudioObjectID) -> CoreAudioProcessInfo? {
        guard let pid = pid(for: objectID), pid > 0 else { return nil }

        return CoreAudioProcessInfo(
            objectID: objectID,
            processIdentifier: pid,
            bundleIdentifier: stringProperty(kAudioProcessPropertyBundleID, objectID: objectID, retained: true),
            isRunningInput: boolProperty(kAudioProcessPropertyIsRunningInput, objectID: objectID),
            isRunningOutput: boolProperty(kAudioProcessPropertyIsRunningOutput, objectID: objectID),
            outputDeviceIDs: objectIDs(
                selector: kAudioProcessPropertyDevices,
                objectID: objectID,
                scope: kAudioDevicePropertyScopeOutput
            )
        )
    }

    static func address(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func objectIDs(
        selector: AudioObjectPropertySelector,
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var propertyAddress = address(selector: selector, scope: scope)
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let dataStatus = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard dataStatus == noErr else { return [] }
        return ids.filter { $0 != kAudioObjectUnknown }
    }

    static func pid(for objectID: AudioObjectID) -> pid_t? {
        var propertyAddress = address(selector: kAudioProcessPropertyPID)
        guard AudioObjectHasProperty(objectID, &propertyAddress) else { return nil }

        var pid: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, &pid)
        return status == noErr ? pid : nil
    }

    static func boolProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> Bool {
        var propertyAddress = address(selector: selector)
        guard AudioObjectHasProperty(objectID, &propertyAddress) else { return false }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, &value)
        return status == noErr && value != 0
    }

    static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID,
        retained: Bool
    ) -> String {
        var propertyAddress = address(selector: selector)
        guard AudioObjectHasProperty(objectID, &propertyAddress) else { return "" }

        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return "" }
        return (retained ? value.takeRetainedValue() : value.takeUnretainedValue()) as String
    }
}
