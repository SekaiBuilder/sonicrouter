import Foundation
import SonicRouterDSP

public struct AudioRouteProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var appName: String
    public var bundleIdentifier: String?
    public var outputDeviceUID: String?
    public var volume: Double
    /// `nil` means flat. Profiles saved before the equalizer existed have no
    /// such key and decode as flat.
    public var equalizer: AudioEqualizerSettings?

    public init(
        id: UUID = UUID(),
        name: String,
        appName: String,
        bundleIdentifier: String?,
        outputDeviceUID: String?,
        volume: Double,
        equalizer: AudioEqualizerSettings? = nil
    ) {
        self.id = id
        self.name = name
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.outputDeviceUID = outputDeviceUID
        self.volume = volume
        self.equalizer = equalizer
    }
}

public struct AudioControlIntent: Equatable, Sendable {
    public var volume: Double
    public var muted: Bool
    public var outputUID: String?
    public var equalizer: AudioEqualizerSettings

    public init(
        volume: Double,
        muted: Bool,
        outputUID: String? = nil,
        equalizer: AudioEqualizerSettings = .flat
    ) {
        self.volume = min(1, max(0, volume))
        self.muted = muted
        self.outputUID = outputUID
        self.equalizer = equalizer
    }

    public init(profile: AudioRouteProfile) {
        self.init(
            volume: profile.volume,
            muted: false,
            outputUID: profile.outputDeviceUID,
            equalizer: profile.equalizer ?? .flat
        )
    }

    public var wantsMute: Bool {
        muted || volume <= 0.001
    }

    /// The re-emit engine is needed to attenuate, to route to a specific
    /// output, or to equalize; anything else keeps the native path.
    public var wantsVolumeEngine: Bool {
        !wantsMute && (volume < 0.999 || outputUID != nil || !equalizer.isFlat)
    }

    public var requiresEngine: Bool {
        wantsMute || wantsVolumeEngine
    }
}

public enum AudioGainPolicy {
    /// Uses only the headroom present in the current input block. A requested
    /// makeup value may lift quiet material, but the boost never pushes the
    /// resulting peak past full scale — so it never needs hard clipping.
    ///
    /// Gains at or below unity are returned untouched: attenuation is the
    /// user's slider and must map 1:1 to the output. The cap also never goes
    /// below unity — a source that is already hot plays at its native level
    /// instead of being ducked quieter than the original path.
    /// Implemented in C++ (`sr_headroom_limited_gain`), shared with the render thread.
    public static func headroomLimitedGain(requestedGain: Float, inputPeak: Float) -> Float {
        sr_headroom_limited_gain(requestedGain, inputPeak)
    }
}

public enum SonicRouterAudioIdentifiers {
    /// Hidden for compatibility with installations made by experimental builds.
    public static let legacyVirtualDeviceUID = "local.sonicrouter.audio.device"
    public static let aggregateDeviceUIDPrefix = "local.sonicrouter.agg."

    public static func isInternalDeviceUID(_ uid: String) -> Bool {
        uid == legacyVirtualDeviceUID || uid.hasPrefix(aggregateDeviceUIDPrefix)
    }
}

public enum AudioProfileMatcher {
    public static func matches(
        _ profile: AudioRouteProfile,
        bundleIdentifier: String?,
        appName: String,
        alternateAppName: String? = nil
    ) -> Bool {
        if let bundleIdentifier, let profileBundleIdentifier = profile.bundleIdentifier {
            return profileBundleIdentifier == bundleIdentifier
        }
        return profile.appName == appName || profile.appName == alternateAppName
    }
}
