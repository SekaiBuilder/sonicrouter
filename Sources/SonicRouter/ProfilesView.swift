import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(
                title: l10n.t("Volumen guardado", "Saved volume", "保存済みの音量"),
                subtitle: l10n.t(
                    "El nivel que eliges para cada app se recuerda y se vuelve a aplicar automáticamente cuando esa app empieza a sonar.",
                    "The level you choose for each app is remembered and re-applied automatically when that app starts playing.",
                    "アプリごとに選んだ音量は記憶され、そのアプリが再生を始めると自動的に再適用されます。"
                )
            )

            if appStore.profiles.isEmpty {
                EmptyHint(
                    symbol: "bookmark",
                    title: l10n.t("Aún no hay niveles guardados", "No saved levels yet", "保存された音量はまだありません"),
                    subtitle: l10n.t(
                        "Ajusta el volumen de una app en el mezclador y se guardará aquí.",
                        "Adjust an app's volume in the mixer and it will be saved here.",
                        "ミキサーでアプリの音量を調整するとここに保存されます。"
                    )
                )
                .card()
                .padding(20)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(appStore.profiles.enumerated()), id: \.element.id) { index, profile in
                            ProfileRow(
                                profile: profile,
                                devices: audioStore.outputDevices,
                                onRemove: { appStore.removeProfile(profile) }
                            )
                            if index < appStore.profiles.count - 1 {
                                Divider().padding(.leading, 46)
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
                    .padding(20)
                }
            }
        }
    }
}

private struct ProfileRow: View {
    let profile: AudioRouteProfile
    let devices: [AudioDevice]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                Image(systemName: "app.fill")
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.appName)
                    .font(.headline)
                    .lineLimit(1)
                Text(profile.bundleIdentifier ?? L10n.shared.t("Sin identificador", "No identifier", "識別子なし"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text("\(Int((profile.volume * 100).rounded()))%")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(profile.volume <= 0.001 ? .red : .secondary)

            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L10n.shared.t("Olvidar nivel guardado", "Forget saved level", "保存した音量を削除"))
        }
        .padding(.vertical, 9)
    }
}
