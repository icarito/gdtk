# SPEC — Paso 11b: HUD de debug con todos los contadores, y perfilado remoto sin dibujar en el dispositivo

Continúa `SPEC-hud.md` (ya implementado: `addons/debug_hud/`, `DebugLog`, widget mini, HUD con F1,
comandos). Pedido del usuario: incluir **draw calls y los conteos relevantes**, y que en el perfil de
gama baja plano **no se dibuje en el dispositivo pero sí llegue al control remoto** para perfilarlo.
Leer antes: `addons/debug_hud/*`, `modules/imgui/` (`DebugLog`), `shell/remote.gd`, `mcp/gdtk_mcp.py`,
`tests/`.

## Reglas

- Repo `/run/media/icarito/DATA/icarito/Proyectos/gdtk`. Motor: árbol **`godot-dev`** con caché
  (`export SCONS_CACHE=$HOME/.cache/scons-godot3 SCONS_CACHE_LIMIT=30000`; build del README), sólo si
  tocás C++. `git add` por nombre (archivo ajeno sin trackear en `shell/`). Sin push. **No modificar
  Odisea** (`/home/icarito/Proyectos/Odisea_Game/src`, sólo lectura). No `pkill -f`/`pgrep -f` con
  patrones de tu propia línea de comando (usar `pgrep -a`).

## 1. Contadores

Además de lo que ya muestra el HUD, todos estos `Performance` (verificar que existan en 3.6;
omitir los que no):
- Render: `RENDER_DRAW_CALLS_IN_FRAME`, `RENDER_2D_DRAW_CALLS_IN_FRAME`, `RENDER_OBJECTS_IN_FRAME`,
  `RENDER_VERTICES_IN_FRAME`, `RENDER_MATERIAL_CHANGES_IN_FRAME`, `RENDER_SHADER_CHANGES_IN_FRAME`,
  `RENDER_SURFACE_CHANGES_IN_FRAME`, `RENDER_2D_ITEMS_IN_FRAME`, `RENDER_VIDEO_MEM_USED`,
  `RENDER_TEXTURE_MEM_USED`, `RENDER_VERTEX_MEM_USED`.
- Objetos: `OBJECT_COUNT`, `OBJECT_RESOURCE_COUNT`, `OBJECT_NODE_COUNT`, `OBJECT_ORPHAN_NODE_COUNT`.
- Tiempo/memoria/física/audio: `TIME_FPS`, `TIME_PROCESS`, `TIME_PHYSICS_PROCESS`, `MEMORY_STATIC`,
  `MEMORY_DYNAMIC`, `MEMORY_STATIC_MAX`, `PHYSICS_3D_ACTIVE_OBJECTS`, `PHYSICS_3D_COLLISION_PAIRS`,
  `PHYSICS_3D_ISLAND_COUNT`, `AUDIO_OUTPUT_LATENCY`.
- **GPU y tramos de CPU del fork**: con `FRT_PERF` definido, el motor imprime `[FRT_GPU] gpu=<ms>ms …`
  y resúmenes `FRT_PERF` cada 120 frames (ver `patches/zzzzzz_frt_gpu_timer.patch` y
  `patches/zzzzz_frt_frame_profiler.patch` en `/home/icarito/Proyectos/godot3-box3d/godot-box3d-3`).
  Parsear esas líneas desde `DebugLog` y mostrarlas como series (GPU ms y los tramos de CPU que traiga
  el resumen). Sin `FRT_PERF`, ocultarlas.
En el HUD: pestaña **Gráficas** con grupos colapsables (Frame, Render, Memoria, Objetos, Física, GPU)
y un plot por grupo; pestaña **Monitores** con todos los valores actuales + mín/máx/media de la
ventana. En el widget mini agregar draw calls y vértices en una línea chica.

## 2. Separar datos de vista

