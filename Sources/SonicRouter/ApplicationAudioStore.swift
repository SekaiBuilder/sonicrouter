import AppKit
import Combine
import CoreAudio
import Foundation

enum AudioPermission {
    case unknown
    case granted
    case denied
}

@MainActor
final class ApplicationAudioStore: ObservableObject {
    @Published private(set) var sessions: [AppAudioSession] = []
    @Published var profiles: [AudioRouteProfile] = []
    @Published private(set) var activeAudioCount = 0
    @Published private(set) var scannerStatus = "Buscando audio…"
    @Published var controlStatus = "Listo"
    @Published private(set) var permission: AudioPermission = .unknown

    /// Makeup gain for the re-emit path (0.5–8.0). The capture→re-emit chain can
    /// come out quieter than the app's native output, so this lifts it back up to
    /// match. Adjustable live from Ajustes; applied to every active volume tap.
    @Published var volumeCompensation: Double = 2.0 {
        didSet {
            let value = Float(min(8, max(0.5, volumeCompensation)))
            for tap in volumeTaps.values { tap.makeup = value }
            UserDefaults.standard.set(volumeCompensation, forKey: compensationKey)
        }
    }

    private let profilesKey = "SonicRouter.RouteProfiles"
    private let compensationKey = "SonicRouter.VolumeCompensation"
    private var refreshTimer: AnyCancellable?

    /// Desired per-app control, keyed by an app/group identity. Many apps
    /// (Chrome, FaceTime) play through helper processes, so PID alone creates
    /// duplicate sliders that point at the wrong audio object.
    private struct Control {
        var volume: Double
        var muted: Bool
    }

    private var controls: [String: Control] = [:]
    private var muteEngines: [String: MuteEngine] = [:]
    private var volumeTaps: [String: AppVolumeTap] = [:]
    private var outputListenerBlock: AudioObjectPropertyListenerBlock?
    private var terminationObserver: NSObjectProtocol?
    private var outputListenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let processTapVolumeEnabled = true

