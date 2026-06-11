import SwiftUI

struct AppRoutingView: View {
    @EnvironmentObject private var appStore: ApplicationAudioStore

    /// Apps that are playing OR currently muted, sorted alphabetically so the
    /// list stays put when you mute something (no rows jumping under the cursor).
    private var active: [AppAudioSession] {
        appStore.sessions
            .filter { $0.isProducingAudio || $0.isMuted || $0.isVolumeEngaged || $0.desiredVolume < 0.999 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MixerHeader(onRestore: { appStore.resetAllControls() })

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(
                        title: "Apps con audio",
                        count: active.count,
                        sessions: active,
                        emptySymbol: "speaker.slash",
                        emptyTitle: "Nada suena por ahora",
                        emptySubtitle: "Reproduce un video o una llamada y aparecerá aquí."
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
                            onReset: { appStore.reset(session) }
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
    let onRestore: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Mezclador")
                    .font(.system(size: 22, weight: .bold))
                Text("Solo muestra apps sonando y controles activos. Usa Restaurar si una llamada queda muda.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(action: onRestore) {
                Label("Restaurar todo", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.bordered)
            .help("Quitar todos los taps y devolver audio normal")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}
