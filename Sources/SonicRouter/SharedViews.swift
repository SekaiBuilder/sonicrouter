import AppKit
import SwiftUI

// MARK: - Design tokens

enum Theme {
    static let accent = Color(red: 0.36, green: 0.42, blue: 0.99)
    static let cornerRadius: CGFloat = 12
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let stroke = Color.primary.opacity(0.07)
}

extension View {
    /// Soft card surface used across the app for a calm, minimalist look.
    func card(_ padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}

// MARK: - Headers & labels

struct HeaderView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

struct SectionLabel: View {
    let text: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
        }
    }
}

struct Badge: View {
    let text: String
    var tint: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - App icon

/// Real app icon when available, with a tasteful symbol fallback for system
/// audio sources (FaceTime/avconferenced) that have no app icon.
struct AppIconView: View {
    let session: AppAudioSession
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let icon = NSRunningApplication(processIdentifier: session.processIdentifier)?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .fill(Theme.accent.opacity(0.16))
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }

    private var fallbackSymbol: String {
        let name = session.name.lowercased()
        if name.contains("facetime") || name.contains("llamada") || name.contains("teléfono") {
            return "phone.fill"
        }
        return "waveform"
    }
}

// MARK: - Playing indicator

/// Lightweight animated equalizer shown next to apps that are producing audio.
struct PlayingBars: View {
    var color: Color = Theme.accent
    var bars = 3

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: height(time: time, index: index))
                }
            }
            .frame(height: 14)
        }
    }

    private func height(time: TimeInterval, index: Int) -> CGFloat {
        let phase = time * 6.5 + Double(index) * 1.4
        return 4 + (sin(phase) * 0.5 + 0.5) * 10
    }
}

// MARK: - Power mode chip

/// Live readout of how hard the app is working — green leaf when idle, accent
/// bolt when actively watching audio, moon when suspended. When handlers are
/// passed it becomes a click target: a menu to suspend/resume or quit the app.
struct PowerModeChip: View {
    let mode: SonicRouterPowerMode
    var isSuspended: Bool = false
    var onToggleSuspend: (() -> Void)? = nil
    var onQuit: (() -> Void)? = nil
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        if onToggleSuspend != nil || onQuit != nil {
            Menu {
                if let onToggleSuspend {
                    Button {
                        onToggleSuspend()
                    } label: {
                        Label(
                            isSuspended
                                ? l10n.t("Reanudar", "Resume", "再開")
                                : l10n.t("Suspender", "Suspend", "一時停止"),
                            systemImage: isSuspended ? "play.fill" : "pause.fill"
                        )
                    }
                }
                if let onQuit {
                    Divider()
                    Button(role: .destructive) {
                        onQuit()
                    } label: {
                        Label(l10n.t("Salir de SonicRouter", "Quit SonicRouter", "SonicRouterを終了"), systemImage: "power")
                    }
                }
            } label: {
                chip
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
        } else {
            chip
        }
    }

    private var modeLabel: String {
        switch mode {
        case .active: l10n.t("Activo", "Active", "稼働中")
        case .idle: l10n.t("En reposo", "Idle", "待機中")
        case .suspended: l10n.t("Suspendido", "Suspended", "停止中")
        }
    }

    private var modeDetail: String {
        switch mode {
        case .active: l10n.t("Vigilando audio en vivo", "Watching live audio", "オーディオを監視中")
        case .idle: l10n.t("Sin escuchas activas — consumo mínimo", "No active listeners — minimal usage", "監視なし — 最小消費")
        case .suspended: l10n.t("Motores liberados", "Engines released", "エンジン解放済み")
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            Image(systemName: mode.symbol)
                .imageScale(.small)
                .contentTransition(.symbolEffect(.replace))
            Text(modeLabel)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
        .help(actionable ? l10n.t("Tócalo para suspender o salir", "Click to suspend or quit", "クリックで一時停止・終了") : modeDetail)
        .animation(.easeInOut(duration: 0.2), value: mode)
    }

    private var actionable: Bool {
        onToggleSuspend != nil || onQuit != nil
    }

    private var tint: Color {
        switch mode {
        case .active: Theme.accent
        case .idle: .green
        case .suspended: .secondary
        }
    }
}

// MARK: - Volume slider

struct AppVolumeSlider: View {
    @Binding var value: Double
    var muted: Bool
    var enabled: Bool
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: speakerSymbol)
                .foregroundStyle(muted ? Color.red : .secondary)
                .frame(width: 18)
                .contentTransition(.symbolEffect(.replace))
            Slider(value: $value, in: 0...1, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .disabled(!enabled)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .opacity(enabled ? (muted ? 0.55 : 1) : 0.4)
    }

