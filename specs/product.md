# Producto

Fuentes: `README.md`, `SECURITY.md`, código. Estado: *actual* salvo la sección
de objetivos.

## Qué es

Mezclador de audio por aplicación para macOS 15 o superior. Permite silenciar,
bajar el volumen, ecualizar y enviar a una salida concreta cada app por
separado, desde una ventana o desde la barra de menús. Código abierto (MIT).

## Para quién

`[POR ACLARAR: público objetivo y posicionamiento frente a otros mezcladores]`.
El README describe un caso: estar en una llamada y querer silenciarla un
momento para oír otra cosa.

## Qué hace hoy (se conserva todo)

| Función | Spec |
|---|---|
| Mute, volumen, salida y ecualizador de tres bandas por app | [AUD-01](features/audio-engine.md) |
| Detección y agrupación de apps con audio, silenciar todo, silenciar las demás, restaurar todo, modos de energía, reposo | [APP-01](features/app-sessions.md) |
| Perfiles persistentes por app, exportar e importar | [PRF-01](features/profiles.md) |
| Permiso de captura, atajos globales, inicio de sesión, modo barra de menús, idiomas es/en/ja | [SIS-01](features/system-integration.md) |
| Dispositivos: salida y entrada predeterminadas, volumen, dispositivo multi-salida | Pendiente de spec |
| Ventana, barra de menús, ajustes, comandos | Pendiente de spec |

## Principios

- El audio capturado no se guarda ni se transmite (INV-1 de `SECURITY.md`).
- Todo objeto de audio creado se destruye al cerrar y al arrancar (INV-3, INV-4).
- Sin drivers ni permisos de administrador ([DEC-001](decisions/README.md)).
- El sonido re-emitido debe ser el original ([DEC-006](decisions/README.md)).
- Consumo mínimo en segundo plano: sin sondeo.

## Objetivos (no implementados)

| Objetivo | Dónde |
|---|---|
| Re-emisión sin alteración del sonido | [CAM-001](changes/CAM-001-reemision-transparente.md) |
| Saber si la app puede vivir en App Sandbox | [CAM-002](changes/CAM-002-prueba-app-sandbox.md) |
| Publicación en Mac App Store y canal directo firmado | [docs/APP_STORE_MIGRATION.md](../docs/APP_STORE_MIGRATION.md) |

## Negocio

Precio, modelo (gratis, pago o compra dentro de la app) y titular legal de la
ficha: **decisión pendiente** del titular. No hay nada decidido en el repo.
