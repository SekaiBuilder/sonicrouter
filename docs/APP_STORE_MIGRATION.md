# Migración a Mac App Store — seguimiento

Documento de seguimiento. Los requisitos viven en [`specs/`](../specs/README.md);
aquí solo están el estado, la matriz de compatibilidad y las listas de tareas.

Última actualización: 2026-11-18. Cuenta de Apple Developer: **pendiente de
verificación**.

## Estado

| Fase | Estado |
|---|---|
| Diagnóstico | Hecho |
| Línea base de specs | En curso: faltan dispositivos e interfaz |
| Sonido transparente ([CAM-001](../specs/changes/CAM-001-reemision-transparente.md)) | Aprobado; T1–T3 hechos en `feature/cam-001-reemision-transparente`; falta la prueba con audio real |
| Prueba de sandbox ([CAM-002](../specs/changes/CAM-002-prueba-app-sandbox.md)) | Preparada, sin ejecutar |
| Mediciones de referencia | Plan escrito ([performance.md](../specs/performance.md)) |
| Evaluación de lenguajes | Núcleo de tiempo real en C++ ([CAM-003](../specs/changes/CAM-003-nucleo-tiempo-real-cpp.md), DEC-007); el resto en Swift ([languages.md](../specs/decisions/languages.md)) |
| Proyecto Xcode, firma, ficha | Sin empezar; borradores en `Config/` y [`docs/store/`](store/metadata.md) |

## Matriz de compatibilidad con App Sandbox

Estados: **C** compatible y comprobado · **P** probable, sin probar ·
**X** incompatible y demostrado · **R** depende de permiso o revisión ·
**?** por investigar.

Nada está comprobado todavía: ninguna fila puede ser **C** hasta ejecutar CAM-002.

| Función | API | Estado | Base |
|---|---|---|---|
| Taps de proceso | `AudioHardwareCreateProcessTap` | P | `pantafive/fader` los usa con sandbox y `device.audio-input` (entitlements leídos el 2026-11-15) |
| Dispositivo agregado privado con tap | `AudioHardwareCreateAggregateDevice` | P | Mismo precedente |
| Permiso de captura de audio | TCC, `NSAudioCaptureUsageDescription` | R | El usuario debe concederlo; el texto ya existe en es/en/ja |
| Lista de procesos con audio | `kAudioHardwarePropertyProcessObjectList` | P | Mismo precedente |
| Nombres e iconos de otras apps | `NSRunningApplication`, `Bundle(url:)`, `NSWorkspace.icon` | ? | Lee bundles fuera del contenedor |
| Audio de llamadas del sistema | Taps sobre `avconferenced`, `callservicesd` | ? | Procesos del sistema |
| Cambiar salida y entrada predeterminadas, volumen | `AudioObjectSetPropertyData` | P | El precedente cambia la salida |
| Cambiar frecuencia de muestreo del hardware | `kAudioDevicePropertyNominalSampleRate` | ? | CAM-001 lo elimina en el caso común |
| Dispositivo multi-salida público | Agregado apilado no privado | ? | Persiste fuera de la app: riesgo de revisión |
| Atajos globales | `RegisterEventHotKey` (Carbon) | P | No pide Accesibilidad; sin entitlement conocido |
| Abrir al iniciar sesión | `SMAppService.mainApp` | P | API pensada para apps con sandbox; es opcional y desactivada por defecto |
| Exportar e importar perfiles | `fileImporter` / `fileExporter` | P | Requiere `files.user-selected.read-write` |
| Preferencias | `UserDefaults` | P | Pasan al contenedor: hay que migrar las existentes |
| Abrir Ajustes de privacidad | URL `x-apple.systempreferences:` | P | — |
| Modo barra de menús | `setActivationPolicy`, `MenuBarExtra` | P | — |
| Limpieza de taps y agregados propios | `AudioHardwareDestroy…` | P | Solo objetos propios |
| Red | Ninguna | P | No se declara `network.client` |
| Driver HAL antiguo en `/Library` | No lo instala la app actual | — | Fuera de alcance; la app solo lo oculta |

## Puntos de revisión de Apple a preparar

Citados de memoria; **hay que releer el texto vigente** de las App Review
Guidelines antes de enviar.

- Sandbox obligatorio y entitlements justificados (sección 2.4.5).
- Nada se ejecuta al iniciar sesión sin consentimiento: el ítem de inicio es
  opcional y está desactivado por defecto.
- Texto de propósito claro para la captura de audio (sección 5.1.1).
- Explicar en las notas de revisión por qué una app que «no graba» pide
  captura de audio, y cómo comprobarlo.
- Cambios en el sistema (salida predeterminada, frecuencia, dispositivo
  multi-salida): explicarlos y poder deshacerlos.

## Canales

| | Mac App Store | Directo |
|---|---|---|
| Sandbox | Sí | Opcional; decidir tras CAM-002 |
| Firma | Apple Distribution + instalador | Developer ID Application |
| Hardened Runtime | Sí | Sí |
| Entrega | App Store Connect, TestFlight | Notarización, `stapler`, Releases de GitHub |
| Actualizaciones | La tienda | Por decidir (Sparkle u otra): sería la primera dependencia y el primer uso de red |
| Código | El mismo | El mismo |

