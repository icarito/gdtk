# SPEC — Paso 13: Linterna de casco con ImGui (widget y "pantalla") en gdtk

Objetivo: validar en gdtk, antes de tocar Odisea, un port a ImGui de la **Linterna de casco**
(FD-298), siguiendo el mismo enfoque que el Paso 12 (Criopod/HoloTerminal): reusar la
infraestructura de `demo_holoterminal/` (`update_hz`, cursor por shader, fuente Silkscreen,
paleta por luma) para dibujar con datos simulados lo que Odisea ya muestra hoy — el **widget
compacto** de la linterna — y, como ejercicio de paridad con el Paso 12, una **pantalla diegética
inventada** que no existe todavía en Odisea (ver advertencia en la sección 0).

## 0. Advertencia: la Linterna NO tiene pantalla 3D en Odisea hoy

A diferencia de la Criopod (`CryoPodHUDable.gd` + `HoloTerminalV2.gd`, con `view_scene()`,
`view_size()`, `borrow_viewport()` y un `Viewport` real montado en un quad del mundo), la Linterna
sólo declara un **widget**:

- `core_v2/things/FlashlightScreen.gd:1-14` (`extends HUDableComponent`, `class_name
  FlashlightScreen`): en `_init()` fija `hud_widget_scene = WidgetScene`
  (`FlashlightWidget.tscn`) pero **nunca** `hud_view_scene`. `HUDableComponent.view_scene()`
  (`core_v2/components/HUDableComponent.gd:51-53`) devuelve por lo tanto `null`.
- `core_v2/ui/hud/HudViewMount.gd:91-99` (`show()`): si `screen.view_scene()` es `null`, `opened`
  queda `false` y cae directo a `_open_widget()` (línea 297): el "modo pantalla completa" de la
  Linterna en HUD/casco es el mismo `FlashlightWidget.tscn` reinstanciado y agrandado
  (`WIDGET_ZOOM = 1.8`, línea 14; de 210×80 a ~378×144).
- Contraste: `core_v2/components/HoloTerminalHUDable.gd:197-208` y
  `core_v2/components/CryoPodHUDable.gd:83` sí implementan `view_size()` /
  `view_hud_config()` / `borrow_viewport()` — son las pantallas "de verdad" con su propio
  `Viewport` en el mundo (`HoloTerminalV2.gd`).

Por lo tanto este spec, para el punto "pantalla en 3D" que pide el mismo enfoque que el Paso 12,
**inventa** una pantalla diegética plausible para la Linterna (p. ej. un visor/gauntlet del casco)
usando exactamente los mismos datos que ya expone `FlashlightScreen.widget_snapshot()` — no hay
layout de referencia en Odisea equivalente a `CryoPodUI.gd` para copiar. Esto es una decisión de
diseño nueva, no un port 1:1; se señala explícitamente en el reporte y en "Cambios para Odisea".

## Referencias en Odisea (sólo lectura): `/home/icarito/Proyectos/Odisea_Game/src`

- `core_v2/ui/hud/FlashlightWidget.gd` (widget completo, 71 líneas) y
  `core_v2/ui/hud/FlashlightWidget.tscn` (layout: `PanelContainer` 210×80, `Margin/VBox` con
  `Header` [`StatusDot` 8×8 + `TitleLabel`], `MeterLabel`, `StatusRow` [`StatusLabel` +
  `ToggleButton`]).
- `core_v2/ui/hud/HudWidget.gd` (base común: `set_snapshot`/`_render`/`_render_offline`,
  `_set_dot`, `_perform(op, args)` vía `HudWidgetAction.gd`, rama OFFLINE del Manual §7).
- `core_v2/things/FlashlightScreen.gd` (fuente HUDable, 121 líneas): `widget_snapshot()`
  (líneas 26-58), `perform_action("toggle", …)` (líneas 87-95), `hud_gamepad_actions()`
  (líneas 81-85, botón A = toggle con `confirm: true`), `relevance()` (líneas 60-77).
