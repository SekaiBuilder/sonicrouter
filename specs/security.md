# Seguridad y privacidad

El modelo vigente está en [`SECURITY.md`](../SECURITY.md) (invariantes INV-1 a
INV-4). Esta spec no lo duplica: recoge su estado de comprobación y lo que
cambia con la tienda.

## Estado de los invariantes

| Invariante | Evidencia hoy |
|---|---|
| INV-1 El audio no va a disco ni a red | Código leído: el IOProc solo escribe en los búferes de salida; no hay `URLSession`, sockets ni escritura de archivos de audio en `Sources/`. Sin prueba automática |
| INV-2 El sondeo del permiso no afecta al audio | Código leído (`AudioProcessTap.swift:256`) |
| INV-3 Objetos propios con prefijo y destruidos al iniciar y cerrar | Código leído. La limpieza de taps compara el **nombre** (`sonicrouter…`), no un UID |
| INV-4 «Restaurar todo» devuelve el audio a su estado nativo | Código leído |

## Superficie

| Elemento | Hoy |
|---|---|
| Permiso TCC de captura de audio del sistema | Único privilegio sensible |
| App Sandbox | **No**. `SECURITY.md` §5 afirma que los taps lo impiden; no hay prueba que lo respalde y un mezclador público con sandbox usa taps (ver [docs/APP_STORE_MIGRATION.md](../docs/APP_STORE_MIGRATION.md)) |
| Hardened Runtime | Solo cuando se firma con identidad real |
| Red | Ninguna |
| Archivos | Solo los que el usuario elige en paneles de importar y exportar; límite de 5 MB y 1.000 entradas |
| Atajos | Carbon, sin Accesibilidad ni Monitorización de entrada |
| Registro (`Logger`) | Nombres de app y PID con privacidad `.public` en `AudioProcessTap.swift:742`, `:890` |

## Requisitos objetivo

| ID | Requisito | Estado |
|---|---|---|
| SEG-01-R01 | La versión de tienda corre con App Sandbox y solo los entitlements que use | Depende de CAM-002 |
| SEG-01-R02 | `SECURITY.md` §5 se corrige con el resultado de CAM-002, sea cual sea | Pendiente |
| SEG-01-R03 | Manifiesto de privacidad (`PrivacyInfo.xcprivacy`) declarando el uso de `UserDefaults` y ningún dato recogido | **Hecho 2026-11-18**: `Config/PrivacyInfo.xcprivacy` (sin rastreo, sin datos recogidos, `UserDefaults` con CA92.1; es la única API de razón obligatoria hallada en `Sources/`), copiado por `Scripts/build-app.sh` y comprobado por `Scripts/verify-app.sh`. Sin validar por App Store Connect |
| SEG-01-R04 | Ningún secreto ni dato de cuenta en el repositorio; la firma se configura en un archivo ignorado por git | Pendiente |
| SEG-01-R05 | Una prueba automática falla si `Sources/` importa `Network` o usa `URLSession`, o si el módulo de audio escribe archivos | **Hecho 2026-11-18**: `Scripts/check-security.sh` (búsqueda estática de red en todo `Sources/` y de escritura de archivos o grabación en `SonicRouterDSP`, `SonicRouterCore`, `AudioProcessTap`, `CoreAudio*`, `AudioDevice*`). Su `--selftest` demuestra que detecta 6 tipos de infracción. Es textual: no ve código generado ni llamadas indirectas |

## Brechas

| ID | Brecha | Fecha |
|---|---|---|
| SEG-01-B01 | La limpieza por nombre (INV-3) borraría un tap ajeno cuyo nombre empiece por «sonicrouter» | 2026-11-15 |
| SEG-01-B02 | El log publica nombres de apps en uso; para la tienda conviene `.private` | 2026-11-15 |
| SEG-01-B03 | La app cambia la frecuencia de muestreo del hardware y la salida del sistema sin que `SECURITY.md` lo mencione | 2026-11-15 |
