# Contexto para Claude: rendimiento de RPCS3 PORT FOR PS4

## Objetivo

Investigar y proponer mejoras medibles de rendimiento para RPCS3 PORT FOR PS4, sin sacrificar compatibilidad, estabilidad, audio ni memoria. Este documento es contexto del proyecto y una hoja de ruta; no autoriza a cambiar valores globales o a afirmar ganancias que no se hayan medido en una PS4.

## Resumen del proyecto

- Port experimental de RPCS3 para PS4/PS4 Pro con GoldHEN, compilado con OpenOrbis y llvm-mingw.
- El núcleo y los renderers vienen de RPCS3; el port agrega el frontend PS4/XMB, adaptadores nativos y políticas para los límites de CPU, threads, memoria y VRAM del hardware.
- El código del port se encuentra principalmente en `rpcs3-ps4/rpcs3/ps4_*.cpp`, `rpcs3-ps4/rpcs3/util/ps4_*.hpp`, partes de `rpcs3-ps4/rpcs3/Emu/` y `rpcs3-ps4/ps4-port/`.
- La versión documentada es 0.40. El rendimiento y la compatibilidad dependen mucho del juego y del modelo de consola; el README describe el proyecto como experimental y dice que 0.40 todavía necesita más pruebas en consola.
- La compilación de producción del PKG requiere Windows y varias dependencias específicas. Los GitHub runners pueden comprobar lógica host, pero no representan el rendimiento de una PS4.

## Principio de trabajo

1. Reproducir el problema con el mismo juego, escena, ajustes, consola y estado de caché.
2. Clasificar primero el cuello de botella: PPU/SPU, RSX/GPU emulada, compilación de shaders, sincronización, E/S, audio o presión de memoria/threads.
3. Medir una línea base y varias repeticiones; cambiar una variable cada vez.
4. Añadir o extender una prueba host para la lógica determinista, y probar el comportamiento real en la consola.
5. Mantener el cambio desactivado o limitado por juego hasta que las mediciones muestren una ganancia reproducible sin regresiones.
6. Documentar coste en memoria, latencia, estabilidad y compatibilidad junto al posible aumento de FPS.

No usar promedios de FPS como única métrica. Registrar tiempo de cuadro y dispersión (p50/p95/p99 o histograma), pausas largas, audio, fallos, nivel de memoria y tiempo de carga/compilación.

## Infraestructura existente que conviene reutilizar

- `rpcs3-ps4/rpcs3/ps4_profiler.cpp` y `ps4_profiler.h`: perfilador por muestreo opcional. Se activa mediante archivos de control y tiene límites de alcance porque las señales pueden interrumpir esperas del sistema. El perfilador añade carga: hacer mediciones de FPS primero sin él y usarlo después para localizar el hot path.
- `rpcs3-ps4/rpcs3/Emu/RSX/RSXThread.cpp`: ya escribe líneas `RSX gameplay` con FPS, guest flips, FIFO load y RSX CPU.
- `rpcs3-ps4/rpcs3/util/ps4_rsx_programs.hpp`: contiene telemetría y políticas de compilación RSX; incluye histogramas/percentiles de espera de pipelines y datos de ráfagas de compilación.
- `rpcs3-ps4/rpcs3/util/ps4_memory_governor.hpp`: administra presión de memoria, compilación PPU/SPU/RSX, límites de threads y políticas por niveles. La versión 0.40 deja como predeterminada la política de concurrencia más conservadora de 0.38; las reglas 0.39 se pueden probar mediante opt-in.
- `rpcs3-ps4/rpcs3/util/ps4_mem_budget.hpp` y `ps4_vram_policy.hpp`: políticas de presupuesto de memoria y VRAM.
- `rpcs3-ps4/rpcs3/ps4_launcher.cpp`: telemetría de renderizado de la XMB en reposo/actividad.
- `rpcs3-ps4/rpcs3/Emu/Cell/Modules/cellVdec.cpp`: telemetría del decoder (`VDEC perf`) que puede separar coste de decodificación, pacing y starvation.
- `rpcs3-ps4/ps4-port/TESTAR_NO_PS4.txt`: protocolo extenso de pruebas manuales en consola. Ampliarlo en vez de crear otro flujo incompatible.
- `rpcs3-ps4/ps4-port/tests/`: 48 pruebas host. Algunas relacionadas con rendimiento y recursos:
  - `mem_budget_test.cpp`, `vram_policy_test.cpp`, `safe_mode_test.cpp`
  - `rsx_programs_test.cpp`, `spu_object_cache_test.cpp`, `spu_memory_bound_test.cpp`
  - `thread_priority_test.cpp`, `host_wait_test.cpp`
  - `audio_stream_test.cpp`, `audio_policy_test.cpp`, `lifecycle_test.cpp`
- `.github/workflows/tests.yml` ejecuta las pruebas host en Windows. Estas pruebas verifican lógica/políticas, **no** FPS ni rendimiento de PS4.
- `.github/workflows/build-pkg.yml` ya expone compilación de PKG, parches optativos, opciones CMake validadas, símbolos, resolución de `hot_offsets` y un `tuning_pack`. No duplicar sus responsabilidades sin una razón clara.

