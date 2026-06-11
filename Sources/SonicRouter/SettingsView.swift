import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore

    var body: some View {
        Form {
            Section("Permiso de captura de audio") {
                LabeledContent("Estado") {
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
                        Label("Comprobar de nuevo", systemImage: "arrow.clockwise")
                    }
                    Button {
                        appStore.openPrivacySettings()
                    } label: {
                        Label("Abrir Ajustes de privacidad", systemImage: "gearshape")
                    }
                }
                Text("SonicRouter usa Process Taps de Core Audio para silenciar y ajustar el volumen de cada app. macOS exige tu autorización para grabar el audio del sistema.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Sistema") {
                LabeledContent("Dispositivos detectados", value: "\(audioStore.devices.count)")
                LabeledContent("Apps con audio", value: "\(appStore.activeAudioCount)")
                Button {
                    audioStore.refresh()
                    appStore.refresh()
                } label: {
                    Label("Actualizar CoreAudio", systemImage: "arrow.clockwise")
                }
            }

            Section("Calibración de volumen por app") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Compensación de re-emisión")
                        Spacer()
                        Text(String(format: "%.2f×", appStore.volumeCompensation))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $appStore.volumeCompensation, in: 0.5...8, step: 0.05)
                    Text("Para calibrar: toca el volumen de una app que esté sonando (queda «controlada»), súbela al 100% y mueve esto hasta que suene exactamente igual que al pulsar el botón de restablecer. Una vez calibrado, no debería haber ningún salto entre 100% y 99%. Se aplica en vivo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Cómo funciona") {
                Text("El mute es inmediato y no añade latencia. El control de volumen captura el audio de la app, lo silencia en su salida original y lo vuelve a emitir al volumen elegido, así que puede añadir unos milisegundos de retardo solo en esa app. Mientras una app está controlada, todo su audio pasa por el motor (incluso al 100%) para que el deslizador sea continuo y sin saltos; «Restablecer» la devuelve a la ruta normal. El deslizador usa una curva perceptual: 50% suena aproximadamente a la mitad.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var permissionText: String {
        switch appStore.permission {
        case .granted: "Concedido"
        case .denied: "Denegado"
        case .unknown: "Sin comprobar"
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
