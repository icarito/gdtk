# SPEC — Paso 11: arreglos del paso 10, módulo más liviano, HUD de debug y benchmark vs controles Godot

Leer antes: `modules/imgui/*` (API del paso 10), `shell/activities/panel.gd`, `shell/shell.gd`,
`shell/remote.gd`, `tests/`.

## Reglas

- Repo `/run/media/icarito/DATA/icarito/Proyectos/gdtk`. Motor: árbol **`godot-dev`**. `git add` por
  nombre (archivo ajeno sin trackear en `shell/`). Sin push. No `pkill -f`/`pgrep -f` con patrones de
  tu propia línea de comando (te matan el shell): usar `pgrep -a <nombre>` y filtrar.
- Build con caché:
  ```sh
  export SCONS_CACHE=$HOME/.cache/scons-godot3 SCONS_CACHE_LIMIT=30000
  cd /home/icarito/Proyectos/godot3-box3d/godot-dev
  scons -j8 platform=frt arch=x86_64 target=release_debug tools=yes frt_desktop_gl=yes production=yes lto=none use_static_cpp=no progress=no extra_suffix=gdtk custom_modules=/home/icarito/Proyectos/godot3-box3d/godot-box3d-3,/run/media/icarito/DATA/icarito/Proyectos/gdtk/modules
  ```

## A. Arreglos del paso 10 (vistos en `panel.png` / `panel-pie-open.png`)

1. **Superficie de ImPlot3D corrupta** (bandas/franjas): ImGui usa `ImDrawIdx` de 16 bits y el backend no
   maneja `VtxOffset`, así que drawlists de más de 65535 vértices se rompen. `#define ImDrawIdx unsigned int`
   en `modules/imgui/thirdparty/imgui/imconfig.h` (el renderer ya convierte índices a `int`; verificar).
2. **Curvas de FPS/frame time invisibles** en la pestaña ImPlot del Panel: el área de datos queda sin
   altura (se ven ejes y etiquetas, no la línea). Dar alto suficiente a cada plot (p.ej. ≥ 160 px o
   repartir `get_content_region_avail().y`), `IMPLOT_AXIS_AUTOFIT` en Y o límites razonables, y verificar
   en el PNG que la curva se ve.
3. **Menú radial**: aparecen líneas finas cruzando el anillo (efecto estrella). Dibujar cada sector como
   polígono convexo relleno (`PathArcTo` exterior + interior invertido + `PathFillConvex`) y los bordes
   con `PathStroke` cerrados por sector, sin trazos entre sectores.

## B. Módulo más liviano (medido hoy: 4,4 MB de código x86_64 -O2)

Hoy: core ImGui 688 KB, imgui_demo 242, ImPlot 1922, implot_demo 73, ImPlot3D 1157, implot3d_demo 58,
bindings 263. ImPlot pesa por instanciar sus plantillas para 10 tipos numéricos.
1. `IMPLOT_CUSTOM_NUMERIC_TYPES="(float)(double)"` (los bindings sólo pasan `PoolRealArray`→float) y el
   equivalente de ImPlot3D si existe (buscar `IMPLOT3D_CUSTOM_NUMERIC_TYPES` o similar en sus fuentes).
2. Opciones del módulo en `modules/imgui/config.py` (`get_opts`): `imgui_implot=yes`, `imgui_implot3d=yes`,
   `imgui_demos=auto` (auto = sólo si `tools=yes`). Con una opción en `no` no se compilan sus fuentes y sus
   métodos no se bindean (`#ifdef` en el C++). La API y el Panel deben tolerar la ausencia
   (`ClassDB.class_has_method` o un método `has_feature("implot")`).
3. Medir y reportar `size -t` de los `.o` por componente **antes y después**, y el total para tres
   perfiles: completo, sin demos, sólo core (implot/implot3d en `no`).

## C. HUD de debug reutilizable: `addons/debug_hud/` (+ captura de logs en C++)

Pensado para que Odisea (u otro proyecto) lo agregue como autoload cuando el módulo `imgui` esté en su
binario. Costo cero cuando está oculto.

1. **Captura de logs (C++)**: clase `DebugLog` (singleton de Engine, `Object`) en `modules/imgui/`:
   un `Logger` propio registrado en `register_types` con `OS::add_logger`. `add_logger` es `protected`:
   usar un puntero a miembro vía subclase auxiliar (`struct OSAccess : OS { using OS::add_logger; };`
   `auto pm = &OSAccess::add_logger; (OS::get_singleton()->*pm)(logger);`) — sin parchear el motor.
   Buffer circular de 2000 entradas con `Mutex` (los logs llegan desde otros hilos), cada entrada
   `{id, time_ms, text, is_error}` (errores de `log_error` con función/archivo/línea). API:
   `DebugLog.get_entries(since_id: int) -> Array` (dicts), `DebugLog.clear()`, `DebugLog.last_id()`.
   El `Logger` no debe desregistrarse a mano (lo libera `OS`); no loguear desde dentro de `logv`.
