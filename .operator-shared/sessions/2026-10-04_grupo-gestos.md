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
- N11 ✔ (cb0c1bc): un solo apilado flotantes+tiled (`z_stack` por clic/foco, `z_order_now` para dibujo y hit-test;
  `_chrome_pick` corta en una tiled elevada). Desplegado 3246ad1+cb0c1bc a los 3 hosts (shell md5 97702fdb),
  tengu/cupid reiniciados sanos; cupid responde con terminal abierta (RPC peor 0.14 s).

## Mañana 2026-10-04 (~10:00–10:20)
- DockApp: con sólo la barra superior fijada no se veía (vivía en el dock inferior oculto) → frame.gd la dibuja al final
  del tramo de ventanas de arriba (2f552dd). `shell.deskflow_input_sessions()` (f79e507) da los pares por el servicio global.
- Deskflow duplicado en cupid: `autostart.sh` lanzaba `org.deskflow.deskflow.desktop` (app gráfica) que arrancaba su
  propio deskflow-core con otra config. Ahora se salta (2f552dd). El supervisor ya mataba deskflow-core al terminar el
  shell; verificado en cupid: tras reiniciar el shell queda un solo core nuevo.
- Puntero atrapado en cupid (intermitente): liberado matando el cliente de cupid. Sin causa confirmada: el servidor de
  bastion se relanzó 10:15:09 y luego sólo conectó tengu; a las 10:16 cupid entra/sale normal. Diagnóstico listo:
  `[cursor]` en shell.log de cupid + enter/leave en /run/user/1000/gdtk-deskflow.log de ambos. Escape: Ctrl+Alt+Esc
  (sway, en el equipo que controla) mata deskflow-core.
- tengu.local no resuelve por mDNS esta mañana: tengu SIN deployar 3246ad1..2f552dd.
- Corrección: matar el cliente de cupid NO liberó el puntero de bastion; se liberó matando deskflow-core en bastion.
  Causa probable: el servidor no pidió Release al caerse el destino. Fix 44cb7cc: `RemoteInput.release_capture()`
  (eis_server.c) + vigía `_deskflow_watch` (shell, 1/s sólo con captura): destino del último switch caído, o servidor
  "en local" dos chequeos seguidos → suelta. Log de Deskflow es por línea (mtime = última línea), sin falsos positivos
  por buffer. Binario 4af2803b en bastion y cupid (cupid sin reiniciar a propósito: bastion aún corre el viejo).
- cupid no recibía el mouse: el servidor escuchaba sólo IPv4 y el mDNS resolvía bastion.local sólo a IPv6 →
  `interface=::` en deskflow_settings.build_server_settings (0f2221e); ini vivo de bastion parcheado, cupid y tengu
  conectan por IPv6. tengu desplegado por IP (192.168.18.163; tengu.local no resuelve).
- En curso: (a) DockApp como token real arrastrable + `_next_free_slot` único (agente, frame.gd); (b) lead: señal
  `RemoteInput.remote_left` (stop_emulating) → shell oculta el puntero (`remote_cursor_parked`) hasta el próximo
  motion local (>200 ms). Falta compilar/desplegar (cambió remote_input.cpp).
- Nota del usuario: sesión /polish → delegar en subagentes Kilo cuando se pueda (tools/kilo-launch.sh).
- 5dd4c3e: dockapp = token `s:sharing` (agente; `_place_new_token`/`next_free_slot` único, también para applets;
  dibujo radial en coords de pantalla) + `RemoteInput.remote_left` → puntero oculto hasta motion local. Binario
  b9115026 en los 3 hosts (tengu por IP); tengu/cupid reiniciados sanos. Bastion: reiniciar sesión para el binario.
- Vigía Deskflow dispara seguido en uso real: "volvió a este equipo sin soltar" = borde con barrera tocado, Release
  ignorado (ventana 250 ms) y Deskflow no cruzó (tramo sin vínculo) → captura trabada; ahora rescate cada 300 ms
  (aa56e8c). ✔ Raíz f27ee80: Release ignorado queda pendiente; motion físico hacia adentro >24 px (sin adentrarse >40 px, <1,5 s) lo aplica. Binario 3f6cf649 en los 3 (clientes sin reiniciar: el cambio actúa en el servidor).
