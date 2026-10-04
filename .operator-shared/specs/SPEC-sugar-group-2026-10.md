# SPEC — Grupo (zoom Sugar), Vecindario sin solapes, Hogar por orientación y dockapp Compartiendo (2026-10-03)

Reglas transversales: las de SPEC-ui-rework-2026-10.md (Godot 3, lógica pura + test, vocabulario de
producto, nada bloqueante en _draw/_process, sin commit/deploy, no revertir cambios ajenos).

## Context
El Vecindario actual mezcla todo (hosts, Wi-Fi, BT) en un layout polar comprimido: los íconos
se pisan y no usan la pantalla (`neighborhood_map.map_radii` limita a 36% del ancho; Wi-Fi en dos
arcos de ±77°; BT por hash; `relax_capsules` existe en `neighborhood.gd:529` pero sólo lo usa un test).
Compartir teclado / extender pantalla vive en menús de clic derecho sin feedback persistente.
Objetivo (alineado con Sugar clásico): tres niveles de zoom **Hogar → Grupo → Vecindario** con el
ícono central del equipo como ancla visible del zoom; **Grupo** = equipos conocidos/pareados (+ BT
pareados) aunque estén apagados, donde se comparte arrastrando al lado; y una **dockapp en el Frame
de ambos equipos** que muestra qué lados están compartidos y gestiona las ventanas extendidas.

Decisiones tomadas con el usuario:
- Miembro de Grupo = tiene entrada en `~/.config/gdtk/neighborhood-directions.json`, o token en
  `peer-tokens.json`, o pantalla en `settings.json → screens`. Entra desde Vecindario con "Añadir a mi
  grupo"; sale con "Quitar del grupo".
- BT: todos los pareados en Grupo (ícono por tipo, clic = conectar/desconectar); no pareados sólo en Vecindario.
- Dockapp = bloque del Frame (evoluciona `shared_block.gd` / `frame._draw_shared`), visible en ambos equipos.
- Gesto en Grupo = arrastrar el equipo a un lado del ícono central → se imanta (dirección) → popup con
  dos interruptores "Extender mi pantalla" / "Compartir teclado y mouse". Clic derecho = mismo menú.
- Zoom: F1 Vecindario, F2 Grupo, F3 Hogar (F4 vuelve a la actividad), y Super+rueda vertical / pinch.
- Cadena vertical (gesto de 3 dedos): Vecindario → Grupo → pantalla → exposé → Hogar → Apps (sin ventanas se
  saltan pantalla y exposé; `swipe_model.vertical_levels`). La rueda **sin** Super sobre los bloques
  Vecindario/Grupo/Hogar del Frame o sobre el ícono central de la vista avanza un nivel de esa misma cadena con
  las mismas transiciones (`shell._wheel_vchain`): rueda arriba = dedos arriba; una muesca = un nivel (ráfagas
  recortadas a 300 ms). Fuera de esas anclas la rueda conserva su uso.
- Hogar: transición de zoom + anillo relativo a la orientación (los dos primeros íconos a lo ancho en
  landscape, a lo alto en portrait).

## Items

### G1 — Modelo de zoom de 3 niveles + ícono central animado
- Nuevo puro `shell/zoom_model.gd` (`extends Reference`): niveles `HOME=0, GROUP=1, NEIGHBORHOOD=2`;
  `center_icon_rect(level_f, vp)` (escala del ícono central: Hogar 1.0 → Grupo ~0.6 → Vecindario ~0.35,
  interpolado con `_ease_out`); `layer_transform(layer, level_f)` → {scale, alpha} (al alejar, la capa
  saliente se encoge hacia el centro y se desvanece; la entrante entra desde escala ~1.4 a 1.0).
  Test `tests/zoom_model_test.gd`.
- `shell/shell.gd`: reemplazar `neighborhood_view`/`nb_zoom` (:167-172, :1377-1392, :1474-1513) por
  `zoom_level`/`zoom_f` animado con `ZOOM_MS`; el ícono central se dibuja **una vez** en la posición
  interpolada (unificar `_draw_home` :3405 centro y `neighborhood_ui._draw_center_plate` :941).
  `_go_neighborhood`/`_close_neighborhood`/`_go_home` (:5148/:5162/:4795) pasan a `_set_zoom(level)`; nuevo `_go_group()`.
- Entrada: `frame.gd` junto a Esc (:2225): F1/F2/F3/F4. Super+rueda **vertical** en vistas de zoom =
  alejar/acercar un nivel (horizontal sigue paneando, SPEC-sugar-spatial); pinch del touchpad igual.
- Riesgo: Super+rueda hoy se usa para alcanzar el Hogar en la fila — sólo cambia el eje vertical y sólo en vista de zoom.

### G2 — Hogar: anillo según orientación
- Extraer `_orbit_layout` (shell.gd:3805) a puro `shell/ring_layout.gd` con test. Modo círculo →
  **elipse** que usa `avail_x`/`avail_y`, ángulo base `PI` en landscape (ítems 0 y 1 a izquierda/derecha)
  y `-PI/2` en portrait (arriba/abajo). Espiral sin cambios. Test con 1920×1080 y 800×1280.

