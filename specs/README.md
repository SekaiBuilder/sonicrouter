# Specs de SonicRouter

Memoria del proyecto: qué hace hoy, qué se quiere que haga y con qué se ha
comprobado. Markdown plano, sin depender de ninguna herramienta.

Estado: **línea base en construcción** (iniciada el 2026-11-15). Describe el
árbol de trabajo de `feature/native-multi-output` en `e67f575` más los cambios
sin guardar de esa fecha.

## Reglas

1. Lo actual y lo deseado van separados. Cada requisito dice si es
   *actual* (lo hace el código hoy), *objetivo*, *brecha* o *decisión pendiente*.
2. Nada está «verificado» sin evidencia ejecutada: comando o recorrido,
   commit, entorno y resultado. Sin eso, el estado es «código leído».
3. Los identificadores son estables y no se reutilizan.
4. Una brecha se cierra con evidencia o se queda escrita.
5. Lo que el código no deja claro se escribe como `[POR ACLARAR: …]`.
6. La spec cambia en el mismo commit que el código que describe.

## Flujo de un cambio

Propuesta → spec (`changes/CAM-NNN-…md`) → diseño → tareas → implementación →
pruebas → verificación → actualizar la línea base.

Requieren visto bueno del titular: refactor de arquitectura, lenguaje o
dependencia nuevos, retirar o degradar una función, publicar.

## Índice

| Documento | Contenido | Estado |
|---|---|---|
| [product.md](product.md) | Qué es, qué hace, objetivos | Primera versión; negocio sin decidir |
| [architecture.md](architecture.md) | Módulos y flujo de audio AS-IS | Primera versión |
| [features/audio-engine.md](features/audio-engine.md) | `AUD-01` Motor de mute, volumen, ruta y ecualizador | Leído a fondo |
| [features/app-sessions.md](features/app-sessions.md) | `APP-01` Detección de apps, control, energía | Leído a fondo |
| [features/profiles.md](features/profiles.md) | `PRF-01` Perfiles, exportar e importar | Lógica leída a fondo |
| [features/system-integration.md](features/system-integration.md) | `SIS-01` Permiso, atajos, inicio, barra de menús | Leído a fondo |
| [interfaces/README.md](interfaces/README.md) | `CTR-NN` Contratos | Primera versión |
| [security.md](security.md) | `SEG-01` Estado de los invariantes y objetivos de tienda | Primera versión |
| [performance.md](performance.md) | `REN-01` Lo medido (nada) y plan de medición | Primera versión |
| [testing.md](testing.md) | Pruebas actuales y estrategia | Primera versión |
| [risks.md](risks.md) | `RIE-NN` Registro de riesgos | Primera versión |
| [decisions/README.md](decisions/README.md) | Decisiones registradas y abiertas | Primera versión |
| [decisions/languages.md](decisions/languages.md) | Evaluación Swift / Rust / C++ | Preliminar, sin mediciones |
| [changes/CAM-001-reemision-transparente.md](changes/CAM-001-reemision-transparente.md) | Sonido sin alteración en la re-emisión | Propuesta, sin implementar |
| [changes/CAM-002-prueba-app-sandbox.md](changes/CAM-002-prueba-app-sandbox.md) | Prueba mínima con App Sandbox | Preparada, sin ejecutar |
| [../docs/APP_STORE_MIGRATION.md](../docs/APP_STORE_MIGRATION.md) | Seguimiento de la migración a la tienda | En curso |
| [../docs/store/metadata.md](../docs/store/metadata.md) | Ficha, notas de revisión, política de privacidad | Borrador |

Pendientes de escribir: specs de dispositivos (`CoreAudioClient.swift`,
`AudioDeviceStore.swift`, multi-salida) y de interfaz (`*View.swift`,
`Commands.swift`), y la trazabilidad requisito → prueba.

## Cobertura de lectura

| Archivo | Profundidad |
|---|---|
| `Sources/SonicRouter/AudioProcessTap.swift` | A fondo |
| `Sources/SonicRouterCore/Equalizer.swift` (procesado en tiempo real, líneas 250–476) | A fondo |
| `Sources/SonicRouterCore/OutputChannelMap.swift`, `MultiOutputPlan.swift` | A fondo |
| `Sources/SonicRouter/LaunchAtLogin.swift`, `SonicRouterApp.swift` | A fondo |
| `Sources/SonicRouter/ApplicationAudioStore.swift` | A fondo |
| `Sources/SonicRouterCore/AudioControlPolicy.swift`, `ProfileArchive.swift` | A fondo |
| `Sources/SonicRouter/GlobalHotKeys.swift` | A fondo |
| `Sources/SonicRouterCore/Equalizer.swift` (diseño de filtros, líneas 1–249) | No leído |
| `Tests/SonicRouterPolicyTests/main.swift` | No leído (solo ejecutado) |
| `Package.swift`, `Scripts/build-app.sh`, `Scripts/test.sh`, README, SECURITY, CONTRIBUTING, roadmap | A fondo |
| Resto de `Sources/` y `Tests/` | No leído o solo por nombres |

## Identificadores

`MOD-NN` módulo · `CTR-NN` contrato · `XXX-01-RNN` requisito, `-BNN` brecha y
`-ANN` aceptación de una spec (`AUD`, `APP`, `PRF`, `SIS`, `SEG`, `REN`) ·
`DEC-NNN` decisión · `CAM-NNN` cambio · `RIE-NN` riesgo · `INV-N` invariantes
de `SECURITY.md` (ya existían).

## Evidencia de la línea base

| Qué | Comando | Commit | Entorno | Resultado |
|---|---|---|---|---|
| Compila | `swift build` | `e67f575` + cambios sin guardar | Xcode 27.2, Swift 6.4.2, macOS 27.2, arm64 | OK |
| Pruebas de lógica pura | `Scripts/test.sh` | ídem | ídem | 85 comprobaciones, todas pasan |

| Compila para Intel | `swift build -c release --triple x86_64-apple-macosx15.0 --product SonicRouter` | ídem | ídem | OK; binario no ejecutado |

No ejecutado: la app en marcha, `-warnings-as-errors`, la unión universal con
`lipo`, cualquier prueba con audio real o con App Sandbox.