    init() {
        SonicRouterAudioCleanup.destroyOwnedAudioObjects()
        loadProfiles()
        if let saved = UserDefaults.standard.object(forKey: compensationKey) as? Double {
            volumeCompensation = min(8, max(0.5, saved))
        }
        installOutputListener()
        installTerminationObserver()
        refreshTimer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    deinit {
        SonicRouterAudioCleanup.destroyOwnedAudioObjects()
    }

    // MARK: - Permission

    /// Probes (and on first launch triggers) the system-audio-capture permission.
    func checkPermission() {
        permission = AudioCapturePermission.probe() ? .granted : .denied
    }

    func openPrivacySettings() {
        let anchors = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]
        for anchor in anchors {
            if let url = URL(string: anchor), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Scan

    private struct SessionGroup {
        let key: String
        var name: String
        var bundleIdentifier: String?
        var representativePID: pid_t
        var preferredApp: NSRunningApplication?
        var audioProcessIDs: [AudioObjectID]
        var activeAudioProcessIDs: [AudioObjectID]
        var isProducingAudio: Bool
        var outputDeviceIDs: [AudioObjectID]
    }

    func refresh() {
        let workspaceApps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier > 0 }
        let regularApps = workspaceApps.filter { $0.activationPolicy == .regular }
        let appsByPID = Dictionary(workspaceApps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let regularAppsByBundle = Dictionary(
            regularApps.compactMap { app -> (String, NSRunningApplication)? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return (bundleID, app)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let audioProcesses = CoreAudioProcessClient.allProcessesByPID()
        var groups: [String: SessionGroup] = [:]

        for info in audioProcesses.values {
            guard !isSonicRouterProcess(info, app: appsByPID[info.processIdentifier]) else { continue }
            let app = appsByPID[info.processIdentifier]
            let key = sessionKey(for: app, processInfo: info)
            let parentBundleID = parentBundleIdentifier(for: app) ?? normalizedBundleIdentifier(info.bundleIdentifier)
            let preferredApp = parentBundleID.flatMap { regularAppsByBundle[$0] } ?? app
            let name = appDisplayName(for: preferredApp ?? app, processInfo: info)
            let shouldShowOrKeep = info.isRunningOutput || controls[key] != nil

            if groups[key] == nil {
                groups[key] = SessionGroup(
                    key: key,
                    name: name,
                    bundleIdentifier: parentBundleID ?? info.bundleIdentifier,
                    representativePID: preferredApp?.processIdentifier ?? info.processIdentifier,
                    preferredApp: preferredApp,
                    audioProcessIDs: [],
                    activeAudioProcessIDs: [],
                    isProducingAudio: false,
                    outputDeviceIDs: []
                )
            }

            if var group = groups[key] {
                group.audioProcessIDs.append(info.objectID)
                if info.isRunningOutput {
                    group.activeAudioProcessIDs.append(info.objectID)
                }
                group.isProducingAudio = group.isProducingAudio || info.isRunningOutput
                group.outputDeviceIDs.append(contentsOf: info.outputDeviceIDs)

                if shouldShowOrKeep, let preferredApp {
                    group.preferredApp = preferredApp
                    group.representativePID = preferredApp.processIdentifier
                }

                groups[key] = group
            }
        }

        let visibleGroups = groups.values.filter { group in
            group.isProducingAudio || controls[group.key] != nil
        }
        activeAudioCount = visibleGroups.filter(\.isProducingAudio).count

        sessions = visibleGroups.map(makeSession(group:)).sorted { lhs, rhs in
            if lhs.isProducingAudio != rhs.isProducingAudio { return lhs.isProducingAudio }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        reconcileLifecycle(presentKeys: Set(groups.keys))
        scannerStatus = activeAudioCount == 0
            ? "Ninguna app reproduce audio ahora"
            : "\(activeAudioCount) app(s) reproduciendo audio"
    }

    // MARK: - Controls

    func setMuted(_ muted: Bool, for session: AppAudioSession) {
        let key = session.id

        if muted {
            let processIDs = controlProcessIDs(for: session)
            guard !processIDs.isEmpty else {
                controlStatus = "\(session.name) aún no tiene audio activo para controlar."
                return
            }

            if permission != .granted {
                checkPermission()
                guard permission == .granted else {
                    controlStatus = "Falta permiso de captura de audio para silenciar \(session.name)."
                    return
                }
            }

            do {
                tearDownVolume(key)
                tearDownMute(key)
                guard let outputUID = CoreAudioClient.defaultOutputDeviceUID(),
                      let outputDeviceID = CoreAudioClient.defaultOutputDeviceID() else {
                    controlStatus = "No hay dispositivo de salida disponible para silenciar."
                    return
                }
                let engine = MuteEngine(processObjectIDs: processIDs, name: session.name)
                try engine.activate(outputUID: outputUID, outputDeviceID: outputDeviceID)
                muteEngines[key] = engine
                var control = controls[key] ?? Control(volume: session.desiredVolume, muted: false)
                control.muted = true
                controls[key] = control
                mutateSession(key) { $0.isMuted = true }
                permission = .granted
                controlStatus = "\(session.name): silenciado"
            } catch {
                tearDownMute(key)
                permission = AudioCapturePermission.probe() ? .granted : .denied
                controlStatus = error.localizedDescription
            }
        } else {
            tearDownMute(key)
            var control = controls[key] ?? Control(volume: session.desiredVolume, muted: false)
            control.muted = false
            if control.volume >= 0.999 {
                controls[key] = nil
            } else {
                controls[key] = control
                // Re-engage the volume tap: muting tore it down, and without
                // this the app would play at 100% while the slider shows less.
                apply(session: session, control: control)
            }
            mutateSession(key) { $0.isMuted = false }
            controlStatus = "\(session.name): activado"
        }
    }

    /// Live volume update while dragging — adjusts the engine gain but does not
    /// hit disk. Call `commitVolume(for:)` when the drag ends to persist.
    func setVolume(_ volume: Double, for session: AppAudioSession) {
        let clamped = min(1, max(0, volume))
        var control = controls[session.id] ?? Control(volume: clamped, muted: false)
        control.volume = clamped
        controls[session.id] = control
        if session.supportsVolumeControl,
           !controlProcessIDs(for: session).isEmpty,
           !apply(session: session, control: control) {
            controls[session.id]?.volume = session.desiredVolume
            return
        }
        if !session.supportsVolumeControl {
            controlStatus = "Volumen guardado para la UI. Para que afecte el audio real hace falta el driver local."
        }
        mutateSession(session.id) { $0.desiredVolume = clamped }
    }

    func commitVolume(for session: AppAudioSession) {
        let volume = controls[session.id]?.volume ?? session.desiredVolume
        persistVolume(volume, for: session)
    }

    /// Restores an app to normal, untouched playback.
    func reset(_ session: AppAudioSession) {
        controls[session.id] = nil
        tearDownAll(session.id)
        persistVolume(1, for: session)
        mutateSession(session.id) {
            $0.isMuted = false
            $0.desiredVolume = 1
        }
        controlStatus = "\(session.name): volumen normal"
    }

    /// Emergency restore: destroys every SonicRouter tap/aggregate and clears
    /// live controls. Use this if a call/app remains silent after experimenting.
    func resetAllControls(updateStatus: Bool = true) {
        for key in Array(muteEngines.keys) {
            tearDownMute(key)
        }
        for key in Array(volumeTaps.keys) {
            tearDownVolume(key)
        }
        SonicRouterAudioCleanup.destroyOwnedAudioObjects()
        controls.removeAll()
        for index in sessions.indices {
            sessions[index].isMuted = false
            sessions[index].desiredVolume = 1
        }
        if updateStatus {
            controlStatus = "Audio restaurado"
        }
    }

    @discardableResult
    private func apply(session: AppAudioSession, control: Control) -> Bool {
        let key = session.id
        let name = session.name
        let wantMute = control.muted || control.volume <= 0.001
        // Once the re-emit engine is running, keep it running even at 100%:
        // tearing it down would switch back to the native path, which plays at
        // a different loudness and makes 100 → 99 sound like a cliff. The tap
        // only goes away with "Restablecer", mute, or when the app stops.
        let wantVolume = !wantMute && (control.volume < 0.999 || volumeTaps[key] != nil)

        do {
            if wantMute {
                tearDownVolume(key)
                if muteEngines[key] == nil {
                    let processIDs = controlProcessIDs(for: session)
                    guard !processIDs.isEmpty else {
                        controlStatus = "\(name) aún no tiene audio activo para controlar."
                        return false
                    }
                    guard let outputUID = CoreAudioClient.defaultOutputDeviceUID(),
                          let outputDeviceID = CoreAudioClient.defaultOutputDeviceID() else {
                        controlStatus = "No hay dispositivo de salida disponible para silenciar."
                        return false
                    }
                    let engine = MuteEngine(processObjectIDs: processIDs, name: name)
                    try engine.activate(outputUID: outputUID, outputDeviceID: outputDeviceID)
                    muteEngines[key] = engine
                }
                permission = .granted
                controlStatus = "\(name): silenciado"
                return true
            }

            tearDownMute(key)

            if wantVolume {
                guard processTapVolumeEnabled else {
                    tearDownVolume(key)
                    controlStatus = "El volumen por app requiere instalar un driver local tipo Background Music."
                    return false
                }
                guard let outputUID = CoreAudioClient.defaultOutputDeviceUID(),
                      let outputDeviceID = CoreAudioClient.defaultOutputDeviceID() else {
                    controlStatus = "No hay dispositivo de salida para re-emitir el audio."
                    return false
                }
                if let tap = volumeTaps[key], tap.outputUID == outputUID {
                    tap.gain = VolumeCurve.gain(forSlider: control.volume)
                } else {
                    tearDownVolume(key)
                    let tap = AppVolumeTap(
                        pid: session.processIdentifier,
                        processObjectIDs: controlProcessIDs(for: session),
                        gain: VolumeCurve.gain(forSlider: control.volume),
                        makeup: Float(min(8, max(0.5, volumeCompensation))),
                        outputUID: outputUID,
                        outputDeviceID: outputDeviceID
                    )
                    try tap.activate()
                    volumeTaps[key] = tap
                }
                permission = .granted
                controlStatus = "\(name): volumen \(Int((control.volume * 100).rounded()))%"
                return true
            }

            tearDownVolume(key)
            if !control.muted && control.volume >= 0.999 {
                controls[key] = nil
            }
            controlStatus = "\(name): volumen normal"
            return true
        } catch {
            tearDownAll(key)
            permission = AudioCapturePermission.probe() ? .granted : .denied
            controlStatus = error.localizedDescription
            return false
        }
    }

    // MARK: - Lifecycle reconciliation

    private func reconcileLifecycle(presentKeys: Set<String>) {
        for key in Array(muteEngines.keys) where !presentKeys.contains(key) {
            tearDownMute(key)
            controls[key] = nil
        }
        for key in Array(volumeTaps.keys) where !presentKeys.contains(key) {
            tearDownVolume(key)
            controls[key] = nil
        }
    }

    private func handleOutputChange() {
        guard let outputUID = CoreAudioClient.defaultOutputDeviceUID(),
              let outputDeviceID = CoreAudioClient.defaultOutputDeviceID() else { return }
        for (key, tap) in volumeTaps where tap.outputUID != outputUID {
            let sliderVolume = controls[key]?.volume ?? 1
            let processObjectIDs = tap.processObjectIDs
            tap.invalidate()
            volumeTaps[key] = nil
            let rebuilt = AppVolumeTap(
                pid: tap.pid,
                processObjectIDs: processObjectIDs,
                gain: VolumeCurve.gain(forSlider: sliderVolume),
                makeup: Float(min(8, max(0.5, volumeCompensation))),
                outputUID: outputUID,
                outputDeviceID: outputDeviceID
            )
            if (try? rebuilt.activate()) != nil {
                volumeTaps[key] = rebuilt
            }
        }
    }

    private func tearDownMute(_ key: String) {
        if let engine = muteEngines.removeValue(forKey: key) {
            engine.invalidate()
        }
    }

    private func tearDownVolume(_ key: String) {
        if let tap = volumeTaps.removeValue(forKey: key) { tap.invalidate() }
    }

    private func tearDownAll(_ key: String) {
        tearDownMute(key)
        tearDownVolume(key)
    }

    private func installOutputListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleOutputChange() }
        }
        outputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outputListenerAddress, DispatchQueue.main, block
        )
    }

    private func installTerminationObserver() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resetAllControls(updateStatus: false)
            }
        }
    }

    private func mutateSession(_ id: String, _ transform: (inout AppAudioSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        transform(&sessions[index])
    }

    // MARK: - Session building

    private func makeSession(group: SessionGroup) -> AppAudioSession {
        let name = group.name
        let bundleID = group.bundleIdentifier
        let hasAudioObject = !group.audioProcessIDs.isEmpty

        let profile = profiles.first { profile in
            profile.bundleIdentifier == bundleID || profile.appName == name || profile.appName == group.preferredApp?.localizedName
        }
        let control = controls[group.key]
        let supportsVolumeControl = processTapVolumeEnabled && hasAudioObject
        let displayedVolume = supportsVolumeControl ? (control?.volume ?? profile?.volume ?? 1) : 1

        return AppAudioSession(
            id: group.key,
            name: name,
            bundleIdentifier: bundleID,
            processIdentifier: group.representativePID,
            audioProcessID: group.audioProcessIDs.first,
            audioProcessIDs: group.audioProcessIDs,
            activeAudioProcessIDs: group.activeAudioProcessIDs,
            isProducingAudio: group.isProducingAudio,
            isCapturable: hasAudioObject,
            isMuted: control?.muted ?? false,
            outputDeviceNames: CoreAudioProcessClient.deviceNames(for: Array(Set(group.outputDeviceIDs))),
            desiredVolume: displayedVolume,
            desiredOutputUID: profile?.outputDeviceUID,
            isControllable: hasAudioObject,
            supportsVolumeControl: supportsVolumeControl,
            isVolumeEngaged: volumeTaps[group.key] != nil
        )
    }

    private func controlProcessIDs(for session: AppAudioSession) -> [AudioObjectID] {
        session.activeAudioProcessIDs.isEmpty ? session.audioProcessIDs : session.activeAudioProcessIDs
    }

    private func sessionKey(for app: NSRunningApplication?, processInfo: CoreAudioProcessInfo) -> String {
        let identifiers = [processInfo.bundleIdentifier, app?.localizedName].compactMap { $0?.lowercased() }
        if identifiers.contains(where: { $0.contains("avconferenced") || $0.contains("callservicesd") }) {
            return "system:facetime-call"
        }
        if identifiers.contains(where: { $0.contains("rapportd") }) {
            return "system:continuity-call"
        }

        if let bundleID = parentBundleIdentifier(for: app) ?? normalizedBundleIdentifier(processInfo.bundleIdentifier) {
            return "bundle:\(bundleID)"
        }
        return "pid:\(processInfo.processIdentifier)"
    }

    private func isSonicRouterProcess(_ processInfo: CoreAudioProcessInfo, app: NSRunningApplication?) -> Bool {
        if processInfo.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return true
        }
        let identifiers = [processInfo.bundleIdentifier, app?.bundleIdentifier].compactMap { $0?.lowercased() }
        return identifiers.contains("local.sonicrouter.app")
    }

    private func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let helperTokens = [".helper", ".Helper", ".renderer", ".Renderer"]
        for token in helperTokens {
            if let range = bundleIdentifier.range(of: token) {
                return String(bundleIdentifier[..<range.lowerBound])
            }
        }
        return bundleIdentifier
    }

    private func parentBundleIdentifier(for app: NSRunningApplication?) -> String? {
        guard let bundleURL = app?.bundleURL else { return app?.bundleIdentifier }
        if bundleURL.pathExtension == "app",
           let bundleID = Bundle(url: bundleURL)?.bundleIdentifier,
           !bundleID.localizedCaseInsensitiveContains("helper") {
            return bundleID
        }

        let components = bundleURL.pathComponents
        for index in components.indices.reversed() where components[index].hasSuffix(".app") {
            let appPath = NSString.path(withComponents: Array(components[...index]))
            let appURL = URL(fileURLWithPath: appPath)
            if let bundleID = Bundle(url: appURL)?.bundleIdentifier,
               !bundleID.localizedCaseInsensitiveContains("helper") {
                return bundleID
            }
        }

        return normalizedBundleIdentifier(app?.bundleIdentifier)
    }

    private func appDisplayName(for app: NSRunningApplication?, processInfo: CoreAudioProcessInfo?) -> String {
        if let appName = app?.localizedName, !appName.isEmpty {
            if let mappedName = mappedSystemAudioName(bundleIdentifier: processInfo?.bundleIdentifier, processName: appName) {
                return mappedName
            }
            return normalizedHelperName(appName, bundleURL: app?.bundleURL)
        }
        if let mappedName = mappedSystemAudioName(bundleIdentifier: processInfo?.bundleIdentifier, processName: nil) {
            return mappedName
        }
        if let bundleID = processInfo?.bundleIdentifier, !bundleID.isEmpty {
            return bundleID
        }
        if let pid = processInfo?.processIdentifier {
            return "Proceso \(pid)"
        }
        return "App desconocida"
    }

    private func mappedSystemAudioName(bundleIdentifier: String?, processName: String?) -> String? {
        let identifiers = [bundleIdentifier, processName].compactMap { $0?.lowercased() }
        if identifiers.contains(where: { $0.contains("avconferenced") }) {
            return "FaceTime / Llamada Apple"
        }
        if identifiers.contains(where: { $0.contains("callservicesd") }) {
            return "FaceTime / Teléfono"
        }
        if identifiers.contains(where: { $0.contains("rapportd") }) {
            return "Continuity / Llamada Apple"
        }
        return nil
    }

    private func normalizedHelperName(_ name: String, bundleURL: URL?) -> String {
        let lowercasedName = name.lowercased()
        guard lowercasedName.contains("helper"), let bundleURL else { return name }
        let components = bundleURL.pathComponents
        if let outerApp = components.first(where: { $0.hasSuffix(".app") }) {
            return String(outerApp.dropLast(4))
        }
        return name
    }

    // MARK: - Profiles

    func updateOutput(for session: AppAudioSession, outputDeviceUID: String?) {
        saveProfile(for: session, outputDeviceUID: outputDeviceUID, volume: session.desiredVolume, shouldRefresh: false)
        mutateSession(session.id) { $0.desiredOutputUID = outputDeviceUID }
    }

    private func persistVolume(_ volume: Double, for session: AppAudioSession) {
        saveProfile(for: session, outputDeviceUID: session.desiredOutputUID, volume: volume, shouldRefresh: false)
    }

    func saveProfile(for session: AppAudioSession, outputDeviceUID: String?, volume: Double, shouldRefresh: Bool = true) {
        let profile = AudioRouteProfile(
            name: "\(session.name) route",
            appName: session.name,
            bundleIdentifier: session.bundleIdentifier,
            outputDeviceUID: outputDeviceUID,
            volume: volume
        )
        profiles.removeAll { existing in
            existing.bundleIdentifier == session.bundleIdentifier || existing.appName == session.name
        }
        profiles.append(profile)
        saveProfiles()
        if shouldRefresh { refresh() }
    }

    func removeProfile(for session: AppAudioSession) {
        profiles.removeAll { existing in
            existing.bundleIdentifier == session.bundleIdentifier || existing.appName == session.name
        }
        saveProfiles()
        refresh()
    }

    func removeProfile(_ profile: AudioRouteProfile) {
        profiles.removeAll { $0.id == profile.id }
        saveProfiles()
    }

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: profilesKey) else { return }
        profiles = (try? JSONDecoder().decode([AudioRouteProfile].self, from: data)) ?? []
    }

    private func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: profilesKey)
    }
}