### G3 — Vecindario sin solapes y a pantalla completa
- `neighborhood_map.gd`: radios elípticos (`map_radii` usa ancho y alto por separado), Wi-Fi en arcos
  más anchos, BT en su propia banda; tras `map_layout`+`wifi_dots`+`bt_dots` correr
  `neighborhood.relax_capsules` (:529) sobre **todos** los ítems con rótulo truncado.
- Conocidos del Grupo que estén offline también aparecen (atenuados).
- Test: 5 hosts + 30 APs + 10 BT a 1280×720, 1920×1080 y 800×1280 → ningún par de cápsulas se solapa
  y bounding box ≥ 80% del área útil.
- Menú: agregar "Añadir a mi grupo" / "Quitar del grupo" (`neighborhood_actions.host_actions` :198).

### G4 — Vista Grupo
- Nuevo puro `shell/group_model.gd`: `members(directions, tokens, screens, live_hosts, bt_devices)` →
  lista {id, name, online, direction, bt_kind}; lee lo ya persistido, nada nuevo. Arreglar
  `neighborhood.gd:206` para pasar overrides a `neighborhood_hosts.build_hosts` (soporte "guardado" ya existe).
- `neighborhood_ui.gd` con `mode = "group" | "neighborhood"` (misma Control, no un archivo nuevo):
  en Grupo el centro es grande, los equipos con dirección se dibujan pegados a su lado (N/S/E/O),
  los sin ubicar en un arco inferior "sin ubicar", BT pareados en una banda pequeña. Online vs apagado
  (atenuado + "apagado").
- Drag: revivir el arrastre (hoy `_drag_id = ""` en cada press, neighborhood_ui.gd:282-287), usar
  `magnet_direction`/`drag_direction` (neighborhood_map :256-266) → `_set_host_direction` → popup con
  dos interruptores que disparan las acciones existentes (`share_my_screen` vía `_start_gvd_screen`,
  `serve_input_here` vía `_run_deskflow_server`). Offline → interruptores deshabilitados con razón.
- Vocabulario: SPEC-ui-rework "Vocabulario de producto" (nunca gvd/deskflow/hid…).

- Menú único (2026-10-04): en Grupo, cualquier equipo (clic, clic derecho o Enter) abre el MISMO menú:
  «Extender mi pantalla» y «Compartir teclado y mouse», cada uno con su propio Encendido/Apagado, y al
  final «Quitar del grupo» o «Añadir a mi grupo». Nunca cae al menú del Vecindario.

### Teclado y mouse: una sola entrada (2026-10-04)
- Deskflow se enciende y apaga SÓLO con el interruptor «Compartir teclado y mouse» del Grupo. No hay
  ícono en el anillo del Hogar, ni página «Compartir control» en Configuración, ni acciones de
  teclado y mouse en el menú del Vecindario. La dockapp «Compartiendo» sólo puede apagar, por el
  mismo camino.
- Motor único: el servicio global. Encendido por equipo = `input: true` en host_directions; alguno
  encendido → servidor (topología de Pantallas), ninguno → apagado. Se guarda en
  `settings["deskflow"]`, que ahora escribe el shell (Configuración conserva lo del disco al guardar).
- El otro equipo no configura nada: el aviso `share_notify` (input) lo pone como cliente del que
  comparte, y el «stopped» lo apaga. Un equipo que es servidor no se vuelve cliente.
- Al iniciar sesión se restaura solo (`auto`), en ambos lados.

### Portapapeles del Grupo (2026-10-04)
- Siempre compartido entre los equipos del Grupo, sin opción ni configuración: cada copia local de
  texto (vigía `session/gdtk-clipboard`, ext-data-control) va por el canal peer (`clip_set`, token
  por par) a todos los miembros alcanzables; el receptor la pone como su selección.
- Sólo texto, hasta 64 KiB. Lo marcado sensible no se guarda y por lo tanto no viaja.
- Lo recibido no se reenvía (anti-rebote). El texto viaja por archivo en `XDG_RUNTIME_DIR`, nunca
  por argumentos. LAN de confianza: el canal no cifra.

### Enviar audio y ventanas (2026-10-04)
- **Ventana** = arrastrar y soltar en la vista Grupo, sin menú. El destino lo resuelve
  `neighborhood_ui.group_drop_target` (equipo encendido). Compartir en vivo por gvd (espejo: la local
  sigue visible): soltar el bloque de la ventana del Frame sobre un equipo → `window_cast.gd` la
  compone fuera de pantalla y la vuelca a `$XDG_RUNTIME_DIR/gdtk/win-<hid>.frames` (archivo con
  seqlock, nunca FIFO: SIGPIPE tumbaría el shell) → `gvd send --capture shm` → del otro lado la misma
  «Pantalla compartida» que al extender (`gvd_recv`, que ahora lleva `w`/`h` del video). El receptor
  ajusta esa ventana para que su contenido mida como el video (sin franjas; achica sin deformar si no
  entra), también cada vez que gvd la recrea. Se deja de compartir SÓLO cerrando una de las dos
  ventanas: la original (corta y cierra el receptor remoto) o la «Pantalla compartida» del otro lado
  (termina su `gvd recv` y avisa con `share_stop`). Todo cierre pasa por `shell._close_window_id`.
  Una ventana por equipo a la vez (un receptor por puerto).
