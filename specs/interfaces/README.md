# Contratos

Lo que ningún cambio puede romper sin migración. Estado: *actual, código leído*.

| ID | Contrato | Fuente |
|---|---|---|
| CTR-01 | **Tiempo real.** Dentro del IOProc no se reserva memoria, no se toman locks, no se escribe en el log ni se llama a Objective-C. Los parámetros entran por atómicos; el estado se reserva al crear el motor | `CONTRIBUTING.md`, `AudioProcessTap.swift:199` |
| CTR-02 | **Audio efímero.** El audio capturado solo vive en los búferes de un ciclo; nunca va a disco, log ni red (INV-1) | `SECURITY.md` |
| CTR-03 | **Nombres propios.** Taps con nombre que empieza por `SonicRouter`; agregados temporales con UID `local.sonicrouter.agg.*`. El dispositivo multi-salida (`local.sonicrouter.multioutput`) queda fuera de ese prefijo a propósito para que la limpieza no lo borre | `AudioProcessTap.swift:93`, `MultiOutputPlan.swift:28` |
| CTR-04 | **Fallo seguro.** Una activación incompleta destruye lo creado; un motor de mute en uso no se suelta hasta que su reemplazo ha arrancado | `CONTRIBUTING.md` |
| CTR-05 | **Formato de perfiles v1.** `format = local.sonicrouter.profiles`, `version = 1`; se acepta también una lista simple. Los campos nuevos son opcionales | `ProfileArchive.swift` |
| CTR-06 | **Claves de preferencias.** `SonicRouter.RouteProfiles`, `SonicRouter.VolumeCompensation.v5`, `SonicRouter.GlobalShortcuts`, `SonicRouter.StartInMenuBar`, `SonicRouter.Language`, `SonicRouter.LastScreen` | `ApplicationAudioStore.swift:46`, `Models.swift:25`, `Localization.swift:38`, `ContentView.swift:165` |
| CTR-07 | **Tres idiomas.** Todo texto de interfaz va en es, en y ja | `L10n.t` en todo el código |
| CTR-08 | **Núcleo sin sistema.** `SonicRouterCore` no importa Core Audio ni AppKit | `Package.swift` |

## Migraciones que estos contratos exigirán

- Cambiar el bundle ID o activar App Sandbox mueve el dominio de `UserDefaults`:
  CTR-06 exige copiar las preferencias en el primer arranque.
- CTR-05: el identificador de formato se conserva aunque cambie el bundle ID.
