import SwiftUI

/// One-click curves for the per-app equalizer.
enum EqualizerPreset: String, CaseIterable, Identifiable {
    case flat
    case voice
    case bassBoost
    case bassCut
    case softTreble

    var id: String { rawValue }

    var settings: AudioEqualizerSettings {
        switch self {
        case .flat: .flat
        case .voice: AudioEqualizerSettings(bass: -4, mid: 3, treble: 2)
        case .bassBoost: AudioEqualizerSettings(bass: 6)
        case .bassCut: AudioEqualizerSettings(bass: -6)
        case .softTreble: AudioEqualizerSettings(treble: -5)
        }
    }

    @MainActor
    func title(_ l10n: L10n) -> String {
        switch self {
        case .flat: l10n.t("Plano", "Flat", "フラット")
        case .voice: l10n.t("Voz clara", "Clear voice", "クリアな声")
        case .bassBoost: l10n.t("Más graves", "More bass", "低音を強調")
        case .bassCut: l10n.t("Menos graves", "Less bass", "低音を抑える")
        case .softTreble: l10n.t("Agudos suaves", "Softer treble", "高音を和らげる")
        }
    }

    static func matching(_ settings: AudioEqualizerSettings) -> EqualizerPreset? {
        allCases.first { $0.settings == settings }
    }
}

extension EqualizerBand {
    @MainActor
    func title(_ l10n: L10n) -> String {
        switch self {
        case .bass: l10n.t("Graves", "Bass", "低音")
        case .mid: l10n.t("Medios", "Mid", "中音")
        case .treble: l10n.t("Agudos", "Treble", "高音")
        }
    }

    var frequencyLabel: String {
        switch self {
        case .bass: "100 Hz"
        case .mid: "1 kHz"
        case .treble: "8 kHz"
        }
    }
}

extension AudioEqualizerSettings {
    /// The preset name, or "Graves +3 · Medios 0 · Agudos −2 dB".
    @MainActor
    func summary(_ l10n: L10n) -> String {
        if let preset = EqualizerPreset.matching(self) { return preset.title(l10n) }
        let bands = EqualizerBand.allCases.map { band in
            "\(band.title(l10n)) \(EqualizerFormat.gain(self[band], unit: false))"
        }
        return bands.joined(separator: " · ") + " dB"
    }
}

enum EqualizerFormat {
    /// "+3 dB", "0 dB", "−2 dB", with a true minus sign.
    static func gain(_ value: Double, unit: Bool = true) -> String {
        let rounded = Int(value.rounded())
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "−" : "")
        return "\(sign)\(abs(rounded))" + (unit ? " dB" : "")
    }
}

/// Popover with the three bands of an app's equalizer.
struct EqualizerPanel: View {
    let appName: String
    let onChange: (AudioEqualizerSettings) -> Void
    let onCommit: () -> Void

    @State private var draft: AudioEqualizerSettings
    @ObservedObject private var l10n = L10n.shared

    init(
        appName: String,
        settings: AudioEqualizerSettings,
        onChange: @escaping (AudioEqualizerSettings) -> Void,
        onCommit: @escaping () -> Void
    ) {
        self.appName = appName
        self.onChange = onChange
        self.onCommit = onCommit
        _draft = State(initialValue: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("Ecualizador", "Equalizer", "イコライザー"))
                        .font(.headline)
                    Text(appName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                presetMenu
            }

            VStack(spacing: 10) {
                ForEach(EqualizerBand.allCases, id: \.self) { band in
                    bandRow(band)
                }
            }

            Text(l10n.t(
                "Para que nunca sature, al realzar una banda el nivel general baja en la misma medida.",
                "To prevent clipping, boosting a band lowers the overall level by the same amount.",
                "音割れを防ぐため、帯域をブーストすると全体の音量が同じだけ下がります。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(l10n.t("Dejar plano", "Set flat", "フラットに戻す")) {
                    apply(.flat)
                }
                .disabled(draft.isFlat)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private var presetMenu: some View {
        Menu {
            ForEach(EqualizerPreset.allCases) { preset in
                Button {
                    apply(preset.settings)
                } label: {
                    if EqualizerPreset.matching(draft) == preset {
                        Label(preset.title(l10n), systemImage: "checkmark")
                    } else {
                        Text(preset.title(l10n))
                    }
                }
            }
        } label: {
            Text(EqualizerPreset.matching(draft)?.title(l10n) ?? l10n.t("Personalizado", "Custom", "カスタム"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(l10n.t("Preajustes", "Presets", "プリセット"))
    }

    private func bandRow(_ band: EqualizerBand) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(band.title(l10n))
                    .font(.subheadline)
                Text(band.frequencyLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 66, alignment: .leading)

            Slider(
                value: binding(for: band),
                in: AudioEqualizerSettings.gainRange,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
            )
            .controlSize(.small)

            Text(EqualizerFormat.gain(draft[band]))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(draft[band] == 0 ? Color.secondary : Theme.accent)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func binding(for band: EqualizerBand) -> Binding<Double> {
        Binding(
            get: { draft[band] },
            set: { newValue in
                guard draft[band] != newValue else { return }
                draft[band] = newValue
                onChange(draft)
            }
        )
    }

    private func apply(_ settings: AudioEqualizerSettings) {
        draft = settings
        onChange(settings)
        onCommit()
    }
}
