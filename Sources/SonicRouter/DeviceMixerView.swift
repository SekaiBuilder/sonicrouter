import SwiftUI

struct DeviceMixerView: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @ObservedObject private var l10n = L10n.shared

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 14, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(
                title: l10n.t("Dispositivos", "Devices", "デバイス"),
                subtitle: l10n.t(
                    "\(audioStore.outputDevices.count) salidas · \(audioStore.inputDevices.count) entradas",
                    "\(audioStore.outputDevices.count) outputs · \(audioStore.inputDevices.count) inputs",
                    "出力 \(audioStore.outputDevices.count) · 入力 \(audioStore.inputDevices.count)"
                )
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let defaultOutput = audioStore.outputDevices.first(where: \.isDefaultOutput) {
                        ActiveOutputStrip(device: defaultOutput)
                    }

                    if audioStore.multiOutputCandidates.count >= 2 || audioStore.multiOutputDevice != nil {
                        MultiOutputCard()
                    }

                    DeviceSection(title: l10n.t("Salidas", "Outputs", "出力")) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(audioStore.outputDevices) { device in
                                DeviceCard(device: device, mode: .output)
                            }
                        }
                    }

                    DeviceSection(title: l10n.t("Entradas", "Inputs", "入力")) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(audioStore.inputDevices) { device in
                                DeviceCard(device: device, mode: .input)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }
}

private struct ActiveOutputStrip: View {
    let device: AudioDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(L10n.shared.t("Salida del sistema", "System output", "システム出力"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let volume = device.outputVolume {
                Text("\(Int(volume * 100))%")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Plays the system output on several devices at once through a native
/// macOS multi-output device, so the sound is the original stream on each.
private struct MultiOutputCard: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @ObservedObject private var l10n = L10n.shared
    /// UIDs the user turned off; everything else is in, so new devices join by default.
    @State private var excludedUIDs: Set<String> = []

    private var selected: [AudioDevice] {
        audioStore.multiOutputCandidates.filter { !excludedUIDs.contains($0.uid) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hifispeaker.2.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(l10n.t("Salida múltiple", "Multi-output", "複数出力"))
                            .font(.headline)
                        if audioStore.multiOutputDevice?.isDefaultOutput == true {
                            Badge(text: l10n.t("activa", "active", "使用中"))
                        }
                    }
                    Text(l10n.t(
                        "Todo el audio suena a la vez en las salidas elegidas, con el sonido original de macOS.",
                        "All audio plays at once on the chosen outputs, with macOS's original sound.",
                        "選んだ出力すべてで、macOSの元の音のまま同時に再生します。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(audioStore.multiOutputCandidates) { device in
                    Toggle(device.name, isOn: Binding(
                        get: { !excludedUIDs.contains(device.uid) },
                        set: { isOn in
                            if isOn { excludedUIDs.remove(device.uid) } else { excludedUIDs.insert(device.uid) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }

            HStack(spacing: 8) {
                Button {
                    audioStore.useMultiOutput(selected)
                } label: {
                    Label(
                        audioStore.multiOutputDevice == nil
                            ? l10n.t("Crear y usar", "Create and use", "作成して使用")
                            : l10n.t("Actualizar y usar", "Update and use", "更新して使用"),
                        systemImage: "speaker.wave.2.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.count < 2)

                if audioStore.multiOutputDevice != nil {
                    Button(role: .destructive) {
                        audioStore.removeMultiOutput()
                    } label: {
                        Label(l10n.t("Quitar", "Remove", "削除"), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)

            Text(l10n.t(
                "El volumen se ajusta en cada dispositivo; macOS no da un volumen común a la salida múltiple.",
                "Set the volume on each device; macOS gives a multi-output device no shared volume.",
                "音量は各デバイスで調整します。複数出力には共通の音量がありません。"
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct DeviceSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

private struct DeviceCard: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    let device: AudioDevice
    let mode: DeviceMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode == .output ? "speaker.wave.2.fill" : "mic.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if device.isDefaultOutput && mode == .output {
                            Badge(text: L10n.shared.t("salida", "output", "出力"))
                        }
                        if device.isDefaultInput && mode == .input {
                            Badge(text: L10n.shared.t("entrada", "input", "入力"))
                        }
                        if device.isDefaultSystemOutput && mode == .output {
                            Badge(text: L10n.shared.t("sistema", "system", "システム"))
                        }
                    }
                }
                Spacer(minLength: 8)
            }

            VolumeControl(
                title: mode == .output
                    ? L10n.shared.t("Volumen", "Volume", "音量")
                    : L10n.shared.t("Entrada", "Input", "入力"),
                symbol: mode == .output ? "speaker.wave.3" : "mic",
                value: mode == .output ? device.outputVolume : device.inputVolume,
                onChange: { value in
                    if mode == .output {
                        audioStore.setOutputVolume(value, for: device)
                    } else {
                        audioStore.setInputVolume(value, for: device)
                    }
                }
            )

            Button {
                if mode == .output {
                    audioStore.makeDefaultOutput(device)
                } else {
                    audioStore.makeDefaultInput(device)
                }
            } label: {
                Label(
                    mode == .output
                        ? L10n.shared.t("Usar salida", "Use as output", "出力に設定")
                        : L10n.shared.t("Usar entrada", "Use as input", "入力に設定"),
                    systemImage: "checkmark.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct VolumeControl: View {
    let title: String
    let symbol: String
    let value: Double?
    let onChange: (Double) -> Void

    @State private var draftValue: Double = 1
    @State private var pendingUpdate: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline)
                Spacer()
                Text(valueText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if value != nil {
                Slider(
                    value: $draftValue,
                    in: 0...1,
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            commit(draftValue, delay: 0)
                        }
                    }
                )
                .onChange(of: draftValue) { _, newValue in
                    // Skip the syncs from `onAppear` / `value` below: they would
                    // otherwise write the device's current volume back to
                    // CoreAudio (and surface any error) each time a card appears.
                    guard let value, abs(newValue - value) > 0.001 else { return }
                    commit(newValue, delay: 0.08)
                }
                .onAppear {
                    draftValue = value ?? draftValue
                }
                .onChange(of: value) { _, newValue in
                    if let newValue, abs(newValue - draftValue) > 0.015 {
                        draftValue = newValue
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "lock")
                    Text(L10n.shared.t("Sin control", "No control", "調整不可"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var valueText: String {
        guard value != nil else { return L10n.shared.t("bloqueado", "locked", "ロック") }
        return "\(Int(draftValue * 100))%"
    }

    private func commit(_ value: Double, delay: TimeInterval) {
        pendingUpdate?.cancel()
        pendingUpdate = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            onChange(value)
        }
    }
}

private enum DeviceMode {
    case input
    case output
}
