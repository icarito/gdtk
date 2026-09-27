# SPEC — Paso 10: API ImGui razonable + ImPlot + ImPlot3D + menú radial + ejemplo complejo

Hoy `ImGuiCanvas` (`modules/imgui/imgui_canvas.{h,cpp}`) expone 18 funciones escritas a mano. Objetivo:
una API curada que cubra el uso normal, dos plugins de gráficos, un widget radial propio y un ejemplo
que lo use todo. Leer antes: `modules/imgui/*`, `shell/shell.gd`, `shell/activities/chat.gd`,
`shell/remote.gd`, `tests/`.

## Reglas

- Repo `/run/media/icarito/DATA/icarito/Proyectos/gdtk`. Motor: **árbol `godot-dev`**
  (`/home/icarito/Proyectos/godot3-box3d/godot-dev`), NO `godot`. `git add` por nombre (archivo ajeno
  sin trackear en `shell/`). Sin push. No `pkill -f`/`pgrep -f` con patrones de tu propia línea.
- Build (exportar la caché):
  ```sh
  export SCONS_CACHE=$HOME/.cache/scons-godot3 SCONS_CACHE_LIMIT=30000
  cd /home/icarito/Proyectos/godot3-box3d/godot-dev
  scons -j8 platform=frt arch=x86_64 target=release_debug tools=yes frt_desktop_gl=yes production=yes lto=none use_static_cpp=no progress=no extra_suffix=gdtk imgui_implot3d=yes custom_modules=/home/icarito/Proyectos/godot3-box3d/godot-box3d-3,/run/media/icarito/DATA/icarito/Proyectos/gdtk/modules
  ```
  Si el link falla con `undefined reference to register_*_types`: borrar
  `modules/modules_enabled.gen.h modules/register_module_types.gen.*` en godot-dev y recompilar.
- **ImGui se queda en 1.91.9** (el backend sube el atlas de fuentes una vez; 1.92+ exige texturas
  dinámicas). Vendorear en `modules/imgui/thirdparty/`:
  - **ImPlot** (github.com/epezent/implot, MIT): el tag más nuevo que compile con ImGui 1.91.9
    (probar `v0.17`; si no, `v0.16`). Sólo `implot.h implot_internal.h implot.cpp implot_items.cpp LICENSE`.
  - **ImPlot3D** (github.com/brenocq/implot3d, MIT): el tag más nuevo que compile con 1.91.9 y con el
    ImPlot elegido. Sólo sus `.h/.cpp` y `LICENSE`.
  Anotar en el reporte qué tags quedaron y por qué. Contextos: `ImPlot::CreateContext()` y
  `ImPlot3D::CreateContext()` junto al de ImGui (uno por `ImGuiCanvas`, `SetCurrentContext` de los tres).

## 1. API curada (métodos de `ImGuiCanvas`, snake_case)

Convención para punteros de ImGui (`bool*`, `float*`, `int*`, `char*`): **se recibe el valor y se
devuelve el nuevo** (como `checkbox`). Cuando la función además devuelve `bool` (cambió/clickeado),
devolver el valor nuevo y exponer `is_item_edited()`/`is_item_clicked()` para quien lo necesite.
Vectores como `Vector2`/`Vector3`/`Color`; listas como `Array`/`PoolStringArray`/`PoolRealArray`.

- Ventanas/layout: `begin(title, flags=0, closable=false) -> bool` (si `closable`, `is_window_open()`
  dice si el usuario la cerró), `end`, `begin_child/end_child` (ya), `set_next_window_pos/size` (ya),
  `set_next_window_bg_alpha`, `same_line(offset=0, spacing=-1)`, `new_line`, `spacing`, `dummy(size)`,
  `indent(w=0)`, `unindent(w=0)`, `separator`, `separator_text(label)`, `begin_group/end_group`,
  `push_id(id)/pop_id`, `push_item_width(w)/pop_item_width`, `get_content_region_avail() -> Vector2`,
  `get_window_size/pos`, `set_cursor_pos` (ya).
- Texto: `text`, `text_wrapped` (ya), `text_colored(color, s)`, `text_disabled(s)`, `bullet_text(s)`,
  `label_text(label, s)`.
- Botones/selección: `button(label, size)` (ya), `small_button`, `checkbox` (ya), `radio_button(label,
  active) -> bool`, `selectable(label, selected=false, size=Vector2()) -> bool`, `progress_bar(frac,
  size=Vector2(-1,0), overlay="")`, `image(texture: Texture, size, tint=Color(1,1,1))` (ImTextureID =
  puntero al `Texture` vivo durante el frame; mantener una lista por frame para que no se libere) e
  `image_button(id, texture, size) -> bool`.
