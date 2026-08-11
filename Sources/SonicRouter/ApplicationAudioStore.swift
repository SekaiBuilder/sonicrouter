import AppKit
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
    /// Coarse, live view of how much work the app is doing. Drives the activity
    /// indicator in the UI and reflects the battery optimizations in real time.
    @Published private(set) var powerMode: SonicRouterPowerMode = .idle
    /// User-initiated pause from the activity chip. While set, the app releases
    /// every engine and stops observing — same as system sleep, but it persists
    /// until the user resumes.
    @Published private(set) var isManuallySuspended = false

    /// Makeup gain for the re-emit path (0.5–8×). Defaults to a transparent
    /// 1:1 copy. Values above unity are constrained in realtime to the headroom
    /// of each audio block, so they can lift quiet material without
    /// hard-clipping speech peaks.
    @Published var volumeCompensation: Double = 1.0 {
        didSet {
            let clamped = min(8, max(0.5, volumeCompensation))
            if clamped != volumeCompensation {
                volumeCompensation = clamped
                return
            }
            let value = Float(clamped)
            for tap in volumeTaps.values { tap.makeup = value }
            UserDefaults.standard.set(clamped, forKey: compensationKey)
        }
    }

    private let profilesKey = "SonicRouter.RouteProfiles"
    private let compensationKey = "SonicRouter.VolumeCompensation.v4"
    private let legacyCompensationKey = "SonicRouter.VolumeCompensation.v2"
    private var refreshTask: Task<Void, Never>?

    /// Desired per-app control, keyed by an app/group identity. Many apps
    /// (Chrome, FaceTime) play through helper processes, so PID alone creates
    /// duplicate sliders that point at the wrong audio object.
    private typealias Control = AudioControlIntent
    private var controls: [String: Control] = [:]
    /// Prevents a denied or unavailable saved route from being retried on every
    /// Core Audio refresh. The key is released when the app process disappears.
    private var attemptedProfileKeys: Set<String> = []
    private var muteEngines: [String: MuteEngine] = [:]
    private var volumeTaps: [String: AppVolumeTap] = [:]
    private struct ProcessListener {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var processListeners: [AudioObjectID: [ProcessListener]] = [:]
    private var outputListenerBlock: AudioObjectPropertyListenerBlock?
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    private var terminationObserver: NSObjectProtocol?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var visibleSurfaces: Set<SonicRouterInterfaceSurface> = []
    /// While the machine sleeps we release every audio engine and stop observing
    /// so nothing keeps the audio hardware (or the CPU) awake behind a closed lid.
    private var isSystemAsleep = false
    private var outputListenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var processListListenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let processTapVolumeEnabled = true

    init() {
        SonicRouterAudioCleanup.destroyOwnedAudioObjects()
        loadProfiles()
        if let saved = UserDefaults.standard.object(forKey: compensationKey) as? Double {
            volumeCompensation = min(8, max(0.5, saved))
        } else if let calibrated = UserDefaults.standard.object(forKey: legacyCompensationKey) as? Double {
            volumeCompensation = min(8, max(0.5, calibrated))
        }
        installTerminationObserver()
        installSleepWakeObservers()
    }

    deinit {
        MainActor.assumeIsolated {
            refreshTask?.cancel()
            removeWorkspaceObservers()
            removeProcessListeners()
            removeProcessListListener()
            removeOutputListener()
            removeTerminationObserver()
            removeSleepWakeObservers()
            SonicRouterAudioCleanup.destroyOwnedAudioObjects()
        }
    }

    // MARK: - Routing integration

    /// Where re-emitting engines render when an app does not have an explicit
    /// route. Experimental virtual-driver builds used a silent device with this
    /// UID, so skip it if it is still installed on the machine.
    private var effectiveOutput: (uid: String, id: AudioObjectID)? {
        guard let uid = CoreAudioClient.defaultOutputDeviceUID(),
              let id = CoreAudioClient.defaultOutputDeviceID() else { return nil }
        if uid == SonicRouterAudioIdentifiers.legacyVirtualDeviceUID {
            if let real = CoreAudioClient.devices().first(where: { $0.hasOutput && $0.uid != uid }) {
                return (real.uid, real.id)
            }
            return nil
        }
        return (uid, id)
    }

    /// The specific device this app is sent to, if the user chose one and it is
    /// currently present. `nil` means "follow the system default".
    private func routedOutput(for control: Control) -> (uid: String, id: AudioObjectID)? {
        guard let uid = control.outputUID,
              let device = CoreAudioClient.devices().first(where: { $0.uid == uid && $0.hasOutput }) else { return nil }
        return (uid, device.id)
    }

    /// An explicit route must never fall back silently: that would make the UI
    /// claim one device while audio is actually sent somewhere else.
    private func targetOutput(for control: Control) -> (uid: String, id: AudioObjectID)? {
        control.outputUID == nil ? effectiveOutput : routedOutput(for: control)
    }

    /// Selecting the device that is already the system default must not force a
    /// capture/re-emit route. Treat it as the native/default path instead.
    private func normalizedOutputUID(_ uid: String?) -> String? {
        guard let uid else { return nil }
        return uid == effectiveOutput?.uid ? nil : uid
    }

    /// Sends an app's audio to a specific output device (its original output is
    /// muted) — or back to the system default when `uid` is nil.
    func setOutputDevice(_ uid: String?, for session: AppAudioSession) {
        defer { updateObservationState() }
        let normalizedUID = normalizedOutputUID(uid)
        let previous = controls[session.id]
        var control = previous ?? Control(volume: session.desiredVolume, muted: false)
        control.outputUID = normalizedUID
        controls[session.id] = control

        // Nothing left to do: default output, full volume, not muted.
        if normalizedUID == nil, !control.muted, control.volume >= 0.999 {
            tearDownVolume(session.id)
            controls[session.id] = nil
            mutateSession(session.id) { $0.desiredOutputUID = nil }
            saveProfile(for: session, outputDeviceUID: nil, volume: control.volume, shouldRefresh: false)
            controlStatus = L10n.shared.t("\(session.name): salida predeterminada", "\(session.name): default output", "\(session.name)：既定の出力")
            return
        }

        if session.supportsVolumeControl, !controlProcessIDs(for: session).isEmpty {
            guard apply(session: session, control: control) else {
                controls[session.id] = previous
                return
            }
        }
        mutateSession(session.id) { $0.desiredOutputUID = normalizedUID }
        saveProfile(for: session, outputDeviceUID: normalizedUID, volume: control.volume, shouldRefresh: false)
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

    func setInterfaceVisible(_ surface: SonicRouterInterfaceSurface, _ isVisible: Bool) {
        if isVisible {
            visibleSurfaces.insert(surface)
        } else {
            visibleSurfaces.remove(surface)
        }

        updateObservationState()

        if isVisible {
            refresh()
        }
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

        let audioProcesses = CoreAudioProcessClient.audioProcesses()
        if shouldObserveSessions {
            reconcileProcessListeners(currentProcessIDs: processIDsToObserve(from: audioProcesses))
        } else {
            removeProcessListeners()
        }
        var groups: [String: SessionGroup] = [:]

        for info in audioProcesses {
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

        restoreProfilesIfNeeded()
        reconcileControlEngines()
        reconcileLifecycle(presentKeys: Set(groups.keys))
        scannerStatus = activeAudioCount == 0
            ? L10n.shared.t("Ninguna app reproduce audio ahora", "No app is playing audio right now", "音声を再生中のアプリはありません")
            : L10n.shared.t("\(activeAudioCount) app(s) reproduciendo audio", "\(activeAudioCount) app(s) playing audio", "\(activeAudioCount)個のアプリが再生中")
        updateObservationState()
    }

    // MARK: - Controls

    func setMuted(_ muted: Bool, for session: AppAudioSession) {
        defer { updateObservationState() }
        let key = session.id

        if muted, permission != .granted {
            checkPermission()
            guard permission == .granted else {
                controlStatus = "Falta permiso de captura de audio para silenciar \(session.name)."
                return
            }
        }

        let previous = controls[key]
        var control = previous ?? Control(volume: session.desiredVolume, muted: false)
        control.muted = muted
        controls[key] = control

        guard apply(session: session, control: control) else {
            controls[key] = previous
            return
        }

        if !control.requiresEngine { controls[key] = nil }
        mutateSession(key) {
            $0.isMuted = muted
            $0.isVolumeEngaged = !muted && control.wantsVolumeEngine
        }
    }

    /// Live volume update while dragging — adjusts the engine gain but does not
    /// hit disk. Call `commitVolume(for:)` when the drag ends to persist.
    func setVolume(_ volume: Double, for session: AppAudioSession) {
        defer { updateObservationState() }
        let clamped = min(1, max(0, volume))
        let previous = controls[session.id]
        var control = previous ?? Control(volume: clamped, muted: false)
        control.volume = clamped
        control.outputUID = normalizedOutputUID(control.outputUID)
        controls[session.id] = control

        guard session.supportsVolumeControl, !controlProcessIDs(for: session).isEmpty else {
            controls[session.id] = previous
            controlStatus = L10n.shared.t(
                "\(session.name) aún no tiene audio activo para controlar.",
                "\(session.name) does not have active audio to control yet.",
                "\(session.name)にはまだ制御できる音声がありません。"
            )
            return
        }

        if !apply(session: session, control: control) {
            controls[session.id] = previous
            return
        }
        mutateSession(session.id) {
            $0.desiredVolume = clamped
            $0.desiredOutputUID = control.outputUID
        }
    }

    func commitVolume(for session: AppAudioSession) {
        let liveSession = sessions.first(where: { $0.id == session.id }) ?? session
        let volume = controls[session.id]?.volume ?? liveSession.desiredVolume
        persistVolume(volume, for: liveSession)
    }

    /// Restores an app to normal, untouched playback.
    func reset(_ session: AppAudioSession) {
        defer { updateObservationState() }
        controls[session.id] = nil
        tearDownAll(session.id)
        saveProfile(for: session, outputDeviceUID: nil, volume: 1, shouldRefresh: false)
        mutateSession(session.id) {
            $0.isMuted = false
            $0.desiredVolume = 1
            $0.desiredOutputUID = nil
        }
        controlStatus = L10n.shared.t("\(session.name): volumen normal", "\(session.name): normal volume", "\(session.name)：通常音量")
    }

    /// Emergency restore: destroys every SonicRouter tap/aggregate and clears
    /// live controls. Use this if a call/app remains silent after experimenting.
    func resetAllControls(updateStatus: Bool = true) {
        defer { updateObservationState() }
        releaseAudioEngines()
        controls.removeAll()
        attemptedProfileKeys.removeAll()
        for index in profiles.indices {
            profiles[index].volume = 1
            profiles[index].outputDeviceUID = nil
        }
        saveProfiles()
        for index in sessions.indices {
            sessions[index].isMuted = false
            sessions[index].desiredVolume = 1
            sessions[index].desiredOutputUID = nil
            sessions[index].isVolumeEngaged = false
        }
        if updateStatus {
            controlStatus = L10n.shared.t("Audio restaurado", "Audio restored", "オーディオを復元しました")
        }
    }

    @discardableResult
    private func apply(session: AppAudioSession, control: Control) -> Bool {
        let key = session.id
        let name = session.name
        let processIDs = controlProcessIDs(for: session)

        do {
            if control.wantsMute {
                guard !processIDs.isEmpty else {
                    controlStatus = "\(name) aún no tiene audio activo para controlar."
                    return false
                }
                guard let output = targetOutput(for: control) else {
                    controlStatus = control.outputUID == nil
                        ? L10n.shared.t(
                            "No hay dispositivo de salida disponible para silenciar.",
                            "No output device available to mute.",
                            "ミュートに使える出力デバイスがありません。"
                        )
                        : L10n.shared.t(
                            "La salida seleccionada ya no está disponible.",
                            "The selected output is no longer available.",
                            "選択した出力は利用できなくなりました。"
                        )
                    return false
                }
                let current = muteEngines[key]
                if current?.outputUID != output.uid
                    || current?.outputDeviceID != output.id
                    || Set(current?.processObjectIDs ?? []) != Set(processIDs) {
                    let engine = MuteEngine(processObjectIDs: processIDs, name: name)
                    try engine.activate(outputUID: output.uid, outputDeviceID: output.id)
                    muteEngines[key] = engine
                    current?.invalidate()
                }
                tearDownVolume(key)
                permission = .granted
                mutateSession(key) { $0.isVolumeEngaged = false }
                controlStatus = L10n.shared.t("\(name): silenciado", "\(name): muted", "\(name)：ミュート")
                return true
            }

            // Full volume on the default output must be the app's untouched
            // native path. This also guarantees that returning to 100% restores
            // the Mac's exact level without quitting SonicRouter.
            if control.wantsVolumeEngine {
                guard !processIDs.isEmpty else {
                    controlStatus = "\(name) aún no tiene audio activo para controlar."
                    return false
                }
                guard let output = targetOutput(for: control) else {
                    controlStatus = control.outputUID == nil
                        ? L10n.shared.t(
                            "No hay dispositivo de salida para re-emitir el audio.",
                            "No output device to re-emit the audio to.",
                            "再出力先の出力デバイスがありません。"
                        )
                        : L10n.shared.t(
                            "La salida seleccionada ya no está disponible.",
                            "The selected output is no longer available.",
                            "選択した出力は利用できなくなりました。"
                        )
                    return false
                }
                let current = volumeTaps[key]
                if let tap = current,
                   tap.outputUID == output.uid,
                   tap.outputDeviceID == output.id,
                   Set(tap.processObjectIDs) == Set(processIDs) {
                    tap.gain = VolumeCurve.gain(forSlider: control.volume)
                    tap.makeup = Float(min(8, max(0.5, volumeCompensation)))
                } else {
                    // A volume tap renders an audible copy of the process. Stop the
                    // previous renderer first so a route change can never play two
                    // copies at once and create echo/comb filtering.
                    volumeTaps[key] = nil
                    current?.invalidate()

                    let tap = AppVolumeTap(
                        pid: session.processIdentifier,
                        processObjectIDs: processIDs,
                        gain: VolumeCurve.gain(forSlider: control.volume),
                        makeup: Float(min(8, max(0.5, volumeCompensation))),
                        outputUID: output.uid,
                        outputDeviceID: output.id
                    )
                    try tap.activate()
                    volumeTaps[key] = tap
                }
                tearDownMute(key)
                permission = .granted
                mutateSession(key) { $0.isVolumeEngaged = true }
                controlStatus = L10n.shared.t(
                    "\(name): volumen \(Int((control.volume * 100).rounded()))%",
                    "\(name): volume \(Int((control.volume * 100).rounded()))%",
                    "\(name)：音量 \(Int((control.volume * 100).rounded()))%"
                )
                return true
            }

            tearDownAll(key)
            controls[key] = nil
            mutateSession(key) { $0.isVolumeEngaged = false }
            controlStatus = L10n.shared.t("\(name): volumen normal", "\(name): normal volume", "\(name)：通常音量")
            return true
        } catch {
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
        attemptedProfileKeys.formIntersection(presentKeys)
    }

    private func handleOutputChange() {
        defer { updateObservationState() }
        for session in sessions {
            guard let control = controls[session.id],
                  muteEngines[session.id] != nil || volumeTaps[session.id] != nil else { continue }
            _ = apply(session: session, control: control)
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

    /// Stops live Core Audio work without changing user intent or persisted
    /// profiles. Used for quit, sleep, and manual suspension.
    private func releaseAudioEngines() {
        for key in Array(muteEngines.keys) { tearDownMute(key) }
        for key in Array(volumeTaps.keys) { tearDownVolume(key) }
        SonicRouterAudioCleanup.destroyOwnedAudioObjects()
    }

    /// Apps with an active mute or volume engine right now. Derived from the
    /// published `sessions`, so the UI updates live as engines come and go.
    var controlledAppCount: Int {
        sessions.filter { $0.isMuted || $0.isVolumeEngaged }.count
    }

    private var isInterfaceVisible: Bool {
        !visibleSurfaces.isEmpty
    }

    private var hasLiveControls: Bool {
        !muteEngines.isEmpty || !volumeTaps.isEmpty
    }

    private var shouldObserveSessions: Bool {
        !isSystemAsleep && !isManuallySuspended && (isInterfaceVisible || hasLiveControls)
    }

    private var controlledProcessIDs: Set<AudioObjectID> {
        Set(muteEngines.values.flatMap(\.processObjectIDs))
            .union(volumeTaps.values.flatMap(\.processObjectIDs))
    }

    private func processIDsToObserve(from audioProcesses: [CoreAudioProcessInfo]) -> Set<AudioObjectID> {
        let currentProcessIDs = Set(audioProcesses.map(\.objectID))
        guard !isInterfaceVisible else { return currentProcessIDs }

        return currentProcessIDs.intersection(controlledProcessIDs)
    }

    private func updateObservationState() {
        if shouldObserveSessions {
            installProcessListListener()
            if isInterfaceVisible {
                installWorkspaceObservers()
            } else {
                removeWorkspaceObservers()
                reconcileProcessListeners(currentProcessIDs: controlledProcessIDs)
            }
        } else {
            refreshTask?.cancel()
            removeWorkspaceObservers()
            removeProcessListeners()
            removeProcessListListener()
        }

        if volumeTaps.isEmpty && muteEngines.isEmpty {
            removeOutputListener()
        } else {
            installOutputListener()
        }

        updatePowerMode()
    }

    private func updatePowerMode() {
        let mode: SonicRouterPowerMode
        if isSystemAsleep || isManuallySuspended {
            mode = .suspended
        } else if shouldObserveSessions {
            mode = .active
        } else {
            mode = .idle
        }
        if powerMode != mode { powerMode = mode }
    }

    // MARK: - Manual suspend (activity chip)

    /// Pause or resume from the activity chip. Suspending releases every engine
    /// and stops all observation; resuming restores the controls that were live.
    func setManuallySuspended(_ suspended: Bool) {
        guard suspended != isManuallySuspended else { return }
        isManuallySuspended = suspended

        if suspended {
            releaseAudioEngines()
            controlStatus = L10n.shared.t("SonicRouter en pausa", "SonicRouter paused", "SonicRouter一時停止中")
            updateObservationState()
        } else {
            updateObservationState()
            controlStatus = L10n.shared.t("SonicRouter reanudado", "SonicRouter resumed", "SonicRouter再開")
            refresh()
            if !controls.isEmpty {
                reapplyControls()
                refresh()
            }
        }
    }

    private func installOutputListener() {
        guard outputListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleOutputChange() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outputListenerAddress, DispatchQueue.main, block
        )
        guard status == noErr else { return }
        outputListenerBlock = block
    }

    private func removeOutputListener() {
        guard let outputListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputListenerAddress,
            DispatchQueue.main,
            outputListenerBlock
        )
        self.outputListenerBlock = nil
    }

    private func installProcessListListener() {
        guard processListListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &processListListenerAddress,
            DispatchQueue.main,
            block
        )
        guard status == noErr else { return }
        processListListenerBlock = block
    }

    private func removeProcessListListener() {
        guard let processListListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &processListListenerAddress,
            DispatchQueue.main,
            processListListenerBlock
        )
        self.processListListenerBlock = nil
    }

    private func reconcileProcessListeners(currentProcessIDs: Set<AudioObjectID>) {
        for objectID in Array(processListeners.keys) where !currentProcessIDs.contains(objectID) {
            removeProcessListeners(for: objectID)
        }

        for objectID in currentProcessIDs where processListeners[objectID] == nil {
            installProcessListeners(for: objectID)
        }
    }

    private func installProcessListeners(for objectID: AudioObjectID) {
        let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal),
            (kAudioProcessPropertyDevices, kAudioDevicePropertyScopeOutput)
        ]

        var listeners: [ProcessListener] = []
        for (selector, scope) in properties {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(objectID, &address) else { continue }

            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            let status = AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
            guard status == noErr else { continue }
            listeners.append(ProcessListener(objectID: objectID, address: address, block: block))
        }

        if !listeners.isEmpty {
            processListeners[objectID] = listeners
        }
    }

    private func removeProcessListeners() {
        for objectID in Array(processListeners.keys) {
            removeProcessListeners(for: objectID)
        }
    }

    private func removeProcessListeners(for objectID: AudioObjectID) {
        guard let listeners = processListeners.removeValue(forKey: objectID) else { return }
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                listener.objectID,
                &address,
                DispatchQueue.main,
                listener.block
            )
        }
    }

    private func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let notifications: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        workspaceObservers = notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        }
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func scheduleRefresh(after delay: Duration = .milliseconds(200)) {
        guard shouldObserveSessions else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func installTerminationObserver() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseAudioEngines()
            }
        }
    }

    private func removeTerminationObserver() {
        guard let terminationObserver else { return }
        NotificationCenter.default.removeObserver(terminationObserver)
        self.terminationObserver = nil
    }

    // MARK: - System sleep / wake

    /// These two observers are always live (they're cheap and only fire on real
    /// sleep/wake), so SonicRouter can release its audio engines the moment the
    /// machine sleeps even if a mute was left active with the lid closed.
    private func installSleepWakeObservers() {
        guard sleepWakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemSleep() }
        }
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemWake() }
        }
        sleepWakeObservers = [sleep, wake]
    }

    private func removeSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers {
            center.removeObserver(observer)
        }
        sleepWakeObservers.removeAll()
    }

    /// Tear down every running engine before the machine sleeps. The user's
    /// intent stays in `controls`, so we can rebuild exactly the same mutes and
    /// volume taps on wake — but while asleep nothing holds the audio hardware
    /// (or wakes the CPU through CoreAudio callbacks) behind a closed lid.
    private func handleSystemSleep() {
        guard !isSystemAsleep else { return }
        isSystemAsleep = true
        releaseAudioEngines()
        updateObservationState()
    }

    /// Restore the engines that were active before sleep. A fresh scan first, so
    /// we only rebuild controls whose app is still around and skip anything that
    /// quit during sleep.
    private func handleSystemWake() {
        guard isSystemAsleep else { return }
        isSystemAsleep = false
        updateObservationState()
        guard !controls.isEmpty else { return }
        refresh()
        reapplyControls()
        refresh()
    }

    /// Rebuilds mute/volume engines from the persisted `controls` intent — used
    /// on wake. Only touches sessions that currently exist.
    private func reapplyControls() {
        for session in sessions {
            guard let control = controls[session.id] else { continue }
            _ = apply(session: session, control: control)
        }
    }

    /// Turns persisted profiles back into live engines once their app has an
    /// active Core Audio process. A profile is attempted once per process life
    /// so a denied permission or missing output cannot trigger a refresh loop.
    private func restoreProfilesIfNeeded() {
        for session in sessions {
            guard controls[session.id] == nil,
                  !attemptedProfileKeys.contains(session.id),
                  let profile = matchingProfile(
                    bundleIdentifier: session.bundleIdentifier,
                    appName: session.name
                  ) else { continue }

            var control = Control(profile: profile)
            control.outputUID = normalizedOutputUID(control.outputUID)
            guard control.requiresEngine,
                  session.supportsVolumeControl,
                  !controlProcessIDs(for: session).isEmpty else { continue }

            attemptedProfileKeys.insert(session.id)
            controls[session.id] = control
            if !apply(session: session, control: control) {
                controls[session.id] = nil
            }
        }
    }

    /// Apps such as browsers can replace their helper process while the group
    /// identity stays the same. Rebuild only when the active process set changed
    /// or a saved/live intent does not currently have an engine.
    private func reconcileControlEngines() {
        for session in sessions {
            guard let control = controls[session.id] else { continue }
            let wantedIDs = Set(controlProcessIDs(for: session))
            guard !wantedIDs.isEmpty else { continue }

            let muteMatches = muteEngines[session.id].map {
                let target = targetOutput(for: control)
                return Set($0.processObjectIDs) == wantedIDs
                    && $0.outputUID == target?.uid
                    && $0.outputDeviceID == target?.id
            } ?? false
            let volumeMatches = volumeTaps[session.id].map {
                let target = targetOutput(for: control)
                return Set($0.processObjectIDs) == wantedIDs
                    && $0.outputUID == target?.uid
                    && $0.outputDeviceID == target?.id
            } ?? false

            if control.wantsMute ? !muteMatches : (control.wantsVolumeEngine && !volumeMatches) {
                _ = apply(session: session, control: control)
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

        let profile = matchingProfile(
            bundleIdentifier: bundleID,
            appName: name,
            alternateAppName: group.preferredApp?.localizedName
        )
        let control = controls[group.key]
        let supportsVolumeControl = processTapVolumeEnabled && hasAudioObject
        let displayedVolume = supportsVolumeControl ? (control?.volume ?? profile?.volume ?? 1) : 1
        let outputDeviceIDs = Array(Set(group.outputDeviceIDs))
        let desiredOutputUID: String?
        if let control {
            desiredOutputUID = control.outputUID
        } else {
            desiredOutputUID = normalizedOutputUID(profile?.outputDeviceUID)
        }

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
            outputDeviceNames: CoreAudioProcessClient.deviceNames(for: outputDeviceIDs),
            desiredVolume: displayedVolume,
            desiredOutputUID: desiredOutputUID,
            isControllable: hasAudioObject,
            supportsVolumeControl: supportsVolumeControl,
            isVolumeEngaged: volumeTaps[group.key] != nil
        )
    }

    private func controlProcessIDs(for session: AppAudioSession) -> [AudioObjectID] {
        session.activeAudioProcessIDs.isEmpty ? session.audioProcessIDs : session.activeAudioProcessIDs
    }

    private func matchingProfile(
        bundleIdentifier: String?,
        appName: String,
        alternateAppName: String? = nil
    ) -> AudioRouteProfile? {
        profiles.first { profile in
            AudioProfileMatcher.matches(
                profile,
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                alternateAppName: alternateAppName
            )
        }
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
        profiles.removeAll {
            AudioProfileMatcher.matches(
                $0,
                bundleIdentifier: session.bundleIdentifier,
                appName: session.name
            )
        }
        profiles.append(profile)
        saveProfiles()
        if shouldRefresh { refresh() }
    }

    func removeProfile(for session: AppAudioSession) {
        profiles.removeAll {
            AudioProfileMatcher.matches(
                $0,
                bundleIdentifier: session.bundleIdentifier,
                appName: session.name
            )
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
