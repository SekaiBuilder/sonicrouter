import Foundation
import CoreAudio
import Combine

@MainActor
final class AudioDeviceStore: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published var selectedDeviceID: AudioObjectID?
    @Published var statusMessage = "Listo"
    @Published var lastError: String?

    private var refreshTimer: AnyCancellable?

    init() {
        refreshTimer = Timer.publish(every: 4, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh(quietly: true)
            }
    }

    var outputDevices: [AudioDevice] {
        devices.filter(\.hasOutput)
    }

    var inputDevices: [AudioDevice] {
        devices.filter(\.hasInput)
    }

    var selectedDevice: AudioDevice? {
        guard let selectedDeviceID else {
            return devices.first(where: \.isDefaultOutput) ?? devices.first
        }
        return devices.first { $0.id == selectedDeviceID }
    }

    func refresh(quietly: Bool = false) {
        devices = CoreAudioClient.devices()
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first(where: \.isDefaultOutput)?.id ?? devices.first?.id
        }
        if !quietly {
            statusMessage = "Dispositivos actualizados"
        }
    }

    func select(_ device: AudioDevice) {
        selectedDeviceID = device.id
    }

    func makeDefaultOutput(_ device: AudioDevice) {
        run("Salida activa: \(device.name)") {
            try CoreAudioClient.setDefaultOutput(device.id)
        }
    }

    func makeDefaultInput(_ device: AudioDevice) {
        run("Entrada activa: \(device.name)") {
            try CoreAudioClient.setDefaultInput(device.id)
        }
    }

    func setOutputVolume(_ volume: Double, for device: AudioDevice) {
        runWithoutRefresh("Volumen de salida: \(Int(volume * 100))%") {
            try CoreAudioClient.setOutputVolume(volume, for: device.id)
            updateVolume(volume, for: device.id, output: true)
        }
    }

    func setInputVolume(_ volume: Double, for device: AudioDevice) {
        runWithoutRefresh("Volumen de entrada: \(Int(volume * 100))%") {
            try CoreAudioClient.setInputVolume(volume, for: device.id)
            updateVolume(volume, for: device.id, output: false)
        }
    }

    private func run(_ successMessage: String, action: () throws -> Void) {
        do {
            try action()
            lastError = nil
            refresh()
            statusMessage = successMessage
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Hubo un problema"
        }
    }

    private func runWithoutRefresh(_ successMessage: String, action: () throws -> Void) {
        do {
            try action()
            lastError = nil
            statusMessage = successMessage
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Hubo un problema"
        }
    }

    private func updateVolume(_ volume: Double, for deviceID: AudioObjectID, output: Bool) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        if output {
            devices[index].outputVolume = volume
        } else {
            devices[index].inputVolume = volume
        }
    }
}
