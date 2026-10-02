# SPEC — Modo ventanas tradicional (WindowMaker) — K13 (DISEÑO)

Estado: **sólo diseño**. No hay implementación en esta entrega. Este documento es el
entregable de K13 de `SPEC-ui-rework-2026-10.md`.

Origen: en la prueba real el shell se ve como un escritorio tiled sin chrome; las
ventanas no tienen barra de título, el Frame tiene huecos entre bloques y no existe
forma de soltar una ventana "libre" estilo WindowMaker. K13 define cómo pasar a un
escritorio con **modo flotante por defecto** y **tiled como alternativa**, con una
apariencia indistinguible de WindowMaker a primera vista, y parte el trabajo en tareas
delegables (K13a…) con write sets y tests.

Leído para este diseño: `SPEC-windows.md`, `SPEC-sugar-frame-blocks.md`,
`SPEC-ui-rework-2026-10.md`, `shell/shell.gd`, `shell/frame.gd`, `shell/tiles_ui.gd`,
`shell/menu_style.gd`, `shell/content_layout.gd`, `modules/wayland/wl_server.c`
y `modules/wayland/wl_server.h`.

## Reglas transversales (aplican a todas las K13x)

- Godot 3.6 GDScript (no Godot 4). Lógica pura en `extends Reference`; su test
  `extends SceneTree` con `load("res://...").new()`, `check()`, `OS.exit_code`, `quit()`.
- Nada de I/O ni procesos en `_draw`/`refresh`/`_process`: snapshots cacheados con TTL,
  escrituras en `Thread`/tmp+rename (mismo patrón que `_save_applets`).
- **Vocabulario de producto** en toda cadena visible: no aparecen `gvd`, `deskflow`,
  `role`, `hid`, `kind`, mDNS, DNS-SD, `recv`, `server/client` ni puertos. Los nombres
  internos viven sólo en código/logs/tooltips bajo `GDTK_DEBUG`.
- Sin commit, sin deploy, sin ssh; no revertir cambios ajenos. Un `kilo run` a la vez.
- El Frame **no** guarda una segunda copia del layout: `shell._units()` sigue siendo la
  fuente y `frame.gd` sólo dibuja.
- Binario de verificación:
  `/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk --no-window --path shell -s $PWD/tests/<test>.gd`.

## 1. Estado actual relevante (base del rediseño)

- **Ventanas = tiles en una sola fila.** `shell.gd` mantiene `tiles`, `groups`,
  `split_weight`, `_units()` y `_compute_slide_layout()` (l. 775); cada ventana ocupa
  el hueco central (`content_layout.gd::content_rect`, K12) y la fila desliza con el
  ancho del viewport; el Hogar es la ranura `units.size()`. **No hay posición libre ni
  solapamiento**: todo es `Rect2` calculado por la fila.
- **No hay decoración dibujada.** `wl_server.c` fija decoración *server-side* (l. 782
  `WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE`) y no implementa maximize/fullscreen;
  `shell.gd` pide el tamaño del slot con `compositor.set_size` (l. 1115) y el contenido
  del cliente llena el rect. Hoy no existe barra de título sobre la ventana.
- **Frame = bloques cuadrados NeXT** (`frame.gd`): `NX_*`, `BEVEL=2`, `TITLE_H=14`,
  `MINI=14`, `PAD=6` **entre** bloques. `frame_bar_h` = una unidad de rejilla
  (`grid_unit`, l. 312) y `content_rect` reserva arriba/abajo (`_frame_edges`, l. 331).
  Ya existe el look de chrome (bisel, mini-teselas `-`/`x`) y el menú WindowMaker
  (`menu_style.gd: FACE/LIGHT/DARK/TITLE_BG/ACTIVE`, bisel 2px, título 16px).
- **Interacciones existentes a conservar**: Alt+M minimiza, Alt+F10 maximiza (saca del
  grupo para llenar `content_rect`), Alt+F11 pantalla completa, Super+←/→ tilea,
  Super+arrastrar mueve al Frame, exposé (toque de Super), Super+W / Alt+F4 cierran,
  drag al basurero cierra.

