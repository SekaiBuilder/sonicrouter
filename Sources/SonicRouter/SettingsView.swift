import SwiftUI

/// Settings, split into short tabs: General (language and startup), Audio
/// (permission, calibration and engine), Shortcuts, and Activity.
struct SettingsView: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label(l10n.t("General", "General", "一般"), systemImage: "gearshape") }
            AudioSettingsTab()
                .tabItem { Label(l10n.t("Audio", "Audio", "オーディオ"), systemImage: "waveform") }
            ShortcutsSettingsTab()
                .tabItem { Label(l10n.t("Atajos", "Shortcuts", "ショートカット"), systemImage: "keyboard") }
            ActivitySettingsTab()
                .tabItem { Label(l10n.t("Actividad", "Activity", "アクティビティ"), systemImage: "bolt.horizontal") }
        }
        .onAppear {
            audioStore.setInterfaceVisible(.settings, true)
            appStore.setInterfaceVisible(.settings, true)
        }
        .onDisappear {
            audioStore.setInterfaceVisible(.settings, false)
            appStore.setInterfaceVisible(.settings, false)
        }
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject private var l10n = L10n.shared
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @AppStorage(StartupPreferences.startInMenuBarKey) private var startInMenuBar = false

    var body: some View {
        Form {
            Section(l10n.t("Idioma", "Language", "言語")) {
                Picker(l10n.t("Idioma de la app", "App language", "アプリの言語"), selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(l10n.t("Inicio", "Startup", "起動")) {
                Toggle(isOn: launchAtLoginBinding) {
                    Text(l10n.t("Abrir al iniciar sesión", "Launch at login", "ログイン時に起動"))
                }
                .disabled(!launchAtLogin.isAvailable)
                if let detail = launchAtLoginDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(launchAtLogin.errorMessage == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if launchAtLogin.needsApproval {
                    Button {
                        launchAtLogin.openSystemSettings()
                    } label: {
                        Label(l10n.t("Abrir Ítems de inicio", "Open Login Items", "ログイン項目を開く"), systemImage: "gearshape")
                    }
                }
                Toggle(isOn: $startInMenuBar) {
                    Text(l10n.t("Iniciar solo en la barra de menús", "Start in the menu bar only", "メニューバーのみで起動"))
                }
                Text(l10n.t(
                    "Sin ventana ni icono en el Dock al arrancar; ábrela desde el icono de la barra de menús. Se aplica en el próximo inicio.",
                    "No window or Dock icon at launch; open it from the menu bar icon. Takes effect on the next launch.",
                    "起動時にウインドウやDockアイコンを表示せず、メニューバーのアイコンから開きます。次回の起動から適用されます。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private var launchAtLoginDetail: String? {
        if !launchAtLogin.isAvailable {
            return l10n.t(
                "Disponible solo al ejecutar SonicRouter.app.",
                "Only available when running SonicRouter.app.",
                "SonicRouter.appとして実行している場合のみ利用できます。"
            )
        }
        if let error = launchAtLogin.errorMessage { return error }
        if launchAtLogin.needsApproval {
            return l10n.t(
                "Pendiente de aprobación en Ajustes del Sistema → Ítems de inicio.",
                "Waiting for approval in System Settings → Login Items.",
                "システム設定 → ログイン項目 での承認待ちです。"
            )
        }
        return nil
    }
}

// MARK: - Audio

struct AudioSettingsTab: View {
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section(l10n.t("Permiso de captura de audio", "Audio capture permission", "オーディオキャプチャの権限")) {
                LabeledContent(l10n.t("Estado", "Status", "状態")) {
                    HStack(spacing: 6) {
                        Image(systemName: permissionSymbol)
                            .foregroundStyle(permissionColor)
                        Text(permissionText)
                    }
                }
                HStack {
                    Button {
                        appStore.checkPermission()
                    } label: {
                        Label(l10n.t("Comprobar de nuevo", "Check again", "再確認"), systemImage: "arrow.clockwise")
                    }
                    Button {
                        appStore.openPrivacySettings()
                    } label: {
                        Label(l10n.t("Abrir Ajustes de privacidad", "Open Privacy Settings", "プライバシー設定を開く"), systemImage: "gearshape")
                    }
                }
                Text(l10n.t(
                    "SonicRouter usa Process Taps de Core Audio para silenciar, ajustar el volumen y ecualizar cada app. macOS exige autorización para capturar el audio del sistema.",
                    "SonicRouter uses Core Audio Process Taps to mute, adjust and equalize each app. macOS requires permission to capture system audio.",
                    "SonicRouterはCore AudioのProcess Tapsを使って各アプリのミュート・音量調整・イコライザーを行います。システム音声の取得にはmacOSの許可が必要です。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section(l10n.t("Calibración de volumen por app", "Per-app volume calibration", "アプリ別音量のキャリブレーション")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(l10n.t("Compensación de re-emisión", "Re-emission makeup gain", "再出力の補正ゲイン"))
                        Spacer()
                        Text(String(format: "%.2f×", appStore.volumeCompensation))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $appStore.volumeCompensation, in: 0.5...8, step: 0.05)
                        .labelsHidden()
                    Text(l10n.t(
                        "1.00× no amplifica. Los valores superiores recuperan nivel solo cuando la señal tiene margen; el limitador baja la ganancia antes de recortar un pico.",
                        "1.00× adds no gain. Higher values restore level only when the signal has headroom; the limiter reduces gain before a peak can clip.",
                        "1.00×では増幅しません。大きい値はヘッドルームがある場合だけ音量を補い、ピークがクリップする前にリミッターがゲインを下げます。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if appStore.volumeCompensation > 1.01 {
                        Button {
                            appStore.volumeCompensation = 1
                        } label: {
                            Label(l10n.t("Restablecer a 1.00×", "Reset to 1.00×", "1.00×に戻す"), systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }

            Section(l10n.t("Motor de audio", "Audio engine", "オーディオエンジン")) {
                Text(l10n.t(
                    "El mute, el volumen y el ecualizador por app usan Process Taps privados y dispositivos agregados temporales. No se instala ningún driver ni se modifica permanentemente la configuración de audio.",
                    "Per-app mute, volume and equalizer use private Process Taps and temporary aggregate devices. No driver is installed and the audio configuration is not changed permanently.",
                    "アプリ別のミュート・音量・イコライザーにはプライベートなProcess Tapと一時的な集約デバイスを使用します。ドライバのインストールや恒久的な音声設定変更は行いません。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var permissionText: String {
        switch appStore.permission {
        case .granted: l10n.t("Concedido", "Granted", "許可済み")
        case .denied: l10n.t("Denegado", "Denied", "拒否")
        case .unknown: l10n.t("Sin comprobar", "Not checked", "未確認")
        }
    }

    private var permissionSymbol: String {
        switch appStore.permission {
        case .granted: "checkmark.seal.fill"
        case .denied: "xmark.seal.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var permissionColor: Color {
        switch appStore.permission {
        case .granted: .green
        case .denied: .red
        case .unknown: .secondary
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsTab: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var hotKeys = GlobalHotKeys.shared

    var body: some View {
        Form {
            Section(l10n.t("Atajos globales", "Global shortcuts", "グローバルショートカット")) {
                Toggle(isOn: Binding(get: { hotKeys.isEnabled }, set: { hotKeys.setEnabled($0) })) {
                    Text(l10n.t("Activar atajos globales", "Enable global shortcuts", "グローバルショートカットを有効にする"))
                }
                ForEach(GlobalHotKeys.Action.allCases) { action in
                    LabeledContent(action.title(l10n)) {
                        ShortcutKeys(
                            text: action.displayKeys,
                            warning: hotKeys.isEnabled && hotKeys.unavailable.contains(action),
                            dimmed: !hotKeys.isEnabled
                        )
                    }
                }
                if hotKeys.isEnabled && !hotKeys.unavailable.isEmpty {
                    Text(l10n.t(
                        "Otra app ya usa el atajo marcado. Ciérrala o cambia su atajo y vuelve a activar esta opción.",
                        "Another app already uses the marked shortcut. Quit it or change its shortcut, then turn this option on again.",
                        "マークしたショートカットは他のアプリが使用中です。そのアプリを終了するかショートカットを変更してから、もう一度オンにしてください。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text(l10n.t(
                    "Funcionan con SonicRouter en segundo plano o solo en la barra de menús. No piden permiso de accesibilidad: macOS solo avisa a SonicRouter de estas combinaciones, nunca de otras teclas.",
                    "They work with SonicRouter in the background or in the menu bar only. No Accessibility permission is needed: macOS tells SonicRouter about these combinations only, never about other keys.",
                    "SonicRouterがバックグラウンドやメニューバーのみでも動作します。アクセシビリティの許可は不要です。macOSがSonicRouterに伝えるのはこれらの組み合わせだけで、他のキー入力は伝えません。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section(l10n.t("En la ventana", "In the window", "ウインドウ内")) {
                shortcutRow(l10n.t("Mezclador", "Mixer", "ミキサー"), "⌘1")
                shortcutRow(l10n.t("Dispositivos", "Devices", "デバイス"), "⌘2")
                shortcutRow(l10n.t("Guardados", "Saved", "保存済み"), "⌘3")
                shortcutRow(l10n.t("Actualizar", "Refresh", "更新"), "⌘R")
                shortcutRow(l10n.t("Silenciar todo", "Mute all", "すべてミュート"), "⇧⌘M")
                shortcutRow(l10n.t("Activar todo", "Unmute all", "すべてのミュートを解除"), "⇧⌘U")
                shortcutRow(l10n.t("Ajustes", "Settings", "設定"), "⌘,")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) {
            ShortcutKeys(text: keys)
        }
    }
}

private struct ShortcutKeys: View {
    let text: String
    var warning = false
    var dimmed = false

    var body: some View {
        HStack(spacing: 6) {
            if warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(text)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .foregroundStyle(dimmed ? .secondary : .primary)
        }
    }
}

// MARK: - Activity

struct ActivitySettingsTab: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section(l10n.t("Actividad y energía", "Activity & energy", "アクティビティと電力")) {
                LabeledContent(l10n.t("Modo actual", "Current mode", "現在のモード")) {
                    PowerModeChip(
                        mode: appStore.powerMode,
                        isSuspended: appStore.isManuallySuspended,
                        onToggleSuspend: { appStore.setManuallySuspended(!appStore.isManuallySuspended) },
                        onQuit: { NSApp.terminate(nil) }
                    )
                }
                LabeledContent(
                    l10n.t("Apps controladas ahora", "Apps under control", "制御中のアプリ"),
                    value: "\(appStore.controlledAppCount)"
                )
                Button {
                    appStore.setManuallySuspended(!appStore.isManuallySuspended)
                } label: {
                    Label(
                        appStore.isManuallySuspended
                            ? l10n.t("Reanudar", "Resume", "再開")
                            : l10n.t("Suspender ahora", "Suspend now", "今すぐ一時停止"),
                        systemImage: appStore.isManuallySuspended ? "play.fill" : "pause.fill"
                    )
                }
            }

            Section(l10n.t("Sistema", "System", "システム")) {
                LabeledContent(
                    l10n.t("Dispositivos detectados", "Devices detected", "検出されたデバイス"),
                    value: "\(audioStore.devices.count)"
                )
                LabeledContent(
                    l10n.t("Apps con audio", "Apps playing audio", "音声を再生中のアプリ"),
                    value: "\(appStore.activeAudioCount)"
                )
                Button {
                    audioStore.refresh()
                    appStore.refresh()
                } label: {
                    Label(l10n.t("Actualizar CoreAudio", "Refresh CoreAudio", "CoreAudioを更新"), systemImage: "arrow.clockwise")
                }
            }
        }
        .formStyle(.grouped)
    }
}
