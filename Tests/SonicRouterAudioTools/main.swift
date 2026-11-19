// SonicRouterAudioTools — read-only Core Audio checks for sessions in front of
// the Mac (CAM-002-A17, DEV-01). Creates nothing and needs no permission.
//
//   swift run SonicRouterAudioTools objects            list SonicRouter's audio objects
//   swift run SonicRouterAudioTools objects --json     same, as JSON (for diffs)
//   swift run SonicRouterAudioTools orphans            fail if any remain while
//                                                      SonicRouter is not running
//
// Private taps and aggregates belong to the process that made them and other
// processes cannot see them, so from outside only public objects show up:
// the multi-output device (public on purpose, DEV-01) and anything that leaked
// as public. The leftovers of a `kill -9` are checked by SonicRouter itself at
// launch; this tool proves that nothing public stays behind.

import AppKit
import CoreAudio
import Foundation

struct AudioObjectEntry: Codable {
    let kind: String
    let id: UInt32
    let name: String
    let uid: String
    let isPrivate: Bool?
    let isStacked: Bool?
    let expectedToPersist: Bool
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)
let multiOutputUID = "local.sonicrouter.multioutput"

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func objectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var propertyAddress = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &propertyAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &propertyAddress, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func string(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var propertyAddress = address(selector)
    guard AudioObjectHasProperty(objectID, &propertyAddress) else { return "" }
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &value) == noErr, let value else { return "" }
    return value.takeRetainedValue() as String
}

func uint32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var propertyAddress = address(selector)
    guard AudioObjectHasProperty(objectID, &propertyAddress) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &value) == noErr ? value : nil
}

func isSonicRouter(name: String, uid: String) -> Bool {
    name.lowercased().hasPrefix("sonicrouter") || uid.hasPrefix("local.sonicrouter.")
}

func sonicRouterObjects() -> [AudioObjectEntry] {
    var entries: [AudioObjectEntry] = []
    for device in objectList(kAudioHardwarePropertyDevices) where uint32(device, kAudioObjectPropertyClass) == kAudioAggregateDeviceClassID {
        let name = string(device, kAudioObjectPropertyName)
        let uid = string(device, kAudioDevicePropertyDeviceUID)
        guard isSonicRouter(name: name, uid: uid) else { continue }
        var composition: Unmanaged<CFDictionary>?
        var propertyAddress = address(kAudioAggregateDevicePropertyComposition)
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        var isPrivate: Bool?
        var isStacked: Bool?
        if AudioObjectGetPropertyData(device, &propertyAddress, 0, nil, &size, &composition) == noErr,
            let dictionary = composition?.takeRetainedValue() as? [String: Any]
        {
            isPrivate = (dictionary[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue
            isStacked = (dictionary[kAudioAggregateDeviceIsStackedKey] as? NSNumber)?.boolValue
        }
        entries.append(
            AudioObjectEntry(
                kind: "aggregate", id: device, name: name, uid: uid, isPrivate: isPrivate, isStacked: isStacked,
                expectedToPersist: uid == multiOutputUID))
    }
    for tap in objectList(kAudioHardwarePropertyTapList) {
        let uid = string(tap, kAudioTapPropertyUID)
        var description: Unmanaged<CATapDescription>?
        var propertyAddress = address(kAudioTapPropertyDescription)
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        var name = ""
        var isPrivate: Bool?
        if AudioObjectGetPropertyData(tap, &propertyAddress, 0, nil, &size, &description) == noErr, let value = description {
            let tapDescription = value.takeRetainedValue()
            name = tapDescription.name
            isPrivate = tapDescription.isPrivate
        }
        guard isSonicRouter(name: name, uid: uid) else { continue }
        entries.append(
            AudioObjectEntry(kind: "tap", id: tap, name: name, uid: uid, isPrivate: isPrivate, isStacked: nil, expectedToPersist: false))
    }
    return entries
}

func sonicRouterIsRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "local.sonicrouter.app" }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let objects = sonicRouterObjects()
switch arguments.first {
case "objects":
    if arguments.contains("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(objects), as: UTF8.self))
    } else if objects.isEmpty {
        print("Ningún objeto de audio de SonicRouter visible.")
    } else {
        for object in objects {
            let flags = [
                object.isPrivate.map { $0 ? "privado" : "público" },
                object.isStacked.map { $0 ? "apilado" : nil } ?? nil,
                object.expectedToPersist ? "persiste a propósito (multi-salida)" : nil,
            ].compactMap { $0 }.joined(separator: ", ")
            print("\(object.kind) \(object.id)  \(object.name)  \(object.uid)  \(flags)")
        }
    }
case "orphans":
    let running = sonicRouterIsRunning()
    let leftovers = objects.filter { !$0.expectedToPersist }
    print("SonicRouter \(running ? "en marcha" : "cerrado"); objetos visibles: \(objects.count), inesperados: \(leftovers.count).")
    for object in objects {
        print("  \(object.kind) \(object.name) \(object.uid)\(object.expectedToPersist ? " (multi-salida, DEV-01-B01)" : "")")
    }
    if !running && !leftovers.isEmpty {
        print("RESULTADO: FALLA, quedan objetos de SonicRouter con la app cerrada (CAM-002-A17).")
        exit(1)
    }
    print(running ? "RESULTADO: cierra SonicRouter (o haz kill -9) y vuelve a ejecutar." : "RESULTADO: PASA, sin objetos huérfanos.")
default:
    print("Uso: SonicRouterAudioTools objects [--json] | orphans")
    exit(2)
}
