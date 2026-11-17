# Rendimiento

## Lo que se sabe hoy

No hay ninguna medición reproducible. Lo único anotado está en comentarios:

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
| REN-01-R03 | El callback de audio no reserva memoria ni toma locks (CTR-01) | Actual por diseño; sin medir (AUD-01-B02) |
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

- Copia muestra a muestra en varios dispositivos (AUD-01-B03).
- Biquads en `Double` escalar: `vDSP_biquad` es la primera opción si hiciera
  falta, antes de cambiar de lenguaje.
