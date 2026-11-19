import Foundation

/// Carries SonicRouter's preferences over when the app starts under a new
/// preferences domain (plan A8, RIE-06): a new bundle ID (DEC-104) and/or the
/// App Sandbox container (CAM-002).
///
/// Two steps:
/// 1. With App Sandbox, `Contents/Resources/container-migration.plist` asks
///    macOS to move the old `~/Library/Preferences/<old domain>.plist` into the
///    container on first launch. With the same bundle ID that is already the
///    app's own domain and nothing else is needed.
/// 2. If the bundle ID changed, `migrate` copies the `SonicRouter.*` keys from
///    the old domain (now inside the container) into the current one, once.
///    It never overwrites a value the new install already has, and records a
///    marker so it does not run again.
public enum PreferenceMigration {
    public static let legacyDomain = "local.sonicrouter.app"
    public static let keyPrefix = "SonicRouter."
    public static let markerKey = "SonicRouter.PreferencesMigratedFrom"

    /// Values to write into the current domain, or `nil` when there is
    /// nothing to do (already migrated, or no old SonicRouter keys).
    public static func plan(old: [String: Any], current: [String: Any], from oldDomain: String) -> [String: Any]? {
        guard current[markerKey] == nil else { return nil }
        var changes: [String: Any] = [:]
        for (key, value) in old where key.hasPrefix(keyPrefix) && key != markerKey && current[key] == nil {
            guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else { continue }
            changes[key] = value
        }
        guard !changes.isEmpty || old.keys.contains(where: { $0.hasPrefix(keyPrefix) }) else { return nil }
        changes[markerKey] = oldDomain
        return changes
    }

    /// Runs step 2 against real defaults. Returns the keys copied (empty when
    /// nothing was done). Same domain or no bundle ID: no-op.
    @discardableResult
    public static func migrate(
        from oldDomain: String = legacyDomain,
        currentDomain: String?,
        defaults: UserDefaults = .standard
    ) -> [String] {
        guard let currentDomain, currentDomain != oldDomain,
            let old = defaults.persistentDomain(forName: oldDomain)
        else { return [] }
        let current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        guard let changes = plan(old: old, current: current, from: oldDomain) else { return [] }
        for (key, value) in changes { defaults.set(value, forKey: key) }
        return changes.keys.filter { $0 != markerKey }.sorted()
    }
}
