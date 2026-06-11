import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let uid: String
    let hasInput: Bool
    let hasOutput: Bool
    var outputVolume: Double?
    var inputVolume: Double?
    var isDefaultOutput: Bool
    var isDefaultInput: Bool
    var isDefaultSystemOutput: Bool
}

struct AppAudioSession: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    var audioProcessID: AudioObjectID?
    var audioProcessIDs: [AudioObjectID]
    var activeAudioProcessIDs: [AudioObjectID]
    var isProducingAudio: Bool
    var isCapturable: Bool
    var isMuted: Bool
    var outputDeviceNames: [String]
    var desiredVolume: Double
    var desiredOutputUID: String?
    var isControllable: Bool
    var supportsVolumeControl: Bool
    /// True while the re-emit volume engine is running for this app, even at
    /// 100%: the tap stays alive so moving the slider never switches between
    /// the native path and the re-emit path (no volume jump at 100 ↔ 99).
    var isVolumeEngaged: Bool
}

struct CoreAudioProcessInfo: Hashable {
    let objectID: AudioObjectID
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool
    let outputDeviceIDs: [AudioObjectID]
}

struct AudioRouteProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var appName: String
    var bundleIdentifier: String?
    var outputDeviceUID: String?
    var volume: Double
}
