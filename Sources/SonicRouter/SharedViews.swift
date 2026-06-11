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

    @State private var volume: Double = 1

    private var isControlled: Bool {
        session.isMuted || session.isVolumeEngaged || session.desiredVolume < 0.999
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

            muteButton

            if !compact && isControlled {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Restablecer a volumen normal")
            }
        }
        .padding(.vertical, compact ? 6 : 9)
        .padding(.horizontal, compact ? 4 : 2)
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
            Text(session.isMuted ? "Silenciada" : (session.isProducingAudio ? "Sonando" : "En pausa"))
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
                        session.isMuted ? "Activar" : "Silenciar",
                        systemImage: session.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
                    )
                    .foregroundStyle(session.isMuted ? Theme.accent : Color.red)
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(!session.isControllable)
        .help(session.isMuted ? "Activar sonido" : "Silenciar app")
    }

    private var detailText: String? {
        if !session.outputDeviceNames.isEmpty {
            return session.outputDeviceNames.joined(separator: ", ")
        }
        return session.bundleIdentifier
    }
}

// MARK: - Permission banner

struct PermissionBanner: View {
    var onRetry: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Falta permiso de captura de audio")
                    .font(.subheadline.weight(.semibold))
                Text("Para silenciar y ajustar el volumen de cada app, autoriza la grabación de audio del sistema y vuelve a intentar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button("Reintentar", action: onRetry)
                    .buttonStyle(.borderedProminent)
                Button("Abrir Ajustes", action: onOpenSettings)
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
