# Rendimiento

## Lo que se sabe hoy

Única medición reproducible: el coste del render con búferes sintéticos
(CAM-003, 2026-11-18, Apple M5, `swift run -c release SonicRouterBench`).
No mide nada dentro de Core Audio. Nanosegundos por bloque de 256 tramas:

| Caso | Swift (`2b8aa30`) | C++ (CAM-003) |
|---|---|---|
| Estéreo, ganancia 1, EQ plano | 81–85 | 34 |
| Estéreo, ganancia 0,5, EQ plano | 81–82 | 34 |
| Dos salidas [2, 2] | 15.595 | 351 |
| EQ activo | 1.418–1.422 | 1.352–1.354 |
| Compensación ×2 (limitador) | 110–111 | 60 |

El peor caso (EQ activo) usa el 0,03 % del presupuesto de un bloque (5,33 ms).

Lo demás solo está anotado en comentarios:

| Dato | Fuente | Evidencia |
|---|---|---|
| Retardo tap → altavoz de ~66 ms, ~50 ms con búfer de 256 tramas | `AudioProcessTap.swift:850` | Comentario; sin método ni fecha |
| «128 tramas ganaba pocos ms con más CPU» | ídem | Comentario |
| El README dice «un par de milisegundos» | `README.md` | Contradice lo anterior |

## Presupuestos

**Decisión pendiente.** Se fijan a partir de la primera medición, no a ojo. Lo
que sí es requisito desde ya:

| ID | Requisito | Estado |
|---|---|---|
| REN-01-R01 | Ninguna afirmación de mejora sin medición antes y después con el mismo método | Objetivo |
| REN-01-R02 | Sin ventana y sin controles activos, la app no tiene escuchas ni temporizadores (APP-01-R16) | Actual, código leído |
| REN-01-R03 | El callback de audio no reserva memoria ni toma locks (CTR-01) | Actual por diseño; desde CAM-003 el objeto del núcleo no enlaza Swift ni reserva fuera de crear y destruir (`nm -u`). Sin medir en Mac real (AUD-01-B02) |
| REN-01-R04 | Cero sobrecargas de E/S (`kAudioDeviceProcessorOverload`) en una hora con 5 apps controladas | Objetivo |

## Plan de medición de referencia

Arnés a construir; todo requiere Mac real con permiso de captura.

| Métrica | Cómo | Escenarios |
|---|---|---|
| Tiempo del callback (p50, p99, máximo) | `os_signpost` alrededor del bloque, leído con `xctrace` | 1, 5 y 10 apps; EQ plano y activo; uno y dos dispositivos |
| Sobrecargas | Escucha de `kAudioDeviceProcessorOverload` en el agregado | ídem |
| CPU, memoria, despertares, energía | Plantillas Time Profiler, Allocations y Energy Log de Instruments | En reposo, ventana abierta, 5 apps controladas |
| Reservas en el hilo de audio | Allocations filtrado por hilo, y `malloc` instrumentado en compilación de prueba | Durante 10 minutos de re-emisión |
| Latencia de extremo a extremo | Impulso emitido por una app de prueba y capturado con un segundo tap | Mismo dispositivo; otro dispositivo |
| Transparencia | Prueba de residuo de [CAM-001](changes/CAM-001-reemision-transparente.md) | Mismo dispositivo |
| Estabilidad | Sesión de 8 horas con registro de sobrecargas y memoria | 3 apps controladas |

## Candidatos a optimizar (sin medir todavía)

- ~~Copia muestra a muestra en varios dispositivos (AUD-01-B03)~~: resuelto en CAM-003.
- Biquads en `Double` escalar (el caso más caro, aun así mínimo): solo si una
  medición en Mac real lo pidiera; cambiar el algoritmo rompería la igualdad
  bit a bit con la versión anterior.