- `core_v2/props/lights/HelmetFlashlight.gd` (estado real): `enabled` (export, línea 5),
  `battery`/`battery_max`/`battery_drain_per_second`/`battery_low_threshold` (líneas 57-62),
  señal `battery_changed(value, max_value)` (línea 64), `get_battery()`/`get_battery_max()`/
  `is_battery_low()` (líneas 202-211), `toggle()`/`set_enabled()` (líneas 400-444). Nota:
  `scan_mode`, `spot_range`, `spot_angle`, `light_color`, `light_energy` existen como parámetros
  del cono volumétrico pero **no** se exponen en `widget_snapshot()` — el widget/pantalla actual
  de Odisea sólo muestra encendido + batería, no modos ni intensidad.
- `core_v2/components/HUDableComponent.gd` (contrato base: `screen_id()`, `screen_title()`,
  `widget_snapshot()` default con `proto`/`id`/`title`/`source`, `view_scene()`).
- `core_v2/ui/hud/HudViewMount.gd` (líneas 91-99, 297-313): por qué la Linterna cae al widget
  ampliado en vez de a un `view_scene()`; `WIDGET_ZOOM`, `WIDGET_PANEL_ALPHA` (B3a, tier LOW
  queda opaco).
- `core_v2/ui/hud/SuitOSWidgetHost.gd` y `core_v2/autoloads/SuitOS.gd` (`register_screen`,
  `perform_action`, `get_registered_screens`): cómo se registra y despacha la acción `toggle`.
- `core_v2/ui/hud/RemoteHudBackend.gd`: consumidor de `widget_snapshot()` para el HUD del
  teléfono/control remoto (mismo Dictionary, JSON-serializable — verificado en
  `core_v2/tests/test_flashlight_screen.gd:54-58`).
- `core_v2/ui/OdiseaOSTheme.gd`: paleta (`STATE_ACTIVE` turquesa `Color(0.18,0.88,0.78,0.9)`,
  `STATE_ALARM` rojo `Color(0.9,0.3,0.2,0.9)`, `STATE_OFFLINE` gris `Color(0.5,0.5,0.5,0.8)`,
  `INK` `Color(0.85,0.95,1.0,1.0)`, `accent_for("player:flashlight")` → `SUIT_ACCENT` cian
  `Color(0.0,0.835,1.0,1.0)` por el prefijo `player:`).
- `core_v2/tests/test_flashlight_screen.gd` (contrato exacto del snapshot: claves
  `["proto","on","battery","battery_max","low","source"]` más `id`/`title`; `on=false` en frío).
- `core_v2/tests/test_helmet_flashlight.gd`: comportamiento de batería/auto-apagado a probar con
  datos simulados.
- `assets/fonts/Silkscreen-Regular.ttf` (mismo TTF que el Paso 12; ya copiado a
  `demo_holoterminal/assets/`), `core_v2/visual/HoloScreen.shader` (regla de luma:
  `coverage = luma / ink_level`, oscuro = vidrio).

## Reglas

- Repo `/run/media/icarito/DATA/icarito/Proyectos/gdtk`. Motor: árbol **`godot-dev`**, caché
  (`export SCONS_CACHE=$HOME/.cache/scons-godot3 SCONS_CACHE_LIMIT=30000`), comando de build del
  README. `git add` por nombre — hay un archivo ajeno sin trackear en `shell/` (un volcado de
  crash) y `demo_holoterminal/`/`.claude/` sin commitear del Paso 12 en curso: no barrer con
  `git add -A`. Sin push. **No modificar Odisea.** No `pkill -f`/`pgrep -f` con patrones de la
  propia línea de comando (usar `pgrep -a` y filtrar).
- No se necesitan cambios en `modules/imgui/*` (C++): este paso reusa `update_hz`/`input_hz`/
  `redrawn`/`request_redraw()`/`add_font()` tal como quedaron especificados en el Paso 12
  (`SPEC-holoterminal.md`), asumiendo que ya están implementados ahí. Si al empezar este paso esa
  API todavía no existe en `modules/imgui/imgui_canvas.h`, primero completar el Paso 12 (o al
  menos esa parte de la API) antes de seguir.
- Reusar de `demo_holoterminal/`: `assets/HoloScreen.shader`, `assets/Silkscreen-Regular.ttf`
  (con su licencia si está al lado), y el patrón de `holoterminal.gd` (raycast del mouse contra el
  plano del quad → UV → `cursor_uv` del shader + reenvío de `InputEventMouseMotion`/clicks al
  `Viewport`) — no reinventar el mouse-picking.

