# Roadmap del motor de audio

Estado actual:

- ✅ **Mute por app** (`MuteEngine`: tap `.mutedWhenTapped` + aggregate en marcha + IOProc) — funcional y verificado.
- ✅ **Volumen por app** (`AppVolumeTap`: mismo montaje, IOProc re-emite con ganancia) — funcional y verificado.
- ✅ Escaneo y agrupación de apps con audio activo.
- ✅ Permiso de captura de audio (TCC) integrado.
- ⬜ Ecualizador y routing de salida por app.

Para igualar Background Music, SoundSource o eqMac aún hacen falta estas piezas:

## 1. Captura por aplicación

Opciones:

- `AudioHardwareCreateProcessTap` en macOS 14.2+: permite crear taps de audio para procesos concretos.
- `AudioServerPlugIn`: crea un dispositivo virtual que el sistema ve como salida/entrada de audio.

El tap es más moderno y evita parte de la fricción de instalar drivers. El driver virtual da una experiencia más parecida a Background Music.

## 2. Grafo de procesamiento

Una vez capturado el audio:

- Aplicar ganancia por app.
- Aplicar mute/solo.
- Añadir EQ por bandas con `AVAudioUnitEQ`.
- Enviar cada stream al dispositivo elegido con `AVAudioEngine`.

## 3. Permisos y distribución

Para distribuir fuera de este Mac habrá que resolver:

- Firma de código.
- Hardened Runtime.
- Notarización.
- Permisos de captura de audio del sistema si se usa Process Tap.
- Instalador/desinstalador si se usa driver virtual.

## 4. Integración con la UI actual

La pantalla `Apps` ya guarda:

- Bundle id de la app.
- Dispositivo de salida deseado.
- Volumen deseado.

El futuro motor debería observar esos perfiles y activar/desactivar rutas al iniciar o cerrar apps.
