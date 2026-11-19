# UI-01 — Interfaz de usuario

Módulo: MOD-06 (`*View.swift`, `Commands.swift`, escenas de `SonicRouterApp.swift`),
más `Localization.swift` (MOD-07) y `Scripts/make-icon.swift`.
Profundidad: a fondo las vistas, los comandos y la localización; de
`SonicRouterApp.swift` solo las escenas (líneas 55–104).
Evidencia: **código leído** el 2026-11-19 en `feature/cam-001-reemision-transparente`
(`93c97fc`). La app no se abrió; nada de esta spec se ha visto en pantalla.

Esta spec describe solo lo que se ve y se toca. El comportamiento que hay
detrás ya está en [APP-01](app-sessions.md) (apps y control),
[AUD-01](audio-engine.md) (motor), [PRF-01](profiles.md) (perfiles),
[SIS-01](system-integration.md) (permiso, atajos globales, inicio, barra de
menús) y, para dispositivos, en DEV-01 (`devices.md`, en redacción).
Rutas sin carpeta: `Sources/SonicRouter/`.

## Requisitos actuales

### Escenas y navegación

| ID | Comportamiento | Fuente |
|---|---|---|
| UI-01-R01 | Tres escenas: ventana única `Window("SonicRouter", id: "main")` de 880×640 por defecto, mínimo 720×520 y redimensionable desde ese mínimo; `MenuBarExtra` con estilo `.window`; y `Settings` de 480 de ancho. Las tres llevan `.tint(Theme.accent)`. La ventana puede no abrirse al arrancar (SIS-01-R09) | `SonicRouterApp.swift:62`, `:67`, `:72`, `:73`, `:80`, `:91`, `:93`, `:98` |
| UI-01-R02 | La ventana es una barra lateral fija de 196 pt (icono de la app 34×34, «SonicRouter», `v` + versión o `dev` si no hay bundle, tres secciones, «Actualizar» y «Ajustes») y un detalle con, de arriba abajo: aviso de permiso, la sección elegida y la barra de estado | `ContentView.swift:5`, `:37–99`, `:101–123` |
| UI-01-R03 | Secciones, en orden: Mezclador (`slider.vertical.3`, ⌘1), Dispositivos (`hifispeaker.2`, ⌘2) y Guardados (`bookmark`, ⌘3). La elegida se recuerda entre arranques en `UserDefaults` (`SonicRouter.LastScreen`) y la comparten la barra lateral y el menú Visualización | `ContentView.swift:14`, `:164–197`, `Commands.swift:9` |
| UI-01-R04 | El botón de sección elegido se pinta con fondo del color de acento, texto blanco y sombra; al pasar el ratón, fondo gris al 6 % con animación de 0,13 s; su tooltip es el atajo (`⌘1`…) | `ContentView.swift:126–159` |
| UI-01-R05 | Al aparecer, la ventana devuelve el icono al Dock si no estaba (SIS-01-R08) y avisa a los dos stores de que la interfaz es visible (APP-01-R16); al desaparecer lo retira. El panel de la barra de menús y los Ajustes hacen lo mismo con su propia marca | `ContentView.swift:22–34`, `MenuBarView.swift:75–82`, `SettingsView.swift:21–28` |
| UI-01-R06 | La barra de estado muestra: un icono verde `checkmark.circle.fill`, o naranja `exclamationmark.triangle.fill` si hay error de dispositivos; el texto del error, si no el último mensaje de cualquiera de los dos stores, si no «Listo»; el estado del escáner («Buscando audio…» al arrancar, luego «Ninguna app reproduce audio ahora» o «N app(s) reproduciendo audio»); y la ficha de energía. Cambiar de idioma borra el mensaje | `ContentView.swift:200–248`, `ApplicationAudioStore.swift:16`, `:321` |
| UI-01-R07 | Ficha de energía: Activo (`bolt.fill`, acento), En reposo (`leaf.fill`, verde), Suspendido (`moon.zzz.fill`, gris), en cápsula con fondo del mismo tono al 14 %. Con acciones es un menú: Suspender/Reanudar (APP-01-R18) y «Salir de SonicRouter». Aparece en la barra de estado, en la cabecera de la barra de menús y en Ajustes → Actividad | `SharedViews.swift:156–240`, `Models.swift:51` |
| UI-01-R08 | Si el permiso está denegado, la ventana y el panel de la barra de menús muestran un aviso naranja: título, explicación, «Reintentar» (vuelve a sondear, SIS-01-R01) y «Abrir Ajustes» (SIS-01-R03). Con el permiso sin comprobar o concedido no se muestra nada | `SharedViews.swift:562–600`, `ContentView.swift:103`, `MenuBarView.swift:28` |