- **Audio** = interruptor «Enviar audio — Encendido/Apagado» en el mismo menú del equipo que
  «Extender mi pantalla», pero sin lado (no es espacial): basta con que el equipo esté encendido. Saca
  TODO el sonido por ese equipo. Túnel PulseAudio/PipeWire por `pactl` (`audio_send.gd`): el
  receptor abre `module-native-protocol-tcp` (4714) sólo con `auth-ip-acl` = IP del pedido peer
  (nunca `auth-anonymous`); el emisor crea `module-tunnel-sink`, lo pone por omisión y muda los
  streams; apagar restaura en ambos lados. Un destino a la vez, no se persiste, se apaga solo al salir
  el shell. Anda con PipeWire y PulseAudio.
- Métodos peer `audio_recv`/`audio_stop`. Como todo cambio de `peer_link.METHODS` o de un `preload`
  (p. ej. `gvd_launch.gd`), entra con el reinicio del proceso del shell; una recarga no alcanza.

### G5 — Dockapp "Compartiendo" en ambos Frames
- `shared_block.gd`: además de bloques por sesión, `diagram(sessions)` → un bloque con mini-diagrama:
  cuadro central = mi pantalla, cada lado N/S/E/O encendido por tipo (barra llena = pantalla extendida,
  flecha = teclado y mouse) + inicial del equipo. Menú clic derecho: por sesión "Dejar de extender a X",
  "Dejar de compartir teclado con X"; por ventana extendida (`_pantalla_window_ids` shell.gd:~6000)
  "Mostrar", "Maximizar/Restaurar", "Cerrar"; y "Abrir Grupo".
- Del otro lado: nuevo método peer `share_notify` {type, side, state} y `share_stop` en
  `peer_link.METHODS` (:17) + handler en `peer_control._handle` (:131); el remoto guarda `remote_shares`
  (lado = `neighborhood_directions.inverse`) que alimenta su bloque; detener desde cualquiera de los dos.
  Emitir desde `_start_gvd_screen`/`_stop_gvd_screen`/`_run_deskflow_server` y sus paradas.
- Dibujo en `frame._draw_shared` (:1498). Tests: `shared_block_test.gd`, `peer_link_test.gd`, `peer_control_test.gd`.

## Reparto (archivos disjuntos)
- **Ola 1 en paralelo**
  - Agente A (G1+G2): `shell/zoom_model.gd`, `shell/ring_layout.gd`, `shell/shell.gd` (zoom/orbit),
    `shell/frame.gd` (sólo teclas), tests nuevos.
  - Agente B (G3 luego G4, serie): `shell/neighborhood_map.gd`, `neighborhood_ui.gd`, `neighborhood.gd`,
    `neighborhood_actions.gd`, `shell/group_model.gd`, tests de neighborhood/group.
    El enganche `_go_group()` en shell.gd lo hace A; B expone `set_mode()`.
- **Ola 2** (tras A, porque toca shell.gd/frame.gd): Agente C (G5): `shared_block.gd`, `peer_link.gd`,
  `peer_control.gd`, `frame.gd` (`_draw_shared`), `shell.gd` (hooks notify).
- Ejecutores: **todo vía Kilo** (`kilo/deepseek/deepseek-v4.1-flash`, `kilo run --attach
  http://127.0.0.1:4096 --dir ~/Proyectos/gdtk --agent code --title ...`, en paralelo, espaciados ~10 s).
  Tareas chicas: partir cada agente en briefs cortos (G1, G2, G3, G4a modelo, G4b UI+drag, G5a puro+peer,
  G5b frame/shell), en serie dentro de cada cluster. Briefs con archivo:línea, criterio de hecho, sin
  commit/deploy. Vigilar colgados (`pgrep -af 'kilo run'`) y verificar por git diff + tests.

## Verificación
- Tests puros (binario dev, desde `~/Proyectos/gdtk`):
  `zoom_model_test`, `ring_layout_test`, `neighborhood_test`, `neighborhood_ui_test`, `group_model_test`,
  `neighborhood_actions_test`, `shared_block_test`, `peer_link_test`, `peer_control_test` + `tools/verify_all.sh`.
- Parseo de `shell.gd`/`frame.gd` con `~/gdtk/bin/godot-gdtk` (clases nativas).
- Visual: instancia anidada aislada si existe lanzador; si no, `rsync` + `deploy.sh` a tengu/cupid
  (no recargar el shell principal de bastion). Probar: F1/F2/F3 y Super+rueda (ícono central se
  achica/agranda continuo), Hogar landscape vs portrait (tengu rotado), Vecindario sin solapes,
  arrastrar tengu al Sur en Grupo → "Extender" → dockapp aparece en bastion y en tengu con el lado
  correcto; detener desde tengu corta en ambos.
- Entrega final (commit + deploy a los 3 hosts con md5) sólo cuando el usuario lo pida.
