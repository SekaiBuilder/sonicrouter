# Trazabilidad requisito → prueba

Fecha: 2026-11-19. Rama `feature/cam-001-reemision-transparente`.

Cómo se ha hecho: por grupo de pruebas. Cada requisito se asocia al grupo que
prueba el archivo y la función que el requisito cita, comprobado buscando en
`Tests/SonicRouterPolicyTests/main.swift` el nombre de la función. No es una
revisión caso a caso. Los grupos están en `Tests/SonicRouterPolicyTests/main.swift`
y se ejecutan con `Scripts/test.sh` (170 comprobaciones el 2026-11-19).

Niveles: **Auto** (prueba automática, en la CI), **Herramienta** (existe una
herramienta, pero necesita al titular o hardware), **Manual** (solo un recorrido
manual de [testing.md](testing.md) o de un cambio), **Ninguna**.

## Con prueba automática

| Prueba | Requisito | Qué cubre y qué no |
|---|---|---|
| `runPolicyTests` (`requiresEngine`, `wantsVolumeEngine`) | AUD-01-R01 | La decisión de montar o no motor; no que la app suene por su ruta nativa |
| `runRealtimeRenderTests`, `runCppEquivalenceTests` | AUD-01-R07 | Ganancia × compensación en el render; no el deslizador de la interfaz |
| `runPolicyTests` (`headroomLimitedGain`), `runRealtimeRenderTests` (limitador neutro con g ≤ 1), `runCppEquivalenceTests` | AUD-01-R08 | Completo con búferes sintéticos |
| `runOutputChannelMapTests`, `runRealtimeRenderTests`, `runDeviceStreamMapTests` | AUD-01-R09 | Copia rápida, mapa de canales y multi-dispositivo |
| `runEqualizerSettingsTests`, `runFilterDesignTests`, `runRealtimeEqualizerTests`, `runCppEquivalenceTests` | AUD-01-R10 | Respuesta en frecuencia, deslizamiento, plano sin tocar muestras |
| `runCppEquivalenceTests` con ASan/UBSan en la CI | AUD-01-R16 | Memoria correcta; la ausencia de reservas en el callback se revisó con `nm` (CAM-003-A04), no con una prueba |
| `runRenderFormatCheckTests` | AUD-01-R17 | La comprobación de formato; no el arranque con un dispositivo real no Float32 |
| `runRenderStatsTests` | AUD-01-R18 | Contadores, histograma y que el audio no cambia; no el registro en la app |
| `runDeviceStreamMapTests` | CAM-001-R01 | Solo la parte lógica (mapa identidad); el montaje real necesita T4 |
| `runRealtimeRenderTests` (A01, A02) | CAM-001-R04 | Bit a bit con búferes sintéticos |
| `runRenderFormatCheckTests` (A06) | CAM-001-R05 | Parte lógica |
| `static_assert` de lock-free al compilar | CAM-003-R02 | Atómicos; reservas revisadas con `nm` |
| `runCppEquivalenceTests` (debug y release en la CI) | CAM-003-R03 | Igualdad bit a bit con el oráculo `SwiftReference.swift` |
| `runCppEquivalenceTests` en release; mutación con `fp contract(fast)` detectada | CAM-003-R04 | x86_64 solo bajo Rosetta, a mano |
| Las de AUD-01-R07 a R10, R16, R17 y CAM-001-R04 | CAM-003-R07 | Ver sus filas |
| `runPolicyTests` (`isInternalDeviceUID`) | DEV-01-R01 | El filtro de UID internos; no la lectura de Core Audio |
| `runMultiOutputPlanTests` (`orderedMembers`, `sharedSampleRate`) | DEV-01-R15, DEV-01-R18 | El plan puro; no la creación del agregado |
| `runPolicyTests` (perfiles, `matches`) | PRF-01-R01, PRF-01-R02, PRF-01-R06 | Formato y coincidencia del perfil |
| `runProfileArchiveTests` | PRF-01-R07 a PRF-01-R10 | Exportar e importar; R10 solo la fusión, no su aplicación en la app |
| `Scripts/verify-app.sh` en la CI | SEG-01-R03 | Contenido del manifiesto; no la validación de App Store Connect |
| `Scripts/check-security.sh` (y su `--selftest`) en la CI | SEG-01-R05 | Búsqueda textual |

Plan A8 (migración de preferencias, RIE-06) no tiene ID de requisito: lo cubre
`runPreferenceMigrationTests`.

## Con herramienta, pendiente de ejecutar

| Herramienta | Requisito | Falta |
|---|---|---|
| `SonicRouterNullTest` (A03 a A05) | CAM-001-R01 a CAM-001-R03 | El titular, con permiso de captura |
| `SonicRouterNullTest` con otra salida | CAM-001-R06 | Ídem |
| Lectura de código de `AppVolumeTap.invalidate()`; ASan en las pruebas | CAM-003-R05 | Una prueba con taps reales |
| `SonicRouterBench` (a mano, no en la CI: depende del Mac) | CAM-003-R06 | Repetir en cada cambio del núcleo |
| `SonicRouter.RenderStats` + `Scripts/render-stats.sh` | REN-01-R04 | Una hora con 5 apps |
| `SonicRouterAudioTools orphans` | APP-01-R12, APP-01-R19, DEV-01-R20 | Recorrido con la app (CAM-002-A17) |
| `Scripts/cam002-sandbox.sh`, `Scripts/verify-app.sh --store` | SEG-01-R01 | CAM-002 y la cuenta |
| `Scripts/release-common.sh` se niega si `Config/Signing.xcconfig` no está ignorado | SEG-01-R04 | Visto bueno de B6 |

## Solo manual o sin prueba

Todo lo que vive en el ejecutable `SonicRouter` y no en `SonicRouterCore` ni en
`SonicRouterDSP` no tiene prueba automática (brecha de [architecture.md](architecture.md)):

| Verificación prevista | Requisitos |
|---|---|
| Recorrido manual de testing.md; CAM-001 T4/T5 | AUD-01-R02 a AUD-01-R06, AUD-01-R11 a AUD-01-R15 |
| Recorrido manual; CAM-002-A02, A03, A08, A18 | APP-01-R01 a APP-01-R19 (salvo los de arriba) |
| Recorrido manual; CAM-002-A09 a A11 | DEV-01-R02 a DEV-01-R14, DEV-01-R16, DEV-01-R17, DEV-01-R19, DEV-01-R21 a DEV-01-R26 |
| Recorrido manual y el arnés de render fuera de pantalla (memoria del proyecto) | UI-01-R01 a UI-01-R41 |
| Recorrido manual; CAM-002-A14 | PRF-01-R03 a PRF-01-R05 |
| Recorrido manual; CAM-002-A01, A12, A13, A15 | SIS-01-R01 a SIS-01-R10 |
| Regla de proceso (R01) y revisión de código (R02, R03) | REN-01-R01 a REN-01-R03 |
| Se cierra al escribir el resultado de CAM-002 en `SECURITY.md` | SEG-01-R02 |
| Las de los requisitos que conserva | CAM-001-R07 |
| `nm -u` del objeto (CAM-003-A04), a mano | CAM-003-R01 |

Para subir de nivel la mayor parte, haría falta sacar lógica del ejecutable a
`SonicRouterCore` (refactor de arquitectura: necesita visto bueno).