### Mezclador

| ID | Comportamiento | Fuente |
|---|---|---|
| UI-01-R09 | Cabecera «Mezclador» con subtítulo y dos botones: uno alterna «Silenciar todo» / «Activar todo» (este último solo cuando no queda nada audible que silenciar y hay apps silenciadas; desactivado si no cabe ninguno, APP-01-R09) y «Restaurar todo» (APP-01-R12), que actúa **sin confirmación** | `AppRoutingView.swift:93–146` |
| UI-01-R10 | Una sola sección «Apps con audio» con contador. Lista las apps que el store marca para el mezclador, **ordenadas por nombre** sin tener en cuenta si suenan, para que las filas no salten al silenciar. Vacía: «Nada suena por ahora» y una pista | `AppRoutingView.swift:15–19`, `:27–38`, `:58–60` |
| UI-01-R11 | Cada fila: icono de la app (o, para fuentes del sistema, un símbolo `phone.fill` o `waveform` sobre fondo de acento), nombre, barras animadas si suena, etiqueta verde «Llamada nativa» con explicación en el tooltip (APP-01-R05, AUD-01-R13) y, a la derecha, las salidas actuales o el bundle ID | `SharedViews.swift:90–122`, `:308–339`, `:514–519` |
| UI-01-R12 | Si la app admite volumen: deslizador 0–100 % con icono de altavoz de 1, 2 o 3 ondas (tachado y rojo si está silenciada o a 0) y porcentaje en monoespaciada; envía cambios en vivo y guarda al soltar (PRF-01-R03). Si no lo admite: línea «Silenciada», «Sonando» o «En pausa» | `SharedViews.swift:245–274`, `:341–360`, `:401–415` |
| UI-01-R13 | Selector de salida (`airplayaudio`, de acento si hay una elegida): menú con «Salida predeterminada» y cada salida, con marca en la actual; oculta el dispositivo virtual antiguo (lógica en DEV-01). Solo si la app admite volumen | `SharedViews.swift:363`, `:522–557`, `AppRoutingView.swift:9` |
| UI-01-R14 | Botón de ecualizador (`slider.horizontal.3`, de acento si no es plano; el tooltip resume la curva) que abre un popover; solo en la ventana y si la app admite volumen | `SharedViews.swift:303`, `:491–512` |
| UI-01-R15 | Botón «Silenciar» / «Activar» con borde, en rojo o en acento, desactivado si la app no es controlable. «Restablecer» (`arrow.uturn.backward`, APP-01-R11) solo aparece si la app tiene ajustes propios. Menú contextual: Silenciar/Activar sonido, «Silenciar las demás» (APP-01-R10), «Ecualizador…» y «Restablecer» | `SharedViews.swift:371–384`, `:417–489` |
| UI-01-R16 | Popover del ecualizador, 330 pt: título y nombre de la app, menú de preajustes (Plano, Voz clara −4/+3/+2, Más graves +6, Menos graves −6, Agudos suaves −5 dB; «Personalizado» si no coincide), tres deslizadores Graves 100 Hz / Medios 1 kHz / Agudos 8 kHz en pasos de 1 dB con la ganancia escrita con signo menos tipográfico, una nota sobre la bajada de nivel y «Dejar plano» (desactivado si ya lo está). Mover envía en vivo; soltar o elegir un preajuste guarda (AUD-01-R10) | `EqualizerView.swift:4–37`, `:49–76`, `:80–206` |

### Barra de menús

| ID | Comportamiento | Fuente |
|---|---|---|
| UI-01-R17 | El icono es `slider.vertical.3`, o `speaker.slash.fill` mientras alguna app esté silenciada (SIS-01-R10), con etiqueta de accesibilidad fija «SonicRouter» | `SonicRouterApp.swift:85–89`, `:101` |
| UI-01-R18 | Panel de 340 pt: cabecera (icono 22×22, nombre, ficha de energía, alternar silenciar/activar todo y actualizar), aviso de permiso, nombre de la salida predeterminada, filas compactas por nombre y un pie con «Abrir ventana» (devuelve el Dock), «Restaurar audio» (APP-01-R12, **sin confirmación**), Ajustes y «Salir». Vacío: «Nada suena ahora» | `MenuBarView.swift:18–22`, `:24–162` |
| UI-01-R19 | Una fila compacta tiene icono de 30, deslizador de volumen, selector de salida y un botón redondo de silencio; no tiene ecualizador ni botón «Restablecer», pero sí el menú contextual | `MenuBarView.swift:53–65`, `SharedViews.swift:303`, `:373`, `:419–428` |