El rediseño **no tira** este modelo: agrega un segundo modelo de colocación (flotante)
y un chrome, y reutiliza foco/minimizar/cerrar/exposé.

## 2. Modelo de producto

Dos modos, conmutables desde un **BlockApp "Ventanas"** del Frame (bloque de control,
`SPEC-sugar-frame-blocks.md`):

| Modo | Comportamiento | Default |
|---|---|---|
| **Flotante** | Ventanas libres con barra de título WindowMaker; se mueven, redimensionan, apilan por foco. Pueden solaparse. | **Sí** |
| **Tiled** | Lo de hoy: fila de pantallas, grupos (pantallas partidas), sin solape. | Alternativa |

El modo es **global** (no por ventana). Al cambiar de modo se conserva la identidad,
el foco, las minimizadas y el contenido; sólo cambia la colocación:

- tiled → flotante: cada `_units()` se materializa como ventana flotante en cascada
  alrededor del foco, **dentro** de `content_rect` (nunca debajo del Frame).
- flotante → tiled: las ventanas se reordenan por su centro x/y a la fila, respetando
  `tiles`; sin solapes por construcción.

Una ventana **maximizada** (Alt+F10) en modo flotante pasa a ocupar todo `content_rect`
(sigue siendo "tile" lógico y puede desmaximizarse). Pantalla completa (Alt+F11) sigue
ocultando el Frame y es ortogonal al modo.

## 3. Chrome WindowMaker (por ventana)

Dibujado por el shell con la lista de dibujo de ImGui (igual que `frame.gd::_bevel` y
`menu_style.gd::chrome`); el cliente **no** dibuja decoración (server-side decoration
ya activa en `wl_server.c`). El shell reserva el alto del chrome al pedir el tamaño del
cliente con `compositor.set_size`.

**Barra de título** (medidas en px lógicos, escaladas por `ui.get_imgui_scale()`):

```
   ┌──────────────────────────────────────────────────────────────┐   bisel exterior 1px
   │ [–]           Título de la ventana centrado              [x] │   barra 20px
   ├──────────────────────────────────────────────────────────────┤   bisel 2px
   │                                                              │
   │                     contenido del cliente                    │
   │                                                              │
   └──────────────────────────────────────────────────────────────┘
```

- Alto de barra `TITLE_H = 20`; bisel de la barra `1`; bisel del marco `2`.
- Botón **izquierdo = minimizar** (`–`), **derecho = cerrar** (`x`), teselas de `16×16`
  con bisel; hover invierte el bisel (mismo `_bevel`). Zona de no-arrastre.
- Texto centrado, recortado con `...` si no cabe; se dibuja sobre la barra.
- **Foco**: barra activa azul (`WM_TITLE_ACTIVE`), inactiva gris-azul
  (`menu_style.TITLE_BG`) y marco de foco de 1px. El foco por color **siempre** se
  acompaña de la barra activa (nunca sólo color).
- **Redimensión**: borde de `BORDER_HIT = 6` px en los cuatro lados y esquinas; el
  cursor cambia de forma. La barra de título arrastra.
- El contenido del cliente se dibuja en `content = rect - (0, TITLE_H) - border`; el
  mapeo de input (`tile_fit`) usa ese mismo `content` como origen.

**Paleta** (reusa `menu_style.gd`; no se inventan grises nuevos):

| Rol | Valor |
|---|---|
| FACE (cara/marco) | `Color(0.72, 0.72, 0.75)` |
| LIGHT (bisel claro) | `Color(0.96, 0.96, 0.96)` |
| DARK (bisel oscuro) | `Color(0.32, 0.32, 0.35)` |
| TITLE_BG (barra inactiva) | `Color(0.42, 0.42, 0.55)` |
| TITLE_ACTIVE (barra con foco) | `Color(0.24, 0.32, 0.62)` |
| TITLE_TEXT | `Color(0.97, 0.97, 1.00)` |

