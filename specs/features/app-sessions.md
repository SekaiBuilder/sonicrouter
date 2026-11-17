# APP-01 — Sesiones de apps y control

Módulo: MOD-04 (`Sources/SonicRouter/ApplicationAudioStore.swift`).
Lectura: a fondo. Evidencia: **código leído**; sin pruebas automáticas.

## Requisitos actuales

### Detección

| ID | Comportamiento | Fuente (línea) |
|---|---|---|
| APP-01-R01 | Los procesos con audio se agrupan en una fila por app: por bundle ID de la app contenedora (quitando sufijos de helper o renderer), o por PID si no hay bundle | 1291, 1314, 1325 |
| APP-01-R02 | `avconferenced` y `callservicesd` forman la fila «FaceTime»; `rapportd`, la de «Continuity» | 1293, 1365 |
| APP-01-R03 | SonicRouter no se lista a sí mismo (por PID o por bundle `local.sonicrouter.app`) | 1306 |
| APP-01-R04 | Se muestran las apps que suenan ahora y las que tienen un control activo; primero las que suenan, luego por nombre | 307, 312 |
| APP-01-R05 | Una app está «en llamada» cuando usa entrada y salida a la vez | 1268 |

### Control

| ID | Comportamiento | Fuente |
|---|---|---|
| APP-01-R06 | Cada cambio (mute, volumen, salida, EQ) se guarda como intención y se aplica; si la aplicación falla, se restaura la intención anterior | 345–353, 385 |
| APP-01-R07 | Silenciar sin permiso concedido vuelve a sondear el permiso y, si sigue denegado, lo dice y no hace nada | 333 |
| APP-01-R08 | Elegir como salida la que ya es predeterminada equivale a «predeterminada» | 164 |
| APP-01-R09 | «Silenciar todo» actúa sobre las apps que suenan y no están silenciadas, y se detiene si el permiso está denegado. «Activar todo» reactiva las silenciadas | 489–532 |
| APP-01-R10 | «Silenciar las demás» deja sonando una app y silencia el resto | 541 |
| APP-01-R11 | «Restaurar» una app la deja al 100 %, salida predeterminada y EQ plano, y lo guarda en su perfil | 446 |
| APP-01-R12 | «Restaurar todo» destruye todos los motores y objetos de audio propios, borra las intenciones y pone todos los perfiles a 100 %, sin salida y sin EQ | 463 |
| APP-01-R13 | Una app en llamada con salida elegida cambia la salida del sistema a ese dispositivo y la devuelve al terminar, salvo que el usuario haya elegido otra entretanto | 749, 791 |
| APP-01-R14 | Si cambia el conjunto de procesos de una app o la salida predeterminada, sus motores se reconstruyen | 816, 1187 |

### Energía y ciclo de vida

| ID | Comportamiento | Fuente |
|---|---|---|
| APP-01-R15 | No hay sondeo: la app reacciona a escuchas de Core Audio y a avisos de lanzamiento y cierre de apps, con un retardo de 200 ms que agrupa ráfagas | 961–1076 |
| APP-01-R16 | Sin ventana visible ni control activo no hay ninguna escucha (modo «En reposo»); con ventana cerrada y controles activos solo se observan los procesos controlados | 862–892 |
| APP-01-R17 | Al dormir el Mac se liberan todos los motores; al despertar se reconstruyen para las apps que siguen abiertas | 1129, 1139 |
| APP-01-R18 | La pausa manual hace lo mismo que el reposo hasta que el usuario reanuda | 919 |
| APP-01-R19 | Al cerrar la app se liberan los motores y se destruyen los objetos de audio propios; al arrancar se barren los huérfanos | 92, 1078 |

## Brechas

| ID | Brecha | Fecha |
|---|---|---|
| APP-01-B01 | Ningún requisito de esta spec tiene prueba automática: toda la lógica vive en una clase `@MainActor` atada a Core Audio y AppKit | 2026-11-15 |
| APP-01-B02 | La agrupación de procesos (R01, R02) es lógica pura probable, pero está dentro del store | 2026-11-15 |
| APP-01-B03 | R03 lleva el bundle ID escrito a mano; cambiarlo para la tienda rompería esta comprobación | 2026-11-15 |
| APP-01-B04 | R12 modifica todos los perfiles guardados sin confirmación ni forma de deshacer `[POR ACLARAR: ¿la interfaz pide confirmación?]` | 2026-11-15 |
