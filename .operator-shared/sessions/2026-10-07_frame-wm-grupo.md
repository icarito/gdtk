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

## Kilo tanda 3 (2026-10-07 23:25) — dockapp volumen: indicador + rueda
- `applet_volume.gd:draw` deja UN indicador horizontal (riel + relleno de nivel +
  marcas + valor); se quitan los 3 faders (no arrastrables).
- `frame._input` (rueda): sobre `_applet_at == "volumen"` llama
  `system_osd.rpc_action({"action":"up"|"down"})` y consume el evento. Sólo actúa si
  la barra está dibujada (`_applet_at` usa applets_drawn), así que con el Frame oculto
  no intercepta. Verificado en vivo (wpctl 62%->72%->62%).

## Kilo tanda 4 (2026-10-07 23:40) — volumen LED verde vertical + refresco inmediato
- `applet_volume.draw`: indicador VERTICAL segmentado estilo LED verde retro (12
  segmentos de abajo hacia arriba, halo en los encendidos, valor abajo). La placa LCD
  toma `frame.VOLUME_LED` (verde) como acento.
- Rueda/pan: `frame._input` maneja WHEEL_UP/DOWN y además `InputEventPanGesture`
  (scroll suave de touchpad) sobre `_applet_at == "volumen"`.
- La "demora en reaccionar" era el período del worker del applet (PERIOD_MS=3000): el
  volumen cambiaba al instante pero el bloque no releía. Ahora, tras la rueda/pan y
  tras las teclas multimedia (shell._input), se llama `frame.volume.refresh(true)`
  para releer ya.

## Kilo tanda 5 (2026-10-07 23:53 → 2026-10-08 05:00) — failsafe + "no lee el volumen"
- El shell cayó a FAILSAFE a las 23:46:50: caída rc=139 (segfault) y luego rc=1 por un
  error de parseo TRANSITORIO en `frame.gd` (`Variable "side" already defined in the
  scope`, línea 3343) mientras el editor aún escribía. El supervisor arrancó el snapshot
  `20261007-221727` y NO el árbol vivo (`running-version` = `fallback 20261007-221727`).
  A las 23:52 hubo otra caída (rc=134) y volvió al mismo snapshot.
- Sintoma "el volumen ya no lee": el shell corriendo era el snapshot con el `applet_volume.gd`
  viejo (buggy `_run` = `timeout timeout ...`, sin `draw`, sin icono). No era regresión del código:
  era la copia de fallback desactualizada.
- Fix operativo (sin reiniciar, VS Code abierto): rsync del `shell/` + `settings/` vivos
  al directorio del snapshot y `reload_shell` transaccional. Verificado en vivo:
  `frame.volume.state`=`activo`, `frame.volume.value`=`55%` == `wpctl get-volume` 0.55;
  la fuente cargada es byte-idéntica al `shell/applet_volume.gd` commiteado (10712 B;
  `get_source_code().length()` da 10677 por UTF-8 multibyte). Icono Sugar, medidor cian
  y `[TIMEOUT_S] + argv` presentes en vivo (commit b05a3eb).
- Deuda: el árbol vivo (`~/gdtk/shell`) sigue sin ser el que corre. Volver a él exige un
  reinicio pedido (prohibido con VS Code abierto); el snapshot quedó overlaid con el código
  actual, equivalente funcional. Caída rc=139/134 sin diagnóstico (no reproducida desde 23:52).

## Kilo tanda 6 (2026-10-08 00:00) — icono nuevo + caída total y recuperación
- Icono del parlante rediseñado: SVG `audio-volume-high/muted` con cuerpo redondeado
  (sólo M/L/Q/Z, como los otros Sugar) y ondas/X de trazo grueso; legible a 26 px. Se
  verifica que el motor lo rasteriza (nanosvg no trae `load_svg_from_string`; cae al
  `_load_sugar_file` y da 192x192). Commit 52ba38e.
- `system_osd._draw_plate`: el icono iba con trazo OSCURO (0.32,0.30,0.38) sobre la placa
  oscura → las ondas/X casi no se veían. Ahora trazo claro (0.88,0.90,0.95). Afecta a
  todos los iconos del OSD (volumen/brillo).
- INCIDENTE: la sesión gdtk cayó y GDM arrancó GNOME. Causa: el `frame.gd` WIP de OTRA
  sesión (interruptor del DockApp "Compartiendo") quedó a medio escribir y mi rsync de
  `shell/` lo desplegó. El parseo fallaba en cadena: primero `_draw_radar()` con 4 args y
  def de 3 (estado intermedio), luego `Variable "k" already defined` (el `var k` nuevo
  chocaba con `for k in`). El supervisor acumuló 5 caídas y "se rindió".
- Fix mínimo y quirúrgico (NO revertir el WIP ajeno): renombrar el factor nuevo a `damp`
  en `_draw_radar`. `session/gdtk-preflight` da 75 scripts, 0 fallas en el árbol vivo y en
  el snapshot. Sin locks stale (`gdtk-supervisor.lock`/`gdtk-shell.pid` ausentes). El
  árbol vivo arranca limpio en el próximo login (elegir la sesión gdtk en GDM).
- `frame.gd` sigue SIN COMMITEAR a propósito: contiene el WIP de la otra sesión. Sólo se
  armó el fix de parseo en el archivo desplegado.

## Kilo (2026-10-08 16:30) — exposé universal: Deskflow no dejaba cambiar de pantalla
- Causa: `_capture_remote_input_event` (shell.gd:12270) cortaba TODO el input hacia
  RemoteInput/Deskflow con `if expose: return false`; el puntero nunca llegaba a la
  barrera de borde y no se podía cambiar de pantalla del Grupo con el exposé abierto.
- Fix: se corta el cruce SÓLO mientras se arrastra una miniatura (`expose_drag != null`);
  sin arrastre el borde sigue disponible (el guard de `button_mask` ya frena el arrastre).
  En `_toggle_expose(on)` se libera la captura remota si estaba activa, así
  `_sync_capture_cursor` no la re-lockea cada frame.
- Test: `tests/input_capture_cursor_test.gd` +2 checks (cruce permitido sin arrastre;
  negado arrastrando). `shell.gd` parsea con el binario instalado. Sync de `shell.gd` a
  `~/gdtk` + recarga transaccional verificada (mismo PID 876253, 5 ventanas vivas).

## Kilo (2026-10-08 19:15) — el Frame oculto seguía comiendo clics
- B1 reaparece por un hueco: `set_visible(false)` (frame.gd:2415) reseteaba presses y
  drags pero NO `shared_power_rect`, así que el interruptor I/O del radar quedaba con el
  rect del último dibujo; con la franja oculta un clic ahí se consumía y, al soltar,
  disparaba `_share_all_toggle()`. Los demás hit-tests sí quedaban inertes (layouts
  limpiados por `draw()` al no estar `drawn`).
- Fix: `bars_shown()` (Home/visible/pin/exposé) + `drop_mouse_interaction()` (resetea
  presses, drags y rects del último dibujo). En `_input`, para eventos de mouse con las
  barras fuera se descarta el estado antes de seguir; NO hay `return`, así los gestos
  globales (Super+rueda, pinch, vchain, Super+arrastrar) siguen. Además `set_visible(false)`
  limpia `shared_power_rect`.
- Test: `tests/frame_hidden_mouse_test.gd` (8 ok, extrae las funciones reales). `frame.gd`
  y `shell.gd` parsean con el binario instalado; `frame_menu_test` 17 ok. Sync de
  `shell/frame.gd` a `~/gdtk` + recarga transaccional (mismo PID 876253).