Objetivo: **un solo código**. Si CAM-002 muestra que alguna función no cabe en
el sandbox, se aísla tras un protocolo y una condición de compilación; no dos
apps.

Arquitecturas: la tienda no exige Intel. `Scripts/build-app.sh` genera el
paquete universal (arreglado el 2026-11-18) y las pruebas pasan en Intel bajo
Rosetta 2; la app Intel no se ha ejecutado. Mantenerlo es
[DEC-102](../specs/decisions/README.md).

## Tareas

### A. Disponibles ahora (sin cuenta)

| # | Tarea | Estado |
|---|---|---|
| A1 | Línea base de specs | En curso |
| A2 | CAM-002: prueba de sandbox con firma ad hoc | Preparada; necesita al titular delante del Mac |
| A3 | CAM-001: sonido transparente | Aprobado 2026-11-18; T1–T3 hechos; T4 y T5 necesitan al titular |
| A4 | Arnés de medición y primera línea de referencia | Sin empezar |
| A5 | Pruebas automáticas nuevas y CI | Sin empezar |
| A6 | Proyecto Xcode que envuelva el paquete, catálogo de recursos con el icono, `Info.plist` versionado, String Catalogs | Sin empezar; necesita visto bueno (cambia la forma de compilar) |
| A7 | Manifiesto de privacidad | Sin empezar |
| A8 | Migración de preferencias al contenedor | Sin empezar |
| A9 | Textos de la ficha en es/en/ja, notas de revisión, política de privacidad | Borrador en [`docs/store/metadata.md`](store/metadata.md) |
| A10 | Capturas de pantalla | Sin empezar; necesita la app en marcha |
| A11 | Corregir README (latencia) y `SECURITY.md` §5 | Tras CAM-001 y CAM-002 |

### B. Preparables en parte (faltan datos)

| # | Tarea | Falta |
|---|---|---|
| B1 | `Config/Signing.xcconfig` | Team ID, bundle ID. Plantilla en `Config/Signing.xcconfig.example` |
| B2 | Script de archivo, exportación y subida (`xcodebuild archive`, `-exportArchive`, `altool`/Transporter) | Identidades de firma |
| B3 | Script de notarización del canal directo | Perfil de `notarytool` |
| B4 | Flujo de publicación en CI | Secretos de firma; decidir si se firma en CI o en local |
| B5 | Ficha en App Store Connect | Nombre disponible, URL de soporte y de privacidad, precio |
| B6 | Añadir `Config/Signing.xcconfig` a `.gitignore` | Solo visto bueno |

### C. Bloqueadas hasta activar la cuenta

Hacer en este orden; cada paso se hace una sola vez.

1. Aceptar los acuerdos en developer.apple.com y App Store Connect (y los
   datos fiscales y bancarios si la app es de pago).
2. Anotar el Team ID en `Config/Signing.xcconfig`.
3. Registrar el App ID con el bundle ID definitivo ([DEC-104](../specs/decisions/README.md)).
4. Crear certificados: Apple Development, Apple Distribution, Mac Installer
   Distribution y Developer ID Application.
5. Crear los perfiles de aprovisionamiento de macOS (desarrollo y tienda).
6. Crear la app en App Store Connect con ese bundle ID y el nombre.
7. Repetir CAM-002 con la firma real de tienda.
8. Subir una compilación y probarla por TestFlight.
9. Rellenar ficha, etiquetas de privacidad, clasificación por edades y
   cumplimiento de exportación (la app no usa cifrado propio ni red).
10. Enviar a revisión con las notas de `docs/store/metadata.md`.
11. Canal directo: guardar credenciales con `xcrun notarytool store-credentials`,
    notarizar, grapar y publicar la release.

## Lista de publicación

- [ ] CAM-002 ejecutado y matriz sin «P» ni «?» en funciones esenciales
- [ ] CAM-001 verificado por el titular
- [ ] Línea de referencia de rendimiento medida
- [ ] Specs completas y `sdd-deriva.py` sin errores
- [ ] Pruebas automáticas y CI en verde
- [ ] Recorrido manual de [testing.md](../specs/testing.md) con el build de tienda
- [ ] Manifiesto de privacidad y política publicada
- [ ] Preferencias migradas desde la versión sin sandbox
- [ ] Ficha, capturas y notas de revisión en es/en/ja
- [ ] Versión y notas de lanzamiento
- [ ] README y `SECURITY.md` al día

## Referencias consultadas (2026-11-15)

- `CATapDescription.h` y `AudioHardware.h` del SDK de macOS de Xcode 27.2.
- [pantafive/fader](https://github.com/pantafive/fader) — archivo de entitlements y montaje del tap.
- [ronitsingh10/FineTune](https://github.com/ronitsingh10/FineTune) — política de compensación de deriva y tap por flujo (GPL-3.0: solo como referencia, no se copia código).
- [insidegui/AudioCap](https://github.com/insidegui/AudioCap) — uso de `NSAudioCaptureUsageDescription`.
- [App Sandbox en App Store Connect Help](https://www.developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information).

No consultado todavía: texto vigente de las App Review Guidelines, documentación
actual de `SMAppService` y de notarización.