### Dispositivos (lógica en DEV-01)

| ID | Comportamiento | Fuente |
|---|---|---|
| UI-01-R20 | Cabecera «Dispositivos» con «N salidas · M entradas»; franja de la salida del sistema con su volumen; tarjeta «Salida múltiple» si hay al menos dos candidatas o ya existe; y dos rejillas adaptables (columnas de 300–420 pt), Salidas y Entradas | `DeviceMixerView.swift:3–53`, `:55–82` |
| UI-01-R21 | Tarjeta «Salida múltiple»: insignia «activa» si es la salida del sistema, casillas por candidata (marcadas por defecto; las desmarcadas solo viven mientras la vista existe), «Crear y usar» / «Actualizar y usar» (desactivado con menos de dos), «Quitar» si existe, y nota de que no hay volumen común | `DeviceMixerView.swift:86–172` |
| UI-01-R22 | Tarjeta de dispositivo: icono, nombre en dos líneas, insignias «salida», «entrada», «sistema», control de volumen (o candado y «Sin control» / «bloqueado» si no lo admite) y «Usar salida» / «Usar entrada». El deslizador escribe con 80 ms de espera mientras se arrastra y sin espera al soltar | `DeviceMixerView.swift:187–327` |

### Guardados

| ID | Comportamiento | Fuente |
|---|---|---|
| UI-01-R23 | Cabecera «Ajustes guardados» con explicación y botones «Importar…» (solo JSON), «Exportar…» y «Olvidar todos»; los dos últimos se desactivan sin perfiles. Vacío: «Aún no hay ajustes guardados» en una tarjeta | `ProfilesView.swift:19–35`, `:82–138` |
| UI-01-R24 | Cada perfil: icono de la app instalada (o `app.fill`), nombre, bundle ID o «Sin identificador», ruta («Salida predeterminada», nombre del dispositivo o «Salida no conectada» en naranja), resumen del ecualizador si no es plano, volumen en % (rojo a 0) y papelera que lo borra **sin confirmación** | `ProfilesView.swift:236–317` |
| UI-01-R25 | «Olvidar todos» pide confirmación con un diálogo destructivo que aclara que las apps que suenan no cambian | `ProfilesView.swift:66–79`, `:124–129` |
| UI-01-R26 | Exportar propone «SonicRouter ajustes AAAA-MM-DD» (en el idioma activo) y, al terminar, pone «Ajustes exportados: N» en la barra de estado. Importar rechaza archivos de más de 5 MB (PRF-01-B01) y traduce cada error del formato (PRF-01-R08) a un mensaje propio en una alerta; cancelar no muestra nada | `ProfilesView.swift:140–233` |

### Ajustes

| ID | Comportamiento | Fuente |
|---|---|---|
| UI-01-R27 | Cuatro pestañas con `Form` agrupado: General (`gearshape`), Audio (`waveform`), Atajos (`keyboard`), Actividad (`bolt.horizontal`) | `SettingsView.swift:11–20` |
| UI-01-R28 | General: selector de idioma (Sistema, Español, English, 日本語); «Abrir al iniciar sesión» con texto de estado y botón «Abrir Ítems de inicio» si falta aprobación (SIS-01-R07); «Iniciar solo en la barra de menús» con su nota (SIS-01-R09) | `SettingsView.swift:34–110` |
| UI-01-R29 | Audio: estado del permiso (Concedido verde, Denegado rojo, Sin comprobar gris), «Comprobar de nuevo», «Abrir Ajustes de privacidad»; deslizador de compensación 0,5–8× en pasos de 0,05 con el valor «%.2f×» y botón «Restablecer a 1.00×» por encima de 1,01 (AUD-01-R07); texto sobre el motor | `SettingsView.swift:114–216` |
| UI-01-R30 | Atajos: interruptor de atajos globales, cada acción con sus teclas (atenuadas si está apagado, con triángulo naranja si el sistema la rechazó) y aviso naranja (SIS-01-R04, SIS-01-R05); y una lista fija de los atajos de la ventana | `SettingsView.swift:220–298` |
| UI-01-R31 | Actividad: ficha de energía, número de apps controladas, «Suspender ahora» / «Reanudar», dispositivos detectados, apps con audio y «Actualizar CoreAudio» | `SettingsView.swift:302–353` |

