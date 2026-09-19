import Foundation

public enum AudioProfileArchiveError: Error, Equatable, Sendable {
    /// Not JSON, or not a SonicRouter export.
    case unrecognizedFormat
    /// Written by a newer SonicRouter.
    case unsupportedVersion(Int)
    case tooManyProfiles(Int)
    /// A valid file with nothing usable in it.
    case noProfiles
}

/// File format for exporting and importing saved settings. Only preferences
/// travel in it (app names, bundle IDs, output UIDs, volumes and equalizer
/// gains), never audio.
public struct AudioProfileArchive: Codable, Sendable {
    public static let formatIdentifier = "local.sonicrouter.profiles"
    public static let currentVersion = 1
    public static let maximumProfileCount = 1_000

    public var format: String
    public var version: Int
    public var exportedAt: Date?
    public var profiles: [AudioRouteProfile]

    public init(profiles: [AudioRouteProfile], exportedAt: Date = Date()) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.profiles = profiles
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Reads a file written by `encoded()` or, for hand-made files, a bare
    /// array of profiles. The result is sanitized (see `sanitized(_:)`).
    public static func decodeProfiles(from data: Data) throws -> [AudioRouteProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let profiles: [AudioRouteProfile]
        if let header = try? decoder.decode(Header.self, from: data), let format = header.format {
            guard format == formatIdentifier else { throw AudioProfileArchiveError.unrecognizedFormat }
            let version = header.version ?? 0
            guard version <= currentVersion else { throw AudioProfileArchiveError.unsupportedVersion(version) }
            guard let archive = try? decoder.decode(AudioProfileArchive.self, from: data) else {
                throw AudioProfileArchiveError.unrecognizedFormat
            }
            profiles = archive.profiles
        } else if let list = try? decoder.decode([AudioRouteProfile].self, from: data) {
            profiles = list
        } else {
            throw AudioProfileArchiveError.unrecognizedFormat
        }

        guard profiles.count <= maximumProfileCount else {
            throw AudioProfileArchiveError.tooManyProfiles(profiles.count)
        }
        let usable = sanitized(profiles)
        guard !usable.isEmpty else { throw AudioProfileArchiveError.noProfiles }
        return usable
    }

    /// Clamps volumes, drops entries that identify no app, clears empty
    /// strings and flat equalizers, and collapses duplicates for the same app
    /// (the later entry wins).
    public static func sanitized(_ profiles: [AudioRouteProfile]) -> [AudioRouteProfile] {
        var result: [AudioRouteProfile] = []
        for var profile in profiles {
            profile.appName = profile.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.bundleIdentifier = nonEmpty(profile.bundleIdentifier)
            profile.outputDeviceUID = nonEmpty(profile.outputDeviceUID)
            if profile.appName.isEmpty {
                guard let bundleIdentifier = profile.bundleIdentifier else { continue }
                profile.appName = bundleIdentifier
            }
            profile.volume = profile.volume.isFinite ? min(1, max(0, profile.volume)) : 1
            if profile.equalizer?.isFlat == true { profile.equalizer = nil }
            if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.name = "\(profile.appName) route"
            }

            if let index = result.firstIndex(where: {
                AudioProfileMatcher.matches($0, bundleIdentifier: profile.bundleIdentifier, appName: profile.appName)
            }) {
                result[index] = profile
            } else {
                result.append(profile)
            }
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private struct Header: Decodable {
        var format: String?
        var version: Int?
    }
}

public enum AudioProfileMerge {
    public struct Result: Equatable, Sendable {
        public var profiles: [AudioRouteProfile]
        public var added: Int
        public var replaced: Int
    }

    /// Imported profiles win over saved ones for the same app. A replaced
    /// profile keeps its identity and added ones get a fresh ID, so importing
    /// a file twice, or one exported from this Mac, never duplicates a row.
    public static func merge(existing: [AudioRouteProfile], imported: [AudioRouteProfile]) -> Result {
        var profiles = existing
        var added = 0
        var replaced = 0
        for var profile in imported {
            let matches = profiles.indices.filter {
                AudioProfileMatcher.matches(
                    profiles[$0],
                    bundleIdentifier: profile.bundleIdentifier,
                    appName: profile.appName
                )
            }
            if let first = matches.first {
                profile.id = profiles[first].id
                profiles[first] = profile
                for index in matches.dropFirst().reversed() {
                    profiles.remove(at: index)
                }
                replaced += 1
            } else {
                profile.id = UUID()
                profiles.append(profile)
                added += 1
            }
        }
        return Result(profiles: profiles, added: added, replaced: replaced)
    }
}
