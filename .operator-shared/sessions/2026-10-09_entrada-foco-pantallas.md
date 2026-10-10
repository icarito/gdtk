# Sesión 2026-10-09 — Entrada, foco y cambio de pantalla

Sesión /polish incremental. Observaciones sueltas del usuario, consolidadas y ancladas.
Estado: **planeado**, sin código nuevo. Ancestro: observar `AGENTS.md` (editar sólo en el
repo, sincronizar a `~/gdtk`, no recargar con VS Code/Kilo abierto).

## Items

- **A — Diálogos detrás de ventanas tiled/maximizadas.** *Backlog* (el usuario pidió
  investigar). Ver `.operator-shared/plans/tech-debt.md` sección **B.3**.
- **B — Grilla de apps en la pantalla del puntero.** En exposé, al teclear debe abrirse
  la **grilla de apps** (`apps.gd`) en la pantalla/salida donde está el puntero; hoy sólo
  en la central/principal.
- **C1 — Super+Tab** para cambiar de pantalla.
- **C2 — Destello del cursor** (onda breve ~0.5 s) al cambiar de pantalla y en exposé.
- **D1 — Cursor de resize pegado** que deja el Frame.
- **D2 — El Frame no debería recibir focus.** (Definición pendiente del usuario.)
- **D3 — Alt+Tab filtra el Alt a la ventana** (Firefox abre el menú).
- **D4 — Focus-follows-mouse no debe robar** el foco recién dado por Alt+Tab.
- **E — Al cerrar flotante/diálogo volver al padre**, no saltar a otro workspace.
- **F — Click fantasma con el Frame invisible (click izquierdo).** Persiste pese al
  brief previo (`.operator-shared/briefs/2026-10-07-K1-frame.txt` ítem 1, ya aplicado:
  `_clear_zone_layout`, `frame.gd:4715`). Hay otro camino que come el clic.
- **G — Un píxel entre el Frame con autohide y el borde de la pantalla.** Persiste.

## Ánclas

- **B**: teclado en exposé → `_go_home()`+`apps_view`+`apps.type()` (`shell.gd:12535-12544`);
  grilla `apps.draw` (`apps.gd:477-567`); dibujo `_draw_apps` con offset 0 (`shell.gd:5338-5343`);
  Hogar al final de la fila (`_row_s`, `shell.gd:2061`); salida bajo puntero
  `_expose_unit_at` (`shell.gd:2391`); salidas span `span_out_layout` (`shell.gd:1665`).
  Nota: Hogar/Exposé "viven sólo en la principal" (SPEC-physical-multi-monitor §1) → esto
  es un avance de v2.
- **C1**: paneo discreto `_pan_by` (`shell.gd:3394`), `_snap_pan` (`shell.gd:3614`),
  `_focus_unit` (`shell.gd:3865`); Tab sin modificador alterna Anillo/Grilla
  (`shell.gd:4460`); zona Super+tecla en `frame.gd:_input` (`frame.gd:3119`).
- **C2**: `focus_flash` de ventana (`shell.gd:559`,`3311`); cursor fallback
  `_make_eis_cursor` (`shell.gd:12926`); estado/visibilidad `_apply_client_cursor_state`
  (`shell.gd:12268`) y `_on_remote_left`/`remote_cursor_parked` (`shell.gd:12293`).
- **D1**: `_apply_cursor` (`shell.gd:11776`), `_cursor_for_part` (`shell.gd:11757`),
  `_reset_cursor` (`shell.gd:11829`); chrome `WINDOW_CHROME`/`_chrome_pick` (`shell.gd:1122`).
- **D3**: Alt+Tab → `cycle()` + `_gulp(KEY_TAB)` (`frame.gd:3241-3257`); el Alt ya llegó
  a la app. `swallowed`/`_gulp` (`frame.gd:130`,`2666`).
- **D4**: FFM puro `focus_follow.decide/dwell` (`focus_follow.gd`), aplicado en
  `_focus_follow` (`shell.gd:11996-12016`).
- **E**: `_on_toplevel_removed` (`shell.gd:11276`), foco al cerrar
  (`shell.gd:11333-11344`), diálogos `_refocus_dialog` (`shell.gd:11348`), memoria por
  pantalla `unit_focus` (`shell.gd:3313`).

## Decisiones del usuario

- A → backlog, sólo investigar.
- B → es la **grilla de apps**; se busca/abre en la pantalla del puntero.
- C2 → **onda breve de ~medio segundo** en la posición del puntero; "sorprendeme" con
  el diseño (onda/halo que expande y se desvanece).
- D2 → el **focus-follows-mouse no debe seleccionar el Frame** (al pasar por la barra
  no debe cambiar el foco).
