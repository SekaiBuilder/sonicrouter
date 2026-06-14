# Política y modelo de seguridad

SonicRouter es una app sensible a la privacidad: para silenciar y ajustar el volumen
por aplicación necesita **capturar el audio del sistema** (un permiso TCC fuerte). Este
documento explica qué hace con ese acceso, qué **garantiza**, cuál es su superficie de
ataque y —igual de importante— qué **no** hace. Los límites se documentan con honestidad
en lugar de insinuar garantías que no podemos cumplir.

## 1. Modelo de seguridad en una línea

> SonicRouter procesa el audio **solo en memoria y solo en tu Mac**. No graba, no
> almacena y no transmite el audio que captura: lo reinyecta al instante en tu salida.

## 2. Frontera de confianza y flujo de datos

```
  TU MAC (de confianza)
  ───────────────────────────────────────────────────────────
  App de origen (FaceTime, Chrome, Spotify, …)
        │  audio del sistema
        ▼
  Process Tap de CoreAudio  ──►  IOProc de SonicRouter  ──►  dispositivo de salida real
        (mutedWhenTapped)        (descarta = mute,            (tu altavoz/auriculares)
                                  o copia × ganancia = volumen)
```

- Todo ocurre **dentro de CoreAudio**, en el mismo dominio de reloj que la salida real.
- El audio capturado vive en *buffers en memoria* durante un ciclo de IO y se sobrescribe
  en el siguiente. **Nunca se serializa** a disco ni a la red.
- SonicRouter **no abre sockets ni hace peticiones de red** de ningún tipo.

## 3. Garantías verificables

| Invariante | Garantía |
|---|---|
| **INV-1** | El audio capturado no se escribe a disco ni se envía por red — solo se reinyecta a la salida. |
| **INV-2** | El permiso de captura solo se solicita mediante la API oficial (`AudioHardwareCreateProcessTap`); el *probe* de permiso crea un tap **sin mute** y lo destruye al instante, sin afectar audio. |
| **INV-3** | Todos los taps y dispositivos agregados creados por la app llevan el prefijo `local.sonicrouter.*` y se destruyen al iniciar, al cerrar y con «Restaurar todo». |
| **INV-4** | «Restaurar todo» (y el cierre de la app) elimina todo tap/agregado propio y devuelve el audio del sistema a su estado nativo. |

Estos puntos son auditables leyendo el código: las únicas operaciones sobre el audio
están en `StereoRender` y los `IOBlock` de `MuteEngine` / `AppVolumeTap`
(`Sources/SonicRouter/AudioProcessTap.swift`), y la limpieza en
`SonicRouterAudioCleanup`.

## 4. Qué protege / respeta

- **Solo controla el audio, no lo escucha.** El IOProc de mute emite silencio; el de
  volumen multiplica las muestras por una ganancia. No hay ninguna ruta que copie el
  audio a otro destino.
- **Aislamiento por app.** Cada control crea su propio tap + dispositivo agregado
  privado; tocar una app no altera el resto.
- **Limpieza agresiva.** Si la app se cae o se cierra de forma inesperada, el siguiente
  arranque barre cualquier tap/agregado huérfano con el prefijo `local.sonicrouter.*`.

## 5. Qué NO hace — no-garantías honestas

- **No es un sandbox.** SonicRouter se ejecuta sin App Sandbox porque los Process Taps
  necesitan acceso al audio del sistema. Concédele el permiso solo si confías en el
  binario que estás ejecutando (compílalo tú mismo desde la fuente si quieres certeza).
- **No cifra ni protege tu audio frente a otras apps.** Cualquier otra app con el mismo
  permiso TCC podría capturar el audio igual que SonicRouter; el control de quién tiene
  ese permiso lo gestiona macOS, no esta app.
- **No persiste el audio en ningún momento.** Lo único que guarda en disco son tus
  *preferencias* (volúmenes y rutas por app) en `UserDefaults` — nunca audio.
- **Una máquina comprometida queda fuera de alcance.** SonicRouter asume que tu propio
  Mac es de confianza; malware local puede leer el audio antes de que SonicRouter lo vea.

## 6. Superficie de ataque

- **Permiso de captura de audio (TCC).** Es el único privilegio sensible. Se solicita por
  la vía oficial y se puede revocar en *Ajustes → Privacidad y seguridad*.
- **Sin red.** No hay listeners, ni clientes HTTP, ni telemetría. No hay superficie de red.
- **Dispositivos agregados privados.** Se crean con `kAudioAggregateDeviceIsPrivateKey`, así
  que no aparecen como salidas seleccionables para otras apps.
- **Preferencias en `UserDefaults`.** Solo nombres de app, UID de dispositivo y volúmenes;
  nada sensible.

## 7. Valores por defecto seguros

- El audio se procesa en memoria y se descarta cada ciclo.
- Los taps se crean como privados (`isPrivate = true`) y con `mutedWhenTapped`.
- Al arrancar, al cerrar y ante cualquier error de activación, se destruyen los objetos
  de audio propios para no dejar el sistema en un estado raro.

## 8. Reportar una vulnerabilidad

Por favor **no abras un issue público** para problemas de seguridad. En su lugar abre un
**GitHub Security Advisory** privado en este repositorio (Security → *Report a
vulnerability*). Se intentará responder con prontitud; agradecemos un plazo razonable para
corregir antes de la divulgación pública.

## 9. Alcance de esta evaluación

Esto describe las propiedades de privacidad/seguridad de la app y su manejo de CoreAudio.
**No es una auditoría externa** ni certifica cumplimiento normativo. Para usos de alto
riesgo, encarga una revisión independiente.
