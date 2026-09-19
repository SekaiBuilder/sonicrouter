# Roadmap del motor de audio

Estado actual:

- ✅ **Mute por app** (`MuteEngine`: tap `.mutedWhenTapped` + aggregate en marcha + IOProc) — funcional y verificado.
- ✅ **Volumen por app** (`AppVolumeTap`: mismo montaje, IOProc re-emite con ganancia) — funcional y verificado.
- ✅ **Routing de salida por app** mediante el mismo tap de re-emisión.
- ✅ **Perfiles persistentes** que restauran volumen, salida y ecualizador cuando la app vuelve a reproducir audio, exportables e importables como JSON.
- ✅ Escaneo y agrupación de apps con audio activo.
- ✅ Permiso de captura de audio (TCC) integrado.
- ✅ **Ecualizador por app** de tres bandas (`RealtimeEqualizer`): biquads RBJ calculados para la frecuencia de muestreo de la salida, preamplificación automática que compensa los realces y bypass exacto cuando es plano. Verificado con pruebas de respuesta en frecuencia y de procesado.
- ✅ Silenciar todo, «silenciar las demás» y atajos globales opcionales.

## Arquitectura admitida

SonicRouter usa exclusivamente `AudioHardwareCreateProcessTap` en macOS 15 o superior. Cada control activo crea un tap privado y un dispositivo agregado temporal que comparte el reloj de la salida real. No instala drivers, servicios privilegiados ni dispositivos virtuales permanentes.

Los motores se crean bajo demanda y se destruyen al restaurar, pausar, dormir o cerrar la app. Si una reconstrucción falla, el motor anterior se conserva hasta que el reemplazo haya arrancado correctamente.

## Próximas piezas

- Ecualizador con más bandas o curvas propias por salida.
- Recalcular los filtros si la frecuencia de muestreo de la salida cambia con el motor en marcha (hoy se toma al crear el motor).
- Añadir pruebas de integración sobre hardware de salida real y cambios de dispositivo.
- Medir latencia, consumo y estabilidad en sesiones largas.

## Distribución

Para distribuir fuera de este Mac habrá que resolver:

- Firma con una identidad Developer ID Application.
- Hardened Runtime (el script lo activa cuando recibe `CODE_SIGN_IDENTITY`).
- Notarización y stapling del bundle distribuido.
- Validación manual del diálogo TCC en una cuenta limpia de macOS.
