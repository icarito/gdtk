# SPEC — Paso 12: HoloTerminal de la Criopod con ImGui (UI diegética), cursor fluido y ECG con ImPlot

Objetivo: validar en gdtk, antes de tocar Odisea, la pantalla de la Criopod de Odisea rehecha con
ImGui **dentro de un `Viewport` sobre una malla 3D**, con:
- el contenido a **10 Hz** (el `Viewport` sólo re-renderiza cuando ImGui redibuja),
- el **cursor fluido a la tasa del juego**, dibujado en el shader de la pantalla y no dentro de la
  textura (hoy en Odisea el cursor va dentro del Viewport: a 10 Hz salta, y con foco la terminal pasa
  a `UPDATE_ALWAYS` y re-renderiza 60 veces por segundo sólo por el cursor —
  `core_v2/things/HoloTerminalV2.gd:499` y el comentario de la línea 834),
- el **monitor cardíaco con un plot de verdad** (ImPlot) en vez del trazo a mano.

Referencias en Odisea (sólo lectura): `/home/icarito/Proyectos/Odisea_Game/src`
`core_v2/props/criopod/CryoPodUI.gd` (layout 1024×640, paleta, `_ecg(p)` PQRST, signos vitales, botón
de escotilla), `core_v2/things/HoloTerminalV2.gd` (static_content / request_redraw / modos de update),
`core_v2/visual/HoloScreen.shader` (opacidad por **luma**: `coverage = luma / ink_level`, lo oscuro es
vidrio; flips), `assets/fonts/Silkscreen-Regular.ttf`.

## Reglas

- Repo `/run/media/icarito/DATA/icarito/Proyectos/gdtk`. Motor: árbol **`godot-dev`**, caché
  (`export SCONS_CACHE=$HOME/.cache/scons-godot3 SCONS_CACHE_LIMIT=30000`), comando de build del README.
  `git add` por nombre (archivo ajeno sin trackear en `shell/`). Sin push. **No modificar Odisea.**
  No `pkill -f`/`pgrep -f` con patrones de tu propia línea (usar `pgrep -a`).
- Copiar a `demo_holoterminal/assets/` (el usuario es dueño de ambos repos): `HoloScreen.shader` y
  `Silkscreen-Regular.ttf` (con su licencia OFL si está al lado; si no, anotar el origen en un README).

## 1. `ImGuiCanvas`: tasa de actualización y fuentes (C++)

- Propiedad `update_hz: float = 0.0` (0 = cada frame, como hoy). Con `update_hz > 0`: sólo se arma un
  frame de ImGui (NewFrame→señal `imgui_frame`→Render→canvas items) cuando toca por tiempo **o** cuando
  hubo input en ImGui desde el último frame; en los demás frames no se toca nada (los canvas items
  quedan como están). Propiedad `input_hz: float = 30.0`: mientras llega input (últimos 250 ms), sube a
  esa tasa para que el hover responda. Señal `redrawn` emitida tras cada frame efectivamente armado
  (el host la usa para pedir `UPDATE_ONCE` a su Viewport). Método `request_redraw()`.
  **Cuidado**: los eventos de input recibidos entre frames deben quedar en la cola de ImGui
  (`io.Add*Event`) y procesarse en el siguiente NewFrame — no perder clicks; `io.DeltaTime` = tiempo
  real desde el último frame armado.
- Fuentes: `add_font(path: String, size_px: float) -> int` (ttf vía `AddFontFromFileTTF` leyendo el
  archivo con `FileAccess`/`File` de Godot a memoria — `res://` no es ruta del sistema; usar
  `AddFontFromMemoryTTF` con `FontDataOwnedByAtlas = false` y mantener el buffer vivo), antes del
  primer frame o reconstruyendo el atlas y la textura si es después; `push_font(idx)`, `pop_font()`,
  `set_default_font(idx)`. Rango de glifos: Latin + Latin-1 (acentos/ñ).

## 2. Demo `demo_holoterminal/` (proyecto Godot) + actividad "Criopod" en el shell

- Escena 3D: cámara con mouse-look suave (o fija mirando la terminal), luz, piso, y la **terminal**:
  `MeshInstance` `QuadMesh` 1.6×1.0 inclinado, con `ShaderMaterial` = copia de `HoloScreen.shader` +
  dos uniforms nuevos: `uniform vec2 cursor_uv = vec2(-1.0);` y `uniform sampler2D cursor_tex;`
  (+ `uniform vec2 cursor_size_uv`). En el fragment, después de leer la textura del Viewport (respetando
  los flips que ya aplica el shader al UV), mezclar el cursor sobre `tex_color` **antes** del cálculo de
  luma/coverage, así el cursor es "tinta" como el resto. `cursor_uv < 0` = sin cursor.
