# Ficha de la tienda — borrador

Borrador para revisar. Los textos describen solo lo que la app hace hoy según
`specs/`. Los campos marcados **PENDIENTE** dependen del titular o de la cuenta
y no se han inventado.

## Datos

| Campo | Valor |
|---|---|
| Nombre | SonicRouter — **PENDIENTE** comprobar disponibilidad en App Store Connect |
| Bundle ID | **PENDIENTE** (hoy `local.sonicrouter.app`) |
| Categoría principal | Utilidades (ya es la del `Info.plist`); alternativa: Música |
| Precio y modelo | **PENDIENTE** |
| Titular / vendedor | **PENDIENTE** |
| URL de soporte | **PENDIENTE** (candidata: las issues del repositorio) |
| URL de política de privacidad | **PENDIENTE** (texto abajo) |
| Copyright | **PENDIENTE** (el `Info.plist` dice «© 2026 SonicRouter»; la licencia, «© 2026 Francesco Catania») |
| Versión | 1.5 hoy; la primera de tienda, por decidir |
| Clasificación por edades | Sin contenido sensible: se rellena en el cuestionario |
| Cifrado | No usa cifrado propio ni red |

## Etiquetas de privacidad

Datos recogidos: **ninguno**. La app no tiene red, analítica ni cuentas.

## Textos

### Español

**Subtítulo** (30 máx.): Volumen y mute por aplicación

**Descripción**

SonicRouter te deja controlar el sonido de cada app por separado: silencia una
llamada sin colgar, baja la música mientras ves un vídeo o manda una app a
otros altavoces.

- Silencia o ajusta el volumen de cada app de forma independiente.
- Envía cada app a la salida que elijas.
- Ecualizador de graves, medios y agudos por app, con preajustes.
- Recuerda los ajustes de cada app y los recupera cuando vuelve a sonar.
- Exporta e importa tus ajustes.
- Silenciar todo, o dejar sonando solo una app, con un clic.
- Panel rápido en la barra de menús y atajos globales opcionales.
- Sin drivers ni instaladores.

Tu audio no sale de tu Mac: SonicRouter no graba, no guarda y no envía nada.

**Palabras clave**: volumen,mezclador,audio,silenciar,ecualizador,sonido,app,salida,altavoces,auriculares

### English

**Subtitle**: Per-app volume and mute

**Description**

SonicRouter lets you control the sound of each app separately: mute a call
without hanging up, turn the music down while you watch a video, or send one
app to different speakers.

- Mute or adjust the volume of each app independently.
- Send each app to the output you choose.
- Per-app bass, mid and treble equalizer, with presets.
- Remembers each app's settings and restores them when it plays again.
- Export and import your settings.
- Mute everything, or keep just one app playing, in one click.
- Quick panel in the menu bar and optional global shortcuts.
- No drivers, no installers.

Your audio never leaves your Mac: SonicRouter does not record, store or send
anything.

**Keywords**: volume,mixer,audio,mute,equalizer,sound,app,output,speakers,headphones

### 日本語

**サブタイトル**: アプリごとの音量とミュート

**説明**

SonicRouterはアプリごとに音をコントロールできます。通話を切らずにミュートしたり、動画を見ながら音楽の音量を下げたり、特定のアプリだけ別のスピーカーに出力したりできます。

- アプリごとにミュートや音量調整が可能。
- アプリごとに出力先を選択。
- アプリごとの低音・中音・高音イコライザー（プリセット付き）。
- アプリごとの設定を記憶し、再生時に自動で復元。
- 設定の書き出しと読み込み。
- ワンクリックですべてミュート、または1つのアプリだけ再生。
- メニューバーのクイックパネルと、任意のグローバルショートカット。
- ドライバやインストーラは不要。

音声がMacの外に出ることはありません。SonicRouterは録音・保存・送信を一切行いません。

**キーワード**: 音量,ミキサー,オーディオ,ミュート,イコライザー,サウンド,アプリ,出力,スピーカー,ヘッドホン

Los textos en japonés necesitan revisión de un hablante nativo antes de publicarse.

## Notas para App Review (inglés)

> SonicRouter is a per-app volume mixer. macOS has no public per-app volume
> API, so the app uses Core Audio process taps (AudioHardwareCreateProcessTap)
> to mute an app's original output and re-emit it at the chosen level. This is
> why it requests the System Audio Recording permission.
>
> The captured audio is only held in memory for one I/O cycle and written back
> to the output device. It is never written to disk and the app has no network
> access.
>
> To test: play audio in any app (for example Music or Safari), open
> SonicRouter, grant the permission when prompted, then move that app's slider
> or press its mute button. "Restore all" removes every tap.
>
> "Open at login" and global shortcuts are optional and off by default.

Añadir, cuando se sepa por CAM-002: qué cambios hace la app en el sistema
(salida predeterminada durante llamadas, dispositivo multi-salida) y cómo se
deshacen.

## Política de privacidad — borrador

> **SonicRouter y tu privacidad**
>
> SonicRouter no recoge, guarda ni transmite datos personales.
>
> Para ajustar el volumen de cada app, SonicRouter necesita el permiso de
> grabación de audio del sistema. El audio se procesa en la memoria de tu Mac
> y se devuelve de inmediato a tu salida de sonido. No se graba, no se guarda
> en disco y no se envía a ningún sitio. La app no se conecta a internet.
>
> Lo único que SonicRouter guarda, en tu Mac, son tus preferencias: nombre e
> identificador de las apps que ajustas, su volumen, su salida y su
> ecualizador. Puedes borrarlas desde la propia app.
>
> Contacto: **PENDIENTE**.

Traducir a en y ja cuando el texto esté aprobado.

## Recursos visuales

| Recurso | Estado |
|---|---|
| Icono | Existe `Assets/AppIcon.icns`; la tienda pide catálogo de recursos con 1024 px |
| Capturas (1280×800, 1440×900, 2560×1600 o 2880×1800) | Sin hacer: mezclador, barra de menús, ecualizador, guardados; en es/en/ja |
| Vídeo de vista previa | Opcional; hay dos GIF en `docs/` como referencia |

## Versionado y notas

Versión semántica en `MARKETING_VERSION` y número de compilación creciente.
Notas de lanzamiento: **PENDIENTE** hasta saber qué entra en la primera versión
de tienda.
