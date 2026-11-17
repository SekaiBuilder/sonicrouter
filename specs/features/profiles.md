# PRF-01 — Perfiles por app

Módulos: MOD-01 (`ProfileArchive.swift`, `AudioControlPolicy.swift`) y MOD-04.
Lectura: a fondo la lógica; la vista `ProfilesView.swift`, no leída.
Evidencia: `Scripts/test.sh` cubre el formato y la fusión (ver
[testing.md](../testing.md)); el resto, código leído.

## Requisitos actuales

| ID | Comportamiento | Fuente |
|---|---|---|
| PRF-01-R01 | Un perfil guarda nombre de app, bundle ID, UID de salida, volumen y ecualizador (ausente si es plano) | `AudioControlPolicy.swift:3` |
| PRF-01-R02 | Un perfil casa con una app por bundle ID cuando ambos lo tienen; si no, por nombre | `AudioControlPolicy.swift:104` |
| PRF-01-R03 | El perfil se guarda al soltar el deslizador de volumen o del ecualizador, al elegir salida y al restaurar | `ApplicationAudioStore.swift:395`, `:440`, `:171`, `:446` |
| PRF-01-R04 | Los perfiles viven en `UserDefaults`, clave `SonicRouter.RouteProfiles`, como JSON | `ApplicationAudioStore.swift:1472` |
| PRF-01-R05 | Cuando una app con perfil vuelve a sonar, su perfil se aplica una vez por vida del proceso; un fallo no se reintenta en bucle | `ApplicationAudioStore.swift:1161` |
| PRF-01-R06 | El mute no se guarda en el perfil | `AudioControlPolicy.swift:52` |
| PRF-01-R07 | Exportar produce JSON con `format = local.sonicrouter.profiles`, `version = 1`, fecha ISO 8601 y la lista | `ProfileArchive.swift` |
| PRF-01-R08 | Importar acepta ese formato o una lista simple de perfiles; rechaza formato desconocido, versión mayor que 1, más de 1.000 entradas o ninguna utilizable | `ProfileArchive.swift` |
| PRF-01-R09 | Al importar se recortan espacios, el volumen se acota a 0–1 (no finito pasa a 1) y los duplicados de una misma app se quedan con el último | `ProfileArchive.swift` |
| PRF-01-R10 | Lo importado sustituye al perfil existente de la misma app y se aplica a las apps que suenan en ese momento | `ProfileArchive.swift`, `ApplicationAudioStore.swift:1457` |

## Brechas

| ID | Brecha | Fecha |
|---|---|---|
| PRF-01-B01 | El límite de 5 MB al importar (`ProfilesView.swift:17`) vive en la vista y no en el núcleo, así que ninguna prueba lo cubre | 2026-11-15 |
| PRF-01-B02 | Borrar todos los perfiles no tiene recuperación; hay un diálogo de confirmación en `ProfilesView.swift:66` `[POR ACLARAR: qué acción confirma]` | 2026-11-15 |
| PRF-01-B03 | El identificador de formato lleva el prefijo `local.sonicrouter`; debe seguir aceptándose aunque cambie el bundle ID | 2026-11-15 |