    private var speakerSymbol: String {
        if muted || value <= 0.001 { return "speaker.slash.fill" }
        if value < 0.4 { return "speaker.wave.1.fill" }
        if value < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

// MARK: - App mixer row (shared by window + menu bar)

struct AppMixerRow: View {
    let session: AppAudioSession
    var compact = false
    var onMute: (Bool) -> Void
    var onVolume: (Double) -> Void
    var onCommit: () -> Void
    var onReset: () -> Void
    /// Output devices the app can be sent to. When empty, the output picker is
    /// hidden (e.g. the compact menu-bar panel).
    var outputDevices: [AudioDevice] = []
    var onSelectOutput: ((String?) -> Void)?

    @State private var volume: Double = 1
    @State private var isHovered = false

    private var isControlled: Bool {
        session.isMuted || session.isVolumeEngaged || session.desiredVolume < 0.999 || session.desiredOutputUID != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(session: session, size: compact ? 30 : 38)

            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                HStack(spacing: 7) {
                    Text(session.name)
                        .font(compact ? .subheadline.weight(.medium) : .headline)
                        .lineLimit(1)
                    if session.isProducingAudio {
                        PlayingBars()
                    }
                    Spacer(minLength: 0)
                    if !compact, let detail = detailText {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if session.supportsVolumeControl {
                    AppVolumeSlider(
                        value: $volume,
                        muted: session.isMuted,
                        enabled: true,
                        onEditingChanged: { editing in
                            onVolume(volume)
                            if !editing { onCommit() }
                        }
                    )
                    .onChange(of: volume) { _, newValue in
                        onVolume(newValue)
                    }
                } else {
                    statusLine
                }
            }

            if let onSelectOutput, !outputDevices.isEmpty, session.supportsVolumeControl {
                outputPicker(onSelectOutput)
            }

            muteButton

            if !compact && isControlled {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L10n.shared.t("Restablecer a volumen normal", "Reset to normal volume", "通常の音量に戻す"))
            }
        }
        .padding(.vertical, compact ? 6 : 9)
        .padding(.horizontal, compact ? 4 : 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(!compact && isHovered ? Color.primary.opacity(0.045) : .clear)
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onAppear { volume = session.desiredVolume }
        .onChange(of: session.desiredVolume) { _, newValue in
            if abs(newValue - volume) > 0.001 { volume = newValue }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.caption2)
                .foregroundStyle(session.isMuted ? Color.red : .secondary)
            Text(session.isMuted
                 ? L10n.shared.t("Silenciada", "Muted", "ミュート中")
                 : (session.isProducingAudio
                    ? L10n.shared.t("Sonando", "Playing", "再生中")
                    : L10n.shared.t("En pausa", "Paused", "一時停止中")))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: 22, alignment: .leading)
    }

    private var muteButton: some View {
        Group {
            if compact {
                Button {
                    onMute(!session.isMuted)
                } label: {
                    Image(systemName: session.isMuted ? "speaker.wave.2.circle.fill" : "speaker.slash.circle.fill")
                        .font(.title3)
                        .foregroundStyle(session.isMuted ? Theme.accent : Color.red)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    onMute(!session.isMuted)
                } label: {
                    Label(
                        session.isMuted
                            ? L10n.shared.t("Activar", "Unmute", "ミュート解除")
                            : L10n.shared.t("Silenciar", "Mute", "ミュート"),
                        systemImage: session.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
                    )
                    .foregroundStyle(session.isMuted ? Theme.accent : Color.red)
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(!session.isControllable)
        .help(session.isMuted
              ? L10n.shared.t("Activar sonido", "Unmute", "ミュートを解除")
              : L10n.shared.t("Silenciar app", "Mute app", "アプリをミュート"))
    }

    private var detailText: String? {
        if !session.outputDeviceNames.isEmpty {
            return session.outputDeviceNames.joined(separator: ", ")
        }
        return session.bundleIdentifier
    }

    @ViewBuilder
    private func outputPicker(_ onSelect: @escaping (String?) -> Void) -> some View {
        let selected = session.desiredOutputUID
        Menu {
            Button {
                onSelect(nil)
            } label: {
                if selected == nil {
                    Label(L10n.shared.t("Salida predeterminada", "Default output", "既定の出力"), systemImage: "checkmark")
                } else {
                    Text(L10n.shared.t("Salida predeterminada", "Default output", "既定の出力"))
                }
            }
            Divider()
            ForEach(outputDevices) { device in
                Button {
                    onSelect(device.uid)
                } label: {
                    if selected == device.uid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            Image(systemName: "airplayaudio")
                .foregroundStyle(selected == nil ? Color.secondary : Theme.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.shared.t("Enviar esta app a otra salida", "Send this app to another output", "このアプリを別の出力へ"))
    }
}

// MARK: - Permission banner

struct PermissionBanner: View {
    var onRetry: () -> Void
    var onOpenSettings: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.t("Falta permiso de captura de audio", "Audio capture permission missing", "オーディオキャプチャの権限がありません"))
                    .font(.subheadline.weight(.semibold))
                Text(l10n.t(
                    "Para silenciar y ajustar el volumen de cada app, autoriza la grabación de audio del sistema y vuelve a intentar.",
                    "To mute and adjust each app's volume, allow system audio recording and try again.",
                    "各アプリの音量調整・ミュートには、システム音声の録音を許可して再試行してください。"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button(l10n.t("Reintentar", "Retry", "再試行"), action: onRetry)
                    .buttonStyle(.borderedProminent)
                Button(l10n.t("Abrir Ajustes", "Open Settings", "設定を開く"), action: onOpenSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Empty state

struct EmptyHint: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}