- D3 → **sí**: bufferear Alt y reenviarlo sólo si fue tap (sin combo Alt+Tab).
- E → **probemos** el enfoque propuesto (volver a la pantalla/workspace previa).

## Preguntas abiertas

- **F/G**: reproducir el camino que queda. F: el fix K1 limpió `bar_layout`/
  `window_region`/`window_span`, pero el clic fantasma persiste → revisar ImGui
  `##frame`/rects stale, `_applet_at`, `_shared_at`, y el orden `frame._input` vs
  ImGuiCanvas. G: revisar `frame_bar_h` (entero) vs el offset del slide y el dibujo del
  fondo/bisel pegado al borde.
- **B**: confirmar si la pantalla del puntero es la **salida física** (span) o la
  **unidad/workspace** de exposé.

## Ownership (archivos disjuntos)

- `frame.gd`: C1, D2, D3.
- `shell.gd` (cursor): D1, C2.
- `shell.gd` (foco/cierre): D4, E.
- `shell.gd` (grilla/exposé): B.

Los tres últimos comparten `shell.gd` ⇒ **serializar** (o un solo agente por tanda).

## Próximos pasos

1. Cerrar preguntas 1-3.
2. Briefs por cluster (frame.gd y bloques de shell.gd serializados).
3. Tests puntuales por área; no recargar el shell principal (VS Code/Kilo abiertos).

## Tanda 1 (hecha, revisada)

- **frame.gd** — C1 (Super+Tab → `_focus_dir`, `frame.gd:3233`) y D3 (Alt retenido como
  Super: `alt_press`+`_alt_used/_alt_combo/_is_alt_combo`; flush en Alt+clic agregado en
  revisión, `frame.gd:2768`). Verificado: `PARSE_OK`, `frame_menu_test` 22/22 ok.
- **shell.gd** — D1 (resets de cursor en chrome drag/minimize/remove + guarda en
  `_process`, `_over_frame_bar`), C2 (ripple `RIPPLE_MS=500` en `_focus_unit`/`_snap_pan`/
  `_toggle_expose`), D2 (FFM ignora la banda del Frame). Revisado: guard
  `_client_cursor_applied`/`shape != ARROW` para no re-setear por vuelta. `PARSE_OK`.

## Tanda 2 (hecha, revisada)

Un subagente (shell.gd + frame.gd): **D4** (`ffm_suppress_until`/`FFM_KEYBOARD_GRACE_MS=700`,
`_keyboard_focus_grace` desde `_focus_dir` y `frame.cycle`; `_focus_follow` early-return) y
**E** (`focus_parent` recordado al enfocar flotante y restaurado al cerrarla si sigue vivo:
`_can_restore_focus`). Verificado: `PARSE_OK` shell.gd+frame.gd.

## Entrega (hecha)

Cambios sólo de scripts (`shell/frame.gd`, `shell/shell.gd`). **Sin commit** (no pedido).

- **bastion** (1920x1080 landscape): rsync a `~/gdtk` (md5 igual) + `reload_shell` por el
  control local (:7777). Mismo PID (124811), state responde, ventanas Alacritty(10) y
  Firefox(13) vivas.
- **tengu.local** (1280x800 landscape): rsync directo de `shell`/`settings`/`session` a
  `~/gdtk` (md5 igual) + `reload_shell`. Mismo PID (2855).
- **cupid.local** (1440x2160 **portrait**): idem. Mismo PID (968), ventana Thorium viva.

No se corrió `deploy.sh` (compila engine; innecesario para cambios sólo de scripts).

Pendiente: **B** (grilla de apps en la pantalla del puntero), **D2/D4/E** verificados sólo por
parseo+modelo (falta prueba viva), **F/G** (reproducir).

## Tanda 3 (hecha, desplegada)

- **F — clic fantasma del Frame oculto** (`frame.gd`): `_zone_at()` con guard `not drawn`
  (`frame.gd:1464`); `drop_mouse_interaction()` limpia `_win_pick/_win_close/_win_min` y
  `applets_bar_rect` (`frame.gd:2758`).
- **G — 1 px entre el Frame y el borde** (`frame.gd` `_slide`): al ocultar, se empuja la
  barra 1 px más allá del canto.
- **B**: el usuario confirmó que **ya hace lo que quería** (no requiere cambio extra).

Verificado: `PARSE_OK`, `frame_menu_test` 22/22. Desplegado y recargado en bastion,
tengu.local y cupid.local (md5 `6c262e6e…`, mismo PID).

## Estado final

- **Hecho y desplegado**: C1, C2, D1, D2, D3, D4, E, F, G.
- **B**: funcionando (confirmado por el usuario).
- **A**: en backlog (`.operator-shared/plans/tech-debt.md` §B.3, diálogos detrás).
- Sin commit (no fue pedido).

