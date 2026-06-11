import SwiftUI

/// Compact panel shown from the menu bar — the fast path for "mute this call
/// while I watch a video" without opening the full window.
struct MenuBarView: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var playing: [AppAudioSession] {
        appStore.sessions
            .filter { $0.isProducingAudio || $0.isMuted || $0.isVolumeEngaged || $0.desiredVolume < 0.999 }
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
                    title: "Nada suena ahora",
                    subtitle: "Reproduce algo y aparecerá aquí."
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
                            onReset: { appStore.reset(session) }
                        )
                    }
                }
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .task {
            appStore.refresh()
            audioStore.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .foregroundStyle(Theme.accent)
            Text("SonicRouter")
                .font(.headline)
            Spacer()
            Button {
                appStore.refresh()
                audioStore.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Actualizar")
        }
    }

    private var footer: some View {
        HStack {
            Button {
                AppDelegate.showInDock()
                openWindow(id: "main")
            } label: {
                Label("Abrir ventana", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                appStore.resetAllControls()
            } label: {
                Label("Restaurar audio", systemImage: "arrow.uturn.backward.circle")
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
            .help("Ajustes")

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Salir")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