### Menús y teclado

| ID | Comportamiento | Fuente |
|---|---|---|
| UI-01-R32 | Antes del grupo de barra de herramientas del menú Visualización: Mezclador ⌘1, Dispositivos ⌘2, Guardados ⌘3 (eligen la sección y abren la ventana y el Dock) y Actualizar ⌘R | `Commands.swift:13–27`, `:62–66` |
| UI-01-R33 | Menú «Audio»: Silenciar todo ⇧⌘M y Activar todo ⇧⌘U (desactivados cuando no aplican), «Restaurar todo el audio» sin atajo ni confirmación, y Suspender/Reanudar SonicRouter | `Commands.swift:29–57` |
| UI-01-R34 | Ajustes se abre con ⌘, (el estándar de la escena `Settings`), desde la barra lateral y desde el panel de la barra de menús | `ContentView.swift:83–94`, `MenuBarView.swift:142–150` |

### Localización

| ID | Comportamiento | Fuente |
|---|---|---|
| UI-01-R35 | Los textos se escriben en línea en las tres lenguas: `l10n.t(es, en, ja)` en vistas y `L10n.text` fuera del hilo principal. No hay catálogo de cadenas ni `.lproj` con textos de la interfaz | `Localization.swift:30–92` |
| UI-01-R36 | El idioma se guarda en `UserDefaults` (`SonicRouter.Language`). «Sistema» toma el primer idioma preferido del Mac que empiece por es, ja o en; si ninguno, **español**. Las vistas observan `L10n.shared` y cambian al momento | `Localization.swift:38–61` |
| UI-01-R37 | El paquete declara `es` (región de desarrollo), `en` y `ja`, y solo trae traducido el texto del diálogo de permiso (SIS-01-R02) | `Scripts/build-app.sh:57–63`, `:101–110` |

### Identidad visual

| ID | Comportamiento | Fuente |
|---|---|---|
| UI-01-R38 | Acento fijo RGB (0,36; 0,42; 0,99), sin variante oscura ni de alto contraste. Tarjetas: fondo `controlBackgroundColor`, radio 12 continuo y borde del color primario al 7 %. Barra lateral y de estado con material `.bar`. Títulos de sección de 22 pt en negrita; etiquetas de sección en mayúsculas con espaciado 0,6; insignias en cápsula con el tono al 15 % | `SharedViews.swift:6–84`, `ContentView.swift:98`, `:229` |
| UI-01-R39 | Rojo para «silenciado», acento para «activar» y salida elegida, verde para llamada, reposo y «listo», naranja para avisos y errores. Las barras de reproducción son tres cápsulas de 2,5 pt animadas sin parar con `TimelineView(.animation)` | `SharedViews.swift:127–149`, `:254`, `:425`, `:439` |
| UI-01-R40 | El icono `Assets/AppIcon.icns` lo dibuja `Scripts/make-icon.swift`: squircle al 82 % del lienzo con radio 0,2237, degradado índigo → violeta de tres paradas (la del medio es el acento), brillo superior y tres faders blancos a alturas distintas; sombras desde 64 px; tamaños de 16 a 1024 empaquetados con `iconutil`. `build-app.sh` lo ejecuta solo si falta el `.icns` | `Scripts/make-icon.swift:41–45`, `:60–66`, `:81–131`, `:137–161`, `Scripts/build-app.sh:35` |

### Accesibilidad (lo que hay)

| ID | Comportamiento | Fuente |
|---|---|---|
| UI-01-R41 | El único modificador de accesibilidad explícito es la etiqueta del icono de la barra de menús. Los botones solo con icono llevan tooltip (`.help`); los controles estándar (`Toggle`, `Picker`, `Form`, `Menu`) tienen la accesibilidad del sistema; la navegación principal tiene atajos de teclado | `SonicRouterApp.swift:89`; búsqueda de `accessibility` en `Sources/SonicRouter/` |

## Brechas