## Hoja de ruta propuesta

### P0 — Observabilidad y protocolo de benchmark

**Meta:** que una prueba pueda responder “qué limitó esta escena” y “¿mejoró de verdad?”.

- Definir un protocolo reproducible: escena, duración de calentamiento, ventana medida, caché fría/caliente, renderer, ajustes, temperatura/estado de la consola y número de repeticiones.
- Unificar un informe de sesión con versión/build, Title ID, renderer, perfil efectivo, tiempo de cuadro, FPS, guest flips, carga RSX, compilaciones/esperas de pipelines, nivel máximo de memoria, presión de threads y motivo de salida.
- Incluir pausas largas y percentiles, no solo el promedio. Si no puede calcularse online con coste bajo, guardar histogramas/counters y calcularlos al cerrar la sesión.
- Mantener diagnóstico detallado fuera del camino crítico: buffer preasignado, muestreo espaciado y escritura al final o por intervalos largos. No formatear strings ni hacer I/O por frame.
- Sanitizar identificadores personales en cualquier informe destinado a compartirse. No subir datos de consola a Actions sin un mecanismo explícito y opt-in.
- Añadir al guion de consola una plantilla tabular para la matriz por juego/modelo/renderer/version y comparar la misma escena entre builds.

**Aceptación:** dos ejecuciones repetidas de una misma configuración producen informes completos y no muestran que la propia telemetría cambie materialmente el resultado. Comparar una build de logging mínimo con la de medición.

### P1 — Perfilar y optimizar según el cuello de botella

**PPU/SPU y threads**

- Usar el perfilador existente solo después de detectar una escena limitada por CPU. Identificar funciones calientes y muestras por clase de thread, sin asumir que una prioridad más alta mejora el rendimiento.
- Medir tiempo de ejecución y stalls PPU/SPU, fallos de creación de threads, ocupación de slots y tiempo que los compiladores compiten con el juego.
- Revisar tamaño/orden de bloques SPU y la reutilización del object cache. Medir memoria retenida frente a tiempo de compilación y ejecución; no aumentar workers si el resultado aumenta presión o empeora el gameplay.
- Evaluar políticas alternativas del governor solo como opt-in por título/build, contrastando fps y frametime con memoria, audio, estabilidad y errores de creación de threads.
- No elevar prioridades de threads globalmente sin una traza que demuestre inanición; podría perjudicar audio, RSX, servicios o el sistema.

**RSX, GPU emulada y pipelines**

- Correlacionar `RSX gameplay`, FIFO load/RSX CPU, histogramas de espera y ráfagas de pipelines.
- Separar: coste del guest RSX, coste del driver RADV/Zink, compilación de shaders y bloqueos por sincronización/readback.
- Cuando el límite sea GPU, comparar por título Vulkan/OpenGL, resolución, MSAA y opciones de ZCULL con imágenes de referencia y estabilidad. Resolución menor no ayuda si el límite es PPU/SPU.
- Investigar bloqueos de pipeline y presentaciones solo si la telemetría los muestra. Evitar sincronización asíncrona que cambie el orden visible o las reglas de memoria sin casos de regresión.
- Probar cambios de command-buffer splitting y cachés de shaders con la telemetría ya expuesta; preservar una ruta de reversión.

**Memoria y cargas**

- Correlacionar frame hitches con niveles del memory governor, recortes de caché, budget de VRAM, compilación, VDEC y lectura de disco.
- Revisar si hay asignaciones/liberaciones o bloqueos evitables en loops calientes, pero demostrarlo con muestras y no reemplazar sincronización correcta por heurísticas.
- Medir caché fría y caliente por separado. Mantener límites por recurso y eliminar cachés solo cuando su coste/beneficio esté medido.
- No reducir reservas o aumentar límites para mejorar una prueba corta: validar sesiones largas y reinicios, especialmente los juegos que antes alcanzaban el límite de memoria.

**Audio, vídeo y E/S**

- Usar `VDEC perf` para distinguir decoder lento, cola insuficiente, pacing y starvation antes de cambiar tamaño de buffers.
- Verificar que cualquier mejora de CPU/GPU no introduzca dropouts, deriva A/V ni más latencia de entrada.
- Para streaming desde disco, medir latencias y starvation primero; read-ahead/caché puede consumir memoria y perjudicar a otros subsistemas.

### P2 — Calidad de vida para rendimiento

- Añadir una vista de diagnóstico (no necesariamente siempre visible) que clasifique el cuello de botella y explique qué ajustes podrían ayudar.
- Proponer perfiles por juego “compatibilidad”, “equilibrado” y “prueba”, pero enseñar los valores realmente aplicados y su razón; conservar la elección del jugador.
- Permitir exportar un informe sanitizado y una comparación A/B de dos sesiones del mismo juego.
- Considerar cambios dinámicos únicamente si se estabilizan con histéresis y límites. No hacer que resolución, calidad o threads oscilen frame a frame.
- Mantener toda nueva opción en el catálogo, settings browser y traducciones existentes; no añadir archivos de configuración alternativos que contradigan la tabla de features de `ps4_safe_mode.hpp`.