## F/G — seguimiento (2026-10-09 noche)

- **F (clic fantasma del Frame oculto)**: causa real (reporte del usuario: **clic derecho
  fantasma sobre la barra inferior**). Con la barra superior fijada, `applets_drawn` era
  true y `_applet_bar_at` devolvía true para **ambas** franjas (incluida la inferior
  oculta) → el clic derecho abría el selector de Controles. Igual `_zone_at` devolvía
  "dock" por el `drawn` global. Fix: `_zone_at`/`_applet_bar_at` ahora usan el estado
  **por franja** (`bar_top_drawn`/`bar_bottom_drawn`). Desplegado. **Confirmado resuelto
  por el usuario (2026-10-10 00:14).**
- **G (1 px entre el Frame y el borde)**: causa raíz con evidencia. `canvas_transform`
  es identidad y `position` (0,0); las ventanas Godot (`CanvasLayer`) llegan al borde,
  pero el contenido **ImGui** deja 1 px en top/left donde asoma `default_clear_color
  (0.1,0.1,0.12)`. El clip interno de la ventana ImGui (`WindowBorderSize=1`) recorta el
  fondo dibujado en (0,0). El motor **no expone** `STYLE_VAR_WINDOW_BORDER_SIZE`, así que
  el workaround en scripts es limitado; conviene exponerlo/forzarlo a 0 en el engine.

## H — demora al abrir popups (investigación)

- Los popups son ImGui y sólo aparecen cuando el shell **rearama** el frame ImGui. La
  cadencia la fija `update_hz=4` en reposo, `input_hz=60` sólo mientras
  `last_input_usec` es reciente (<250 ms, seteado en `ImGuiCanvas::_input`), o un
  `request_redraw()` puntual (fuerza un build en el próximo `_process`).
- Medido en bastion: armado de ImGui ≈ **5.4 ms** (`_imgui_us/_imgui_n`); builds de
  ImGui en reposo ≈ **4–5/s**; loop del motor medido ≈ **11–12 fps** (a confirmar; el
  `low_processor_mode_sleep_usec=16000` debería dar más).
- Huecos encontrados y corregidos:
  - `wm_menu_want` (menú de ventana, `frame.gd:2909`) **no** llamaba `request_redraw`
    → podía esperar el tick de `update_hz` (~250 ms). Agregado.
  - Popups con auto-resize pueden verse mal un frame; se agregó un `request_redraw()`
    de asiento tras cada `open_popup` (frame.gd shared/applets; shell.gd home_session/
    wifi_psk/wm_menu).
- Pendiente de confirmar: si el input real arma el boost de 60 Hz (`last_input_usec`);
  y si el loop a ~11 fps es real (posible techo de latencia ~90 ms por frame).
  Opción si se quiere más respuesta: subir `update_hz` mientras hay un popup abierto.

### H — causa raíz y fix (los popups que molestan son los de las apps, no ImGui)

Un popup de una app (`xdg_popup`/subsurface, p. ej. menú contextual de Firefox) **agrega
una capa** al árbol del toplevel. Su commit entra por el camino liviano
(`compositor.commit_count` cambia → `_present_commit` → `view.update()` +
`send_frame_callbacks`), que **no crea nodos** para capas nuevas, y **no hay señal** de
cambio de capas por toplevel (la `layers_changed` del compositor es de layer-shell, no de
esto). Resultado: el popup quedaba invisible hasta el próximo frame completo → tick de
`update_hz=4` en reposo (hasta ~250 ms).

Fix (`shell.gd`): cachear `layer_counts[id]` en `_update_tile` y, en `_present_commit`,
si el conteo de capas de alguna ventana cambió, escalar a frame completo
(`request_redraw`). Desplegado en los tres hosts.

Nota: también se corrigió que `wm_menu_want` no pedía `request_redraw` y se agregó un
frame de asiento tras cada `open_popup` de ImGui (popups del shell que se veían mal un
frame).

## I — cierre forzado de ventanas con diálogo de guardado (hecho)

`_close_window_id` mandaba el close educado y agendaba un force-close a los **700 ms**
(`_poll_force_close` → `_force_close_window_id` → `compositor.forget`), así que una app
que abría un diálogo de "guardar cambios" se destruía igual.

Fix (`shell.gd`): el primer cierre es educado y **sin timeout** (la app puede preguntar y
quedarse); un **segundo** cierre seguido sobre la misma ventana (dentro de
`CLOSE_REASK_MS=1500`) fuerza. `_poll_force_close` sólo poda pedidos vencidos;
`_on_toplevel_removed` limpia el pedido. Desplegado en los tres hosts.
