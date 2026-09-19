import AppKit
import Carbon.HIToolbox
import OSLog

private let shortcutLog = Logger(subsystem: "local.sonicrouter.app", category: "Shortcuts")
/// 'SnRt': tags SonicRouter's hot keys so foreign events are ignored.
private let hotKeySignature: OSType = 0x536E_5274

/// System-wide shortcuts registered through the Carbon hot key API. Unlike
/// event taps or global NSEvent monitors this needs no Accessibility or Input
/// Monitoring permission: macOS delivers only the exact combinations
/// registered here, never any other keystroke.
@MainActor
final class GlobalHotKeys: ObservableObject {
    enum Action: UInt32, CaseIterable, Identifiable {
        /// ⌃⌥⌘M: mute or unmute the app in front.
        case toggleFrontmostApp = 1
        /// ⌃⌥⇧⌘M: mute everything that is playing, or undo it.
        case toggleAllApps = 2

        var id: UInt32 { rawValue }

        var displayKeys: String {
            switch self {
            case .toggleFrontmostApp: "⌃⌥⌘M"
            case .toggleAllApps: "⌃⌥⇧⌘M"
            }
        }

        fileprivate var carbonModifiers: UInt32 {
            switch self {
            case .toggleFrontmostApp: UInt32(controlKey | optionKey | cmdKey)
            case .toggleAllApps: UInt32(controlKey | optionKey | shiftKey | cmdKey)
            }
        }

        @MainActor
        func title(_ l10n: L10n) -> String {
            switch self {
            case .toggleFrontmostApp:
                l10n.t(
                    "Silenciar o activar la app en primer plano",
                    "Mute or unmute the frontmost app",
                    "最前面のアプリをミュート／解除"
                )
            case .toggleAllApps:
                l10n.t("Silenciar todo o deshacerlo", "Mute everything, or undo it", "すべてミュート／元に戻す")
            }
        }
    }

    static let shared = GlobalHotKeys()
    static let preferenceKey = "SonicRouter.GlobalShortcuts"

    @Published private(set) var isEnabled = false
    /// Shortcuts macOS refused, usually because another app already owns them.
    @Published private(set) var unavailable: Set<Action> = []

    var handler: (@MainActor (Action) -> Void)?

    private var hotKeys: [Action: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    private init() {}

    func applySavedPreference() {
        setEnabled(UserDefaults.standard.bool(forKey: Self.preferenceKey))
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        unregisterAll()
        isEnabled = enabled
        guard enabled else { return }
        guard installEventHandler() else {
            unavailable = Set(Action.allCases)
            return
        }

        var refused: Set<Action> = []
        for action in Action.allCases {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(kVK_ANSI_M),
                action.carbonModifiers,
                EventHotKeyID(signature: hotKeySignature, id: action.rawValue),
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                hotKeys[action] = reference
            } else {
                refused.insert(action)
                shortcutLog.notice("Shortcut \(action.displayKeys, privacy: .public) refused: \(status)")
            }
        }
        unavailable = refused
        let registered = hotKeys.count
        shortcutLog.notice("Global shortcuts registered: \(registered)/\(Action.allCases.count)")
    }

    fileprivate func perform(_ id: UInt32) {
        guard isEnabled, let action = Action(rawValue: id) else { return }
        handler?(action)
    }

    private func unregisterAll() {
        for reference in hotKeys.values {
            UnregisterEventHotKey(reference)
        }
        hotKeys.removeAll()
        unavailable = []
    }

    private func installEventHandler() -> Bool {
        guard eventHandler == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        return status == noErr
    }
}

/// Carbon calls this on the main thread for every registered combination.
private func hotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        GlobalHotKeys.shared.perform(id)
    }
    return noErr
}
