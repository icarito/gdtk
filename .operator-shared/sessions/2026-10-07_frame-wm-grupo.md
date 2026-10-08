# Sesión 2026-10-07 — Frame, WM, exposé de grupo, dockapps (/polish)

Plan completo: items B1-B6, T1-T2, F1-F5 (anclados a archivo:línea) en el plan de la sesión;
resumen acá. Base: trabajo SIN COMMITEAR de 2026-10-06 (popup layout) en shell.gd,
screen_layout.gd, displays.gd — no revertir.

## Decisiones del usuario
- F2 ventanas: recarga (guardar flotantes/z-order) + reapertura por app_id+título en
  ~/.config/gdtk/windows.json; NO relanzar apps.
- Radar (Compartiendo): quitar etiquetas de host; nombre sólo en tooltip.
- Hover: dwell 250 ms; tiled nunca se elevan sobre flotantes por hover.

## Ola 1 (en curso)
| Agente | Items | Write set | Estado |
|---|---|---|---|
| Kilo polish-K1-frame | B1 franjas, B5 scroll+radar, T1 rueda, F3 menú desde bloque | shell/frame.gd | corriendo |
| Kilo polish-K2-volume | F4 módulo | applet_volume.gd (nuevo), audio_send.gd, tests/applet_volume_test.gd | corriendo |
| Kilo polish-K3-clip | F5 módulo | applet_clipboard.gd, tests/applet_clipboard_history_test.gd | corriendo |
| Sonnet S1 | B4 raise, B3 divisor, B6 zoom lateral | shell.gd, focus_follow.gd, tiles_ui.gd | HECHO: focus_follow 13 ok, expose_layout 60 ok, parseo ok; falta visual |
| Lead | B2 cursor: diagnóstico | — | esperando video del usuario |

Briefs: .operator-shared/briefs/2026-10-07-K{1,2,3}-*.txt. Logs Kilo: /tmp/kilo-gdtk/polish-*.jsonl.

## Ola 2 (pendiente)
- Kilo K4: T2 slots anclados al costado (shell/bar_slots.gd puro + test) + registro/popups
  de volumen y portapapeles en frame.gd.
- Sonnet S2 (LANZADO adelantado, shell.gd libre): F1 exposé universal (peer_link METHODS + peer_control match + _expose_sync_poll),
  F2 ventanas, fix B2 si es script.

## B2 cursor — hallazgos
- Binario instalado (06-oct) ya trae c1b594e (no resetear cursor entre subsurfaces).
- Script: _on_client_cursor_hidden → _apply_client_cursor_state → MOUSE_MODE_HIDDEN. En papel
  correcto. Falta evidencia: con video fullscreen, RPC state.cursor.{mode,client_hidden}.
  Si client_hidden=false → la app no manda set_cursor(NULL) (¿usa cursor_shape?) → engine.

## S1 hecho (falta prueba visual)
- B4: focus_follow.HOVER_DWELL_MS=250 + dwell() puro; shell hover_pend/hover_hit, _process
  reevalúa; _raise_popup_owners salta tiled que no estén en z_stack (elevadas por click).
- B3: shell.float_frames(); tiles_ui parte la línea bajo flotantes; _handle_at ignora asa
  bajo flotante.
- B6: _apply_vlevel nivel 0 desde Hogar = _focus_unit directo (sin _start_home_leave);
  _seed_view_anim desde Hogar siembra rects centrados al 30%.

## S2 hecho (falta prueba en vivo, 2 hosts)
- F1: peer_link METHODS += "expose"; peer_control caso "expose" → shell._peer_expose;
  shell._group_targets() (extraído de _clip_sync_poll), _expose_sync_poll (no envía en
  swipe SEG), _peer_expose setea _expose_sent antes (sin eco).
- F2: shell/window_memory.gd (puro, test 15 ok). Recarga: _save_layout/_adopt_windows
  guardan float_memory, float_layout.order, z_stack, wm_maximized. Restart:
  ~/.config/gdtk/windows.json cada 5 s si cambió; _wmem_apply al mapear toplevel nuevo.
  No guarda unidad/ancla (vuelve al escritorio actual).

