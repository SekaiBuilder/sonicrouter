import SwiftUI

/// Menu bar commands. Navigation lives in View and bulk actions in an Audio
/// menu, which also makes every keyboard shortcut discoverable.
struct SonicRouterCommands: Commands {
    @ObservedObject var appStore: ApplicationAudioStore
    @ObservedObject var audioStore: AudioDeviceStore
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(Screen.storageKey) private var screen: Screen = .mixer
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(Screen.allCases) { item in
                Button(item.title(l10n)) {
                    show(item)
                }
                .keyboardShortcut(item.shortcut, modifiers: .command)
            }
            Divider()
            Button(l10n.t("Actualizar", "Refresh", "更新")) {
                audioStore.refresh()
                appStore.refresh()
            }
            .keyboardShortcut("r", modifiers: .command)
            Divider()
        }

        CommandMenu(l10n.t("Audio", "Audio", "オーディオ")) {
            Button(l10n.t("Silenciar todo", "Mute All", "すべてミュート")) {
                appStore.muteAll()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!appStore.canMuteAll)

            Button(l10n.t("Activar todo", "Unmute All", "すべてのミュートを解除")) {
                appStore.unmuteAll()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!appStore.canUnmuteAll)

            Divider()

            Button(l10n.t("Restaurar todo el audio", "Restore All Audio", "すべてのオーディオを復元")) {
                appStore.resetAllControls()
            }

            Divider()

            Button(
                appStore.isManuallySuspended
                    ? l10n.t("Reanudar SonicRouter", "Resume SonicRouter", "SonicRouterを再開")
                    : l10n.t("Suspender SonicRouter", "Suspend SonicRouter", "SonicRouterを一時停止")
            ) {
                appStore.setManuallySuspended(!appStore.isManuallySuspended)
            }
        }
    }

    /// Selects a section and brings the main window forward, reopening it
    /// (and the Dock icon) when only Settings or the menu bar was visible.
    private func show(_ item: Screen) {
        screen = item
        AppDelegate.showInDock()
        openWindow(id: "main")
    }
}
