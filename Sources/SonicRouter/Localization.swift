import Foundation
import SwiftUI
import Synchronization

/// UI language. `.system` follows the Mac's preferred language, falling back to
/// Spanish (the app's original language) when the system is set to anything the
/// app doesn't ship.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case spanish = "es"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "Sistema · System · システム"
        case .spanish: "Español"
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}

/// Snapshot of the resolved language readable from any thread, so messages
/// built off the main actor (CoreAudio errors) can still be localized.
private let resolvedLanguageBox = Mutex<AppLanguage>(.spanish)

/// Tiny inline-translation store. Call sites pass the three variants directly —
/// `l10n.t("Mezclador", "Mixer", "ミキサー")` — so there is no key table to drift
/// out of sync. Views observe the shared instance and re-render live when the
/// user switches language in Ajustes.
@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    private let storageKey = "SonicRouter.Language"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: storageKey)
            publishResolved()
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: storageKey) ?? ""
        language = AppLanguage(rawValue: saved) ?? .system
        publishResolved()
    }

    private var resolved: AppLanguage {
        guard language == .system else { return language }
        for preferred in Locale.preferredLanguages {
            if preferred.hasPrefix("es") { return .spanish }
            if preferred.hasPrefix("ja") { return .japanese }
            if preferred.hasPrefix("en") { return .english }
        }
        return .spanish
    }

    private func publishResolved() {
        let language = resolved
        resolvedLanguageBox.withLock { $0 = language }
    }

    /// Spanish, English, Japanese — in that order.
    func t(_ es: String, _ en: String, _ ja: String) -> String {
        Self.pick(resolved, es, en, ja)
    }

    /// Same as `t`, callable from any isolation (error descriptions, helpers
    /// that run off the main actor). Reads the language the main actor last
    /// published; the stores touch `L10n.shared` at launch, so it is current
    /// by the time any error can be produced.
    nonisolated static func text(_ es: String, _ en: String, _ ja: String) -> String {
        pick(resolvedLanguageBox.withLock { $0 }, es, en, ja)
    }

    private nonisolated static func pick(
        _ language: AppLanguage,
        _ es: String,
        _ en: String,
        _ ja: String
    ) -> String {
        switch language {
        case .spanish, .system: es
        case .english: en
        case .japanese: ja
        }
    }
}
