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

## Tanda 1 entregada (2026-10-07 21:45)
- Commits a96d596 (frame/dockapps) + ea52b43 (wm/grupo). verify_all: 0 FAIL (rc 134/139 =
  crash conocido al salir; slug_vector ok=0 preexistente).
- bastion: rsync + motor 9143d600 en ~/gdtk/bin (activa en el próximo login) + recarga
  transaccional OK (PID 1900170 igual, 4 ventanas). tengu/cupid: deploy.sh OK, md5 iguales.
- OJO: el MCP gdtk del repo (.mcp.json) apunta a TENGU (192.168.18.163), no a bastion.
  Para bastion: python3 mcp/gdtk_mcp.py → call_shell(...) local.

## F6 (nuevo) — Super+Espacio rota distribuciones (es ↔ latam) en vivo
- Brief: briefs/2026-10-07-F6-keymap-switch.txt. Sonnet en curso (motor set_keymap +
  swaymsg + applet_keyboard lista activa + popup multi + OSD). Requiere recompilar.

## Retomado por Kilo (2026-10-07 22:50) — bugs + features + cierre
- B1 (franjas comen clics con el Frame oculto): verificado en vivo con A2 (K1 ya lo dejó).
  Con pin_top=false y visible=false, `frame.drawn=false`, `bar_layout=[]`, `window_span={}`
  y `_window_dock_hit`/`_item_at` devuelven Null. No requiere más cambios.
- F6 applet_keyboard: dos escrituras concurrentes compartían el .tmp y se pisaban (test
  flaky 1/5). Reemplazado por UN hilo escritor con coalescencia (gana el último cuerpo);
  stress 12/12. tests/applet_keyboard_test.gd.
- F6 motor: compilado (slug, 9 s; binding `set_keymap` presente) e instalado en
  `~/gdtk/bin/godot-gdtk` (md5 e86cbba6). El binario vivo todavía es el viejo: el keymap
  del compositor embebido entra en el próximo lanzamiento/corte controlado; la vía swaymsg
  + OSD ya funciona con la recarga.
- applet_volume: `_run` construía `timeout timeout 2 wpctl ...` (rc 125 → "sin dato");
  corregido a `timeout 2 wpctl ...`; verificado en vivo (47%, salida skl_hda).
- Bastion deploy: rsync scripts + binario instalado + recarga transaccional (mismo PID
  19223, ventanas vivas).
- Deploy remoto tengu/cupid NO hecho: 192.168.18.163 sin ruta (ping 100% loss) y `cupid`
  no resuelve ahora. Repetir `./deploy.sh icarito@tengu.local` cuando esté en línea.
- frame_slots_test: fallaba desde Tanda 1 (el stub no tenía Host → `bar_slots`/`bar_order_anchor`
  Nil). Sembrados en el test: 65 ok.
- Nuevo: auto-rescan de apps. shell/apps.gd `maybe_rescan(now)` (firma mtime+conteo por dir
  XDG de applications, poll 4 s desde shell._process). Detecta instalar/desinstalar, incluidas
  ~/.local/share/applications. tests/apps_rescan_test.gd 14 ok. Verificado en vivo (2 s alta, 4 s baja).
- Nuevo: en exposé, teclear lleva al Hogar en modo búsqueda (como el Hogar espiral).
  shell.gd `_input`; verificado en vivo (expose→false, apps_view=true, query).
- Nuevo: anillo del Hogar como Sugar: círculo centrado (radio min(avail_x,avail_y)), no
  estirado a los costados. shell/ring_layout.gd. RING_LAYOUT pasa de `const preload` a
  `Host.sc` para que la recarga transaccional tome el .gd (preload quedaba cacheado).
- bastion: rsync + 2 recargas transaccionales (mismo PID 19223, ventanas vivas).

## Kilo tanda 2 (2026-10-07 23:10) — inotify, espiral real, dockapp volumen
- Auto-rescan sin sondeo: nuevo módulo motor `modules/inotify` (GdtkFileWatch, Object
  nativo) con inotify del kernel + hilo que drena eventos y emite `changed` por
  call_deferred. shell/apps.gd `ensure_watch()`/`stop_watch()`: la señal marca sucio y
  el tick reescanea; sin recorrer el FS. Fallback por firma sólo si el motor viejo no
  trae la clase. Test `tests/inotify_watch_test.gd` (verde con el binario nuevo). Motor
  recompilado e instalado (md5 cfefc290). El binario vivo sigue siendo el viejo hasta el
  próximo lanzamiento; mientras tanto corre el fallback (10 s).
- Espiral del Hogar: filotaxis de ángulo áureo SIN jitter (el jitter la veía como "sopa
  de letras"). Anillo circular centrado.
- Dockapp de volumen: `applet_volume.gd:draw` dibuja faders de mezclador (3 rieles con
  perilla al nivel, relleno de nivel y valor; mute al piso). Reemplaza el texto VOL/47%.
- bastion: rsync + motor nuevo + recarga transaccional. Commit de esta tanda.
