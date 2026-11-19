# CAM-003 — Núcleo de tiempo real en C++

Estado: **implementado y verificado con pruebas automáticas y mediciones
sintéticas**; sin probar con audio real. Fecha: 2026-11-18.
Rama: `feature/cam-001-reemision-transparente` (va antes de CAM-001 T3).
Origen: el titular pide pasar el código a C++ «para potenciarlo y hacerlo más
fiable», y que se pase a C/C++ lo que convenga
([DEC-007](../decisions/README.md)). Afecta a: [AUD-01](../features/audio-engine.md).

## Alcance decidido

Va a C++ todo lo que corre en el hilo de tiempo real de Core Audio, y nada más:

| Pasa a C++ (`Sources/SonicRouterDSP/`) | Se queda en Swift | Por qué |
|---|---|---|
| Copia con ganancia (rápida y por mapa de canales) | Interfaz, stores, perfiles, atajos | SwiftUI y la lógica de estado no corren en tiempo real |
| Limitador de compensación y política de margen | Creación de taps, agregados e IOProc | Son llamadas a una API de C; reescribirlas no cambia nada |
| Ecualizador: deslizamiento, filtros y su memoria | Comprobación de formato (`RenderFormatCheck`) | Se ejecuta una vez, fuera del hilo de audio |
| Diseño de filtros y preganancia (se recalculan en el hilo de audio mientras una banda se desliza) | Mapa de canales (`OutputChannelMap`) | Se construye fuera del hilo de audio; C++ recibe la tabla ya hecha |
| El propio IOProc (función C `sr_renderer_ioproc`) | | Así el hilo de audio no entra nunca en el runtime de Swift |

La API pública de Swift se conserva (`BiquadDesign`, `EqualizerHeadroom`,
`RealtimeEqualizer`, `RealtimeGainLimiter`, `AudioGainPolicy`) como envoltorio
fino del C++, para que haya un solo código de DSP. `StereoRender` y `GainBox`
se retiran: los sustituye `RealtimeRenderer`.

## Requisitos

| ID | Requisito |
|---|---|
| CAM-003-R01 | El IOProc del motor de volumen es una función C sobre estado C++; el hilo de audio no llama al runtime de Swift (ni retención de referencias, ni comprobaciones de exclusividad) |
| CAM-003-R02 | El camino de render no reserva memoria ni toma locks; los parámetros llegan por atómicos sin bloqueo (`static_assert` de `is_always_lock_free`) |
| CAM-003-R03 | La salida es idéntica bit a bit a la de la implementación Swift anterior (commit `2b8aa30`) para las mismas entradas, ganancias y ajustes de EQ, en debug y en release |
| CAM-003-R04 | Sin contracción FMA ni fast-math en el núcleo (`#pragma clang fp contract(off)`), para que el redondeo sea reproducible en arm64 y x86_64 |
| CAM-003-R05 | El estado C++ se libera solo después de parar y destruir el IOProc |
| CAM-003-R06 | Ningún caso medido de la carga de referencia es más lento que en Swift |
| CAM-003-R07 | Se conservan AUD-01-R07 a R10, R16 y R17, y CAM-001-R04 |

## Aceptación

| ID | Dado / cuando / entonces |
|---|---|
| CAM-003-A01 | Dados 5 escenarios (estéreo intercalado y plano, dos salidas, salidas de 2 y 6 canales, entrada por encima de 0 dBFS) y 320 bloques con cambios de ganancia, compensación (hasta ×8) y EQ (planos, deslizamientos, ±12 dB, vuelta a plano), cuando se procesan con C++ y con la referencia Swift, entonces todos los búferes son iguales bit a bit |
| CAM-003-A02 | Los coeficientes de las tres bandas (−12 a +12 dB en pasos de 0,75; 8–192 kHz), la preganancia y la ganancia de margen son iguales bit a bit en C++ y en Swift |
| CAM-003-A03 | CAM-001-A01, A02 y A06 y todas las pruebas previas pasan contra el C++ |
| CAM-003-A04 | El objeto compilado del núcleo no tiene símbolos externos de Swift; las reservas (`new`/`delete`) solo están en crear y destruir |
| CAM-003-A05 | `SonicRouterBench` (256 tramas, 200.000 bloques, mediana de 5 rondas): ningún caso más lento que la referencia Swift medida en la misma sesión |

## Diseño

- `Sources/SonicRouterDSP/include/SonicRouterDSP.h`: interfaz C (`sr_*`), sin
  necesidad de activar la interoperabilidad C++ de Swift.
- `Sources/SonicRouterDSP/SonicRouterDSP.cpp`: C++20, Accelerate (`vDSP_vsmul`,
  `vDSP_maxmgv`; la copia por mapa usa `vDSP_vsmul` con saltos, que antes era
  muestra a muestra).
- `Sources/SonicRouterCore/RealtimeRender.swift`: `RealtimeRenderer` (dueño del
  objeto C++, `ioProc` y `clientData` para `AudioDeviceCreateIOProcID`).
- `AppVolumeTap` guarda ganancia, compensación y EQ en Swift y los reenvía al
  renderizador; registra el IOProc con `AudioDeviceCreateIOProcID` en lugar de
  un bloque Swift; `invalidate()` libera el renderizador al final.
- `Tests/SonicRouterPolicyTests/SwiftReference.swift`: copia literal del camino
  Swift anterior, como oráculo de la equivalencia. No se corrige.

## Tareas