## 1. Demo `demo_flashlight/` (proyecto Godot, junto a `demo_holoterminal/`)

### 1.1 Estado simulado (sustituye a `HelmetFlashlight.gd`)

Script `flashlight_state.gd` (Reference o Node autónomo, sin Godot real): reproduce sólo lo que
Odisea expone hoy —

```
enabled: bool = false
battery: float = 100.0
battery_max: float = 100.0
battery_drain_per_second: float = 0.4
battery_low_threshold: float = 20.0
```

con `toggle()`, `_process(delta)` (drena batería igual que `HelmetFlashlight.gd:220-239`,
auto-apagado a 0), `is_battery_low()`, y una señal `battery_changed(value, max_value)`. Un botón
de debug para forzar "batería baja" sin esperar el drenaje real (acelerar `battery_drain_per_second`
desde el overlay de diagnóstico).

`widget_snapshot()` idéntico en forma al de `FlashlightScreen.gd:49-58`:

```
{ "proto": 1, "id": "player:flashlight", "title": "Linterna",
  "on": bool, "battery": float, "battery_max": float, "low": bool, "source": "online" }
```

y una variante con `"source": "offline"` para ejercitar `_render_offline()`.

### 1.2 Widget compacto (`imgui_flashlight_widget.gd`)

Dibuja con ImGui, a partir del Dictionary de arriba, el equivalente exacto de
`FlashlightWidget.gd` + `FlashlightWidget.tscn`:

- Ventana/panel de tamaño fijo 210×80 (o `push_style_var` para simular el `PanelContainer`),
  fondo `SURFACE_PANEL` (`Color(0.05,0.08,0.1,1.0)`) — oscuro, para que el shader lo lea como
  vidrio.
- Header: punto de estado 8×8 (`ColorRect` → un `image`/rectángulo relleno ImGui) con el color
  de `_set_dot`: `STATE_ACTIVE`/`STATE_ALARM` si `on` (alarma si `low`), `STATE_OFFLINE` si
  apagado u offline. Título "Linterna" (`INK`, Silkscreen 14-16 px aprox para caber en 184 px de
  ancho útil).
- `MeterLabel`: puerto textual de `_format_battery_bar()` (`FlashlightWidget.gd:56-68`) — barra
  ASCII de 10 segmentos `BAT: [||||||...]`, con `_set_font_color` a `STATE_ALARM` si `low and on`,
  si no `INK`. Offline: `"BAT: [----------]"`.
- `StatusRow`: label de estado (`ENCENDIDA`/`BAT. BAJA`/`APAGADA`/`OFFLINE`) + botón
  `ENCENDER`/`APAGAR`/`OFFLINE` (deshabilitado si offline) que dispara la acción `toggle`
  (equivalente a `_on_toggle_pressed` → `_perform("toggle")`).
- Reproducir también el modo ampliado de `HudViewMount._open_widget` (zoom 1.8×, alfa de panel
  ≤ 0.7 salvo tier LOW) como un segundo modo de dibujo del mismo widget, para dejar constancia de
  que así es como se ve hoy "la pantalla completa" de la Linterna en Odisea.

### 1.3 Pantalla diegética inventada (`flashlight_screen.gd`, sobre el mismo quad/Viewport del
Paso 12)

Reusar el `MeshInstance` `QuadMesh` con `HoloScreen.shader` + `cursor_uv`/`cursor_tex` y el
`Viewport` con `ImGuiCanvas` (`update_hz = 10`) de `demo_holoterminal/`. Tamaño de diseño menor
que la Criopod (1024×640): **480×300**, acorde a un visor de casco simple con mucho menos
contenido que mostrar.

Layout (basado únicamente en los campos reales del snapshot; nada de modos/intensidad que Odisea
no expone):

- Encabezado: "LINTERNA · CASCO" con el punto de estado grande.
- Indicador ENCENDIDA/APAGADA grande (Silkscreen ~40 px), color `STATE_ACTIVE`/`STATE_OFFLINE`.
- Medidor de batería: barra ImGui (`progress_bar` con estilo, o `implot_plot_bars` horizontal
  como los signos vitales de la Criopod) con `battery/battery_max`, número grande al lado, y el
  mismo cambio de color a `STATE_ALARM` bajo `battery_low_threshold`.
