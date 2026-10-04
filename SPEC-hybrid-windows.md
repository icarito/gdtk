# SPEC — Gestión híbrida de ventanas (flotante + mosaico por ventana)

Estado: **implementado** (modelos puros + integración en `shell.gd`/`frame.gd`/
`remote.gd`). Este documento supersede la premisa y el modo **global** de
`SPEC-wm-mode.md`: acá el modo es **por ventana** y las flotantes van **ancladas a su
pantalla**. El vocabulario visible es **Flotante**, **Mosaico** y **Escritorio**.

## 0. Corrección de la premisa (research vs gdtk real)

| Research (Sway) | gdtk real |
|---|---|
| Árbol de contenedores Sway + IPC | `wm_units` (registro de unidades) + `_split_rects()` (modelo propio) |
| `floating enable` / `splith` / `layout tabbed` | `hybrid` (modo por ventana) + `wm_units` (eje) |
| workspace_id | "pantallas" (unidades) + ranura **Escritorio** + ranura Hogar |
| `container_id` | ids enteros de toplevel (nunca títulos) |

Las apps son `xdg_toplevel` del compositor embebido (`modules/wayland/wl_server.c`),
no clientes de Sway: no hay IPC de Sway ni que manipular. **Sin cambios de engine.**

## 1. Decisiones fijadas

1. Estructura tiled: fila de pantallas + unidades (grupos) como el árbol.
2. **Modo por ventana** (`"floating"` | `"tiled"`), no global. Default: `floating`.
3. Flotantes **ancladas a su pantalla**: se dibujan sólo sobre su unidad y panean con ella.
4. **Escritorio** (índice 0) fijo al inicio de la fila: ranura virtual sin miembro tiled
   que aloja sus flotantes; entra en navegación y exposé.
5. v1: mitades (izq/der) + maximizar. Sin cuadrantes ni pestañas.
6. Eje según orientación: el área útil manda el default (portrait → filas/Y, landscape →
   columnas/X). El borde elegido fija el eje (izq/der → X, arriba/abajo → Y; arriba =
   maximizar).
7. Snap de borde contextual: si la pantalla centrada tiene miembro tiled → inserta en
   mosaico; si no → resize flotante a media pantalla. Arriba = maximizar.
8. El bloque "Ventanas" del Frame se elimina: el modo se cambia por snap, atajos y menú
   contextual de la barra de título (clic derecho).
9. Sin reglas de apertura por app en v1 (todo flota por default; diálogos ya flotan).
10. Capa de comandos: método remoto estable `wm {action, id?, dir?}`, sin parser `hybrid`.
11. Vocabulario visible: "Escritorio", "Mosaico", "Flotante". Nada de tiling/target/
    container/hid/deskflow en UI.
12. **Auto-fusión**: si al snapear media pantalla queda otra flotante de la misma
    pantalla en el lado complementario (mismo alto, lado a lado), ambas pasan a
    mosaico conservando la proporción del snap (pesos por ancho). Con una sola
    ventana no se fusiona: sigue flotante a media pantalla. Así la vista partida
    siempre es mosaico (no se ven dos chromes flotantes en split) y aparece el asa
    de frontera.
13. Asa de mover CSD: deja de ir centrada; se corre ~1 bloque de rejilla (`grid_unit`)
    del borde izquierdo (`window_chrome.move_grip_rect(..., inset)`), tanto al dibujar
    (`window_deco`) como al detectar el hover/click (`shell._update_csd_hover`,
    `shell._chrome_pick`).
14. Los bloques del Frame reflejan la fusión: las ventanas de una misma pantalla
    tiled van pegadas (sin hueco), comparten número y llevan una placa que las une;
    la ranura Escritorio (sin miembros) no se numera.

## 2. Modelos puros

### `shell/wm_hybrid.gd` (`extends Reference`)
Estado por ventana:

    { id -> {"mode": "floating"|"tiled", "anchor": int, "float_rect": Rect2|null} }

- `anchor`: `0` = **Escritorio**; si no, el **id-líder** de la unidad tiled de la fila
  (los ids reales son > 0). Guardar el líder (no el índice) sobrevive a reordenar la fila.
- API: `mode(id)`, `is_floating(id)`, `anchor(id)`, `float_rect(id, fallback)`,
  `set_floating(id, anchor, rect)`, `set_tiled(id, anchor)`, `set_mode`, `reanchor`,
  `set_float_rect`, `forget`, `ensure`, `serialize()/parse()`, `run_selftest()`.
- Test: `tests/wm_hybrid_test.gd`.

### `shell/wm_units.gd` (`extends Reference`)
Registro de unidades tiled con eje; reemplaza el par `groups` + `split_weight`:

    [ {"id": leader, "members": [ids], "axis": "x"|"y", "weights": {id: float}} ]

