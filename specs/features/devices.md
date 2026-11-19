# DEV-01 — Dispositivos y salida múltiple

Módulos: MOD-03 (`Sources/SonicRouter/CoreAudioClient.swift`), MOD-05
(`Sources/SonicRouter/AudioDeviceStore.swift`), el plan puro de MOD-01
(`Sources/SonicRouterCore/MultiOutputPlan.swift`) y la pestaña «Dispositivos»
de MOD-06 (`Sources/SonicRouter/DeviceMixerView.swift`, solo la lógica que
dispara). Ver [arquitectura](../architecture.md).

Estado: **actual**, línea base del 2026-11-19 sobre la rama
`feature/cam-001-reemision-transparente` en `93c97fc`.

Lectura: a fondo los cuatro archivos citados; de `ApplicationAudioStore.swift`
y `AudioProcessTap.swift`, solo lo que toca a dispositivos, salida múltiple y
limpieza (el resto está en [APP-01](app-sessions.md) y [AUD-01](audio-engine.md)).

Evidencia: **código leído**. El plan de salida múltiple (R14, R15, R18) tiene
pruebas automáticas de lógica pura; nada de esta spec se ha ejecutado contra
dispositivos reales ni con App Sandbox.

Fuentes: archivo y línea; `CAC` = `CoreAudioClient.swift`, `ADS` =
`AudioDeviceStore.swift`, `DMV` = `DeviceMixerView.swift`, `MOP` =
`MultiOutputPlan.swift`, `APT` = `AudioProcessTap.swift`, `AAS` =
`ApplicationAudioStore.swift`.

## Requisitos actuales

### Lista y propiedades

| ID | Comportamiento | Estado | Fuente |
|---|---|---|---|
| DEV-01-R01 | La lista sale de `kAudioHardwarePropertyDevices`; se descartan los UID internos (driver virtual antiguo `local.sonicrouter.audio.device` y prefijo `local.sonicrouter.agg.`) y los dispositivos sin canales de entrada ni de salida (suma de `mNumberChannels` de `kAudioDevicePropertyStreamConfiguration`) | actual | `CAC:7`, `:17`, `:22`, `:143`; `AudioControlPolicy.swift:93`–`:97` |
| DEV-01-R02 | De cada dispositivo se lee nombre, UID, si tiene entrada o salida, volumen de cada lado, si es la salida, la entrada o la salida de alertas predeterminada, si es integrado (transporte `BuiltIn`) y si puede entrar en una salida múltiple (tiene salida y su transporte no es agregado, virtual ni desconocido) | actual | `CAC:25`–`:41`, `Models.swift:60`–`:76` |
| DEV-01-R03 | Orden: primero la salida predeterminada, luego los que tienen salida, luego por nombre sin distinguir mayúsculas | actual | `CAC:43`–`:51` |
| DEV-01-R04 | Si no se puede leer una propiedad de texto, se usa «Audio Device N» con el ID del objeto, también como UID | actual | `CAC:169` |
| DEV-01-R05 | La salida múltiple propia (`local.sonicrouter.multioutput`) sí aparece en la lista, como una salida más, pero no es candidata a otra salida múltiple | actual | `MOP:27`–`:29`, `CAC:37`–`:40`, `Models.swift:76` |
| DEV-01-R06 | La pestaña muestra la salida del sistema con su volumen, y tarjetas de salidas y de entradas con insignias «salida», «entrada» y «sistema» | actual | `DMV:24`, `:32`–`:46`, `:204`–`:212` |

### Predeterminados

| ID | Comportamiento | Estado | Fuente |
|---|---|---|---|
| DEV-01-R07 | «Usar salida» cambia **a la vez** la salida predeterminada y la salida de efectos y alertas del sistema al mismo dispositivo | actual | `DMV:233`–`:238`, `ADS:76`, `CAC:54`–`:57` |
| DEV-01-R08 | «Usar entrada» cambia la entrada predeterminada | actual | `ADS:82`, `CAC:59` |
| DEV-01-R09 | Cambiar la salida predeterminada desde aquí reconstruye los motores de las apps controladas por la escucha de MOD-04 (APP-01-R14). Las llamadas con ruta también cambian la salida del sistema (APP-01-R13) | actual | `AAS:79`, `:749`–`:800` |