| # | Tarea | Estado |
|---|---|---|
| T1 | Arnés `SonicRouterBench` y referencia Swift medida | Hecho |
| T2 | Núcleo C++ con interfaz C y envoltorios Swift | Hecho |
| T3 | Motor de volumen con IOProc C | Hecho |
| T4 | Pruebas de equivalencia bit a bit (A01, A02) y de mutación | Hecho |
| T5 | Recorrido con audio real: volumen, EQ, ruta, dos salidas, quitar y poner controles | Pendiente: necesita al titular |
| T6 | Medición en Mac real del tiempo del callback y sobrecargas (REN-01-R04) | Instrumentación hecha 2026-11-19 (contadores en `sr_renderer_ioproc`, `RenderStatsMonitor`, `Scripts/render-stats.sh`); la medición necesita al titular |

## Evidencia

Entorno: Xcode 27.2, Swift 6.4.2, macOS 27.2, Apple M5 (arm64). Commit: el de
CAM-003 en `feature/cam-001-reemision-transparente`.

| Caso | Comando | Resultado |
|---|---|---|
| A01–A03 | `Scripts/test.sh` (debug) | 136 comprobaciones, todas pasan |
| A01–A03 en release | `swift run -c release SonicRouterPolicyTests` | 136, todas pasan |
| Las pruebas detectan errores | Mutaciones temporales, revertidas: salida del EQ × (1 + 1e−12) → A01 falla en 4 escenarios; recuperación del limitador 0,08 → 0,09 → A01 falla en 4; `fp contract(fast)` en release → A02 falla (194 coeficientes, 93 preganancias) y A01 en 2 | Detectadas |
| A04 | `nm -u` del objeto del núcleo en release (arm64 y x86_64) | Externos: `new`/`delete` (con `nothrow`), `exp10`, `sincos`, `bzero`, `memcpy`, `vDSP_maxmgv`, `vDSP_vsmul`. Ninguno de Swift |
| Memoria y comportamiento indefinido | `swift run --sanitize=address --sanitize=undefined SonicRouterPolicyTests` | 136 pasan; ningún informe de ASan ni UBSan |
| Compilación estricta | `swift build -Xswiftc -warnings-as-errors` | OK |
| Intel | `swift build -c release --triple x86_64-apple-macosx15.0 --product SonicRouterPolicyTests` y `arch -x86_64` sobre el binario (Rosetta 2) | 136, todas pasan, incluida la igualdad bit a bit (CAM-003-R04). Intel nativo no probado |
| Paquete universal | `Scripts/build-app.sh` (tras el arreglo de abajo) | `x86_64 arm64`, firma ad hoc válida, `sr_renderer_ioproc` en las dos; app **no abierta** |
| App arm64 | `SONICROUTER_UNIVERSAL=0 Scripts/build-app.sh` | Construida, firma ad hoc válida, contiene `sr_renderer_ioproc`; **no abierta** |

A05, nanosegundos por bloque de 256 tramas (5,33 ms de audio a 48 kHz);
dos ejecuciones de cada una en la misma sesión:

| Caso | Swift (`2b8aa30`) | C++ | Cambio |
|---|---|---|---|
| Estéreo, ganancia 1, EQ plano | 81–85 | 34 | 2,4× más rápido |
| Estéreo, ganancia 0,5, EQ plano | 81–82 | 34 | 2,4× |
| Dos salidas [2, 2], ganancia 0,5 | 15.595 | 351 | 44× |
| Estéreo, ganancia 0,5, EQ activo | 1.418–1.422 | 1.352–1.354 | 1,05× |
| Estéreo, compensación ×2 (limitador) | 110–111 | 60 | 1,8× |

Qué acredita: aritmética idéntica, ausencia de Swift en el núcleo y coste por
bloque con búferes sintéticos. Qué no acredita: comportamiento con taps y
dispositivos reales, ausencia de cortes bajo carga, ni el tiempo real del
callback dentro de Core Audio.

Observaciones:

- La primera versión con bucles C++ simples era **más lenta** que Swift en la
  copia simple (148 frente a 81 ns): vDSP vectoriza mejor. Se pasó a vDSP,
  que multiplica igual (misma salida bit a bit).
- En release, el compilador convierte `pow(10, x)` en `exp10` en los dos
  lenguajes; la equivalencia se ha comprobado en ese modo, no contra `pow`.
- El ecualizador apenas mejora: ya era código de punteros sin Swift dentro.

No ejecutado: la app en marcha, cualquier audio real, un Mac Intel nativo.

## Arreglo aparte, encontrado al verificar

- `Scripts/build-app.sh` en modo universal: con el sistema de compilación de
  Xcode 27.2 / Swift 6.4.2, `--show-bin-path` devuelve la misma carpeta para
  arm64 e Intel y `lipo` fallaba («same architectures (x86_64)»). Reproducido
  en `2b8aa30`, antes de CAM-003. Arreglado el 2026-11-18 a petición del
  titular: cada binario se copia a `build/arch/<arquitectura>/` antes de
  compilar el siguiente (vale también con el sistema de compilación antiguo).

## Riesgos

- Segundo lenguaje: más superficie que mantener. Mitigado con un solo archivo,
  interfaz C pequeña y el oráculo Swift en las pruebas.
- Un error de memoria en C++ no lo atrapa Swift. Mitigado: sin punteros
  guardados más allá de la llamada, tamaños tomados de los búferes, tabla de
  canales acotada a 64, y ASan + UBSan limpios sobre las pruebas. Las pruebas
  no cubren búferes malformados que Core Audio no debería enviar.
