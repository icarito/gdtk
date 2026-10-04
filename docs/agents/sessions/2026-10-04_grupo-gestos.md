# Sesión /polish — Grupo, Vecindario y cadena vertical (2026-10-04, madrugada)

Base: 81fbb6f. Anterior: 2026-10-03_ventanas.md, 2026-10-04_cuelgue-cursor.md.

| # | Pedido | Ancla | Ejecutor | Estado |
|---|---|---|---|---|
| N1 | Grupo/Vecindario retienen el foco al pasar a una app (teclado muerto) | shell.gd `_focus_tile` no bajaba zoom; `neighborhood_view` descartaba teclas (~8746) | lead | ✔ `_focus_tile` → `_set_zoom(0)` + zoom_f=0; compuerta sólo si no hay app al frente |
| N2 | Vecindario sin ítems Bluetooth | neighborhood_ui.gd ~168 `MAP.bt_dots` | agente G | ✔ |
| N3 | Grupo sólo BT al alcance | group_model.gd `members` | agente G | ✔ |
| N4 | BT distribuidos espacialmente | group_model.gd `group_layout`/`_settle` | agente G | ✔ |
| N5 | Drag&drop 360° alrededor del equipo local → disposición de Pantallas | neighborhood_ui.gd ~635-649 (`MAP.drag_direction` → `_set_host_direction`), screen_layout.gd, settings/pages/displays.gd | agente G + hook lead | ✔ |
| N6 | Hogar fuera de los costados; arriba: exposé → Hogar → Apps | shell.gd `_pan_limits`, `_snap_pan`, `_swipe_start` | lead | ✔ cadena vertical |
| N7 | Abajo desde la pantalla: Grupo → Vecindario | swipe_model `vertical_levels/pos/target` (+test), shell `_vlevel/_apply_vlevel/_swipe_vchain/_swipe_vchain_end` | lead | ✔ |
| N8 | Submenú en íconos de pares: Extender mi pantalla / Compartir teclado y mouse | neighborhood_ui.gd `_group_toggle_items` ~377 | agente G | ✔ |
| N9 | Grupo refleja relaciones | neighborhood_ui.gd (conectores) | agente G | ✔ |
| N10 | DockApp radial de estado (controlando/controlado/foco/pantalla extendida) | shared_block.gd + frame.gd `_draw_shared*` | agente D | ✔ |

Decisión del lead (N5): soltar SÓLO acomoda (persiste ángulo → lado+offset para Pantallas); las acciones van por el submenú (N8).
Cadena vertical: -2 Vecindario, -1 Grupo, 0 pantalla, 1 exposé, 2 Hogar, 3 Apps; sólo pantalla↔exposé es continuo (scrub),
el resto cambia al cruzar la mitad de cada tramo; sin ventanas se saltan 0 y 1. Paneo horizontal: sin Hogar en los extremos.

## Cierre (2026-10-04)
- Agente G: screen_layout `placement_from_angle/angle_from_placement/offset_px`; group_model `bt_in_range`, `placements`,
  `links`, anillo de pares + anillo exterior BT; neighborhood_directions conserva `along`; neighborhood_ui arrastre 360°
  (`_apply_group_placement`), clic → submenú, conectores con glifos/estado/flecha; displays.gd usa `along`.
- Agente D: shared_block `radial()` + `focus_text()`; frame dibuja la dockapp radial.
- Lead: hooks `_set_host_placement(hid, side, along)` y `group_placements` (en `_refresh_direction_views`).
- Pendiente: proveedor BT (neighborhood.gd `_read_bt`) sólo pone rssi a conectados → el Grupo hoy muestra sólo BT
  conectados; para "al alcance" hace falta rssi/seen de pareados cercanos. Foco remoto: falta `capture_peer`
  (hacia qué equipo va la captura) y `controlled_by` (si nos controlan ahora); la dockapp marca sólo que hay captura.
- Ojo: el agente G hizo `git stash`/`pop` sobre el árbol con trabajo ajeno sin commit (se restauró bien). No repetir.
