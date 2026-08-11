import Foundation

public struct AudioRouteProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var appName: String
    public var bundleIdentifier: String?
    public var outputDeviceUID: String?
    public var volume: Double

    public init(
        id: UUID = UUID(),
        name: String,
        appName: String,
        bundleIdentifier: String?,
        outputDeviceUID: String?,
        volume: Double
    ) {
        self.id = id
        self.name = name
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.outputDeviceUID = outputDeviceUID
        self.volume = volume
    }
}

public struct AudioControlIntent: Equatable, Sendable {
    public var volume: Double
    public var muted: Bool
    public var outputUID: String?

    public init(volume: Double, muted: Bool, outputUID: String? = nil) {
        self.volume = min(1, max(0, volume))
        self.muted = muted
        self.outputUID = outputUID
    }

    public init(profile: AudioRouteProfile) {
        self.init(volume: profile.volume, muted: false, outputUID: profile.outputDeviceUID)
    }

    public var wantsMute: Bool {
        muted || volume <= 0.001
    }

    public var wantsVolumeEngine: Bool {
        !wantsMute && (volume < 0.999 || outputUID != nil)
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
    public static func headroomLimitedGain(requestedGain: Float, inputPeak: Float) -> Float {
        let requested = max(0, requestedGain)
        guard requested.isFinite else { return 0 }
        guard requested > 1 else { return requested }
        let peak = max(0, inputPeak)
        guard peak.isFinite, peak > 0 else { return requested }
        return min(requested, max(1, 1 / peak))
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
