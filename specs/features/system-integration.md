# SIS-01 — Integración con el sistema

Módulos: MOD-07, `SonicRouterApp.swift`, `AudioProcessTap.swift` (permiso).
Lectura: a fondo, salvo `Localization.swift` (no leído).
Evidencia: código leído.

## Requisitos actuales

| ID | Comportamiento | Fuente |
|---|---|---|
| SIS-01-R01 | El permiso de captura se sondea creando y destruyendo al instante un tap global privado y sin mute; la primera vez dispara el diálogo del sistema | `AudioProcessTap.swift:256` |
| SIS-01-R02 | El texto del diálogo está en es, en y ja (`NSAudioCaptureUsageDescription`) | `Scripts/build-app.sh` |
| SIS-01-R03 | «Abrir ajustes de privacidad» abre el panel de Privacidad de Ajustes del Sistema por URL | `ApplicationAudioStore.swift:206` |
| SIS-01-R04 | Atajos globales opcionales, desactivados por defecto: ⌃⌥⌘M alterna el mute de la app en primer plano y ⌃⌥⇧⌘M alterna silenciar todo. Se registran con `RegisterEventHotKey` | `GlobalHotKeys.swift` |
| SIS-01-R05 | Un atajo que el sistema rechaza se marca como no disponible | `GlobalHotKeys.swift:80` |
| SIS-01-R06 | Con la app en pausa o el Mac dormido, un atajo solo emite el sonido de aviso | `ApplicationAudioStore.swift:562` |
| SIS-01-R07 | «Abrir al iniciar sesión» usa `SMAppService.mainApp`; solo está disponible ejecutando como `.app`; refleja el estado «requiere aprobación» | `LaunchAtLogin.swift` |
| SIS-01-R08 | Cerrar la última ventana principal no cierra la app: sale del Dock y sigue en la barra de menús; abrir la ventana la devuelve al Dock | `SonicRouterApp.swift:8` |
| SIS-01-R09 | «Iniciar solo en la barra de menús» suprime la ventana al arrancar; el cambio se aplica en el siguiente arranque | `SonicRouterApp.swift:74` |
| SIS-01-R10 | El icono de la barra de menús es un altavoz tachado mientras haya alguna app silenciada | `SonicRouterApp.swift:101` |

## Brechas

| ID | Brecha | Fecha |
|---|---|---|
| SIS-01-B01 | Los atajos no son configurables | 2026-11-15 |
| SIS-01-B02 | R03 abre el panel de Micrófono; el permiso de captura de audio del sistema tiene su propio apartado `[POR ACLARAR: ancla correcta en macOS 15–27]` | 2026-11-15 |
| SIS-01-B03 | Nada de esta spec se ha probado dentro de App Sandbox ([CAM-002](../changes/CAM-002-prueba-app-sandbox.md)) | 2026-11-15 |