- `addons/debug_hud/debug_metrics.gd` (`DebugMetrics`): colector. Muestrea los monitores cada frame (o a
  `sample_hz` configurable) en buffers circulares (600 muestras), mantiene el cursor de `DebugLog`, y
  expone `snapshot(since_frame: int = -1) -> Dictionary` compacto: `{frame, time, series: {nombre:
  [valores nuevos desde since_frame]}, latest: {nombre: valor}, logs: [entradas nuevas], profile:
  {tier, flat, driver, gpu, …}}`. Sin ImGui: corre aunque el módulo imgui no esté.
- `DebugHud` (vista ImGui) dibuja desde un `DebugMetrics` **local** o desde snapshots **remotos**
  (`apply_snapshot(dict)` que alimenta un `DebugMetrics` "espejo" con los mismos buffers).
- Política: `DebugHud.render_local: bool`. Con `false` el dispositivo **no crea el `ImGuiCanvas`** ni
  procesa la vista (costo = sólo el colector), pero el colector sigue. Fuente de la política:
  `ProjectSettings` `debug_hud/render_local` (default true) + env `GDTK_HUD_LOCAL=0|1` (gana el env) +
  un hook `DebugHud.render_local_resolver` (objeto+método) para que el proyecto decida. Documentar el
  mapeo para Odisea en el README del addon:
  `render_local = not (GLES3VendorGate.is_low_tier() and GLES3VendorGate.is_flat_mode())`, y que el
  host del control remoto de Odisea sólo corre en gama baja con `allow_low_tier_offload`
  (`core_v2/net/RemoteControlManager.gd`) y que su HUD del teléfono (`core_v2/ui/hud/RemoteHudBackend.gd`)
  consume `widget_snapshot()` — el snapshot de `DebugMetrics` encaja ahí como una pantalla más.

## 3. Transporte en gdtk (control remoto) y visor remoto

- `shell/remote.gd`: métodos `hud_snapshot {since_frame}` → `DebugMetrics.snapshot()`, y
  `hud_command {line}` → ejecuta un comando de la consola del HUD y devuelve su salida (en builds no
  debug, sólo los comandos incluidos no peligrosos: `help`, `fps`, `vsync`, `timescale`; nunca `eval`).
- `mcp/gdtk_mcp.py`: tools `gdtk_metrics` (texto: tabla de `latest` + resumen mín/máx/media de las
  series) y `gdtk_console` (`hud_command`).
- **Visor remoto**: `DebugHud.remote_source = "host:puerto"` (+ token por la misma vía que usa
  `mcp/gdtk_mcp.py`: archivo de token local; para una máquina remota, túnel ssh — documentarlo) hace
  poll de `hud_snapshot` a 4 Hz y dibuja con `render_local = true` en ESA máquina. Una actividad
  **"Perfil remoto"** en el shell que pide `host:puerto` y abre el HUD completo en modo visor.

## 4. Verificación (obligatoria)

1. Dos instancias locales (cage anidado cada una, puertos distintos, tokens por puerto):
   - "dispositivo": `GDTK_HUD_LOCAL=0`, abre Gears. Verificar que no hay `ImGuiCanvas` del HUD (log o
     `hud_snapshot.profile`) y medir el costo del colector (µs/frame, promedio 600 frames, con
     `OS.get_ticks_usec` alrededor del muestreo).
   - "visor": abre "Perfil remoto" apuntando al dispositivo → screenshot `hud-remote.png` con las curvas
     del dispositivo (FPS, draw calls, vértices) y su log.
2. `FRT_PERF=1` en el dispositivo → las series GPU/CPU aparecen en el visor (`hud-remote-gpu.png`).
3. `gdtk_metrics` por MCP devuelve la tabla (pegar un extracto en el reporte).
4. `./run_shell.sh`, `./run_compositor.sh`, `tests/control_test.sh` pasan.
Leer los PNG y describirlos.

## Entregable

- Commit `feat(debug_hud): todos los contadores (+GPU/CPU de FRT_PERF), colector separado y perfilado remoto`
  terminado en `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`.
- Reporte breve: costo del colector por frame, tamaño típico de un snapshot (bytes) a 4 Hz, qué muestran
  los PNG, desvíos y errores literales. No modificar README.md ni SPEC*.md.
