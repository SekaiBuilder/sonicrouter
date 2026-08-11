import Foundation
import SwiftUI

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

/// Tiny inline-translation store. Call sites pass the three variants directly —
/// `l10n.t("Mezclador", "Mixer", "ミキサー")` — so there is no key table to drift
/// out of sync. Views observe the shared instance and re-render live when the
/// user switches language in Ajustes.
@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    private let storageKey = "SonicRouter.Language"

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: storageKey) }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: storageKey) ?? ""
        language = AppLanguage(rawValue: saved) ?? .system
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

    /// Spanish, English, Japanese — in that order.
    func t(_ es: String, _ en: String, _ ja: String) -> String {
        switch resolved {
        case .spanish, .system: es
        case .english: en
        case .japanese: ja
        }
    }
}