- Entrada: `slider_float(label, v, min, max, fmt="%.3f") -> float`, `slider_int`, `slider_float2/3`
  (Vector2/Vector3), `drag_float(label, v, speed=1, min=0, max=0) -> float`, `drag_int`,
  `drag_float2/3`, `input_float`, `input_int`, `input_text` (ya), `input_text_multiline(label, value,
  size) -> String` (buffer 16 KB), `color_edit3/4(label, color) -> Color`, `color_picker4`,
  `combo(label, current: int, items: PoolStringArray) -> int`, `list_box(label, current, items,
  height_items=-1) -> int`.
- Árboles/pestañas: `tree_node(label, flags=0) -> bool`, `tree_pop`, `collapsing_header(label,
  flags=0) -> bool`, `begin_tab_bar(id) -> bool`, `end_tab_bar`, `begin_tab_item(label) -> bool`,
  `end_tab_item`.
- Tablas: `begin_table(id, columns, flags=0) -> bool`, `end_table`, `table_setup_column(label)`,
  `table_headers_row`, `table_next_row`, `table_next_column() -> bool`.
- Menús/popups: `begin_main_menu_bar/end_main_menu_bar`, `begin_menu_bar/end_menu_bar`,
  `begin_menu(label) -> bool`, `end_menu`, `menu_item(label, shortcut="", selected=false) -> bool`,
  `open_popup(id)`, `begin_popup(id) -> bool`, `begin_popup_modal(title) -> bool`, `end_popup`,
  `close_current_popup`, `begin_popup_context_item(id="") -> bool`, `set_tooltip(s)`,
  `begin_tooltip/end_tooltip`.
- Estado del ítem: `is_item_hovered`, `is_item_active`, `is_item_clicked(button=0)`, `is_item_edited`,
  `is_mouse_clicked(button)`, `is_mouse_double_clicked`, `get_mouse_pos() -> Vector2`.
- Gráficos nativos: `plot_lines(label, values: PoolRealArray, overlay="", min=FLT_MAX, max=FLT_MAX,
  size=Vector2())`, `plot_histogram(...)` (mismos args).
- Estilo: `style_colors_dark/light/classic()`, `push_style_color(idx, color)/pop_style_color(n=1)`,
  `push_style_var_float(idx, v)`, `push_style_var_vec2(idx, v)`, `pop_style_var(n=1)`.
- Constantes (como las `WINDOW_*` existentes, con `bind_integer_constant`): flags de ventana más
  usados (`WINDOW_NO_TITLE_BAR, NO_RESIZE, NO_SCROLLBAR, NO_COLLAPSE, ALWAYS_AUTO_RESIZE, MENU_BAR`,
  más los existentes), `TREE_NODE_DEFAULT_OPEN`, `TABLE_BORDERS, TABLE_ROW_BG, TABLE_RESIZABLE`,
  `COL_*` para los colores de estilo usados en el ejemplo, `STYLE_VAR_FRAME_ROUNDING, WINDOW_ROUNDING,
  FRAME_PADDING, ITEM_SPACING`.
- `show_demo_window()` y `show_metrics_window()`: compilar `imgui_demo.cpp` (está en el repo de ImGui;
  vendorearlo de vuelta) — sirve de catálogo vivo de lo que ImGui puede hacer. Igual `ImPlot::ShowDemoWindow`
  → `implot_show_demo_window()` e `implot3d_show_demo_window()`.

## 2. ImPlot / ImPlot3D (prefijos `implot_` / `implot3d_`)

- `implot_begin_plot(title, size=Vector2(-1,0), flags=0) -> bool`, `implot_end_plot`,
  `implot_setup_axes(x_label, y_label, x_flags=0, y_flags=0)`, `implot_setup_axis_limits(axis, min,
  max, cond_always=false)` (constantes `IMPLOT_AXIS_X1/Y1`, flags `IMPLOT_AXIS_AUTOFIT`),
  `implot_plot_line(label, xs: PoolRealArray, ys: PoolRealArray)`, `implot_plot_scatter`,
  `implot_plot_bars(label, values, bar_size=0.67)`, `implot_plot_shaded(label, xs, ys, y_ref=0)`,
  `implot_plot_heatmap(label, values: PoolRealArray, rows, cols, min=0, max=0)`.
- `implot3d_begin_plot(title, size=Vector2(-1,0), flags=0) -> bool`, `implot3d_end_plot`,
  `implot3d_setup_axes(x, y, z)`, `implot3d_plot_line(label, xs, ys, zs)`,
  `implot3d_plot_scatter(label, xs, ys, zs)`, `implot3d_plot_surface(label, xs, ys, zs, x_count,
  y_count)`.
  (Verificar nombres/firmas reales en los headers de las versiones elegidas.)

