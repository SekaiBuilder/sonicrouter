import Foundation
import CoreAudio
import SonicRouterCore

typealias AudioRouteProfile = SonicRouterCore.AudioRouteProfile
typealias AudioControlIntent = SonicRouterCore.AudioControlIntent
typealias AudioProfileMatcher = SonicRouterCore.AudioProfileMatcher
typealias AudioGainPolicy = SonicRouterCore.AudioGainPolicy
typealias SonicRouterAudioIdentifiers = SonicRouterCore.SonicRouterAudioIdentifiers
typealias AudioEqualizerSettings = SonicRouterCore.AudioEqualizerSettings
typealias EqualizerBand = SonicRouterCore.EqualizerBand
typealias EqualizerParameters = SonicRouterCore.EqualizerParameters
typealias RealtimeEqualizer = SonicRouterCore.RealtimeEqualizer
typealias AudioProfileArchive = SonicRouterCore.AudioProfileArchive
typealias AudioProfileArchiveError = SonicRouterCore.AudioProfileArchiveError
typealias AudioProfileMerge = SonicRouterCore.AudioProfileMerge

/// UserDefaults keys shared by Settings and the app delegate.
enum StartupPreferences {
    /// When set, the main window is suppressed at launch and the app starts as
    /// a menu bar item only.
    static let startInMenuBarKey = "SonicRouter.StartInMenuBar"
}

enum SonicRouterInterfaceSurface: Hashable {
    case mainWindow
    case menuBar
    case settings
}

/// Live coarse picture of how much work SonicRouter is doing, surfaced in the UI
/// so it's visible at a glance that the app idles down when nothing needs it.
enum SonicRouterPowerMode: Hashable {
    /// Watching CoreAudio/workspace events — a window is open or audio is being
    /// controlled. This is the only mode that holds listeners or audio engines.
    case active
    /// No UI visible and nothing being controlled: every listener and timer is
    /// torn down, so the app costs essentially nothing until something changes.
    case idle
    /// The machine is asleep (e.g. lid closed). All audio engines are released
    /// so no IOProc keeps the audio hardware awake; restored on wake.
    case suspended

    /// Display text lives in `PowerModeChip`, which localizes it.
    var symbol: String {
        switch self {
        case .active: "bolt.fill"
        case .idle: "leaf.fill"
        case .suspended: "moon.zzz.fill"
        }
    }
}

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
    var equalizer: AudioEqualizerSettings
    var isControllable: Bool
    var supportsVolumeControl: Bool
    /// True while the re-emit volume engine owns this app's audio path.
    var isVolumeEngaged: Bool
}

extension AppAudioSession {
    /// Anything the user changed from normal playback: mute, level, route or EQ.
    var hasCustomSettings: Bool {
        isMuted || isVolumeEngaged || desiredVolume < 0.999 || desiredOutputUID != nil || !equalizer.isFlat
    }

    /// Mixer rows: apps playing now plus any app carrying custom settings, so
    /// a muted or adjusted app never disappears from under the cursor.
    var isShownInMixer: Bool {
        isProducingAudio || hasCustomSettings
    }
}

struct CoreAudioProcessInfo: Hashable {
    let objectID: AudioObjectID
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool
    let outputDeviceIDs: [AudioObjectID]
}
