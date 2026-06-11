import SwiftUI

struct DeviceMixerView: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 14, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(
                title: "Dispositivos",
                subtitle: "\(audioStore.outputDevices.count) salidas · \(audioStore.inputDevices.count) entradas"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let defaultOutput = audioStore.outputDevices.first(where: \.isDefaultOutput) {
                        ActiveOutputStrip(device: defaultOutput)
                    }

                    DeviceSection(title: "Salidas") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(audioStore.outputDevices) { device in
                                DeviceCard(device: device, mode: .output)
                            }
                        }
                    }

                    DeviceSection(title: "Entradas") {
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
                Text("Salida del sistema")
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
                            Badge(text: "salida")
                        }
                        if device.isDefaultInput && mode == .input {
                            Badge(text: "entrada")
                        }
                        if device.isDefaultSystemOutput && mode == .output {
                            Badge(text: "sistema")
                        }
                    }
                }
                Spacer(minLength: 8)
            }

            VolumeControl(
                title: mode == .output ? "Volumen" : "Entrada",
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
                Label(mode == .output ? "Usar salida" : "Usar entrada", systemImage: "checkmark.circle")
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
                    Text("Sin control")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var valueText: String {
        guard value != nil else { return "bloqueado" }
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