Referencia de aceptación: a 1 m de la pantalla debe leerse como el chrome clásico de
WindowMaker (bisel doble, título centrado, `–` a la izquierda, `x` a la derecha).

## 4. Modo flotante (colocación pura)

Modelo puro `shell/float_layout.gd` (`extends Reference`, sin I/O):

- Estado: `rects: {id -> Rect2}` (exterior, incluye chrome), `order: [ids]` (z-order,
  último = arriba), `focused`.
- `place_new(id, content_rect, existing)` → cascada: `offset = 28px`, envolviento al
  agotar el hueco; nunca tapa por completo al anterior.
- `move_to / resize_to`: aplicar, **encajar** con
  `content_layout.gd::clamp_inside(content_rect, pos, size)` para que nada quede debajo
  del Frame; tamaño mínimo `MIN_W=320`, `MIN_H=240`.
- `snap_to_edges(rect, content_rect, magnet=12)`: imán a los bordes de la pantalla y a
  los de otras ventanas visibles (opuesto al modo tiled, aquí es sólo estético).
- `raise_(id)` / `focus(id)`: reordena `order`; las minimizadas no están en `rects`.
- `from_tiles(units, content_rect, focus)`: materializa el modo tiled a cascada.
- `to_row(rects, content_rect)`: orden de fila por `(centro_y, centro_x)` para volver a
  tiled.

El dibujo y el input usan `rects`; `shell.tiles` pasa a ser **el orden de la fila tiled**,
no la única geometría. En flotante, `_compute_slide_layout()` no se aplica: los `tile_rects`
se copian de `float_layout`.

## 5. Arrastrar entre modos (imán de reincorporación)

Modelo puro `shell/wm_drag.gd`:

- `drop_zone(pos, content_rect, frame_edges, over_block, mode)` →
  `{kind: "float"|"tile-left"|"tile-right"|"tile-top"|"tile-bottom"|"maximize"|"reincorporate", target}`.
- **Soltar sobre un borde/bloque del Frame** (franja superior/inferior o bloque) ⇒
  `reincorporate`: la ventana vuelve al modo tiled en esa posición (izquierda/derecha).
- **Tiled o maximizada arrastrada fuera de su celda** (más de `DRAG_OUT=40` px fuera de
  su `Rect2`) ⇒ se convierte en **flotante bajo el cursor** (centrada en el punto de
  agarre; si saldría del `content_rect`, se encaja).
- Desmaximizar (Alt+F10 o doble clic en la barra) en modo flotante ⇒ flotante del tamaño
  recordado (`restore_size`, por id).
- Esc cancela el arrastre y restituye; soltar fuera de todo en flotante conserva el lugar.

Estas decisiones salen **puras** (`wm_drag.gd`) para poder testearlas sin input real; el
Frame sólo aporta `pos`, `content_rect`, `frame_edges`, `over_block`.

## 6. Frame sin espacios intermedios

En modo WindowMaker los bloques del Frame van **pegados**, como el Clip/dock: `PAD = 0`
entre bloques (barra superior, dock inferior, pines, applets, "Compartido" y basurero),
manteniendo el bisel para separar visualmente. El ancho de la barra sigue saliendo de
`grid_unit`. No se duplica el layout: `frame.gd` sólo cambia el paso de las teselas
(`side + PAD` con `PAD=0`) y el punto de arranque.

## 7. BlockApp "Ventanas" (control del modo)

Bloque de control del Frame (borde inferior, junto a los applets; `APPLETS` de
`frame.gd`):

- Cara cuadrada `U×U` con glifo dibujado a mano (marco + barra de título) y etiqueta
  corta "VENT".
- Estado visible: **"Flotante"** / **"Tiled"** (texto corto + barra de estado); tooltip
  con el nombre largo.
- **Clic izquierdo** alterna de modo (equivale a la acción primaria del bloque).
- **Clic derecho** abre un menú WindowMaker (`menu_style.gd`) con: "Ventanas flotantes"
  (marcado si flotante), "Ventanas en mosaico", separador, "Acomodar ventanas"
  (re-cascada / re-fila). Equivalente de teclado: Enter/Espacio sobre el bloque
  seleccionado y flechas; se respeta el patrón K9 (los menús se abren con derecho).
