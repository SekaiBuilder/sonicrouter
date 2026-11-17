# AUD-01 — Motor de audio por app

Módulo: MOD-02 (`Sources/SonicRouter/AudioProcessTap.swift`), con el
ecualizador de MOD-01 y la elección de motor de MOD-04.

Lectura: a fondo. Evidencia: **código leído**; nada de esta spec se ha
comprobado con audio real en esta línea base.

## Requisitos actuales

| ID | Comportamiento | Fuente |
|---|---|---|
| AUD-01-R01 | Con volumen ≥ 99,9 %, salida predeterminada, EQ plano y sin mute, la app no tiene tap: suena por su ruta nativa | `AudioControlPolicy.swift:66`, `ApplicationAudioStore.swift:724` |
| AUD-01-R02 | El mute (o volumen ≤ 0,1 %) crea un tap de mezcla estéreo `.muted`, un agregado privado con un solo dispositivo físico y un IOProc que escribe ceros | `AudioProcessTap.swift:684` |
| AUD-01-R03 | Volumen por debajo de 99,9 %, salida elegida o EQ no plano crean el motor de re-emisión: tap de mezcla estéreo `.muted` y agregado privado con las salidas físicas y el tap | `AudioProcessTap.swift:816` |
| AUD-01-R04 | El tap del motor de re-emisión lleva compensación de deriva a calidad máxima, siempre, también cuando re-emite en el mismo dispositivo en el que la app ya sonaba | `AudioProcessTap.swift:839`, `:478` |
| AUD-01-R05 | Al crear un motor se cambia la frecuencia nominal de cada salida a la de la salida del sistema si la admite, y la del agregado a la de su reloj | `AudioProcessTap.swift:534` |
| AUD-01-R06 | El motor de re-emisión pide 256 tramas de búfer al agregado | `AudioProcessTap.swift:852` |
| AUD-01-R07 | La ganancia aplicada es `deslizador × compensación`; el deslizador es lineal 0–1 y la compensación va de 0,5 a 8 (1,0 por defecto desde la clave `v5`) | `AudioProcessTap.swift:188`, `ApplicationAudioStore.swift:33` |
| AUD-01-R08 | Con ganancia ≤ 1 no actúa el limitador. Por encima de 1, la ganancia se limita al margen del bloque (`1 / pico`) con recuperación suavizada | `AudioProcessTap.swift:226`, `AudioControlPolicy.swift:84` |
| AUD-01-R09 | Con un solo dispositivo y la misma disposición de búferes, la copia es `vDSP_vsmul`. Si no, se copia muestra a muestra: L/R a los dos primeros canales de cada dispositivo y silencio en el resto | `AudioProcessTap.swift:354`, `:382` |
| AUD-01-R10 | El ecualizador (tres biquads en doble precisión y preamplificación) se aplica después de la ganancia; plano y asentado no toca las muestras | `Equalizer.swift:361` |
| AUD-01-R11 | Los filtros se calculan para la frecuencia del agregado al crear el motor y no se recalculan si cambia después | `AudioProcessTap.swift:855` |
| AUD-01-R12 | Una salida que es un agregado se descompone en sus dispositivos físicos; el primero es el reloj y los demás llevan compensación de deriva | `AudioProcessTap.swift:504`, `:461` |
| AUD-01-R13 | Una app en llamada nunca se re-emite | `ApplicationAudioStore.swift:650`, `:749` |
| AUD-01-R14 | Al sustituir un motor de re-emisión, el anterior se para antes de arrancar el nuevo; al sustituir un motor de mute, el anterior se para después | `ApplicationAudioStore.swift:690`, `:641` |
| AUD-01-R15 | Cualquier fallo al activar un motor ejecuta `invalidate()`, que para el IOProc y destruye agregado y tap | `AudioProcessTap.swift:744`, `:927` |
| AUD-01-R16 | El callback no reserva memoria ni toma locks por diseño: atómicos, punteros reservados de antemano, vDSP | `AudioProcessTap.swift:199`, `Equalizer.swift:304` |

## Dónde deja de ser el sonido original

Cuando el motor de re-emisión está activo, la señal que llega al altavoz ya no
es la de la app. Etapas que la alteran, por orden:

| # | Etapa | Efecto | Evitable |
|---|---|---|---|
| 1 | Tap de **mezcla estéreo** (R03) | Todo se reduce a dos canales: se pierde multicanal y audio espacial; la mezcla puede cambiar el nivel | Sí |
| 2 | **Compensación de deriva** del tap (R04) | Un remuestreador trabaja siempre, aunque origen y destino compartan reloj. El propio código anota que el remuestreador por defecto suena «filtrado» | Sí, cuando el destino es el mismo dispositivo |
| 3 | Conversión de frecuencia si la del tap y la del agregado difieren (R05) | Remuestreo adicional | Sí, en el mismo dispositivo |
| 4 | Cambio de frecuencia nominal del hardware (R05) | Afecta a todo el audio del Mac, no solo a la app | Sí |
| 5 | Compensación > 1 y limitador (R07, R08) | Compresión dinámica | Ya neutra por defecto |
| 6 | Retardo de ~50 ms anotado en el código (R06) | Desfase con la imagen | En parte |
| 7 | Ecualizador en uso | Deliberado | Es la función |
| 8 | Ruta a **otro** dispositivo | Dos relojes distintos: remuestrear es inevitable | No |

Las etapas 1 a 4 son hipótesis razonadas del código, no mediciones. El cambio
[CAM-001](../changes/CAM-001-reemision-transparente.md) las elimina y exige
medirlo.

## Brechas

| ID | Brecha | Fecha |
|---|---|---|
| AUD-01-B01 | El formato del tap se supone Float32 y solo se registra en el log; un formato distinto se trataría como Float32 | 2026-11-15 |
| AUD-01-B02 | R16 es disciplina de código: ninguna prueba ni medición demuestra que el callback no reserve ni retenga memoria (el bloque captura referencias a clases) | 2026-11-15 |
| AUD-01-B03 | La ruta de varios dispositivos (R09) va muestra a muestra, sin vectorizar | 2026-11-15 |
| AUD-01-B04 | R11: un cambio de frecuencia con el motor en marcha deja los filtros mal afinados | 2026-11-15 |
| AUD-01-B05 | No hay ninguna medida de transparencia, latencia ni carga del motor | 2026-11-15 |
| AUD-01-B06 | `StereoRender` vive en el ejecutable de la app y no se puede probar desde `SonicRouterPolicyTests` | 2026-11-15 |
