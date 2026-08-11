import Foundation
import CoreAudio

@MainActor
final class AudioDeviceStore: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published var selectedDeviceID: AudioObjectID?
    @Published var statusMessage = "Listo"
    @Published var lastError: String?

    private struct SystemListener {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var systemListeners: [SystemListener] = []
    private var refreshTask: Task<Void, Never>?
    private var visibleSurfaces: Set<SonicRouterInterfaceSurface> = []

    init() {}

    deinit {
        MainActor.assumeIsolated {
            refreshTask?.cancel()
            removeSystemListeners()
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

    func setInterfaceVisible(_ surface: SonicRouterInterfaceSurface, _ isVisible: Bool) {
        if isVisible {
            visibleSurfaces.insert(surface)
        } else {
            visibleSurfaces.remove(surface)
        }

        updateObservationState()

        if isVisible {
            refresh(quietly: true)
        }
    }

    func refresh(quietly: Bool = false) {
        let latestDevices = CoreAudioClient.devices()
        if devices != latestDevices {
            devices = latestDevices
        }
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

    private func scheduleRefresh(quietly: Bool = true, after delay: Duration = .milliseconds(150)) {
        guard isInterfaceVisible else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh(quietly: quietly)
        }
    }

    private var isInterfaceVisible: Bool {
        !visibleSurfaces.isEmpty
    }

    private func updateObservationState() {
        if isInterfaceVisible {
            installSystemListeners()
        } else {
            refreshTask?.cancel()
            removeSystemListeners()
        }
    }

    private func installSystemListeners() {
        guard systemListeners.isEmpty else { return }
        [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice
        ].forEach(addSystemListener)
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        guard status == noErr else { return }
        systemListeners.append(SystemListener(address: address, block: block))
    }

    private func removeSystemListeners() {
        for listener in systemListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener.block
            )
        }
        systemListeners.removeAll()
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