- `Viewport` 1024×640 (`USAGE_2D`, `render_target_update_mode = UPDATE_DISABLED`, `transparent_bg`
  como en Odisea) con un `ImGuiCanvas` (`update_hz = 10`) adentro; al emitir `redrawn` →
  `UPDATE_ONCE`. Script `holoterminal.gd` en la terminal:
  - cada frame: rayo desde la cámara por el mouse → intersección con el plano del quad (matemática, sin
    física) → UV → `material.set_shader_param("cursor_uv", uv)` (fluido, cada frame) y, si cambió,
    `InputEventMouseMotion` en coordenadas del Viewport hacia `viewport.input(ev)`; clicks igual.
  - fuera de la pantalla: `cursor_uv = (-1,-1)`.
- `criopod_screen.gd` (dibuja en `imgui_frame`, layout sobre 1024×640 como `CryoPodUI`):
  - Estilo: colores de `CryoPodUI` (`CYAN, DIM, GRID, PANEL, OK, WARN`) mapeados a `push_style_color`
    (texto, bordes, fondos de frame/ventana, plot) — **el fondo y los paneles oscuros** para que el
    shader los trate como vidrio; fuente Silkscreen (20 px cuerpo, 56 px números grandes).
  - Encabezado: "CRIOCÁPSULA 07 · ELÍAS VEGA · PILOTO · ESTABLE", días de hibernación.
  - **ECG con ImPlot**: la señal es `_ecg(p)` portada tal cual de `CryoPodUI.gd` (PQRST en
    [-0.35, 1.0]) a `bpm` (12 en hibernación; slider oculto en un menú de debug para subirlo a 60–120);
    ventana deslizante de 2.5 ciclos que avanza con el tiempo (muestras nuevas a la derecha, como un
    monitor), grilla, sin leyenda, eje X sin etiquetas, Y fijo en [-0.5, 1.2], línea del color `OK`/
    acento de 3 px, marcador en la cabeza del barrido. BPM grande al lado con corazón que late
    (`exp(-beat*9)` como hoy).
  - Signos vitales: temperatura corporal, integridad, refrigerante, oxígeno como barras (ImPlot
    `implot_plot_bars` horizontal o `progress_bar` con estilo) con sus valores.
  - Botón "ABRIR/CERRAR CÁPSULA" que alterna el estado (feedback en el texto de estado).
- Overlay de diagnóstico (ImGui 2D normal, fuera de la terminal, esquina): `update_hz` (slider 1–60),
  `input_hz`, renders del Viewport por segundo (contar `redrawn`), FPS del juego, y un toggle
  "cursor en textura (modo viejo)" que dibuja el cursor dentro del Viewport para comparar.
- Actividad **"Criopod"** en `shell/shell.gd` que abre esta escena (sub-escena instanciada dentro de la
  actividad), para poder manejarla con el control remoto.

## Verificación (obligatoria)

1. Build limpio en godot-dev; `./run_shell.sh`, `./run_compositor.sh`, `tests/control_test.sh` pasan.
2. `--open=Criopod --screenshot=$PWD/criopod.png` (cage anidado, `timeout 90`): terminal en 3D con el
   ECG con picos PQRST visibles, BPM, barras y encabezado legibles con Silkscreen, y los oscuros como
   vidrio.
3. Con el control remoto (puerto propio): mover el puntero en 30 pasos sobre la terminal a lo largo de
   1 s y medir (loggear desde el script): cambios de `cursor_uv` por segundo (≈ FPS del juego) y renders
   del Viewport por segundo (≈ `input_hz` mientras se mueve, ≈ `update_hz` en reposo). Screenshot
   `criopod-cursor.png` con el cursor sobre el botón y el hover resaltado. Click en el botón →
   `criopod-open.png` con el estado cambiado.
4. Mismo punto 3 con GLES2 (`GDTK_VIDEO_DRIVER=GLES2`).
5. Reportar números: renders/s del Viewport en reposo y moviendo el mouse, frame time medio, con
   `update_hz` = 10 vs el modo viejo (cursor en textura, Viewport siempre).
Leer los PNG y describirlos.

## Entregable

- Commits `feat(imgui): update_hz/input_hz, redrawn, request_redraw y fuentes TTF`,
  `feat(demo): HoloTerminal de la Criopod con ImGui, cursor por shader y ECG con ImPlot` — terminados
  en `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`.
- Reporte breve: números del punto 5, qué muestran los PNG, desvíos, errores literales, y una lista
  corta de lo que habría que cambiar en Odisea (`HoloScreen.shader`, `HoloTerminalV2.gd`,
  `CryoPodUI.gd`) para adoptar el cursor por shader y el ECG con ImPlot. No modificar README.md ni SPEC*.md.
