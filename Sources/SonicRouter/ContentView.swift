import AppKit
import SwiftUI

struct ContentView: View {
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var l10n = L10n.shared
    /// Remembered across launches so the window reopens where you left it.
    @AppStorage(Screen.storageKey) private var selection: Screen = .mixer

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .onAppear {
            // However the window came back (menu bar, Finder, a menu command),
            // a visible window always gets its Dock icon.
            if NSApp.activationPolicy() != .regular {
                AppDelegate.showInDock()
            }
            audioStore.setInterfaceVisible(.mainWindow, true)
            appStore.setInterfaceVisible(.mainWindow, true)
        }
        .onDisappear {
            audioStore.setInterfaceVisible(.mainWindow, false)
            appStore.setInterfaceVisible(.mainWindow, false)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SonicRouter")
                        .font(.headline)
                    Text("v" + appVersion)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 14)

            ForEach(Screen.allCases) { screen in
                SidebarButton(
                    title: screen.title(l10n),
                    symbol: screen.symbol,
                    shortcut: screen.shortcut,
                    isSelected: selection == screen
                ) {
                    selection = screen
                }
            }

            Spacer()

            Button {
                audioStore.refresh()
                appStore.refresh()
            } label: {
                Label(l10n.t("Actualizar", "Refresh", "更新"), systemImage: "arrow.clockwise")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .help(l10n.t("Volver a leer apps y dispositivos (⌘R)", "Re-read apps and devices (⌘R)", "アプリとデバイスを再読込 (⌘R)"))

            Button {
                openSettings()
            } label: {
                Label(l10n.t("Ajustes", "Settings", "設定"), systemImage: "gearshape")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .help(l10n.t("Idioma, inicio y permisos (⌘,)", "Language, startup and permissions (⌘,)", "言語・起動・権限 (⌘,)"))
        }
        .padding(12)
        .frame(width: 196)
        .background(.bar)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if appStore.permission == .denied {
                PermissionBanner(
                    onRetry: { appStore.checkPermission() },
                    onOpenSettings: { appStore.openPrivacySettings() }
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }

            Group {
                switch selection {
                case .mixer: AppRoutingView()
                case .devices: DeviceMixerView()
                case .saved: ProfilesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusBar()
        }
    }
}

private struct SidebarButton: View {
    let title: String
    let symbol: String
    let shortcut: KeyEquivalent
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
            }
            .font(.body.weight(isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.accent : (isHovered ? Color.primary.opacity(0.06) : .clear))
            )
            .shadow(color: isSelected ? Theme.accent.opacity(0.32) : .clear, radius: 5, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.13), value: isHovered)
        .help("⌘" + String(shortcut.character))
    }
}

/// Main-window sections. The View menu commands and the sidebar share the
/// selection through `storageKey`.
enum Screen: String, CaseIterable, Identifiable {
    static let storageKey = "SonicRouter.LastScreen"

    case mixer
    case devices
    case saved

    var id: String { rawValue }

    @MainActor
    func title(_ l10n: L10n) -> String {
        switch self {
        case .mixer: l10n.t("Mezclador", "Mixer", "ミキサー")
        case .devices: l10n.t("Dispositivos", "Devices", "デバイス")
        case .saved: l10n.t("Guardados", "Saved", "保存済み")
        }
    }

    var symbol: String {
        switch self {
        case .mixer: "slider.vertical.3"
        case .devices: "hifispeaker.2"
        case .saved: "bookmark"
        }
    }

    /// ⌘1 / ⌘2 / ⌘3, in sidebar order.
    var shortcut: KeyEquivalent {
        switch self {
        case .mixer: "1"
        case .devices: "2"
        case .saved: "3"
        }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @ObservedObject private var l10n = L10n.shared
    /// Whichever store reported last: app controls or device actions.
    @State private var message = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            Text(statusText)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Text(appStore.scannerStatus)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            PowerModeChip(
                mode: appStore.powerMode,
                isSuspended: appStore.isManuallySuspended,
                onToggleSuspend: { appStore.setManuallySuspended(!appStore.isManuallySuspended) },
                onQuit: { NSApp.terminate(nil) }
            )
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .onChange(of: appStore.controlStatus, initial: true) { _, status in message = status }
        .onChange(of: audioStore.statusMessage) { _, status in message = status }
        // A message in the previous language would linger; fall back to idle.
        .onChange(of: l10n.language) { message = "" }
    }

    private var statusText: String {
        if let error = audioStore.lastError { return error }
        return message.isEmpty ? l10n.t("Listo", "Ready", "準備完了") : message
    }

    private var statusSymbol: String {
        audioStore.lastError != nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        audioStore.lastError != nil ? .orange : .green
    }
}