- Botón "ENCENDER/APAGAR" grande, mismo `_perform("toggle")`.
- Overlay de diagnóstico (fuera del quad, ImGui 2D normal): `update_hz`, renders/s del Viewport,
  FPS, slider para acelerar el drenaje de batería (para forzar el estado "baja" sin esperar).

Estilo: mismos `push_style_color` con la paleta de `OdiseaOSTheme` (no `CryoPodUI.CYAN/DIM/...`,
que son de la Criopod) — fondo y paneles oscuros por la regla de luma, fuente Silkscreen (mismo
TTF ya copiado en `demo_holoterminal/assets/`).

### 1.4 Actividad "Linterna" en el shell

`shell/shell.gd`: agregar una actividad **"Linterna"** (mismo patrón que la actividad "Criopod"
del Paso 12: sub-escena instanciada dentro de la actividad) que abre `flashlight_screen.gd`, para
poder manejarla con el control remoto (puerto propio, igual que el Paso 12).

## Verificación (obligatoria)

1. Build limpio en godot-dev; `./run_shell.sh`, `./run_compositor.sh`, `tests/control_test.sh`
   pasan.
2. `--open=Linterna --screenshot=$PWD/flashlight.png` (cage anidado, `timeout 90`): pantalla en 3D
   con el indicador ENCENDIDA/APAGADA, la barra de batería y el encabezado legibles con
   Silkscreen, oscuros como vidrio.
3. Con el control remoto: click en "ENCENDER/APAGAR" → screenshot `flashlight-on.png` con el
   estado cambiado (punto de estado y texto). Forzar batería baja (slider de drenaje acelerado) →
   screenshot `flashlight-low.png` con la barra y el texto en `STATE_ALARM`.
4. Widget compacto: screenshot `flashlight-widget.png` (210×80, apagado) y
   `flashlight-widget-on.png` (encendido, batería con segmentos llenos).
5. Mismos puntos 2-4 con GLES2 (`GDTK_VIDEO_DRIVER=GLES2`).
6. Reportar números: renders/s del Viewport en reposo y justo tras la acción de toggle (debe
   pulsar `UPDATE_ONCE` una vez y volver a reposo a `update_hz`), frame time medio.
Leer los PNG y describirlos.

## Cambios para Odisea

Si se quisiera adoptar este port en Odisea (no hacerlo en este paso, sólo documentarlo):

- `core_v2/ui/hud/FlashlightWidget.gd`/`.tscn`: reemplazar el `PanelContainer`/`Label`/`Button`
  de Godot por un `ImGuiCanvas` que dibuje el mismo contenido a partir del mismo
  `widget_snapshot()` — sin cambiar el contrato con `SuitOSWidgetHost`/`HudWidgetAction`.
- `core_v2/things/FlashlightScreen.gd`: si se decide que la Linterna merece una pantalla propia
  (hoy no la tiene), agregar `hud_view_scene`, `view_size()`, `view_hud_config()` y
  `borrow_viewport()` como hace `CryoPodHUDable.gd`/`HoloTerminalHUDable.gd`, y ampliar
  `widget_snapshot()` si se quiere mostrar algo más que on/batería (p. ej. `scan_mode`, que
  `HelmetFlashlight.gd` ya tiene pero no expone).
- Nueva pantalla ImGui (`FlashlightScreenImGui.tscn`/`.gd` o similar) montada como
  `hud_view_scene`, con el layout validado en `demo_flashlight/flashlight_screen.gd`.
- `core_v2/visual/HoloScreen.shader`: adoptar el cursor por shader (`cursor_uv`/`cursor_tex`) si
  esta pantalla termina siendo interactiva con mouse, igual que se documentó para
  `HoloTerminalV2.gd` en el Paso 12.

## Entregable

- Commit `feat(demo): Linterna de casco con ImGui, widget compacto y pantalla diegética` —
  terminado en `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`.
- Reporte breve: números del punto 6 de Verificación, qué muestran los PNG, desvíos, errores
  literales, y la lista de "Cambios para Odisea" ya resumida arriba. No modificar README.md ni
  otros SPEC*.md.