### Volumen y mute del dispositivo

| ID | Comportamiento | Estado | Fuente |
|---|---|---|---|
| DEV-01-R10 | Lectura del volumen: en salida, primero el volumen principal virtual (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`); si no, el escalar del elemento principal; si no, la media de los canales 1 y 2. Sin ninguno, la tarjeta muestra «Sin control» y «bloqueado» | actual | `CAC:176`–`:190`, `DMV:301`–`:313` |
| DEV-01-R11 | Escritura: el valor se acota a 0–1 y se intenta en el mismo orden, solo si la propiedad existe y es modificable; en los canales escribe 1 y 2. Si no se pudo escribir nada: «Este dispositivo no expone control de volumen por software». La entrada nunca usa el volumen virtual | actual | `CAC:207`–`:230`, `:63`–`:69`, `:476` |
| DEV-01-R12 | El deslizador envía el valor 80 ms después del último movimiento y al soltarlo sin espera; no reenvía el valor leído al aparecer la tarjeta. Tras escribir, actualiza el valor en memoria sin volver a leer la lista | actual | `DMV:280`–`:300`, `:317`, `ADS:114`–`:128`, `:220` |
| DEV-01-R13 | No hay mute de dispositivo: ninguna llamada a `kAudioDevicePropertyMute` en `Sources/`. El único mute es por app (AUD-01-R02) | actual | búsqueda en `Sources/` (2026-11-19) |

### Salida múltiple

| ID | Comportamiento | Estado | Fuente |
|---|---|---|---|
| DEV-01-R14 | Es un agregado **público y apilado** (`IsPrivate` 0, `IsStacked` 1) de UID fijo `local.sonicrouter.multioutput`, con el nombre localizado «Salida múltiple» del idioma activo al crearlo. Sin tap ni re-emisión: macOS reproduce en cada miembro | actual | `CAC:293`–`:336`, `MOP:29`, `ADS:101` |
| DEV-01-R15 | Miembros: sin UID repetidos y al menos dos (si no, error «Elige al menos dos salidas para la salida múltiple»); el integrado va primero si está; el primero es reloj y dispositivo principal, y los demás llevan compensación de deriva | actual | `MOP:37`–`:45`, `CAC:307`, `:321`–`:332`, `:484` |
| DEV-01-R16 | Crear o actualizar **destruye primero** la salida múltiple existente y la vuelve a crear | actual | `CAC:309`, `:368`–`:371` |
| DEV-01-R17 | Al crearla la hace salida predeterminada y de alertas (R07), con hasta 10 intentos separados 50 ms (hasta ~450 ms de espera en el hilo principal, porque MOD-05 es `@MainActor`) | actual | `CAC:346`, `:375`–`:387`, `ADS:4` |
| DEV-01-R18 | Frecuencia: la primera de 48, 44,1, 96 y 88,2 kHz que admitan todos los miembros se fija en cada miembro físico y en el agregado. Si no la hay, no se toca ninguna. Los fallos al fijarla se ignoran sin aviso | actual | `MOP:32`, `:50`–`:53`, `CAC:312`–`:319`, `:344`, `:415`–`:423` |
| DEV-01-R19 | Quitarla: si era la salida predeterminada, pasa a la primera candidata no integrada (o la primera candidata) y después se destruye. No vuelve a la salida que había antes de crearla | actual | `ADS:107`–`:111`, `CAC:352`–`:359` |
| DEV-01-R20 | **Persiste fuera de la app**: el cierre, el reposo, «Restaurar todo» y la limpieza del arranque solo destruyen agregados con nombre `sonicrouter…` o UID `local.sonicrouter.agg.…`, así que no la tocan. Solo se quita con el botón «Quitar» | actual | `MOP:27`–`:29`, `APT:119`–`:128`, `AAS:92`, `:843`–`:846` |
| DEV-01-R21 | La tarjeta aparece con dos o más candidatas o si ya existe. Todas las candidatas vienen marcadas (las desmarcadas se guardan solo en el estado de la vista, no se persisten). «Crear y usar» o «Actualizar y usar» se desactiva con menos de dos; «Quitar» no pide confirmación. Avisa de que el volumen se ajusta en cada dispositivo | actual | `DMV:28`, `:89`–`:94`, `:135`–`:164` |
| DEV-01-R22 | Una app con ruta a la salida múltiple, o con ella como salida del sistema, se re-emite a sus miembros físicos (AUD-01-R12) | actual | `APT:287`–`:297`, `AAS:123` |

### Escuchas, refresco y mensajes

| ID | Comportamiento | Estado | Fuente |
|---|---|---|---|
| DEV-01-R23 | Solo con alguna superficie visible (ventana, barra de menús, ajustes) hay escuchas en el objeto del sistema para la lista de dispositivos y las tres propiedades predeterminadas; al ocultarse todas se quitan. Cada aviso refresca en silencio tras 150 ms, y avisos seguidos se agrupan | actual | `ADS:45`–`:57`, `:153`–`:218`; `ContentView.swift:28`, `MenuBarView.swift:77`, `SettingsView.swift:22` |
| DEV-01-R24 | No hay escuchas de volumen ni de frecuencia por dispositivo | actual | `ADS:176`–`:184` |
| DEV-01-R25 | «Actualizar» (⌘R), el botón de la barra de menús y «Actualizar CoreAudio» refrescan con el mensaje «Dispositivos actualizados»; hacerse visible refresca sin mensaje | actual | `ADS:59`–`:70`, `Commands.swift:21`, `MenuBarView.swift:112`, `SettingsView.swift:344` |
| DEV-01-R26 | Cada acción deja un mensaje de éxito en es/en/ja («Salida activa: …», «Entrada activa: …», «Volumen de salida: N%», «Sonando en A + B», «Salida múltiple quitada»). Un fallo deja «Hubo un problema» y el detalle en `lastError`: «No se pudo <acción>. CoreAudio devolvió <código>» con el `OSStatus` como cuatro caracteres. La barra de estado lo muestra en naranja | actual | `ADS:76`–`:151`, `CAC:428`–`:489`, `APT:83`–`:98`, `ContentView.swift:232`–`:247` |

## Efectos fuera de la app y App Sandbox

Cruce con la [matriz de compatibilidad](../../docs/APP_STORE_MIGRATION.md#matriz-de-compatibilidad-con-app-sandbox)
y con [Efectos sobre el sistema](../architecture.md#efectos-sobre-el-sistema-fuera-de-la-app).
Nada de esto se ha probado con sandbox (CAM-002, [aceptación A10](../changes/CAM-002-prueba-app-sandbox.md)).

| Efecto | Requisitos | Fila de la matriz | Estado en la matriz |
|---|---|---|---|
| Cambia salida, entrada y salida de alertas predeterminadas | R07, R08, R17, R19 | Cambiar salida y entrada predeterminadas, volumen | P |
| Cambia el volumen de dispositivos | R11 | ídem | P |
| Cambia la frecuencia nominal de dispositivos físicos y no la devuelve | R18 | Cambiar frecuencia de muestreo del hardware | ? |
| Crea un agregado público que sigue tras cerrar la app | R14, R20 | Dispositivo multi-salida público | ? |
| Destruye agregados propios por nombre o UID | R16, R20 | Limpieza de taps y agregados propios | P |

Riesgos ligados: RIE-01, RIE-02 y RIE-09 en el [registro](../risks.md).

## Brechas

| ID | Brecha | Fecha |
|---|---|---|
| DEV-01-B01 | La salida múltiple pública persiste tras cerrar o desinstalar la app y la app no la ofrece quitar al salir; es el punto de mayor riesgo para la revisión de la tienda (fila «?» de la matriz). `[POR ACLARAR: ¿sobrevive a un reinicio del Mac o de coreaudiod?]` | 2026-11-19 |
| DEV-01-B02 | La frecuencia fijada en los miembros (R18) no se guarda ni se devuelve al quitar la salida múltiple, y sus fallos no se notifican | 2026-11-19 |
| DEV-01-B03 | Quitar la salida múltiple (R19) no vuelve a la salida previa sino a la primera candidata no integrada, que puede no ser la que el usuario tenía | 2026-11-19 |
| DEV-01-B04 | R16 destruye antes de crear: si la creación falla, la salida múltiple anterior ya no existe y macOS elige la salida por su cuenta | 2026-11-19 |
| DEV-01-B05 | R07 cambia también la salida de alertas sin decirlo; el usuario puede tenerla en otro dispositivo a propósito | 2026-11-19 |
| DEV-01-B06 | R17 bloquea el hilo principal hasta ~450 ms con `usleep` | 2026-11-19 |
| DEV-01-B07 | Sin escuchas de volumen (R24), un cambio hecho desde el teclado o el Centro de control no se ve hasta el siguiente refresco de la lista | 2026-11-19 |
| DEV-01-B08 | «Quitar» la salida múltiple no pide confirmación y las salidas desmarcadas se olvidan al cerrar la vista (R21) | 2026-11-19 |
| DEV-01-B09 | Solo el plan puro (R14 en parte, R15, R18) tiene pruebas; MOD-03 y MOD-05 no tienen ninguna | 2026-11-19 |
| DEV-01-B10 | R04 puede producir un UID falso «Audio Device N» que luego se compara como UID real en rutas y perfiles | 2026-11-19 |

`[POR ACLARAR: AudioDeviceStore.selectedDeviceID, selectedDevice y select(_:) no se usan fuera del store (búsqueda del 2026-11-19); ¿restos de una interfaz anterior?]`

## Aceptación

| ID | Escenario | Resultado esperado |
|---|---|---|
| DEV-01-A01 | Conectar y desconectar unos auriculares con la ventana abierta | La lista cambia en menos de 1 s sin pulsar «Actualizar» |
| DEV-01-A02 | «Usar salida» sobre otro dispositivo | Cambian la salida y la salida de alertas del sistema; el mensaje dice «Salida activa: …» |
| DEV-01-A03 | Mover el volumen de un dispositivo con volumen por software | Ajustes del sistema muestra el mismo valor |
| DEV-01-A04 | Dispositivo sin volumen por software (p. ej. HDMI) | La tarjeta muestra «Sin control» y no da error al aparecer |
| DEV-01-A05 | Crear la salida múltiple con integrado y HDMI | El integrado es el reloj, suena en ambos, es la salida del sistema y los dos quedan a 48 kHz |
| DEV-01-A06 | Cerrar la app con la salida múltiple activa | Sigue existiendo y sonando (comportamiento actual, R20) |
| DEV-01-A07 | «Quitar» con la salida múltiple activa | Desaparece y el sonido pasa a una salida física, sin silencio |
| DEV-01-A08 | Acción que falla en Core Audio | «Hubo un problema» y el código de cuatro caracteres en la barra de estado |

Ninguna aceptación se ha ejecutado. A05–A07 equivalen a CAM-002-A10 cuando se
prueben con sandbox.

## Cobertura

| Requisito | Prueba | Resultado |
|---|---|---|
| R15 (orden, reloj integrado, duplicados, mínimo de dos) | `runMultiOutputPlanTests`, `Tests/SonicRouterPolicyTests/main.swift:436`–`:447` | Pasa en `Scripts/test.sh` (ver [testing.md](../testing.md)) |
| R18 (frecuencia común, primera que gana, ninguna) | ídem, `:448`–`:452` | Pasa |
| R05, R20 (el UID de la salida múltiple no es interno y no lo barre la limpieza) | ídem, `:453`–`:456` | Pasa; solo comprueba el prefijo, no la limpieza real |
| Resto | Ninguna | — |
