import SwiftUI

struct AppRoutingView: View {
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @EnvironmentObject private var audioStore: AudioDeviceStore

    /// Real output devices an app can be routed to. Hide the virtual device left
    /// by old experimental builds if it is still installed on this Mac.
    private var routableOutputs: [AudioDevice] {
        audioStore.outputDevices.filter { $0.uid != SonicRouterAudioIdentifiers.legacyVirtualDeviceUID }
    }

    /// Apps that are playing OR currently muted, sorted alphabetically so the
    /// list stays put when you mute something (no rows jumping under the cursor).
    private var active: [AppAudioSession] {
        appStore.sessions
            .filter { $0.isProducingAudio || $0.isMuted || $0.isVolumeEngaged || $0.desiredVolume < 0.999 || $0.desiredOutputUID != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MixerHeader(onRestore: { appStore.resetAllControls() })

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(
                        title: L10n.shared.t("Apps con audio", "Apps with audio", "音声のあるアプリ"),
                        count: active.count,
                        sessions: active,
                        emptySymbol: "speaker.slash",
                        emptyTitle: L10n.shared.t("Nada suena por ahora", "Nothing playing right now", "現在再生中の音声はありません"),
                        emptySubtitle: L10n.shared.t(
                            "Reproduce un video o una llamada y aparecerá aquí.",
                            "Play a video or start a call and it will appear here.",
                            "動画や通話を再生するとここに表示されます。"
                        )
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private func section(
        title: String,
        count: Int,
        sessions: [AppAudioSession],
        emptySymbol: String,
        emptyTitle: String,
        emptySubtitle: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: title, count: count)

            if sessions.isEmpty {
                EmptyHint(symbol: emptySymbol, title: emptyTitle, subtitle: emptySubtitle)
                    .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        AppMixerRow(
                            session: session,
                            onMute: { appStore.setMuted($0, for: session) },
                            onVolume: { appStore.setVolume($0, for: session) },
                            onCommit: { appStore.commitVolume(for: session) },
                            onReset: { appStore.reset(session) },
                            outputDevices: routableOutputs,
                            onSelectOutput: { appStore.setOutputDevice($0, for: session) }
                        )
                        if index < sessions.count - 1 {
                            Divider().padding(.leading, 50)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
            }
        }
    }
}

private struct MixerHeader: View {
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @ObservedObject private var l10n = L10n.shared
    let onRestore: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(l10n.t("Mezclador", "Mixer", "ミキサー"))
                    .font(.system(size: 22, weight: .bold))
                Text(l10n.t(
                    "Solo muestra apps sonando y controles activos. Usa Restaurar si una llamada queda muda.",
                    "Shows only playing apps and active controls. Use Restore if a call goes silent.",
                    "再生中のアプリと制御中のアプリのみ表示します。通話が無音になったら「復元」を使ってください。"
                ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(action: onRestore) {
                Label(l10n.t("Restaurar todo", "Restore all", "すべて復元"), systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.bordered)
            .help(l10n.t("Quitar todos los taps y devolver audio normal", "Remove every tap and restore normal audio", "すべてのタップを解除して通常のオーディオに戻す"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}
