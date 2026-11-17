# Decisiones

## Registradas

| ID | Decisión | Motivo | Fuente |
|---|---|---|---|
| DEC-001 | Solo taps de proceso de Core Audio; sin drivers, servicios privilegiados ni dispositivos virtuales permanentes | Sin instalación ni permisos de administrador | `docs/AudioEngineRoadmap.md` |
| DEC-002 | Al 100 % en la salida predeterminada no hay tap | La ruta nativa es la única garantía de sonido intacto | `ApplicationAudioStore.swift:655` |
| DEC-003 | Las llamadas nunca se re-emiten | El cancelador de eco de la app deja de reconocer su propio audio | `ApplicationAudioStore.swift:742` |
| DEC-004 | Deslizador de volumen lineal | La curva perceptual hacía que el 99 % sonara demasiado bajo | `AudioProcessTap.swift:185` |
| DEC-005 | Pruebas como ejecutable | Las Command Line Tools no traen XCTest ni Testing | `Package.swift` |
| DEC-006 | El sonido que SonicRouter re-emite debe ser el original: sin mezcla, sin remuestreo y sin dinámica añadida, salvo la ganancia y el ecualizador que el usuario pida | Petición del titular, 2026-11-15 | [CAM-001](../changes/CAM-001-reemision-transparente.md) |

## Abiertas

| ID | Pregunta | Depende de |
|---|---|---|
| DEC-101 | ¿Hay versión para Mac App Store? | Prueba mínima con App Sandbox en un Mac real |
| DEC-102 | ¿Sigue siendo Intel un requisito? | Decisión del titular |
| DEC-103 | ¿Algún componente pasa a Rust o C++? | Mediciones de referencia; hoy no hay ningún problema medido que lo pida |
| DEC-104 | Bundle ID definitivo y migración de preferencias desde `local.sonicrouter.app` | Cuenta de desarrollador |
| DEC-105 | Con ruta a otro dispositivo el remuestreo es inevitable: ¿se avisa en la interfaz de que esa ruta no es bit a bit? | Titular, tras CAM-001 |