## 3. Menú radial propio: `pie_menu`

Widget en C++ (`modules/imgui/pie_menu.{h,cpp}`, dibujado con `ImDrawList` sobre el foreground o una
ventana sin decoración, ~100 líneas, sin dependencias):
- `open_pie_menu(id)` lo abre centrado en el mouse (llamar p.ej. en clic derecho o toque largo).
- `pie_menu(id, items: PoolStringArray) -> int`: mientras está abierto dibuja un anillo con N sectores
  iguales (radio interior ~30 px, exterior ~110 px × `imgui_scale`), resalta el sector bajo el
  puntero (por ángulo, con zona muerta en el centro), etiqueta centrada en cada sector; al soltar
  el botón (o al clickear, en táctil) devuelve el índice elegido y se cierra; fuera/centro = -1 y
  cierra. Mientras no se eligió nada devuelve -1.
- Estilo del sector desde los colores de ImGui (`ImGuiCol_Button`, `ButtonHovered`, `Text`).

## 4. Ejemplo complejo: actividad **"Panel"** en el shell

`shell/activities/panel.gd` (actividad interna tipo script, como el Chat) + agregarla a `ACTIVITIES`.
Muestra de verdad lo que da el toolkit, con datos vivos:
- Un `Viewport` 3D propio (hijo creado por el script: cámara, luz, una malla — cubo/esfera/toro
  procedurales con `SpatialMaterial`) renderizado a textura y mostrado con `image()` en una ventana
  "Escena". Controles al lado: `combo` de forma, `color_edit3` → albedo, `slider_float` velocidad de
  rotación, `checkbox` wireframe/animación, `drag_float3` posición de la luz.
- Ventana "Rendimiento" con pestañas: (a) **ImPlot** línea de FPS y de frame time (ms) de los últimos
  300 frames (`Performance.get_monitor`), con `implot_plot_shaded` bajo la curva; (b) barras de
  memoria/objetos/draw calls; (c) tabla (`begin_table`) con los monitores de `Performance` y sus
  valores; (d) `plot_lines` nativo de ImGui como comparación.
- Ventana "3D" con **ImPlot3D**: superficie `z = sin(x·t)·cos(y·t)` animada y una curva 3D (hélice)
  con `implot3d_plot_line`.
- **Menú radial**: clic derecho (o toque largo) sobre la ventana "Escena" abre `pie_menu` con
  "Cubo, Esfera, Toro, Rojo, Verde, Azul, Reset"; la elección cambia la malla/color.
- Barra de menú (`begin_menu_bar`) con "Ver → Demo ImGui / Demo ImPlot / Demo ImPlot3D / Métricas" que
  abre las ventanas demo; y un modal "Acerca de" (`begin_popup_modal`).
- Las ventanas arrancan en un layout legible a 1280×720 (usar `set_next_window_pos/size` con
  `FirstUseEver`).

## Verificación (obligatoria)

1. Build limpio en godot-dev; `./run_demo.sh`, `./run_shell.sh`, `./run_compositor.sh`,
   `tests/control_test.sh` siguen pasando.
2. `session/gdtk-session -- --open=Panel --screenshot=$PWD/panel.png` (cage anidado, `timeout 90`):
   PNG con Escena (malla visible), Rendimiento (curva ImPlot con datos) y 3D (superficie visible).
3. Con el control remoto (`tests/`, puerto propio p.ej. `GDTK_CONTROL_PORT=7798`): abrir Panel,
   clic derecho sobre la Escena, `move` sobre el sector "Esfera", soltar (agregar al control un
   `mouse_button {x,y,button,pressed}` si hace falta para press/release separados) → screenshot
   `panel-pie-open.png` (anillo visible con el sector resaltado) y `panel-pie-done.png` (la malla
   cambió a esfera). Abrir "Ver → Demo ImPlot" → `panel-implot-demo.png`.
4. Medir y reportar el tamaño que suma el módulo: `size -t` de los `.o` de `modules/imgui` antes y
   después (ImGui solo vs + demo + ImPlot + ImPlot3D + pie_menu).
Leer los PNG y describirlos.

## Entregable

- Commit `feat(imgui): API curada (~60 funciones), ImPlot + ImPlot3D, menú radial y actividad Panel`
  terminado en `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`.
- Reporte breve: tags de ImPlot/ImPlot3D elegidos, lista de métodos expuestos, tamaños, qué muestran
  los PNG, desvíos y errores literales. No modificar README.md ni SPEC*.md.
