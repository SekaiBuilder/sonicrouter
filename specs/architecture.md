# Arquitectura actual (AS-IS)

Estado: *actual, código leído* salvo donde se indique. Profundidad de lectura
en [README.md](README.md#cobertura-de-lectura).

## Empaquetado

- Paquete SwiftPM (`swift-tools-version: 6.0`), macOS 15 mínimo, sin
  dependencias externas. No hay proyecto Xcode.
- `Scripts/build-app.sh` compila arm64 y x86_64, une con `lipo`, genera el
  `Info.plist` y firma ad hoc (o con `CODE_SIGN_IDENTITY` y Hardened Runtime).
- Bundle ID `local.sonicrouter.app`, versión 1.5 (build 7). Sin App Sandbox y
  sin archivo de entitlements.
- Las pruebas son un ejecutable (`SonicRouterPolicyTests`), no un `testTarget`.

## Módulos

| ID | Módulo | Archivos | Responsabilidad |
|---|---|---|---|
| MOD-01 | Núcleo puro | `Sources/SonicRouterCore/` | Política de control, ecualizador (diseño y procesado), formato de perfiles, plan multi-salida, mapa de canales, comprobación de formato y envoltorios Swift del núcleo C++ de MOD-08 (`RealtimeRender.swift`, `Equalizer.swift`). Usa tipos de Core Audio (`AudioBufferList`, `AudioStreamBasicDescription`) pero ninguna llamada al HAL. Único módulo con pruebas |
| MOD-02 | Motor de audio | `AudioProcessTap.swift` | Taps, dispositivos agregados, registro del IOProc en C de MOD-08, lectura de formatos, limpieza de objetos propios, sondeo del permiso |
| MOD-03 | Cliente Core Audio | `CoreAudioClient.swift`, `CoreAudioProcessClient.swift` | Dispositivos, procesos con audio, salida predeterminada, dispositivo multi-salida |
| MOD-04 | Estado de apps | `ApplicationAudioStore.swift` | Sesiones por app, intención de control, elección de motor, perfiles, escuchas, energía, reposo, protección de llamadas |
| MOD-05 | Estado de dispositivos | `AudioDeviceStore.swift` | Lista de dispositivos y sus volúmenes |
| MOD-06 | Interfaz | `*View.swift`, `Commands.swift`, `SonicRouterApp.swift` | Ventana, barra de menús, ajustes, comandos |
| MOD-08 | Núcleo de tiempo real (C++) | `Sources/SonicRouterDSP/` | Todo lo que corre en el hilo de audio: copia con ganancia, limitador, ecualizador, diseño de filtros e IOProc (`sr_renderer_ioproc`). Interfaz C; sin Swift, sin reservas ni locks en el render. Desde CAM-003 |
| MOD-07 | Integración con el sistema | `GlobalHotKeys.swift`, `LaunchAtLogin.swift`, `Localization.swift` | Atajos Carbon, `SMAppService`, textos es/en/ja en línea |

## Flujo de audio

Detalle y requisitos en [features/audio-engine.md](features/audio-engine.md).

```
Sin control (100 %, salida predeterminada, EQ plano, sin mute)
  app ──────────────────────────────────────────► dispositivo     (ruta nativa, sin tap)

Mute
  app ──► tap (.muted) ──► agregado privado ──► IOProc escribe ceros

Volumen < 100 %, salida elegida o EQ activo
  app ──► tap mezcla estéreo (.muted, compensación de deriva)
      ──► agregado privado [salidas físicas + tap]
      ──► IOProc en C++ (MOD-08): ganancia × compensación → limitador → mapa de canales → EQ
      ──► dispositivo

Llamada en curso
  nunca se re-emite; si tiene salida elegida, se cambia la salida del sistema
```

## Hilos

- Interfaz y stores en `@MainActor`. Las escuchas de Core Audio llegan a
  `DispatchQueue.main`.
- El IOProc corre en el hilo de tiempo real de Core Audio. Recibe parámetros
  por atómicos de C++ (`sr_renderer`) y usa memoria reservada al crear el
  motor. Es una función C: no entra en el runtime de Swift (CAM-003).

## Persistencia

`UserDefaults`: perfiles por app (`SonicRouter.RouteProfiles`), compensación de
volumen, atajos, inicio en barra de menús, idioma, última sección. Exportación
e importación de perfiles en JSON por paneles del sistema.

## Efectos sobre el sistema fuera de la app

- Cambia la frecuencia de muestreo nominal de dispositivos físicos
  (`TapAggregate.alignSampleRates`).
- Cambia la salida predeterminada del sistema durante una llamada con ruta
  elegida, y la devuelve al terminar.
- Crea un dispositivo multi-salida público (`local.sonicrouter.multioutput`).
- Al arrancar y al cerrar destruye taps y agregados cuyo nombre empieza por
  `sonicrouter` o cuyo UID empieza por `local.sonicrouter.agg.`.

## Brechas conocidas

| Brecha | Fuente |
|---|---|
| Ninguna prueba cubre MOD-02 a MOD-07 (unas 6.300 líneas) | `Tests/` solo importa `SonicRouterCore` |
| El estado de apps concentra muchas responsabilidades en 1.481 líneas | `ApplicationAudioStore.swift` |
| ~~El README dice «un par de milisegundos» de latencia~~ Corregido el 2026-11-19 (CAM-001 T6): ahora cita los ~50 ms anotados | `AudioProcessTap.swift:801` |
| ~~Sin CI~~ CI escrita el 2026-11-19 (`Scripts/ci.sh`, `.github/workflows/ci.yml`) | [testing.md](testing.md) |
| La release publicada (v1.2) va muy por detrás del código (1.5) | `gh release list` |