- Nada de jerga: nunca "tiling", "layout", "WM"; se usa "mosaico"/"flotantes".

## 8. Impacto en Wayland / motor

- **No hace falta protocolo nuevo** para flotante/tiled: el shell ya posiciona y pide
  tamaño con `set_size`. El arrastre y el foco existentes sirven.
- Para que el cliente refleje **maximizado** (y no pelee con `set_size`) conviene exponer
  en `wl_server.c`/`wayland_compositor` los estados `xdg_toplevel.set_maximized` /
  `set_fullscreen` y sus `request` events (K13g). Es opcional en el primer corte; el
  shell puede seguir usando sólo `set_size`.
- El alto del chrome entra en `compositor.default_size` y en el `set_size` por ventana:
  el cliente recibe `content.size`, no `rect.size`.
- Se mantiene la regla de K12: el `content_rect` central es la caja de juego de todo
  (flotante, tiled, diálogos, maximizada).

## 9. Mockup textual (a validar)

1280×800, `U=80`, Frame revelado, bloques **pegados**, 3 ventanas flotantes:

```
┌────────────────────────────────────────────────────────────────────┐ ← borde superior pegado
│[⌂ Inicio][◍ Vecindario][▤ Terminal][▤ Editor][▤ Navegador]  [▓ basura]│
│                                                                    │
│  ┌───────────────────────────────┐                                 │
│  │ [–]      Editor         [x]   │  ← barra 20px, foco (azul)      │
│  ├───────────────────────────────┤                                 │
│  │                               │      ┌───────────────────────┐  │
│  │      contenido Editor         │      │ [–]   Navegador  [x]  │  │
│  │                               │      ├───────────────────────┤  │
│  └───────────────────────────────┘      │   contenido ...       │  │
│        ┌───────────────────────────┐    │                       │  │
│        │ [–]   Terminal     [x]    │    └───────────────────────┘  │
│        ├───────────────────────────┤                               │
│        │      contenido ...        │                               │
│        └───────────────────────────┘                               │
│                                                                    │
│[VENT Flotante] [◔ CPU][▥ RAM][⏱ Reloj][⌨ Teclado]     [Compartido]   │ ← bloques pegados
└────────────────────────────────────────────────────────────────────┘
```

Aceptación visual: sin leer texto se distingue la barra de título, el foco (barra azul),
minimizar/cerrar, y que las ventanas se solapan/flotan (no fila forzada). El Frame se
ve como una tira continua, no como teselas separadas.

## 10. Tareas implementables y delegables

Cada tarea: write set explícito, sin commit/deploy/ssh, tests propios + los de
`neighborhood_*`/`deskflow_*`/`gvd_session` verdes antes de cerrar.

### K13a — Modelo de modos + BlockApp "Ventanas"
- Modelo puro `shell/wm_mode.gd` (`extends Reference`): modo `"floating"|"tiled"`,
  parse/serialize de una línea, decisión de cambio, default `"floating"`.
- `shell/frame.gd`: registrar el applet "ventanas" (cara, estado, menú con
  `menu_style.gd`, clic izq alterna / der menú; teclado Enter/Espacio). Persistencia con
  el patrón de `_save_applets` (tmp+rename, sólo si cambió).
- Write set: `shell/wm_mode.gd`, `shell/frame.gd` (sólo registro/estado del applet).
- Tests: `tests/wm_mode_test.gd`, `tests/frame_menu_test.gd`.

### K13b — Chrome WindowMaker por ventana
- Modelo puro `shell/window_chrome.gd`: `chrome_rect(window, title_h, border)` →
  `{title, min_btn, close_btn, content}` y `hit(pos)` →
  `"title"|"min"|"close"|"left"|"right"|"top"|"bottom"|"tl"|"tr"|"bl"|"br"|""`.