| ID | Brecha | Fecha |
|---|---|---|
| UI-01-B01 | Accesibilidad: los botones solo con icono no tienen `accessibilityLabel`; VoiceOver depende del tooltip o del nombre del símbolo. Afecta a silenciar/activar todo y actualizar de la barra de menús (`MenuBarView.swift:100–117`), Ajustes del pie (`:142`), el botón compacto de silencio (`SharedViews.swift:420`), ecualizador (`:492`), selector de salida (`:546`), restablecer (`:374`) y la papelera de un perfil (`ProfilesView.swift:289`) | 2026-11-19 |
| UI-01-B02 | Accesibilidad: los deslizadores no tienen etiqueta: volumen por app (`SharedViews.swift:257`), bandas del ecualizador (`EqualizerView.swift:174`), volumen de dispositivo (`DeviceMixerView.swift:277`) y compensación con `.labelsHidden()` sin etiqueta propia (`SettingsView.swift:159`). VoiceOver solo leerá un valor | 2026-11-19 |
| UI-01-B03 | Accesibilidad: no se consulta Reduce Motion en ningún sitio. Las barras de reproducción se animan a la frecuencia de pantalla mientras haya una app sonando y visible, y no tienen equivalente para VoiceOver (`SharedViews.swift:132`) | 2026-11-19 |
| UI-01-B04 | Accesibilidad: los botones de la barra lateral son `.plain` hechos a mano y no exponen cuál está elegido (`ContentView.swift:136–155`); el resalte de las filas solo aparece al pasar el ratón | 2026-11-19 |
| UI-01-B05 | Accesibilidad: la etiqueta del icono de la barra de menús está escrita a mano, no se traduce y no dice si hay apps silenciadas aunque el icono sí cambia (`SonicRouterApp.swift:89`) | 2026-11-19 |
| UI-01-B06 | Accesibilidad: acento fijo sin variante para modo oscuro ni Aumentar contraste; el texto blanco sobre acento de la barra lateral no tiene contraste medido; Reducir transparencia queda en manos del material del sistema `[POR ACLARAR: comprobar en ejecución con Aumentar contraste y Reducir transparencia]` | 2026-11-19 |
| UI-01-B07 | Localización: textos escritos a mano fuera de `l10n.t`: «OK» de la alerta (`ProfilesView.swift:62`), el prefijo «v» (`ContentView.swift:47`), la etiqueta de la barra de menús (`SonicRouterApp.swift:89`), «Sistema · System · システム» (`Localization.swift:18`), «Hz/kHz» y «dB» (`EqualizerView.swift:51–75`), el porcentaje y «%.2f×» con punto decimal fijo (`SharedViews.swift:260`, `SettingsView.swift:155`) | 2026-11-19 |
| UI-01-B08 | Localización: sin catálogo de cadenas no hay plurales («N app(s)», `ApplicationAudioStore.swift:323`), ni formato de números según el idioma, ni herramienta para traductores; un texto nuevo sin las tres variantes no se puede detectar automáticamente | 2026-11-19 |
| UI-01-B09 | Localización: lo que dibuja el sistema (menús estándar de la app, botones de los paneles de abrir y guardar, «Cancelar» del diálogo, `error.localizedDescription`) sigue el idioma del Mac, no el elegido en Ajustes, así que puede verse mezclado `[POR ACLARAR: comprobar en ejecución con idioma de la app distinto del sistema]` | 2026-11-19 |
| UI-01-B10 | Localización: con el Mac en un idioma no incluido, la app sale en español (`Localization.swift:60`); para la tienda fuera de España, Japón y países de habla inglesa sería más esperable inglés `[POR ACLARAR: ¿decisión de producto?]` | 2026-11-19 |
| UI-01-B11 | La acción que destruye todos los controles tiene tres nombres («Restaurar todo», «Restaurar audio», «Restaurar todo el audio») y ninguno pide confirmación ni se puede deshacer; esto responde la pregunta de APP-01-B04: la interfaz no confirma. El tooltip del mezclador habla de «taps» (`AppRoutingView.swift:140`) | 2026-11-19 |
| UI-01-B12 | Los atajos se repiten como texto fijo en Ajustes → Atajos (`SettingsView.swift:260–266`) y en tooltips (`ContentView.swift:81`, `:94`, `AppRoutingView.swift:133–134`) en lugar de leerse de `Screen.shortcut` y de los comandos; además hay mayúsculas distintas en inglés («Mute All» en el menú, «Mute all» en el resto) y dos traducciones al japonés de «Activar todo» | 2026-11-19 |
| UI-01-B13 | El comentario de `AppMixerRow` dice que el panel compacto no tiene selector de salida (`SharedViews.swift:285–286`), pero `MenuBarView.swift:60–63` se lo pasa y se muestra | 2026-11-19 |
| UI-01-B14 | Estados: no hay indicador de carga en ninguna pantalla (solo el texto «Buscando audio…»); Dispositivos no tiene estado vacío si no hay salidas o entradas; con el permiso sin comprobar no se dice nada | 2026-11-19 |
| UI-01-B15 | El mezclador y el panel reordenan por nombre (R10, R18) mientras APP-01-R04 dice que el store pone primero las que suenan; la vista manda. Conviene que APP-01-R04 lo diga | 2026-11-19 |
| UI-01-B16 | Borrar un perfil suelto no pide confirmación ni se puede deshacer (R24) | 2026-11-19 |
| UI-01-B17 | Ningún requisito de esta spec tiene prueba automática ni captura de referencia: las vistas viven en el ejecutable y `Tests/` solo importa `SonicRouterCore` | 2026-11-19 |
| UI-01-B18 | Textos para el usuario con jerga técnica: «Process Taps de Core Audio», «dispositivos agregados», «Actualizar CoreAudio», «taps» (`SettingsView.swift:141`, `:181`, `:347`, `AppRoutingView.swift:140`) | 2026-11-19 |

