# Evaluación Swift / Rust / C++

Estado: **preliminar**, hecha con código leído y sin mediciones
([DEC-103](README.md) sigue abierta). Regla: un componente solo cambia de
lenguaje si hay un problema medido, Swift no lo resuelve y un prototipo lo
demuestra con el mismo arnés ([performance.md](../performance.md)).

## Matriz

| Componente | Hoy | Propuesto | Beneficio esperado | Coste y riesgo | Decisión |
|---|---|---|---|---|---|
| Interfaz, ciclo de vida, permisos, menús | Swift / SwiftUI | Swift | — | — | Swift |
| Clientes Core Audio (objetos, escuchas, taps, agregados) | Swift | Swift | Rust o C++ no aportan: todo son llamadas a una API de C de Apple | Capa de puente sin lógica propia | Swift |
| Estado y política de control | Swift | Swift | La seguridad de memoria ya la da Swift 6 con concurrencia estricta | — | Swift |
| Perfiles: formato, validación, fusión | Swift (`Codable`) | Swift | Rust solo compensaría si hubiera otra plataforma; no la hay | Segunda cadena de compilación para 150 líneas | Swift |
| Copia con ganancia | Swift + vDSP | Swift + vDSP | vDSP ya es código vectorial de Apple | — | Swift |
| Copia a varios dispositivos (muestra a muestra) | Swift escalar | Swift + vDSP por canal | Vectorizar sin cambiar de lenguaje | Bajo | Swift; optimizar solo si la medición lo pide |
| Ecualizador de tres bandas | Swift, punteros crudos, `Double` | Swift; `vDSP_biquad` si hiciera falta | 3 biquads por canal es una carga mínima | — | Swift |
| Ecualizador de muchas bandas, o efectos nuevos (futuro) | No existe | Candidato a C++ **si** se adopta una biblioteca DSP existente | Reutilizar código probado | Interop, firma, mantenimiento; hoy no hay necesidad | Aplazado |
| Limitador | Swift | Swift | — | — | Swift |

## Por qué no hoy

- No hay ningún problema de rendimiento medido. Lo que el titular percibe como
  pérdida de calidad viene de cómo se configura Core Audio (mezcla y
  remuestreo), no del lenguaje: lo resuelve [CAM-001](../changes/CAM-001-reemision-transparente.md).
- El riesgo real de tiempo real en Swift es el tráfico de referencias y las
  reservas ocultas en el callback (AUD-01-B02). Se mide y, si aparece, se
  corrige en Swift pasando al callback solo punteros no gestionados.
- Un segundo lenguaje añade cadena de compilación, binarios universales,
  firma de bibliotecas y CI para un proyecto de una sola persona.

## Si algún día se migra un componente

| Punto | Criterio |
|---|---|
| Frontera | C++: interoperabilidad directa de Swift con C++ o cabecera C. Rust: ABI de C con `cbindgen`; UniFFI solo fuera del camino de audio |
| Memoria | El lado Swift reserva y libera; el callback recibe punteros y tamaños, sin copias |
| Hilos | Sin locks ni reservas en el callback; parámetros por atómicos, como hoy |
| Empaquetado | Biblioteca estática enlazada en el ejecutable: nada que firmar aparte y compatible con sandbox |
| Arquitecturas | Las mismas que la app ([DEC-102](README.md)) |
| Prueba | Mismas pruebas de respuesta y de bit a bit contra la implementación Swift |

## Herramientas en este Mac

`rustc` y `cargo` instalados (Homebrew). `cmake` no. No se ha instalado nada.
