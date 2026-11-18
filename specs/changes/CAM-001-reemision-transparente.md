# CAM-001 — Re-emisión transparente

Estado: **aprobado por el titular el 2026-11-18; T1 y T2 hechos**, T3–T6
pendientes. Rama: `feature/cam-001-reemision-transparente`. Fecha: 2026-11-15.
Origen: el titular pide que el sonido sea siempre el original, sin
deformación ni pérdida de claridad ([DEC-006](../decisions/README.md)).
Afecta a: [AUD-01](../features/audio-engine.md).

## Límite que no se puede saltar

macOS no ofrece volumen por app. Para atenuar, ecualizar o enviar una app a
otra salida, su audio tiene que pasar por SonicRouter. «Nativo» solo es
posible literalmente cuando no hay nada que controlar (AUD-01-R01, que se
conserva). Lo que este cambio exige es que, cuando sí pasa por SonicRouter,
lo que sale sea **la misma señal multiplicada por la ganancia**, y nada más.

## Requisitos objetivo

| ID | Requisito |
|---|---|
| CAM-001-R01 | Cuando la app se re-emite en el mismo dispositivo en el que ya sonaba, el tap captura el flujo de ese dispositivo tal cual (`CATapDescription(processes:deviceUID:stream:)`, sin mezcla): mismos canales y misma frecuencia que el dispositivo |
| CAM-001-R02 | En ese caso el tap no lleva compensación de deriva y no se ejecuta ningún remuestreo |
| CAM-001-R03 | SonicRouter no cambia la frecuencia nominal de ningún dispositivo físico para re-emitir en el mismo dispositivo |
| CAM-001-R04 | Con ganancia 1 y EQ plano, la salida del IOProc es idéntica bit a bit a su entrada. Con ganancia g ≤ 1, cada muestra es `entrada × g` en Float32, sin ninguna otra operación |
| CAM-001-R05 | Si el formato del tap no es Float32 lineal o sus canales no casan con los de la salida, el motor no arranca y la app sigue por su ruta nativa, con aviso |
| CAM-001-R06 | Cuando la ruta va a otro dispositivo, el remuestreo se limita al que exigen dos relojes distintos, a calidad máxima, y la spec lo declara como no bit a bit |
| CAM-001-R07 | Se conservan AUD-01-R01, R02, R13, R14, R15 y R16 |

## Aceptación

| ID | Dado / cuando / entonces |
|---|---|
| CAM-001-A01 | Dados búferes sintéticos Float32 intercalados y planos, cuando se copian con ganancia 1 y EQ plano, entonces la salida es igual byte a byte |
| CAM-001-A02 | Dados los mismos búferes y ganancia 0,5, entonces cada muestra de salida es exactamente `entrada × 0,5` |
| CAM-001-A03 | Dada una app de prueba que emite ruido conocido por la salida predeterminada, cuando SonicRouter la controla al 99 % en esa misma salida y se captura lo re-emitido con un segundo tap, entonces, alineadas las señales y deshecha la ganancia, el residuo queda por debajo de −120 dBFS |
| CAM-001-A04 | Misma prueba con una señal de 5.1 en un dispositivo de 6 canales: los seis canales llegan a su canal, sin mezcla |
| CAM-001-A05 | Durante A03, la frecuencia nominal del dispositivo es la misma antes, durante y después |
| CAM-001-A06 | Dado un formato de tap no admitido, el motor no arranca, la app suena por su ruta nativa y el estado lo dice |
| CAM-001-A07 | Escucha del titular: música conocida al 100 % (nativa) frente al 99 % (re-emitida) en altavoces integrados, auriculares con cable y Bluetooth, sin diferencia audible de timbre |

## Diseño

1. `AppVolumeTap` recibe el dispositivo y el flujo en los que la app suena
   (`kAudioProcessPropertyDevices`, que MOD-03 ya lee) y elige:
   - **mismo dispositivo**: tap de flujo de dispositivo, sin deriva, agregado a
     la frecuencia del dispositivo, sin `alignSampleRates`;
   - **otro dispositivo**: montaje actual (R06).
2. `StereoRender` pasa a MOD-01 (`SonicRouterCore`) para poder probarlo, y
   comprueba el formato antes de arrancar. Hecho: `Sources/SonicRouterCore/RealtimeRender.swift`
   (`GainBox`, `RealtimeGainLimiter`, `StereoRender`, `RenderFormatCheck`),
   movidos sin cambiar el código salvo `public`.

   Nota (2026-11-18): CAM-003 sustituyó después `StereoRender` y `GainBox` por
   el renderizador C++ `RealtimeRenderer`; A01 y A02 se ejecutan ahora contra el
   C++ y siguen pasando.

   Decisión de T2 (2026-11-18): un formato que no se puede leer **no** bloquea
   el motor; se arranca como antes y queda en el log. Bloquear ahí podría
   apagar un motor que hoy funciona por un fallo de lectura que no se ha
   podido observar sin hardware. Se revisa con T4. `oneToOne` (canales
   iguales) queda preparado para el tap de flujo de dispositivo de T3; la
   mezcla estéreo actual se reparte con `OutputChannelMap` y no lo usa.
