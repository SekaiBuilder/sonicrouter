import AppKit
import SwiftUI

/// Compact panel shown from the menu bar — the fast path for "mute this call
/// while I watch a video" without opening the full window.
struct MenuBarView: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var l10n = L10n.shared

    private var playing: [AppAudioSession] {
        appStore.sessions
            .filter { $0.isProducingAudio || $0.isMuted || $0.isVolumeEngaged || $0.desiredVolume < 0.999 || $0.desiredOutputUID != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if appStore.permission == .denied {
                PermissionBanner(
                    onRetry: { appStore.checkPermission() },
                    onOpenSettings: { appStore.openPrivacySettings() }
                )
            }

            if let output = audioStore.outputDevices.first(where: \.isDefaultOutput) {
                Label(output.name, systemImage: "hifispeaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            if playing.isEmpty {
                EmptyHint(
                    symbol: "speaker.slash",
                    title: l10n.t("Nada suena ahora", "Nothing is playing", "再生中の音声はありません"),
                    subtitle: l10n.t("Reproduce algo y aparecerá aquí.", "Play something and it will appear here.", "何かを再生するとここに表示されます。")
                )
            } else {
                VStack(spacing: 2) {
                    ForEach(playing) { session in
                        AppMixerRow(
                            session: session,
                            compact: true,
                            onMute: { appStore.setMuted($0, for: session) },
                            onVolume: { appStore.setVolume($0, for: session) },
                            onCommit: { appStore.commitVolume(for: session) },
                            onReset: { appStore.reset(session) },
                            outputDevices: audioStore.outputDevices.filter {
                                $0.uid != SonicRouterAudioIdentifiers.legacyVirtualDeviceUID
                            },
                            onSelectOutput: { appStore.setOutputDevice($0, for: session) }
                        )
                    }
                }
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            appStore.setInterfaceVisible(.menuBar, true)
            audioStore.setInterfaceVisible(.menuBar, true)
        }
        .onDisappear {
            appStore.setInterfaceVisible(.menuBar, false)
            audioStore.setInterfaceVisible(.menuBar, false)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
            Text("SonicRouter")
                .font(.headline)
            Spacer()
            PowerModeChip(
                mode: appStore.powerMode,
                isSuspended: appStore.isManuallySuspended,
                onToggleSuspend: { appStore.setManuallySuspended(!appStore.isManuallySuspended) },
                onQuit: { NSApp.terminate(nil) }
            )
            Button {
                appStore.refresh()
                audioStore.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(l10n.t("Actualizar", "Refresh", "更新"))
        }
    }

    private var footer: some View {
        HStack {
            Button {
                AppDelegate.showInDock()
                openWindow(id: "main")
            } label: {
                Label(l10n.t("Abrir ventana", "Open window", "ウインドウを開く"), systemImage: "macwindow")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)

            Spacer()

            Button {
                appStore.resetAllControls()
            } label: {
                Label(l10n.t("Restaurar audio", "Restore audio", "オーディオを復元"), systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(l10n.t("Ajustes", "Settings", "設定"))

            Button {
                NSApp.terminate(nil)
            } label: {
                Text(l10n.t("Salir", "Quit", "終了"))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
