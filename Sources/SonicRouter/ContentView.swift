import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @State private var selection: Screen = .mixer

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "slider.vertical.3")
                    .foregroundStyle(Theme.accent)
                    .font(.title3)
                Text("SonicRouter")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 12)

            ForEach(Screen.allCases) { screen in
                SidebarButton(
                    title: screen.title,
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
                Label("Actualizar", systemImage: "arrow.clockwise")
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

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body)
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Theme.accent : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum Screen: String, CaseIterable, Identifiable {
    case mixer
    case devices
    case saved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixer: "Mezclador"
        case .devices: "Dispositivos"
        case .saved: "Guardados"
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
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(.bar)
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