### P3 — Frame generation / interpolación: evaluación antes de implementar

No asumir que generar un cuadro sintético duplica el rendimiento. Frame generation puede aumentar la fluidez percibida, pero el juego sigue simulando la misma cantidad de cuadros; añade trabajo GPU, memoria y latencia de entrada. En un PS4 con recursos escasos podría reducir los FPS reales.

**Dificultad técnica específica**

- La ruta normal de RPCS3 produce imágenes del RSX emulado mediante los renderers Vulkan/OpenGL. No hay, por lo revisado, un sistema existente del port para obtener vectores de movimiento por objeto y profundidad coherentes con cada cuadro presentado.
- Un algoritmo basado en vectores del juego necesitaría acceder a motion vectors/depth útiles, preservar su correspondencia temporal y modificar o instrumentar shaders/recursos de múltiples juegos. Los juegos de PS3 no garantizan esos datos en un formato común.
- Interpolación óptica de imagen completa es más genérica, pero requiere capturar cuadros y ejecutar flujo óptico/warping. Eso puede costar demasiado en Jaguar/RADV, fallar con HUD/transparencias/partículas y generar ghosting; requiere memoria adicional y buffering.
- Hay que integrar la salida con `VKPresent`/presentación de OpenGL y el pacing del emulador sin cambiar el tiempo del guest. No se debe retrasar innecesariamente la entrada o el audio.
- Frame doubling mediante repetición no es interpolación y no mejora la suavidad temporal real. Tampoco crea cuadros de simulación adicionales.

**Etapas seguras**

1. Medir si los juegos objetivo son CPU-limited o GPU-limited y fijar un caso de prueba breve con movimiento, HUD, transparencias y cámara rápida.
2. Prototipar offline en PC con cuadros capturados legalmente por el usuario para comparar artefactos, sin modificar la ruta PS4.
3. Estimar coste/latencia/memoria en hardware objetivo o en un prototipo GPU muy acotado antes de integrar RPCS3.
4. Si el coste no cabe en el presupuesto, descartar la característica. Si procede, comenzar como experimento explícitamente opt-in, un renderer/plataforma y pocos casos de prueba; incluir desactivación instantánea.
5. Medir FPS nativos, cuadros generados, latencia input-to-photon, frametime, VRAM, memoria flexible y artefactos. No anunciar “60 FPS” sin separar cuadros renderizados de sintetizados.

**Alternativas de menor riesgo:** mejorar pacing/limiter, reducir stutter de pipelines, reducir pausas de compilación, estabilizar audio/vídeo y ajustar el frame pacing de presentación. Estas no crean detalle temporal, pero pueden mejorar la experiencia real con menor coste.

### P4 — Automatización de CI

- Mantener CI host para pruebas deterministas y políticas; la opción manual `test_filter` de `tests.yml` permite ejecutar una selección regex (por ejemplo, `mem_budget_test|rsx_programs_test|safe_mode_test|vram_policy_test`).
- No convertir un microbenchmark host de Windows en predictor de FPS de PS4.
- Si se añade un benchmark host, usarlo solo para comparar funciones deterministas y misma toolchain/runner; reportar ruido y no bloquear merges por variaciones pequeñas.
- Los resultados de consola deben entrar mediante informes versionados y consentidos, no fingiendo que `windows-latest` ejecuta el PKG o imita el hardware.

## Reglas para cualquier implementación propuesta

- Antes de editar, inspeccionar callers y ciclo de vida; reutilizar políticas/helpers existentes.
- No cambiar defaults globales de rendimiento sin resultados repetibles en varios títulos.
- Cada cambio que altere temporización, orden de threads, sincronización, audio o memoria debe tener kill switch/safe-mode apropiado y prueba de regresión.
- Mantener los tests host relevantes y añadir pruebas de límites/percentiles cuando se cambien policies.
- No incorporar código de generación/interpolación de frames, algoritmos de terceros o dependencias grandes sin prototipo medible, licencia verificada y presupuesto de CPU/GPU/memoria.
- Reportar: archivos tocados, hipótesis, medición antes/después, limitaciones, juegos probados y efectos secundarios; si no hubo PS4, decirlo claramente.

## Primera tarea recomendada para Claude

No empezar con frame generation ni con cambios de prioridad. Primero:

1. Leer las rutas de telemetría y tests mencionadas en este documento.
2. Proponer un formato compacto y de bajo overhead para el informe por sesión, reutilizando counters existentes.
3. Indicar qué datos ya se registran y qué dato falta para distinguir CPU, RSX, compilación, sincronización y presión de recursos.
4. Si implementa algo, limitar la primera entrega a telemetría/formatos/tests host y una extensión del guion manual. No cambiar el comportamiento del emulador ni los defaults.
5. Proponer un protocolo A/B de consola con métricas y criterio explícito de regresión antes de optimizar el hot path.
