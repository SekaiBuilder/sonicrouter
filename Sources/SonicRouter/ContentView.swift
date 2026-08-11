import AppKit
import SwiftUI

struct ContentView: View {
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @ObservedObject private var l10n = L10n.shared
    @State private var selection: Screen = .mixer

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .onAppear {
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
            .padding(.bottom, 4)
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
    }
}

private enum Screen: String, CaseIterable, Identifiable {
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
}

private struct StatusBar: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore

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
    }

    private var statusText: String {
        if let error = audioStore.lastError { return error }
        return appStore.controlStatus
    }

    private var statusSymbol: String {
        audioStore.lastError != nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        audioStore.lastError != nil ? .orange : .green
    }
}
