# Contribuir a SonicRouter

Gracias por querer mejorar SonicRouter. Es una utilidad de audio sensible a la
privacidad, así que la barra es algo inusual: el audio del usuario nunca debe salir de
su máquina. Interioriza los principios de abajo antes de mandar cambios.

## Principios no negociables

1. **El audio nunca se persiste ni se transmite.** Ninguna ruta debe escribir el audio
   capturado a disco, a un log o a la red. SonicRouter solo lo reinyecta en la salida.
2. **Limpia siempre lo que creas.** Todo tap o dispositivo agregado debe llevar el prefijo
   `local.sonicrouter.*` y destruirse en `invalidate()` / al cerrar. Un objeto de audio
   huérfano deja el sistema en mal estado.
3. **Falla seguro.** Si la activación de un motor falla a medias, deshaz lo que hiciste
   (`invalidate()` / `tearDownAll`) en lugar de dejar un tap colgado.
4. **Mantén los docs en sync.** Si cambias el comportamiento, actualiza `README.md` y, si
   toca la privacidad, `SECURITY.md`.

## Entorno de desarrollo

```bash
# Iterar la UI (sin permiso de captura, el mute no afectará audio real):
swift run

# Build de la .app real (necesaria para que el mute/volumen funcionen):
chmod +x Scripts/build-app.sh
Scripts/build-app.sh
open build/SonicRouter.app
```

- macOS 15+ y la toolchain de Swift instalada.
- El proyecto compila con **Swift 6** y concurrencia estricta; mantén el build **sin
  warnings**.

## Disciplina de código

- El **hot path de audio** (`StereoRender`, los `IOBlock`) corre en un hilo de tiempo
  real: nada de asignaciones, locks ni llamadas a Objective-C/Swift runtime dentro del
  IOProc. Lee la ganancia vía `GainBox` (lock-free) y trabaja sobre los buffers que te dan.
- Toda lectura de propiedades de CoreAudio debe calcular el tamaño con
  `AudioObjectGetPropertyDataSize` antes de reservar, y las propiedades `CFString` siguen
  la *Create Rule* (`takeRetainedValue`).
- El estado de la UI vive en stores `@MainActor` (`ApplicationAudioStore`,
  `AudioDeviceStore`); no toques objetos de CoreAudio fuera de ahí salvo en el IOProc.

## Estilo de commits

- Imperativo y conciso, con ámbito: `volume: keep re-emit tap alive at 100%`.
- Un cambio lógico por commit.
