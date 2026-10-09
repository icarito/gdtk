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
  entra), también cada vez que gvd la recrea.
  Redimensionar: si cambia la ventana original, el video la sigue (window_cast publica el tamaño
  nuevo tras 300 ms quieto; gvd rearma el pipeline sin contarlo como fallo) y el receptor reajusta
  su ventana al nuevo video conservando su centro (peer `gvd_size`). Si la persona redimensiona la
  «Pantalla compartida», el emisor no cambia: el video se escala y al soltar el alto sigue la
  proporción del video (respeta el ancho elegido). Se deja de compartir SÓLO cerrando una de las dos
  ventanas: la original (corta y cierra el receptor remoto) o la «Pantalla compartida» del otro lado
  (termina su `gvd recv` y avisa con `share_stop`). Todo cierre pasa por `shell._close_window_id`.
  Una ventana por equipo a la vez (un receptor por puerto).
  Costo: window_cast sólo re-renderiza y lee de la GPU cuando hubo commits o cambió la
  geometría (el readback es síncrono y frenaba todo el shell); gvd sólo codifica frames
  nuevos y, quieta la ventana, repite el último cada 0,5 s (keepalive). En un X200: shell
  ~12% y x264 ~8% de CPU con htop compartido (antes 50% sólo el encoder).
  La transmisión sigue con la ventana oculta o minimizada: window_cast la marca como
  dibujada en cada frame (`get_layers`), así recibe frame callbacks y sus commits mantienen
  activo al shell. Medido en tengu con es2gears: 18,5 capturas/s visible, 15,5 en Hogar y
  15,8 minimizada (antes ~5,5 oculta).
  Mientras esa ventana receptora tiene foco, usa el puntero local (el video sigue con
  `--cursor none`) y devuelve movimiento normalizado, botones/rueda y teclado por el
  canal peer autenticado `window_input`. El emisor sólo acepta el lote si ese `hid`
  tiene una ventana compartida activa y lo inyecta exclusivamente en su `wid`; al
  perder foco, cerrar o cortar se liberan todas las teclas y botones retenidos.
  Deskflow tiene precedencia en el arbitraje: si InputCapture tomó el evento, éste no
  entra a `window_input`. Además gvd corre con nice 5 y su RTP usa DSCP CS1, dejando
  CPU y colas QoS por encima para el tráfico interactivo de Deskflow.
- **Audio** = interruptor «Enviar audio — Encendido/Apagado» en el mismo menú del equipo que
  «Extender mi pantalla», pero sin lado (no es espacial): basta con que el equipo esté encendido. Saca
  TODO el sonido por ese equipo. Túnel PulseAudio/PipeWire por `pactl` (`audio_send.gd`): el
  receptor abre `module-native-protocol-tcp` (4714) sólo con `auth-ip-acl` = IP del pedido peer
  (nunca `auth-anonymous`); el emisor crea `module-tunnel-sink`, lo pone por omisión y muda los
  streams; apagar restaura en ambos lados. Un destino a la vez; la preferencia se
  persiste por equipo y se reconcilia cuando éste reaparece. Anda con PipeWire y PulseAudio.
- Métodos peer `audio_recv`/`audio_stop`. Como todo cambio de `peer_link.METHODS` o de un `preload`
  (p. ej. `gvd_launch.gd`), entra con el reinicio del proceso del shell; una recarga no alcanza.

#### Medición de latencia audio/gvd (2026-10-06)

Banco bastion↔cupid, dos rutas: LAN (ambos clientes de Alvitos_Govista, vía router) y enlace
directo AP (cupid AP + dongle USB MT7601U de bastion). `ping` 50×0.2 s:

- LAN: RTT avg **20.7 ms** (bastion→cupid) / **59.3 ms** (cupid→bastion), mdev **30/58 ms**,
  máx **133/331 ms**, 0% pérdida.