## K2/K3 hechos
- applet_volume.gd (test 9 ok) + audio_send.parse_sinks; applet_clipboard items/pick
  (test 12 ok). Falta registro en frame.gd → K4 (brief 2026-10-07-K4-frame-slots.txt).

## B7 (nuevo) — GTK3 sin headerbar (Thunar) sin barra
- Causa: wl_server.c:2698 anuncia KDE server-decoration default SERVER (GTK3 no dibuja
  barra) pero nadie escucha new_decoration → t->csd=true (1678) → shell sin chrome.
- Sonnet B7 editando modules/wayland/wl_server.c. REQUIERE RECOMPILAR motor.

## K1 hecho
- frame.gd: _clear_zone_layout(zone) en ramas no dibujadas (+fullscreen); const
  WINDOW_NO_SCROLL_WITH_MOUSE=16 (motor no la bindea); radar sin etiquetas; rueda
  invertida; clic derecho en bloque de ventana → shell.wm_menu_*. frame_menu_test 17 ok.
- K4 lanzado (slots anclados + popups volumen/portapapeles).

## B2 cursor — causa encontrada (motor)
- GTK3/Firefox ocultan el puntero con una surface de cursor SIN buffer (no set_cursor NULL).
  cursor_surface_import retornaba sin avisar y set_cursor ya había notificado "visible".
- Fix (lead) wl_server.c: import notifica hidden = (buffer == NULL); set_cursor sólo
  notifica hidden=1 con surface NULL.
- Motor compilando (godot-gdtk-slug, comando de deploy.sh). Instalar: objcopy
  --remove-section=.note.gnu.property + copiar a ~/gdtk/bin/godot-gdtk (sólo con pedido;
  activa en el próximo corte controlado).

## Commits
- b9a8b76 popup layout 10-06 (sin shell.gd); a935c2f motor: KDE deco + cursor vacío.
- Motor compilado OK (godot-gdtk-slug, 8 s). Usuario: commit+deploy a medida (modo /polish).

## B8 (nuevo) — selección se pierde al llegar al borde de la ventana
- Causa: sin grab implícito. _on_chrome_input consume motion sobre bordes; motion va a
  _view_hit_test bajo el puntero. Sonnet S3: pointer_grab mientras haya botón apretado
  (motion/release al cliente del press, coords locales fuera de rango), sin romper
  chrome_drag/DnD/Deskflow/popups.

## T3 (nuevo) — maximizar = tiled (sin "maximizada flotante")
- Hoy _maximize_window (shell.gd:4093): flotante → sólo wm_maximized (hueco central);
  tiled → sale de su franja (maximize_state).
- Nuevo: maximizar siempre → tiled; si su escritorio tiene otras ventanas → escritorio nuevo
  a la derecha del actual (frame_strip_new/_insert_solo ~2577), foco la sigue. Desmaximizar
  → vuelve a origen (flotante con rect en su escritorio / franja con pesos); si el origen
  ya no existe, flotante en el actual. wm_maximized deja de usarse como estado.
- Encolado para S3 (dueño de shell.gd) tras B8.

## Corte de sesión de Claude (agentes murieron) — retomado
- Commit 4a57c06 motor: grab implícito (motion con botón → surface del press, coords fuera
  de rango → autoscroll). Motor compilado. Shell (B8) también tiene grab con clamp: quitar
  el clamp cuando todos los hosts tengan el motor nuevo.
- K4 dejó: bar_slots.gd + test 21 ok + integración parcial. Relanzado como K5 (terminar +
  popups volumen/portapapeles). Brief 2026-10-07-K5-frame-finish.txt.
- S3 dejó T3 a medias en _maximize_window. Relanzado como S4 (T3 + B9 sombra de diálogos).
- OJO: cambios ajenos en deploy.sh, catalog.md, tech-debt.md, session/gdtk-firefox,
  guides/firefox-crashes.md (otra sesión): NO commitear con esta tanda.