- `shell/shell.gd`: reservar `TITLE_H` y borde al pedir `compositor.set_size`, dibujar
  chrome con la lista ImGui y usar `content` en `tile_fit`.
- Write set: `shell/window_chrome.gd`, `shell/shell.gd` (set_size + dibujo + fit).
- Tests: `tests/window_chrome_test.gd`.

### K13c — Modo flotante (colocación, z-order, cascada)
- Modelo puro `shell/float_layout.gd` (ver §4).
- `shell/shell.gd`: usar `float_layout` cuando el modo es flotante; foco/minimizar/
  cerrar/exposé reutilizados.
- Write set: `shell/float_layout.gd`, `shell/shell.gd` (colocación en flotante).
- Tests: `tests/float_layout_test.gd`.

### K13d — Arrastrar/soltar interno↔flotante + maximizar
- Modelo puro `shell/wm_drag.gd` (ver §5).
- `shell/shell.gd` + `shell/frame.gd`: conectar el drag de la barra/bordes, el drop sobre
  borde/bloque (reincorporar) y sobre el centro (flotante); doble clic en barra alterna
  maximizar/restaurar.
- Write set: `shell/wm_drag.gd`, `shell/shell.gd`, `shell/frame.gd` (sólo el drag).
- Tests: `tests/wm_drag_test.gd`.

### K13e — Frame sin espacios (Clip/dock)
- `shell/frame.gd`: `PAD=0` en el paso de teselas (barra, dock, pines, applets,
  Compartido, basurero) manteniendo bisel; sin cambiar el modelo.
- Write set: `shell/frame.gd`.
- Tests: `tests/wm_frame_gap_test.gd` (paso/layout puro) + `tests/frame_driver.py`.

### K13f — Persistencia y vocabulario
- Persistir el modo entre sesiones (patrón atómico existente) y revisar tooltips/estados
  en español; ítems internos sólo con `GDTK_DEBUG`.
- Write set: `shell/wm_mode.gd`, `shell/frame.gd`, `shell/shell.gd` (sólo textos/estado).
- Tests: `tests/wm_mode_test.gd`, `tests/wm_vocab_test.gd` (no aparecen términos internos).

### K13g — (Opcional, motor) maximizado/fullscreen en el compositor
- `modules/wayland/wl_server.{c,h}`, `wayland_compositor.{h,cpp}`: exponer
  `set_maximized`/`set_fullscreen` y los `request` del cliente para sincronizar el estado.
- Write set: `modules/wayland/*`. **No recompilar ni desplegar** en K13; sólo diseño de
  parche y notas, o implementarlo cuando se pida explícitamente.
- Tests: si existe prueba del módulo; si no, compilar en local, sin deploy.

## 11. Riesgos y no-objetivos

- **No** se toca `wl_server.c` en el primer corte salvo K13g explícita; el modo flotante
  se apoya en `set_size`/`get_layers` ya existentes.
- **No** se cambia el vocabulario ni se muestran nombres internos (`gvd`, `deskflow`,
  mDNS, `recv`, etc.).
- **No** se bloquea `_process`/`_draw`: la colocación es pura y las escrituras de
  persistencia van en `Thread`/tmp+rename, como `_save_applets`.
- **No** se duplica el layout: `_units()` sigue siendo la fuente en tiled; `float_layout`
  es la fuente en flotante.
- Los diálogos (SPEC-windows.md) siguen centrándose dentro de `content_rect`; el chrome
  no los afecta.
- El `snap` a bordes en flotante es estético y no reemplaza el imán de `screen_layout.gd`
  (K11b), que sigue siendo la fuente de `host_directions`.

## 12. Criterios de aceptación de K13

1. Este documento existe y describe: modo flotante por defecto, tiled alternativo,
   BlockApp "Ventanas", chrome WindowMaker medido, bloque sin huecos, drag
   interno↔flotante, mockup y lista K13a…K13g con write sets y tests.
2. Ningún término del vocabulario prohibido aparece en la UI descrita.
3. Ninguna implementación se agrega en esta entrega (sólo el `.md`).
