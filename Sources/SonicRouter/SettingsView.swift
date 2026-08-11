import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            languageSection

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
                    "SonicRouter usa Process Taps de Core Audio para silenciar y ajustar el volumen de cada app. macOS exige autorización para capturar el audio del sistema.",
                    "SonicRouter uses Core Audio Process Taps to mute and adjust each app. macOS requires permission to capture system audio.",
                    "SonicRouterはCore AudioのProcess Tapsを使って各アプリの音量調整・ミュートを行います。システム音声の取得にはmacOSの許可が必要です。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

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
                    Text(l10n.t(
                        "1.00× no amplifica. Los valores superiores recuperan nivel solo cuando la señal tiene margen; el limitador baja la ganancia antes de recortar un pico.",
                        "1.00× adds no gain. Higher values restore level only when the signal has headroom; the limiter reduces gain before a peak can clip.",
                        "1.00×では増幅しません。大きい値はヘッドルームがある場合だけ音量を補い、ピークがクリップする前にリミッターがゲインを下げます。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    "El mute y el volumen por app usan Process Taps privados y dispositivos agregados temporales. No se instala ningún driver ni se modifica permanentemente la configuración de audio.",
                    "Per-app mute and volume use private Process Taps and temporary aggregate devices. No driver is installed and the audio configuration is not changed permanently.",
                    "アプリ別ミュートと音量調整にはプライベートなProcess Tapと一時的な集約デバイスを使用します。ドライバのインストールや恒久的な音声設定変更は行いません。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            audioStore.setInterfaceVisible(.settings, true)
            appStore.setInterfaceVisible(.settings, true)
        }
        .onDisappear {
            audioStore.setInterfaceVisible(.settings, false)
            appStore.setInterfaceVisible(.settings, false)
        }
    }

    private var languageSection: some View {
        Section(l10n.t("Idioma", "Language", "言語")) {
            Picker(l10n.t("Idioma de la app", "App language", "アプリの言語"), selection: $l10n.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
        }
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