3. Herramienta `SonicRouterNullTest`: genera la señal, monta el motor, captura
   la re-emisión y da el residuo en dBFS. Es la medida de A03 a A05.

### Referencia externa (leída el 2026-11-15)

`ronitsingh10/FineTune`, un mezclador público por app, hace las dos cosas que
propone este cambio (`FineTune/Audio/Engine/ProcessTapController.swift`):

- crea primero un tap por flujo de dispositivo y solo recurre a la mezcla
  estéreo si esa creación falla;
- apaga la compensación de deriva del tap cuando origen y salida comparten
  reloj, y anota que encendida con Bluetooth produce un chasquido rítmico.
  La mantiene encendida en salidas con cable o USB.

Consecuencia para el diseño: la regla «sin deriva en el mismo dispositivo»
(R02) hay que validarla **por tipo de dispositivo** (integrado, USB, HDMI,
Bluetooth) con la prueba de residuo, no darla por universal. Su licencia es
GPL-3.0: sirve de referencia, no se copia código.

Por comprobar antes de dar el diseño por bueno:

- `[POR ACLARAR: ¿un tap de flujo de dispositivo sin compensación de deriva se
  mantiene estable durante horas en el mismo dispositivo?]` Apple activa la
  deriva en su ejemplo de captura; aquí origen y destino comparten reloj, pero
  hay que medirlo en una sesión larga.
- `[POR ACLARAR: una app con varios flujos o que cambia de dispositivo a mitad]`
  hoy se resuelve reconstruyendo el motor al cambiar la salida.

## Tareas

| # | Tarea | Necesita al titular |
|---|---|---|
| T1 | Mover `StereoRender`, `GainBox` y `RealtimeGainLimiter` a `SonicRouterCore` y cubrir A01 y A02 | No — **hecho 2026-11-18** |
| T2 | Comprobación de formato (R05, A06) | No — **hecho 2026-11-18** (la parte «la app suena por su ruta nativa» de A06 sigue sin probar con audio real) |
| T3 | Tap de flujo de dispositivo y montaje sin deriva (R01–R03) | No para escribirlo; sí para probarlo |
| T4 | `SonicRouterNullTest` (A03–A05) | Sí: permiso de captura de audio para el binario nuevo |
| T5 | Escucha comparada (A07) y sesión larga | Sí |
| T6 | Actualizar AUD-01, README y SECURITY | No |

## Riesgos

- Sin deriva, un desajuste de reloj se oiría como clics periódicos: T4 y T5
  son obligatorias antes de fusionar.
- Dispositivos Bluetooth y AirPlay cambian de formato solos: R05 debe cubrirlo.
- Toca el corazón del motor: va en rama propia y no se fusiona sin A07.

## Evidencia

| Caso | Comando | Commit | Entorno | Resultado |
|---|---|---|---|---|
| A01 (ganancia 1, EQ plano: intercalado 2 canales, plano 2×1, intercalado 6 canales; valores extremos, subnormales y −0) | `Scripts/test.sh` | rama `feature/cam-001-reemision-transparente`, commit de T1/T2 | Xcode 27.2, Swift 6.4.2, macOS 27.2 arm64 | Pasa: igual bit a bit |
| A02 y R04 (g = 0,5; 0,37; 0,99; 0,0001; intercalado y plano; limitador neutro con g ≤ 1; multi-salida [2, 2]) | ídem | ídem | Xcode 27.2, Swift 6.4.2, macOS 27.2 arm64 | Pasa: cada muestra es `entrada × g` bit a bit |
| A06, parte lógica (Int16, Float64, big-endian, tamaño de trama incoherente, AC-3 y sin flujos rechazados; Float32 intercalado y plano aceptados; `oneToOne` rechaza 6→2) | ídem | ídem | Xcode 27.2, Swift 6.4.2, macOS 27.2 arm64 | Pasa |
| Las pruebas detectan un error | Mutación temporal: escalar × 1,000001 en la copia rápida | sin commit (revertida) | Xcode 27.2, Swift 6.4.2, macOS 27.2 arm64 | 5 fallos A01/A02, como se espera |
| Compilación estricta | `swift build -Xswiftc -warnings-as-errors` | ídem | Xcode 27.2, Swift 6.4.2, macOS 27.2 arm64 | OK |

Total de `Scripts/test.sh`: 111 comprobaciones (85 antes), todas pasan.

No ejecutado: A03–A05 y A07 (necesitan T3, T4 y al titular); A06 con un
dispositivo real de formato no Float32; la app en marcha tras el cambio.
