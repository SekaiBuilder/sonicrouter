# CAM-002 — Prueba mínima con App Sandbox

Estado: **propuesta, sin ejecutar**. Fecha: 2026-11-15.
Resuelve: [DEC-101](../decisions/README.md). No cambia el comportamiento de la app.

## Objetivo

Saber, con evidencia de un Mac real, qué funciones de SonicRouter funcionan
dentro de App Sandbox, antes de diseñar nada para la tienda.

## Punto de partida

- `SECURITY.md` §5 afirma que los taps impiden el sandbox. Sin prueba.
- Un mezclador público por app, con taps de proceso y dispositivo agregado,
  declara `com.apple.security.app-sandbox` y
  `com.apple.security.device.audio-input` en su archivo de entitlements
  (`pantafive/fader`, `Fader/Resources/Fader.entitlements`, leído el
  2026-11-15) y se anuncia como distribuido en la Mac App Store. Eso hace
  probable la compatibilidad; no la demuestra para SonicRouter.

## Método

Firmar la app actual, sin cambiar código, con
[`Config/SonicRouter-MAS.entitlements`](../../Config/SonicRouter-MAS.entitlements)
(firma ad hoc; no hace falta cuenta de desarrollador) y recorrer la tabla.

```bash
SONICROUTER_UNIVERSAL=0 Scripts/build-app.sh
codesign --force --options runtime --sign - --entitlements Config/SonicRouter-MAS.entitlements build/SonicRouter.app
```

`[POR ACLARAR: una firma ad hoc cambia de identidad en cada compilación y TCC
puede volver a pedir el permiso; si estorba, usar un certificado de desarrollo
local]`

## Casos

| ID | Función | Se da por bueno si |
|---|---|---|
| CAM-002-A01 | Diálogo de captura de audio | Aparece y, concedido, el sondeo devuelve verdadero |
| CAM-002-A02 | Lista de procesos con audio y sus bundle ID | La lista coincide con la versión sin sandbox |
| CAM-002-A03 | Mute de una app | Se silencia y vuelve |
| CAM-002-A04 | Volumen al 50 % en la salida predeterminada | Suena atenuado, sin doble audio |
| CAM-002-A05 | Ruta a otro dispositivo | Suena solo en el elegido |
| CAM-002-A06 | Ecualizador | Se oye el cambio |
| CAM-002-A07 | Nombres e iconos de apps (lee bundles ajenos) | Se muestran |
| CAM-002-A08 | Llamada de FaceTime (procesos del sistema) | Aparece la fila y se puede silenciar |
| CAM-002-A09 | Cambiar salida y entrada predeterminadas y su volumen | Cambian |
| CAM-002-A10 | Dispositivo multi-salida | Se crea, suena en ambos y se elimina |
| CAM-002-A11 | Cambio de frecuencia de muestreo del hardware | Se aplica o falla sin romper el motor |
| CAM-002-A12 | Atajos globales con la app en la barra de menús | Funcionan |
| CAM-002-A13 | Abrir al iniciar sesión | Se registra y arranca tras reiniciar sesión |
| CAM-002-A14 | Exportar e importar perfiles | Los paneles guardan y leen |
| CAM-002-A15 | Abrir el panel de Privacidad | Se abre |
| CAM-002-A16 | Preferencias | Se guardan en el contenedor; anotar que las anteriores no se ven |
| CAM-002-A17 | Limpieza al arrancar tras `kill -9` | No quedan taps ni agregados propios |
| CAM-002-A18 | Reposo y despertar | Los controles vuelven |

Para cada fallo: mensaje de la consola (`log stream --predicate 'sender == "sandboxd"'`),
código de Core Audio y si un entitlement adicional lo arregla.

## Resultado esperado

La matriz de [docs/APP_STORE_MIGRATION.md](../../docs/APP_STORE_MIGRATION.md)
con cada fila en «comprobado» o «incompatible demostrado», y DEC-101 cerrada.

## Tareas

| # | Tarea | Necesita al titular |
|---|---|---|
| T1 | Borrador de entitlements | Hecho (sin verificar) |
| T2 | Compilar, firmar y recorrer A01–A18 | Sí: Mac delante, aceptar permisos, escuchar |
| T3 | Volcar resultados en la matriz y corregir `SECURITY.md` §5 | No |

## Evidencia

Ninguna todavía.