- `axis "x"`: columnas (ancho); `axis "y"`: filas (alto).
- `default_axis(area)` = `"y"` si `area.size.y > area.size.x` (portrait), si no `"x"`.
- Ops: `solo`, `join(units, id, target, side)`, `remove`, `move_unit`, `swap`,
  `member_rects(unit, area, gap)`, `serialize/parse`, `from_legacy(tiles, groups,
  weights, area)`.
- Test: `tests/wm_units_test.gd`.

### `shell/wm_drag.gd`
- `edge_zone(pos, box, thr)` / `snap_rect(zone, box)` (ya existentes).
- `hybrid_target(pos, box, has_tiled_member, thr)` → `{kind, dir, zone}` con
  `kind ∈ {"float-half","tile-half","maximize"}`.
- `zone_hold(prev, pos, box, thr, hold=ZONE_HOLD)` → conserva la zona hasta
  `thr + 16 px` (histéresis; evita parpadeo del preview).

## 3. Shell (`shell/shell.gd`)

- `hybrid` = `WM_HYBRID.new()`; `wm_units` = registro. `is_floating(id = -1)` es por
  ventana (sin id: la enfocada). Ya no existe `wm_mode` global.
- `_units()` = `[Escritorio]` + unidades tiled en orden de `tiles` + ranura Hogar como
  slot final (`units.size()`). Las flotantes **no** forman unidad: se saltan y se
  dibujan ancladas.
- `_group_of(id)`/`_weight(id)` son accessors de compatibilidad sobre `wm_units`.
- `_compute_slide_layout()` dibuja la fila (unidades tiled por eje) y luego
  `_compute_float_layout(cr, units, s)`: `float_layout` guarda rects **locales** (los de
  la pantalla centrada) y se les suma `(anchor_index - s) * vp.x`. Fuera de la pantalla
  centrada no se dibujan (la visibilidad la resuelve `_update_tile`).
- Snap al soltar (`_commit_chrome_drag`): `maximize` → `_maximize_window`; `tile-half` →
  `_snap_tile_to` (inserta en la unidad centrada); `float-half` → resize flotante y,
  si hay otra flotante en el lado complementario, `_maybe_fuse_snapped_floats` →
  `_fuse_floats` (unidad con pesos ∝ ancho). `_float_half` (teclado) hace lo mismo.
- Menú contextual de la barra de título (`_draw_window_menu`, clic derecho): Flotante /
  Mosaico / Maximizar-Restaurar / Cerrar.
- Persistencia (`_save_layout`/`_adopt_windows`): escribe `units` (serializado) y
  `hybrid`; migra layouts viejos `{groups, weights}` con `WM_UNITS.from_legacy` (eje por
  orientación). La recarga en caliente conserva modo/ancla/rect de cada ventana; la
  geometría **no** sobrevive a la muerte del proceso (contrato ya existente).
- Exposé: cada unidad (incluido Escritorio) es una miniatura; las flotantes de esa
  pantalla entran en su tarjeta en su posición local real.

## 4. Atajos (frame.gd)

Se conservan Alt+M/F10/F11/W, Alt+Tab, Ctrl+Alt+←/→ (foco), Ctrl+Alt+Shift+←/→ (swap),
Super+W/M/T/P/F6 y Super+←/→ (tilear mitad / foco en el Hogar). Nuevos:

- `Super+Shift+Space` — alterna Flotante/Mosaico de la ventana enfocada.
- `Super+↑` maximiza; `Super+↓` restaura a flotante.
- `Super+F` maximiza/restaura (alias de Alt+F10).
- `Super+H/J/K/L` foco entre pantallas; `Super+Shift+H/L` intercambia la pantalla.

## 5. Control remoto (`remote.gd`)

- `wm {action: toggle|float|tile|maximize|arrange|focus|move|anchor, id?, dir?}`.
- `state` agrega `mode` y `anchor` por ventana, y `units`/`modes` (reemplazan `groups`).

## 6. Validación

- Tests puros: `wm_units_test`, `wm_hybrid_test`, `wm_drag_test` (targets + histéresis),
  `float_layout_test`, `wm_mode_test`, `frame_menu_test`, `expose_layout_test`.
- Con binario instalado (clases nativas): `ring_frame_test`, `window_chrome_test`,
  `input_capture_cursor_test`.
- Parseo de scripts tocados con `~/gdtk/bin/godot-gdtk` (ver `tests/parse_check.gd`).
- Sincronizar a `~/gdtk` (`rsync -a --exclude '.import' shell settings session ~/gdtk/`).

## 7. Fuera de alcance

Cuadrantes 2×2 (unidades anidables), pestañas, reglas de apertura por app, eje manual
por unidad, y los estados `set_maximized`/`set_fullscreen` del `xdg_toplevel` en el motor.
