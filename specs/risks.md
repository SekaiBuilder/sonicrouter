# Registro de riesgos

Fecha: 2026-11-15. Probabilidad e impacto: alta, media, baja.

| ID | Riesgo | Prob. | Impacto | Respuesta |
|---|---|---|---|---|
| RIE-01 | Alguna función esencial no funciona con App Sandbox | Baja | Alto | CAM-002 antes de invertir en la tienda; canal directo como alternativa |
| RIE-02 | App Review rechaza una app que captura audio de otras | Media | Alto | Notas de revisión claras, sin red, precedente público; no depende de nosotros |
| RIE-03 | Sin compensación de deriva aparecen clics (CAM-001) | Media | Alto | Prueba de residuo y sesión larga por tipo de dispositivo; mantener la deriva donde haga falta |
| RIE-04 | Apple cambia el comportamiento de los taps en una versión de macOS | Media | Alto | Comprobación de formato (CAM-001-R05), registro de formatos ya existente, recorrido manual en cada versión mayor |
| RIE-05 | Regresiones al tocar el motor sin pruebas | Alta | Alto | Mover la copia de audio al núcleo y cubrirla antes de cambiarla |
| RIE-06 | El usuario pierde ajustes al pasar a la versión con sandbox | Alta | Medio | Migración de preferencias en el primer arranque: `Config/container-migration.plist` (lo lee macOS con sandbox) y `PreferenceMigration` si cambia el bundle ID; probada con dominios falsos, sin probar con sandbox (CAM-002-A16) |
| RIE-07 | La app se cae con controles activos y deja audio silenciado | Baja | Alto | El sistema destruye los taps al morir el proceso `[POR ACLARAR: comprobar con kill -9]`; limpieza al arrancar |
| RIE-08 | Reservas ocultas en el callback provocan cortes bajo carga | Baja (desde CAM-003) | Medio | IOProc en C sin Swift (CAM-003); falta medir en Mac real (AUD-01-B02) |
| RIE-09 | Cambiar la frecuencia del hardware o la salida del sistema molesta al usuario o a la revisión | Media | Medio | CAM-001 lo elimina en el caso común; documentar el resto |
| RIE-10 | Mantener Intel sin un Mac Intel donde probar | Alta | Bajo | Decidir DEC-102 |
| RIE-11 | Las specs se quedan atrás del código | Media | Medio | Spec en el mismo commit; `sdd-deriva.py --estricto` en `Scripts/ci.sh` y en la CI de GitHub (escrita 2026-11-18, sin ejecutar allí) |
| RIE-12 | Trabajo sin guardar en `feature/native-multi-output` (5 archivos) | — | Alto | Guardarlo antes de cualquier cambio de código |
| RIE-13 | Dos canales divergen | Baja | Medio | Un solo código; diferencias tras condición de compilación |
| RIE-14 | Un error de memoria en el núcleo C++ (CAM-003) que Swift no atraparía | Baja | Alto | Interfaz C pequeña, sin punteros guardados, ASan + UBSan en las pruebas, oráculo Swift bit a bit |
| RIE-15 | ~~El paquete universal no se construye~~ (`lipo` fallaba en `Scripts/build-app.sh`). Cerrado el 2026-11-18: el script copia cada arquitectura aparte | — | — | Comprobado con `lipo -info` |