- AP: RTT avg **17/64.7 ms**, mdev **31/166 ms**, máx **126/858 ms**, **2% pérdida** (ch5 y ch11
  similares). El enlace directo **no mejora**; peor jitter y pérdida (radio única + dongle 1×1 +
  co-canal con Alvitos en 2.4G).

Audio (tono 440 Hz por `module-tunnel-sink` → captura del `.monitor` en el receptor; ventanas de
100 ms con RMS≈0 dentro del tono): **LAN 7%** de cortes; **AP 54%** (patrón ~2 s con sonido / ~2 s
mudo). El túnel TCP amortigua el jitter de LAN pero se quiebra con la pérdida/jitter del AP.

gvd (H.264 RTP/UDP, `--jitter-ms 30`, `drop-on-latency=true`): **LAN decodifica** (fps máx ~19,
mín ~1-4, objetivo 30: fluido a rachas); **AP cero frames** (todo paquete llega fuera del buffer y
`wait-for-keyframe` nunca arma). El cuello es la red 2.4G, no el códec. Mitigaciones: subir
`--jitter-ms` (300-500) y/o bajar `--fps`/`--bitrate` para gvd; el AP directo no ayuda aquí.


### Disposición física y preferencias persistentes (2026-10-04)
- `settings.json:screens` (schema v2) es la única fuente de verdad. Cada vecino usa
  su `hid`; `label`/`peer` son nombres mutables. `x/y/w/h` están en milímetros y la
  resolución vive aparte en `px_w/px_h`. Los rangos Deskflow se calculan con tamaño
  físico, no con la cantidad de píxeles de paneles con DPI distintos.
- Configuración → Pantallas edita ancho/alto en centímetros y resolución en píxeles.
  Arrastrar en Grupo actualiza ese mismo layout. `host_directions` es una proyección
  derivada para brújula, gvd y handshake, no otra geometría autoritativa.
- La migración v1 preserva la resolución y aproxima la geometría previa a 96 DPI hasta
  que se ingresen medidas reales; nombres históricos (`cupid`, `tengu`) se reemplazan
  por el `hid` estable al descubrir el equipo.
- Cada pantalla guarda `share.screen`, `share.input` y `share.audio`. Los interruptores
  de Grupo cambian esas preferencias; las sesiones se reconcilian cuando el equipo está
  disponible. Detener desde el dockapp apaga también la preferencia correspondiente.
- El receptor gvd recibe el tamaño anunciado en su argv y renegocia cambios de caps sin
  reiniciar el pipeline: conserva una sola superficie Wayland para no provocar un salto
  de ventanas en el equipo receptor.
- Cambiar la topología regenera el conf y reinicia Deskflow mediante su ciclo de vida
  existente, para que el proceso nunca siga usando el archivo anterior.

### Color de cada equipo (2026-10-04)
- Cada equipo anuncia su acento de Configuración en el TXT mDNS (`accent=#rrggbb`, sólo ese formato;
  se re-anuncia al cambiarlo). Como el XO de Sugar: en Grupo y Vecindario cada equipo se dibuja con
  su acento (anillo + relleno suave) y «Este equipo» con el propio; sin acento, colores neutros.
- La «Pantalla compartida» que llega de otro equipo lleva un marco (y el asa de mover) con el
  acento de ese equipo, para distinguirla de las ventanas locales, y su bloque del Frame se
  resalta con ese mismo color. Se muestra como «<título de la ventana original> @<equipo>»
  (`shell.window_title`, usado por Frame, exposé y decoración). Título y acento los manda el
  emisor por el método peer `gvd_meta` al empezar y cada vez que cambian; el acento del TXT
  mDNS queda de respaldo. `gvd_meta` lleva también el ícono de la ventana (PNG ≤64 px en
  base64, ≤64 KiB, decodificado ≤256 px en el receptor), usado en el Frame y el anillo del
  Hogar junto con «título @equipo».