## Aceptación

Recorridos manuales, sin ejecutar todavía.

| ID | Criterio | Cubre |
|---|---|---|
| UI-01-A01 | Primer arranque: la ventana abre a 880×640, no baja de 720×520, ⌘1/⌘2/⌘3 cambian de sección y la última elegida vuelve tras reiniciar | R01–R03, R32 |
| UI-01-A02 | Con el permiso denegado, ventana y panel muestran el aviso; tras concederlo, «Reintentar» lo quita | R08 |
| UI-01-A03 | Con una app sonando: la fila muestra barras, el deslizador cambia el % y el icono, silenciar pinta en rojo, el popover del ecualizador aplica cada preajuste y el selector marca la salida elegida | R11–R16 |
| UI-01-A04 | El panel de la barra de menús muestra las mismas apps que el mezclador; «Abrir ventana» abre la ventana y el icono del Dock | R17–R19 |
| UI-01-A05 | Importar un JSON ajeno muestra el mensaje propio; «Olvidar todos» pide confirmación y la papelera no | R23–R26 |
| UI-01-A06 | Al cambiar el idioma a es, en y ja en Ajustes, todos los textos propios de cada pantalla cambian sin reiniciar; solo quedan los de UI-01-B07 y UI-01-B09 | R35–R36 |
| UI-01-A07 | Con VoiceOver, cada control de cada pantalla anuncia un nombre en el idioma de la app. Hoy falla por UI-01-B01 y UI-01-B02 | R41 |
| UI-01-A08 | Con Reduce Motion activo no queda ninguna animación continua. Hoy falla por UI-01-B03 | R39 |

## Notas para capturas y revisión de la tienda

- Tamaños útiles para capturas: ventana 880×640 por defecto, panel de la
  barra de menús de 340 pt de ancho, Ajustes de 480 pt (R01, R18).
- Hacer las capturas con el permiso concedido: si no, el aviso naranja
  ocupa la cabecera de la ventana y del panel (R08).
- Fuera de un `.app` la barra lateral dice `vdev` (R02); capturar desde el
  paquete firmado.
- El texto de Ajustes → Audio explica a la revisión qué hace la app y que no
  instala drivers (R29); conviene alinearlo con
  [las notas de revisión](../../docs/store/metadata.md) y quitar jerga (B18).
- Para el mercado japonés y el inglés las pantallas propias están traducidas,
  pero los menús del sistema seguirán el idioma del Mac (B09).
- «Restaurar» sin confirmación (B11) y la falta de etiquetas de VoiceOver
  (B01, B02) son lo primero que un revisor de accesibilidad notaría.

## Cobertura

| Archivo | Profundidad |
|---|---|
| `ContentView.swift`, `MenuBarView.swift`, `SharedViews.swift`, `SettingsView.swift`, `ProfilesView.swift`, `EqualizerView.swift`, `AppRoutingView.swift`, `DeviceMixerView.swift`, `Commands.swift`, `Localization.swift` | A fondo |
| `Scripts/make-icon.swift` | A fondo |
| `SonicRouterApp.swift` | Escenas (55–104) |
| `Models.swift`, `ApplicationAudioStore.swift`, `AudioDeviceStore.swift`, `Scripts/build-app.sh` | Solo las líneas citadas |