2. **Widget mini** (siempre visible, esquina configurable, ~180×56 px × escala): FPS grande con color
   (verde ≥ 55, amarillo ≥ 30, rojo < 30), sparkline de frame time de los últimos 120 frames (ImPlot sin
   ejes ni decoraciones, o `plot_lines` nativo si `implot` está deshabilitado), memoria estática en MB.
   Clic/toque en el widget abre/cierra el HUD completo.
3. **HUD completo** (overlay semitransparente sobre el juego, tecla **F1** o **`** para abrir/cerrar;
   en táctil, toque en el widget mini):
   - Pestaña **Gráficas**: ImPlot con FPS y frame time (ventana de 10 s), memoria estática/dinámica,
     objetos/nodos/huérfanos, draw calls y objetos en el frame (`Performance.RENDER_*`), física.
   - Pestaña **Consola**: log de `DebugLog` (errores en rojo, filtro de texto, autoscroll, botón
     limpiar) y línea de comando (`input_text_enter`, historial con flechas arriba/abajo).
   - Pestaña **Monitores**: tabla con todos los `Performance.*` y su valor.
4. **Comandos**: `DebugHud.register_command(name, target: Object, method: String, help: String)`.
   Incluidos: `help`, `clear`, `fps <n>` (`Engine.target_fps`, 0 = sin límite), `timescale <x>`,
   `vsync on|off`, `quit`, y `eval <expresión>` con la clase `Expression` sobre la escena actual —
   **sólo si `OS.is_debug_build()`** (en release no se registra).
5. **Costo**: con el HUD cerrado sólo corre el widget mini; con `DebugHud.enabled = false` nada (el
   `ImGuiCanvas` no procesa ni tiene canvas items). Documentar en `addons/debug_hud/README.md` cómo
   agregarlo como autoload, la API y los comandos.
6. **Integración en gdtk**: el shell lo carga como overlay global (F1 en cualquier actividad).

## D. Benchmark ImGui vs controles de Godot: `bench/ui_bench/`

Proyecto Godot aparte (reusar el binario FRT de gdtk). Dos escenas **equivalentes**:
- `godot_ui.tscn`: `VBoxContainer` con N filas (`Label` + `ProgressBar` + `Button`) y un `Control` con
  `_draw()` que dibuja una polilínea de 300 puntos.
- `imgui_ui.tscn`: lo mismo con `ImGuiCanvas` (`text`, `progress_bar`, `button`, y `plot_lines` o
  `implot_plot_line`).
Modos: **estático** (nada cambia) y **dinámico** (cada frame cambian todos los valores y la curva).
N = 20, 100, 400. Correr con vsync off, 600 frames después de 120 de calentamiento, y medir por frame:
tiempo de frame (`OS.get_ticks_usec` entre frames), `Performance.TIME_PROCESS`,
`RENDER_DRAW_CALLS_IN_FRAME`, `RENDER_2D_ITEMS_IN_FRAME`, `RENDER_2D_DRAW_CALLS_IN_FRAME` (si existe
en 3.6), memoria estática y cantidad de nodos. Reportar media y p95.
Script `bench/run_ui_bench.sh` que corre la matriz (GLES2 y GLES3, bajo cage anidado o `--no-window` si
FRT lo permite con render real — preferir cage) y escribe `bench/RESULTS.md` con una tabla y 3–5 líneas
de conclusiones medidas (no opiniones): dónde gana cada uno.

## Verificación (obligatoria)

1. Build limpio; `./run_demo.sh`, `./run_shell.sh`, `./run_compositor.sh`, `tests/control_test.sh` pasan.
2. `--open=Panel --screenshot`: curvas ImPlot visibles, superficie 3D limpia, menú radial sin rayas
   (reusar `tests/panel_driver.py`).
3. HUD: con el control remoto abrir el shell, `key F1` → screenshot `hud-graficas.png` (curvas
   visibles); cambiar a Consola, provocar un error (p.ej. `eval nodo_inexistente.x` o un comando
   inexistente) y un `print` → screenshot `hud-consola.png` (el print y el error en rojo); `key F1` de
   nuevo → `hud-mini.png` (sólo el widget mini).
4. Build con `imgui_implot=no imgui_implot3d=no imgui_demos=no` compila y el HUD funciona con
   `plot_lines`.
5. `bench/RESULTS.md` generado con números reales.
Leer todos los PNG y describirlos.

## Entregable

- Commit(s) `fix(imgui): índices 32 bits, plots del Panel, menú radial`,
  `feat(imgui): opciones implot/implot3d/demos y tipos numéricos acotados`,
  `feat(debug_hud): HUD de debug con consola, gráficas y widget mini`,
  `bench: ImGui vs controles de Godot` — cada uno terminado en
  `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`.
- Reporte breve: tamaños antes/después por perfil, tabla del benchmark, qué muestran los PNG, desvíos y
  errores literales. No modificar README.md ni SPEC*.md.