- Re-compartir con el mismo equipo manda `gvd_stop` y `gvd_recv` en el MISMO hilo y en ese
  orden: en hilos separados el stop podía llegar último y cerrar el receptor nuevo.
- Sin ícono XO en ningún lado: ventanas sin ícono muestran su inicial y equipos sin ícono el
  monitor (`np/device-desktop`); `computer-xo.svg` ya no está en el repo.
- `ctl=` sólo se anuncia si el canal peer escucha: vacío invalidaba el TXT y el equipo no se
  anunciaba en absoluto.

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

### G6 — Interruptor retro del radar: master del intercambio (2026-10-08)
- La dockapp "Compartiendo" (radar) lleva en su esquina inferior derecha un **botón redondo de
  encendido** (base rehundida + aro de estado + glifo de power; antes era una palanca I/O) que
  enciende o corta **de una sola vez** todo el intercambio: Deskflow (teclado y mouse), el túnel de
  audio (PipeWire/módulos pactl de `audio_send.gd`) y las sesiones de pantalla gvd (extender,
  recibir, ventanas espejadas). Es "Apagar todo el intercambio" / "Encender el intercambio" —
  también como primera fila del menú del bloque. Nota: lo que la spec anterior decía "la dockapp
  sólo puede apagar" queda ampliado por esta decisión: además de cortar por sesión, el radar puede
  rearmar TODO (pero nunca inventa sesiones nuevas: repone de preferencias/roster con los caminos
  de siempre).
- Cortar (`shell._share_all_enable(false)`): detiene lo vivo con los ciclos existentes
  (`_stop_gvd_screen` por hid, `_stop_tracked` de servidores por equipo, `_audio_work({})` +
  `_peer_audio_stop` para audio, `_toggle_service_by_name("Deskflow")`), cancela lanzamientos peer
  en vuelo y **no borra preferencias** (`share.*` de settings ni `mode` del servicio). Fija
  `share_enabled = false` **y lo persiste** en `settings.json` (`share_enabled`), así el estado del
  radar sobrevive reloads y reinicios (antes era sólo memoria y volvía a encendido). Se restaura al
  arrancar el shell, tras `settings_bridge.reload_now()`.
- Mientras está cortado (`share_enabled == false`): `_sharing_reconcile` y `_deskflow_tick/_deskflow_arm`
  no revivifican; los intentos locales nuevos se rechazan con el mismo mensaje visible
  (`SHARE_DISABLED_ERROR`) en `_group_*_set(on)`, `_start_gvd_screen`, `_run_deskflow_plan/server`,
  `_group_share_window`; recepción vía canal peer se rechaza honesta (`_peer_gvd_open` → false,
  `_peer_audio_recv` → 0), y `share_notify` sólo procesa "stopped" (sin blips fantasma).
  `_share_off_reap()` (vigía en `_deskflow_tick`) mata en silencio todo lo que logré revivir por
  carrera (launch terminando, toggle diferido de escrituras de config, pico del buzón ssh — ese
  buzón ssh remoto queda documentado como lo único fuera de la puerta).
- Los interruptores de Grupo/Vecindario (`_group_input_on`/`_group_screen_on`/`_group_audio_on`)
  muestran encendido=0 mientras corta, así el estado mostrado es siempre el real.
- Encender (`_share_all_enable(true)`): `_share_all_arm()` vuelve a aplicar el roster de teclado y
  mouse del corte (`share_roster_input`, sin tocar el rol si el modo era `use_remote`: un equipo
  cliente no se pincha a servidor), `_deskflow_arm()` reactiva el autoarranque del servicio y
  `_sharing_reconcile` restaura pantalla/audio desde `share.*` guardadas (reintentos inmediatos).
- Conway de UI: encendido+sin sesiones = dockapp desaparece (como siempre); **cortado = dockapp
  SIEMPRE a la vista** (stub apagado, radar muerto con scope gris y sin barrido) para que el
  encendido siempre sea alcanzable. Test `shared_block_test.gd` (sección master).

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
