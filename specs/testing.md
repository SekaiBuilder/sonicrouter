# Pruebas

## Hoy

| Qué | Cómo | Cubre |
|---|---|---|
| `SonicRouterPolicyTests` (ejecutable, 136 comprobaciones desde el 2026-11-18) | `Scripts/test.sh` | `SonicRouterCore` y el núcleo C++ `SonicRouterDSP`: política de control, ecualizador (respuesta en frecuencia y procesado), formato y fusión de perfiles, plan multi-salida, mapa de canales, copia bit a bit, comprobación de formato (CAM-001 A01, A02, A06) y equivalencia bit a bit con la versión Swift anterior (CAM-003, oráculo en `SwiftReference.swift`) |
| `SonicRouterBench` | `swift run -c release SonicRouterBench` | Coste por bloque del render con búferes sintéticos (CAM-003-A05) |
| Sanitizers | `swift run --sanitize=address --sanitize=undefined SonicRouterPolicyTests` | ASan y UBSan sobre las pruebas |
| Compilación estricta | `swift build -Xswiftc -warnings-as-errors` | Ejecutada el 2026-11-18 en la rama de CAM-001: OK |

Sin cobertura: motor de audio, clientes Core Audio, stores, interfaz, atajos,
inicio de sesión. Sin CI.

Evidencia del 2026-11-15, árbol de `e67f575` más cambios sin guardar, Xcode
27.2 / Swift 6.4.2 / macOS 27.2 arm64:

| Comando | Resultado |
|---|---|
| `swift build` | OK |
| `Scripts/test.sh` | 85 comprobaciones, todas pasan |
| `Scripts/test.sh` (2026-11-18, rama `feature/cam-001-reemision-transparente`) | 111 comprobaciones, todas pasan |
| `Scripts/test.sh`, release y ASan + UBSan (2026-11-18, CAM-003) | 136 comprobaciones, todas pasan |
| `swift build -c release --triple x86_64-apple-macosx15.0 --product SonicRouter` (en carpeta temporal) | Compila. El binario Intel no se ha ejecutado |

## Estrategia objetivo

### Automáticas, sin hardware

| Nivel | Qué | Requisito previo |
|---|---|---|
| Unitarias | Lo que ya hay, migrado a Swift Testing cuando el proyecto dependa de Xcode ([DEC-005](decisions/README.md) se revisa entonces) | Decisión del titular |
| Copia de audio | Bit a bit con ganancia 1, exactitud con ganancia g, disposición intercalada y plana, mapa de canales | **Hecho** el 2026-11-18 (CAM-001 T1) |
| DSP | Respuesta en frecuencia, estabilidad con silencio largo (denormales), NaN e infinitos a la entrada, deslizamiento de ganancia | Ya en el núcleo |
| Agrupación de apps | Helpers de Chrome, FaceTime, procesos sin bundle | Extraer la lógica de APP-01-R01 a R03 al núcleo |
| Perfiles | Archivo malformado, versión futura, 1.001 entradas, valores fuera de rango | Ya cubierto en parte |
| Seguridad | Ningún import de red ni escritura de audio (SEG-01-R05) | Ninguno |
| Trazabilidad | Todo ID de requisito citado en una prueba o marcado «manual» | `sdd-deriva.py --estricto` |
| Sanitizers | Thread Sanitizer sobre las pruebas (ASan y UBSan ya se ejecutan, CAM-003) | Ninguno |

### Con Mac real (no automatizables en CI)

| Prueba | Qué se mira |
|---|---|
| Permiso en cuenta limpia | Diálogo, denegar, conceder después, revocar con la app abierta |
| Residuo y latencia | Arnés de CAM-001 |
| Cambio de dispositivo en caliente | Conectar y quitar auriculares con cable, USB, Bluetooth, HDMI, AirPlay con apps controladas |
| Cambio de frecuencia de muestreo | 44,1 ↔ 48 ↔ 96 kHz en Configuración de Audio MIDI con el motor en marcha (AUD-01-B04) |
| Reposo y despertar | Tapa cerrada con mute activo; al despertar, mismos controles |
| App que muere o cambia de helper | Cerrar a la fuerza una app controlada; recargar pestañas de un navegador |
| Llamadas | FaceTime y una app de videollamada: sin eco, salida devuelta al colgar |
| Caída de SonicRouter | `kill -9` con controles activos: el audio vuelve solo o al reabrir |
| Sesión larga | 8 horas, memoria y sobrecargas |
| Intel | Mismo recorrido en un Mac Intel `[DEC-102]` |
| Sandbox | Todo lo anterior con el build de tienda (CAM-002) |

### CI propuesta

GitHub Actions en macOS: compilar con avisos como errores, `Scripts/test.sh`,
sanitizers, `sdd-deriva.py --estricto`. No se ha creado: añadir un flujo de
trabajo es un cambio en el repositorio que necesita visto bueno.
