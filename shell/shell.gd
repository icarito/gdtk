extends ImGuiCanvas

var ACTIVITIES = [
	{"name": "Terminal", "wayland": ["alacritty"]},
	{"name": "Gears", "wayland": ["es2gears_wayland"]},
	{"name": "GTK", "wayland": ["gtk4-widget-factory"]},
	# Pantalla: receptor de gvd (monitor virtual de otro host, H.264/UDP :5600). Se abre como
	# ventana Wayland; el emisor se arranca en el otro host (gvd.py send --host <este host>).
	# La ruta se resuelve como neighborhood_actions.gvd_path_candidates: vendoreado
	# (~/gdtk/tools/gvd), dev (~/Proyectos/gvd), instalado (~/gvd) y PATH; sin
	# hardcodear una sola ubicación.
	# K18: el receptor usa un título fijo ("Pantalla compartida") y se trata como
	# una ventana normal; `match` lo asocia por ese título aunque el comando sea `python3`.
	{"name": "Pantalla", "match": ["Pantalla compartida"], "wayland": ["sh", "-c", "for c in \"$HOME/gdtk/tools/gvd/gvd.py\" \"$HOME/Proyectos/gvd/gvd.py\" \"$HOME/gvd/gvd.py\" \"$(command -v gvd 2>/dev/null)\"; do [ -n \"$c\" ] && [ -f \"$c\" ] && exec python3 \"$c\" recv --sink auto --cursor none; done; echo 'vecindario: gvd no encontrado (recv)' >&2"]},
	# 'Salir' ya no es una actividad del anillo: es una acción de sesión del ícono central
	# del Hogar (ver _draw_home / popup ##home_session).
]

# Servicios en segundo plano sin ícono en el anillo. Deskflow ("Teclado y mouse") se
# enciende SÓLO desde el interruptor de la vista Grupo (_group_input_set): en Wayland
# pide el portal RemoteDesktop/InputCapture y le llega un fd del EIS del shell.
const SERVICES = [
	{"name": "Deskflow", "service": ""},
]

# ImGuiWindowFlags_NoMouseInputs (1 << 9): el binding no lo exporta como constante.
const IMGUI_WINDOW_NO_MOUSE_INPUTS = 512

const TYPE_DELAY = 60
const SHOT_DELAY = 90
const SHOT_MAX_FRAMES = 900

# Modelo puro de la brújula de dirección (Kilo A): sólo normaliza/serializa y
# detecta conflictos; sin I/O. El shell lo cablea a la vista y a la persistencia.
const DIRECTIONS_MODEL = preload("res://neighborhood_directions.gd")
const RING_LAYOUT = preload("res://ring_layout.gd")
# Generadores puros del layout Deskflow (K5): links desde la brujula y el formato
# real de servidor; el shell sólo los consume al aplicar.
const LAYOUT_MODEL = preload("res://deskflow_layout.gd")
const CONF_MODEL = preload("res://deskflow_conf.gd")
const DESKFLOW_SETTINGS = preload("res://deskflow_settings.gd")
const SCREEN_LAYOUT = preload("res://screen_layout.gd")
const DESKFLOW_WATCH = preload("res://deskflow_watch.gd")
const SERVICE_STATE = preload("res://service_state.gd")
# Sesión de pantalla gvd (Kilo F2): modelo puro de estados/planes/clasificación que
# usa el despacho de acciones del Vecindario (no ejecuta nada por sí mismo).
const GVD_SESSION = preload("res://gvd_session.gd")
# K17: planes puros de automatización de gvd (emisor local/receptor remoto por
# ssh, `--position` del mapa, suspensión del vínculo Deskflow).
const GVD_LAUNCH = preload("res://gvd_launch.gd")
const PEER_CALL = preload("res://peer_call.gd")
const PEER_LINK = preload("res://peer_link.gd")
const AUDIO_SEND = preload("res://audio_send.gd")
const MENU_STYLE = preload("res://menu_style.gd")
const HOST_DISPATCH = preload("res://host_dispatch.gd")
# Modelo puro del Grupo (G4a): el shell sólo lo usa para sumar/quitar miembros
# (la vista y el resto del ciclo los maneja neighborhood_ui).
const GROUP_MODEL = preload("res://group_model.gd")
# Publisher mDNS del Vecindario: modelo puro + plan puro de anuncios; el shell
# resuelve avahi una vez y lanza cada anuncio sin bloquear el frame (§2/§14).
const PUBLISH_MODEL = preload("res://neighborhood_publish.gd")
const PUBLISH_PLAN = preload("res://neighborhood_publish_plan.gd")
# Buzón del handshake de dirección (K3): transporte puro por ssh (rutas, argv sin
# shell-injection, decisión por archivo) + modelo puro del DTO. El shell sólo hace
# el I/O en Threads y aplica el snapshot con `apply` (SPEC §6/§9/§14).
const INBOX_MODEL = preload("res://neighborhood_inbox.gd")
const HANDSHAKE = preload("res://neighborhood_handshake.gd")
# Hueco central del Frame (K12): cálculo puro compartido por el layout de tiles y
# los diálogos; ver content_layout.gd. No se repite el descuento de barras.
const CONTENT_LAYOUT = preload("res://content_layout.gd")
# Tipo de equipo local (kind de Vecindario) para el ícono de "Este equipo"/Inicio.
const DEVICE_KIND = preload("res://device_kind.gd")
# Lazy focus follows mouse (Feature Tiles): política pura de cambio de foco al
# mover el puntero sobre la vista; el shell sólo aplica la decisión.
const FOCUS_FOLLOW = preload("res://focus_follow.gd")
# Exposé como "zoom out" del escritorio: layout puro (proporciones reales) por
# workspace, ordenado como la fila de pantallas.
const EXPOSE_LAYOUT = preload("res://expose_layout.gd")
# Volumen/mute/brillo + OSD (teclas multimedia del motor; ver system_osd.gd).
const SYSTEM_OSD = preload("res://system_osd.gd")
# K13 — Modelos puros: chrome, layout flotante, decisiones de arrastre, unidades
# tiled con eje y estado híbrido por ventana. El viejo modo global (wm_mode.gd)
# queda sólo por compatibilidad de su test; el shell ya no lo usa.
const WINDOW_CHROME = preload("res://window_chrome.gd")
const FLOAT_LAYOUT = preload("res://float_layout.gd")
const WM_DRAG = preload("res://wm_drag.gd")
# K13h: unidades tiled con eje + estado híbrido por ventana (flotante/mosaico).
const WM_UNITS = preload("res://wm_units.gd")
const WM_HYBRID = preload("res://wm_hybrid.gd")
const CAPTURE_INPUT = preload("res://capture_input.gd")
# Mapeo puro rueda/gesto -> eje del compositor (ver scroll_gesture.gd).
const SCROLL_GESTURE = preload("res://scroll_gesture.gd")
# Swipe continuo de 3 dedos: FRT lo entrega como InputEventPanGesture con device =
# 1000+dedos (begin/update), 2000+dedos (fin) o 3000+dedos (cancelado).
const SWIPE_MODEL = preload("res://swipe_model.gd")
const SWIPE_DEVICE = 1000
# Scroll de dos dedos con fuente real (FRT): 900 = delta de un frame, 901 = axis_stop.
const SCROLL_FINGER_DEVICE = 900
const SCROLL_STOP_DEVICE = 901
# Matemática pura del icono de drag (rect/hotspot/tamaño; ver drag_icon.gd).
const DRAG_ICON = preload("res://drag_icon.gd")
# G1: zoom Sugar de 3 niveles (Hogar/Grupo/Vecindario) y escala del ícono central.
const ZOOM = preload("res://zoom_model.gd")

onready var compositor = Host.compositor
var view = null          # Control que dibuja las ventanas (se crea en _ready)
var view_layer = null    # CanvasLayer -1 debajo de ImGui

var current_activity = null
var activity_instance = null
# Instancias de actividades internas abiertas: se conservan al ir al Home o a otra
# ventana (el Frame las lista); sólo cerrarlas desde el Frame las descarta.
var script_instances = {}
var frame = null
var capture_input = null  # reenvía a EIS mientras ImGuiCanvas deja de recibir input
var activity_error = ""
var last_launch_pid = -1

var wayland_ids = {}
var pending_wayland = ""
# Lanzamientos wayland esperando su toplevel, en orden (la última es la más reciente).
# Puede haber varios a la vez; `expect` son tokens para casar app_id/título cuando el
# compositor ya publica ese dato, así una ventana que llega fuera de orden se asocia
# con el lanzamiento correcto.
var pending_launches = []
var requested_sizes = {}
var z_stack = []        # ids elevados por clic/foco, de abajo hacia arriba (flotantes y tiled)
var z_order_now = []    # apilado efectivo del último layout (dibujo y hit-test)
var popup_owners = []        # ventanas con popups abiertos este frame (van arriba de todo)
var popup_bounds_sent = {}  # id -> Rect2 enviada a set_popup_bounds
var resize_since = {}     # id -> ms del último set_size (estirar la textura mientras llega)
const RESIZE_STRETCH_MS = 600
var last_geo = {}        # id -> último tamaño observado del cliente (para reafirmar el slot)
# Los buffers wayland vienen con alfa premultiplicado.
var premult_material = null

var frame_count = 0
var screenshot_path = ""
# PrintScreen: guarda el viewport (todo el escritorio compuesto) en Imágenes/Pantallazos.
# La codificación PNG corre en un Thread para no bloquear el render (ver §14 del SPEC).
var _shot_thread = null
var open_on_start = ""
var recovery = Host.sc("res://recovery.gd").new()
var type_text = ""
var typed = false
var type_queue = []
var type_done_frame = -1
var tex_ready_frame = -1

# Dialogos: toplevels con padre. No se asignan a ninguna actividad: se dibujan
# centrados sobre la vista de su ventana raiz, en orden de creacion (el ultimo
# arriba). El padre puede cambiar por set_parent, se consulta cada frame.
var dialogs = []
var focused_dialog = 0
var dialog_view = null
var dialog_boxes = {}
# Tamaño que ya se le pidió a cada diálogo para que quepa en el hueco central (se pide
# una vez por tamaño, sin pelear con la app si su mínimo es mayor).
var dialog_fit_req = {}
# Toplevels sin padre y sin launch pendiente: esperan app_id/titulo para crear
# la actividad dinamica (en `added` todavia no se conocen).
var unmanaged = []
# Tiempo de espera antes de tratar un toplevel suelto como ventana nueva: un
# dialogo de otro proceso (p. ej. el selector de archivos del portal) puede
# declarar su padre (xdg-foreign) un frame despues de `added`. Durante esa
# ventana no se crea actividad/workspace.
const DIALOG_GRACE_MS = 300
var unmanaged_since = {}

# Home: fila(s) de actividades o grilla de apps instaladas (Tab alterna).
var apps = Host.sc("res://apps.gd").new()
var apps_view = false
# Íconos XDG del anillo: rasterizar uno o dos por frame (el SVG bloquea el frame).
var home_icon_loads = 0

# Anillo del Hogar (SPEC-sugar-home-visual): sólo lectura. Sus entradas son las
# actividades abiertas más los atajos fijados en el Frame (ver frame.pinned_ids), así
# que no se edita directamente.
# Orden de último uso (MRU) del anillo: nombres de actividad, el más reciente al
# final. El anillo lista primero lo que está abierto/activo, ordenado por esto.
var activity_mru = []
# Layout animado del anillo: posición mostrada por nombre, animación en curso e
# instante de entrada (fade/escala breve). Se limpia cuando el ítem sale.
var ring_pos = {}
var ring_anim = {}
var ring_intro = {}
var ring_layout = []      # rects del último dibujo

# Rotación de pantalla (menú del anillo): cache de presencia de acelerómetro.
var _rotate_sensor = null

# Vecindario: modelo de Wi-Fi y vista nativa bajo el Frame ImGui.
var neighborhood = null
var neighborhood_ui = null
# Zoom Sugar de 3 niveles: Hogar(0) -> Grupo(1) -> Vecindario(2). `zoom_level` es el
# objetivo (int) y `zoom_f` el nivel animado (float) con ZOOM_MS. `neighborhood_view`
# se conserva por compatibilidad: es true mientras la vista de zoom está activa.
var zoom_level = 0
var zoom_f = 0.0
var neighborhood_view = false
var _df_watch_at = 0       # próximo chequeo del vigía de Deskflow (ms)
var _df_mismatch = 0       # chequeos seguidos con captura activa y servidor "en local"
var group_placements = {}   # hid -> grados alrededor del equipo local (de host_directions)
const ZOOM_MS = 220.0
var nb_version = -1
# Dirección por host (brújula): hid -> entry normalizado de DIRECTIONS_MODEL.
# Se persiste en $XDG_CONFIG_HOME/gdtk/neighborhood-directions.json sin bloquear.
var host_directions = {}
var _dir_write_threads = []   # Threads de escritura de un solo uso, reapeados en _process
var _dir_write_states = []    # estado {"done": bool} compartido con cada Thread
var _dir_mutex = Mutex.new()  # protege los flags "done" de las escrituras

# Buzón del handshake de dirección (K3): worker con TTL que escanea
# ~/.config/gdtk/direction-inbox y publica decisiones ya decodificadas; el hilo
# principal sólo las aplica. Los envíos por ssh van en Threads de un solo uso.
var _inbox_thread = null
var _inbox_want_stop = false
var _inbox_entries = []       # decisiones {"action", "message"} publicadas por el worker
var _inbox_version = 0        # sube cuando el worker publica un lote nuevo
var _inbox_consumed = 0       # última versión aplicada por el hilo principal
var _inbox_send_threads = []  # envíos ssh en curso, reapeados en _inbox_poll
var _inbox_send_states = []   # {"done": bool, "code": int}
var _inbox_mutex = Mutex.new()  # protege el snapshot, los flags y el want_stop

# Sesiones rastreadas del Vecindario (gvd send, servidor Deskflow) y estado por host.
# Sólo memoria: la UI lee estos caches ("idle"/"starting"/"active"); los procesos se
# lanzan en Threads de un solo uso y nunca en el hilo de render (§0/§14).
# Clave por host: el propio host_id (gvd) o "deskflow:" + host_id (servidor Deskflow).
var gvd_session_pids = {}     # key -> pid de la sesión viva
var _gvd_launch_threads = []  # Threads de lanzamiento rastreado, reapeados en _process
var _gvd_launch_states = []   # {"done": bool, "key": String, "pid": int, "error": String}
var _gvd_peer_threads = []    # Threads de llamadas peer gvd_* antes de lanzar procesos
var _gvd_peer_states = []     # {"done": bool, "key": String, "ok": bool, ...}
var _gvd_mutex = Mutex.new()  # protege gvd_session_pids y los flags "done"
# K17: vínculo Deskflow suspendido temporalmente mientras gvd extiende el monitor
# virtual hacia ese vecino/dirección. Se guarda para restaurarlo al cortar la
# sesión de pantalla (SPEC-ui-rework-2026-10, decisión 2026-10-01).
var _gvd_link_suspended = {}      # hid -> direction
var _gvd_link_restore = {}        # hid -> true si hay que relanzar Deskflow al cortar
var _deskflow_server_launch = {}  # hid -> {cmd, args} para restaurar el servidor
# Servidor Deskflow local: se resuelve UNA sola vez si `deskflow-core` está en $PATH
# (File.file_exists, sin OS.execute) y no se recalcula por frame.
var _deskflow_probed = false  # ya se escaneó $PATH una vez
var _deskflow_core = ""       # ruta de deskflow-core en $PATH, o "" si no está
var _deskflow_input_capture = false  # server Wayland: portal InputCapture disponible
# Escrituras de config de plan (p. ej. layout Deskflow) con toggle/lanzamiento diferido
# hasta que la escritura atómica termine; patrón _persist_directions/_dir_poll sin bloquear.
var _plan_write_threads = []
var _plan_write_states = []   # {"done": bool, "then_toggle": String, "then_launch": Dictionary, "path": String}
var _plan_mutex = Mutex.new()
# swaymsg rápido (ajustes de entrada en vivo) fuera del frame: Thread one-shot con
# OS.execute bloqueante adentro; el reap vive en _process (_sway_exec_poll). Antes
# era OS.execute(..., false): Godot no reaparece y quedaban [swaymsg] <defunct>.
var _sway_exec_threads = []
var _sway_exec_states = []    # {"done": bool}
var _sway_exec_mutex = Mutex.new()
# Lo mismo para los one-shot de gdtk-rotate (rotate/hold policy): Thread + reap.
var _rotate_threads = []
var _rotate_states = []       # {"done": bool}
var _rotate_exec_mutex = Mutex.new()
# Deskflow por host: intención en memoria, nunca implícita ni automática. El
# portapapeles dejó de ser una opción (se asume compartido con "Controlar").
var host_deskflow = {}        # host_id -> bool (intención; la actividad es global)
# Avisos de lados compartidos recibidos del otro equipo (G5): cada entrada es
# {host, peer_name, type, side, state}. `side` YA viene invertido por el emisor
# (neighborhood_directions.inverse); alimenta la dockapp "Compartiendo" de ambos
# equipos. Sólo memoria: se puebla con el canal peer, nunca por frame.
var remote_shares = []
var _deskflow_settings_key = ""
var _deskflow_auto_key = ""
var _deskflow_role = "client"
# Autoarranque por defecto: el portal de la sesión se reinicia al arrancar y tumba una
# sesión InputCapture recién abierta; el primer arranque se difiere y, si el proceso
# muere igual, el tick reintenta con cooldown (ver _deskflow_arm/_deskflow_tick).
var _deskflow_want = false        # el autoarranque quiere el servicio corriendo
var _deskflow_retry_at = 0        # ticks_ms: no intentar arrancar antes de
var _deskflow_retries = 0

# Configuración (K11a): puente a ~/.config/gdtk/settings.json, releído en un Thread
# con TTL (sin I/O en el frame). El render sólo copia accent/fondo del snapshot.
var settings_bridge = null
var settings_rev = -1
var accent = Color(0.55, 0.80, 1.0, 1.0)  # RING_FOCUS por defecto; ver _apply_settings
# Apariencia (bisel/plano/relieve) desde Settings; la consumen el Hogar y el Frame.
var appearance = {"bevel": 1.0, "flat": false, "emboss": true}
# Escala de UI configurable (factor sobre la automática por resolución).
var ui_scale_factor = 1.0

# Input remoto por libei (Deskflow, lan-mouse): EIS + portal RemoteDesktop en el módulo.
var remote_input = null
var input_requests = []  # pedidos de otros procesos esperando el diálogo
var eis_cursor = null  # sin cursor propio el host (cage/sway) no lo mueve: se dibuja uno

# Volumen/mute/brillo: worker + OSD (ver system_osd.gd).
var system_osd = null

# Diagnóstico de entrada (ver remote.gd state.input): cuentan eventos que llegan al shell.
var input_motion_count = 0
var input_button_count = 0
var input_touch_count = 0
var input_last_button = {}
var input_last_key = {}
# Pointer lock (SDL relative): mientras Deskflow captura el input local, el puntero del
# compositor queda clavado en el borde y `event.relative` se vuelve ~0. Con capturado,
# sway manda movimiento relativo crudo y el cursor remoto sí avanza (ver RemoteInput).
var mouse_locked = false
# Pointer lock pedido por un cliente alojado (zwp_locked_pointer_v1: SDL relativo de
# emuladores/juegos). A diferencia de Deskflow, el foco del cliente se conserva y el
# shell le manda `event.relative` por compositor.pointer_motion_relative.
var client_pointer_locked = false
# Cursor oculto pedido por el cliente con foco (wl_pointer.set_cursor con surface
# NULL; ver compositor.client_cursor_hidden). El shell debe ocultar su cursor
# dibujado mientras dure, aunque no haya pointer lock.
var client_cursor_hidden = false
var remote_cursor_parked = false  # Deskflow dejó este equipo: puntero oculto hasta mover el mouse
var remote_parked_at = 0
var client_cursor_shape = Input.CURSOR_ARROW  # forma pedida por la app (cursor-shape)
var client_cursor_tex = null                  # o imagen propia (set_cursor con surface)
var client_cursor_hot = Vector2.ZERO
var _client_cursor_applied = null
# Log temporal [ptr-lock] del camino de movimiento relativo: primeras 20 muestras
# y despues 1 de cada 100. Para quitarlo: borrar _ptr_log_motion/estas vars y las
# llamadas que buscan "[ptr-lock]" en _set_client_pointer_lock y _forward_client_pointer.
var _ptr_log_samples = 0
var last_key_target = -1  # última ventana que recibió teclas (para reenviar sueltas)

# --- Pantallas ---
# Cada ventana raíz ocupa una "pantalla" a tamaño completo (1:1: se pide el tamaño al
# cliente). Por default todas van en una sola fila horizontal y sólo la enfocada está
# a la vista: cambiar de pantalla desliza (Ctrl+Alt+←/→, ver _focus_dir). Varias
# ventanas pueden compartir una pantalla: son un "grupo" (split) que se arma arrastrando
# un ítem sobre otro en el Frame y se deshace arrastrándolo fuera.
# `minimized` son ventanas ocultas (siguen vivas; se restauran desde el Frame).
# Alt+Tab cambia de app (ventana), Ctrl+Alt+←/→ cambia de pantalla en la fila.
var tiles = []           # orden de las ventanas visibles (una por entrada, sin minimizadas)
# K13h: registro de unidades tiled (pantallas partidas) con eje. Reemplaza el par
# `groups` + `split_weight`: cada registro es
# {"id": leader, "members": [ids], "axis": "x"|"y", "weights": {id: float}}.
# El acceso de compatibilidad es _group_of()/_weight(); la fila se arma en _units().
var wm_units = []
var minimized = {}       # id -> true
var unit_focus = {}      # id-líder de la pantalla -> último miembro enfocado
var focused_tile = -1
var tile_mode = false
var tile_nodes = {}      # id -> Control (contenedor de capas de la ventana)
var deco_nodes = {}      # id -> Control (decoración OpenStep; intercalada sobre la ventana)
var tile_rects = {}      # id -> Rect2 en coords de la vista
var tile_fit = {}        # id -> {"scale", "offset"}: transform del contenido (para input)
var tile_anim = {}       # id -> {"from": Rect2 footprint visible, "since": int}
var tile_fade = {}       # id -> ms en que apareció (fade-in)
var tile_intro = {}      # id -> true: falta su primera textura para animar la entrada
var expose = false
var expose_sel = 0
var expose_cards = {}    # id -> Rect2 de la ventana en exposé (coords de vista)
var expose_unit_cards = []  # Rect2 de cada workspace (pantalla) en exposé
var expose_hover = -1    # id de la ventana bajo el puntero en exposé (-1 = ninguna)
var expose_units = []    # unidades mostradas en exposé (sólo con contenido, sin ranuras vacías)
var expose_unit_src = [] # índice en _units() de cada ranura de expose_units
var expose_drag = null   # miniatura arrastrada: {"id", "from", "grab", "pos", "moved"}
var expose_drag_target = -1  # ranura destino del arrastre (-1 = ninguna)
var expose_drag_gap = -1  # hueco de inserción bajo el cursor durante el arrastre (-1 = ninguno)
var ghosts = []          # cierres/minimizados animados: {"node", "from", "to", "since"}
var ghost_layer = null   # capa por encima de apps y Home para el fantasma de cierre
# Rect (coords de vista) del ícono que lanzó la próxima ventana: ancla la animación de
# entrada (escala desde el ícono). Se consume en _add_tile; expira a los pocos segundos.
var pending_origin = null
var pending_origin_since = 0
# Origen por actividad/app (match con timeout): permite escalar cada ventana nueva
# DESDE SU ícono aunque haya varios lanzamientos en vuelo y lleguen desordenados.
var launch_origins = {}   # name -> {"rect": Rect2, "since": ms}
const LAUNCH_ORIGIN_MS = 4000
# Notificación de arranque: nombre de actividad -> ms en que se pidió lanzarla.
# Mientras siga acá y la actividad no tenga ventana/estado abierto, su ítem pulsa.
var starting = {}
# SVG de Sugar ya rasterizados: "nombre|stroke|fill" -> ImageTexture.
var sugar_icons = {}
# Íconos Slug por clave (GLES3): textura de Viewport + el SlugVector que la respalda.
var slug_icons = {}
var slug_vectors = {}
# Tamaño en px del TTF ya horneado (-1 = sin cargar).
var ui_font_px = -1.0
# El daemon de auto-rotación se arranca una sola vez (ver _maybe_start_rotate).
var rotate_autostarted = false
# Animación de transformación (entrar/salir de exposé, reacomodo): id -> {"from": Rect2 footprint visible, "since"}.
var view_anim = {}
# Pantalla completa (Alt+F11): la ventana enfocada ocupa todo y se esconde el Frame.
var fullscreen_id = -1
# El reparto por pesos vive en cada registro de `wm_units` (ver _weight/_resize_to).
const SHELL_CHROME_APPS = ["transmission"]  # fragmentos de app_id que siempre llevan chrome del shell
# Ventana maximizada en su workspace: id -> {"members": [ids], "weights": {id: w}}.
# Recuerda la franja partida previa para poder restaurarla (boton max/desmax de la app,
# Alt+F10 o comando remoto). Ver _maximize_window / _restore_maximized_window.
var maximize_state = {}
var handles = []         # asas de la franja enfocada: {"x", "y", "h", "i", "left", "right"}
var hover_handle = null
var resize_handle = null
# K13 — Estado híbrido: modo por ventana (flotante/mosaico), ancla a su pantalla y
# rect flotante recordado. El "modo global" ya no existe; cada ventana decide.
var hybrid = WM_HYBRID.new()
var swipe = SWIPE_MODEL.new()
var swipe_mode = ""   # "" | "pan" (escritorios) | "expose" (entrar/salir) | "none"
var swipe_levels = []        # niveles de la cadena vertical en este gesto
var swipe_start_level = 0
var swipe_live = 0            # nivel que se ve ahora (SWIPE_SEG = dentro del tramo pantalla<->exposé)
var swipe_seg_from = 0
const SWIPE_SEG = 99
var swipe_k = 0.0     # fracción de la animación del exposé fijada por los dedos
var home_ring_hidden = false  # el anillo se ocultó durante el paneo: re-entra animado
var fade_skip_until = 0  # ms: el cambio de vista llega por deslizamiento, sin fundido
var home_bg_alpha = 1.0   # alfa del fondo del Hogar mientras aparece por el paneo
var _prev_units = [[]]   # unidades del frame anterior (hybrid.heal_anchors)
var _fs_sent = -1         # última ventana a la que se le avisó xdg "fullscreen"
var float_layout = FLOAT_LAYOUT.new()
var window_rects = {}        # id -> Rect2 exterior (marco+barra) en coords de pantalla
var wm_maximized = {}        # id -> true: maximizada estando en flotante
var csd_hover_id = -1         # ventana CSD con el puntero encima (muestra su asa de mover)
var csd_grip_show_id = -1     # ventana cuyo asa de mover se dibuja (o se está replegando)
var csd_grip_reveal = 0.0     # 0 = oculta detrás de la ventana, 1 = asomada del todo
var csd_grip_dir = 0          # 1 asomando, -1 replegándose, 0 quieta
var csd_grip_from = 0.0       # reveal al empezar la animación actual
var csd_grip_since = -1
var _max_sent = {}            # id -> último estado xdg "maximized" enviado al cliente
var chrome_drag = null       # {id, kind, edge, grab, start, from} del arrastre de chrome
var drag_overlay = null      # {id, kind, rect} geometría fantasma mientras se redimensiona
var float_memory = {}        # id -> Rect2 exterior recordado (al volver a flotante se restaura)
var wm_anim = {}             # id -> {"from": Rect2, "since": ms} transición tiled<->flotante
var wm_switch_until = -1     # ms hasta cuándo iniciar transiciones de modo (-1: inactivo)
var last_pointer_pos = null  # Vector2 del último motion: ancla el arrastre pedido por el cliente
# Drag and drop nativo (wl_data_device). El icono lo compone el compositor y se
# dibuja como TextureRect en una CanvasLayer alta, pegado al puntero. Si el
# cliente no manda textura (dmabuf no legible) se dibuja un placeholder, para que
# SIEMPRE haya feedback visual. `client_drag_active` permite seguir reenviando
# botón/foco aunque el cursor salga de toda ventana.
var drag_icon_tex = null
var drag_icon_node = null
var drag_layer = null        # CanvasLayer alto: el icono va encima de todo
var drag_placeholder_tex = null
var drag_icon_samples = 0    # logging [drag-icon] de las primeras muestras
var client_drag_active = false
# Modificadores cuya PULSACIÓN se reenvió a la app y cuya suelta todavía no. Si la
# suelta se pierde (la consume ImGui/Frame, p. ej. Alt+Tab), la app queda con el
# modificador pegado y las letras llegan como atajos: "no se puede escribir".
var fwd_mods = {}
var key_drop_logs = 0
var wm_box = Rect2()         # caja de contenido del último layout flotante (para encajar)
var _wm_last_title_click = {"id": -1, "at": 0}
# Menú contextual de la barra de título (botón derecho): id de la ventana y disparo.
var wm_menu_id = -1
var wm_menu_want = false
var expose_scroll = 0.0  # exposé: reservado (todo entra en pantalla; la rueda navega)
var pan = 0.0            # scroll suave entre workspaces (Super+rueda): offset continuo
var pan_active = false   # true mientras se panea; cae al más cercano al soltar Super
# Hogar como pantalla extra al final de la fila (índice units.size()): su deslizamiento
# discreto (flechas/rueda con el Frame) se anima; el continuo (Super+rueda) usa `pan`.
var home_slide_since = -1
var home_slide_from = 0.0
var home_slide_to = 0.0
var window_dragging = false  # Super+arrastre de una ventana: el view no reenvía al cliente
var instant_switch = false   # Alt+Tab: reubicar las pantallas sin animación (1 frame)
var focus_flash = 0      # ms del último cambio de foco (borde que destella)
var tiles_ui = null
var expose_bg = null     # fondo oscuro de exposé, detrás de los tiles
const TILE_GAP = 3.0
const TILE_ANIM_MS = 320
# Transición tiled<->flotante (K13): misma familia de ease que el resto.
const WM_SWITCH_MS = 320
const TILE_FADE_MS = 440
const GHOST_MS = 380
const INTRO_MS = 480
const CSD_GRIP_MS = 170      # deslizamiento del asa de mover CSD desde detrás de la ventana
const EXPOSE_MS = 430
const FOCUS_FLASH_MS = 260
const HANDLE_HIT = 7.0
const EXPOSE_PAD = 28.0
const EXPOSE_GAP = 18.0
# Zoom out: escala máxima del workspace (con uno solo, para que se note el achique).
const EXPOSE_MAX_SCALE = 0.62
# Lado del botón de cerrar de cada ventana en exposé (se ajusta al tamaño de la tarjeta).
const EXPOSE_CLOSE_MAX = 22.0
# Aire entre ventanas en exposé: se encoge cada tarjeta unos px para que las ventanas
# de un workspace partido no queden pegadas (antes las separaba el borde azul de foco).
const EXPOSE_CARD_INSET = 4.0
# Selección en exposé (sin borde): la ventana elegida se agranda y se aclara un poco.
const EXPOSE_SEL_SCALE = 1.03
const EXPOSE_SEL_BRIGHT = 1.13
# Umbral para distinguir un clic (elegir) de un arrastre de miniatura (mover de escritorio).
const EXPOSE_DRAG_PX = 6.0
const MOD_KEYS = [KEY_CONTROL, KEY_SHIFT, KEY_ALT, KEY_META, KEY_SUPER_L, KEY_SUPER_R]

# Hogar: fila(s) de favoritos centradas (SPEC-sugar-home-visual). Íconos de actividad
# con fill claro + stroke oscuro-medio, y estados por contorno/atenuación además del
# color (SPEC-resource-ring).
# Íconos Sugar de actividad: la placa del círculo es oscura, así que el relleno va
# claro para despegarla y el trazo oscuro-medio para definir la silueta.
const SUGAR_FILL = Color(0.96, 0.95, 0.90, 1.0)
const SUGAR_STROKE = Color(0.32, 0.30, 0.38, 1.0)
# Favoritos/actividades: círculos grandes en fila horizontal centrada. Todos los
# tamaños salen de la unidad de rejilla (ver grid_unit), no de constantes en px.
const HOME_BG_TOP = Color(0.12, 0.13, 0.17, 1.0)
const HOME_BG_BOTTOM = Color(0.05, 0.06, 0.09, 1.0)
# Bloque "Apps" del Hogar: misma familia biselada (gris azulado) que los bloques del Frame.
const HOME_BLOCK_FACE = Color(0.27, 0.31, 0.41, 1.0)
const HOME_BLOCK_LIGHT = Color(0.53, 0.59, 0.73, 1.0)
const HOME_BLOCK_DARK = Color(0.07, 0.08, 0.13, 1.0)
const HOME_BLOCK_TEXT = Color(0.92, 0.93, 0.97, 1.0)
const HOME_BEVEL = 2.0
const RING_PLATE = Color(0.10, 0.11, 0.14, 0.88)
const RING_CLOSED = Color(0.62, 0.64, 0.70, 0.55)
const RING_OPEN = Color(0.98, 0.72, 0.30, 0.95)
const RING_FOCUS = Color(0.55, 0.80, 1.0, 1.0)
const RING_MIN = Color(0.56, 0.59, 0.68, 0.90)  # minimizada: contorno punteado atenuado
const RING_LABEL = Color(0.90, 0.91, 0.94, 1.0)
const RING_LABEL_DIM = Color(0.72, 0.74, 0.79, 1.0)
# Favorito cerrado (app fijada al anillo sin ventana viva): contorno más definido
# que una actividad cerrada, sin fingir "abierto" (SPEC-sugar-home-visual).
const RING_FAVORITE = Color(0.66, 0.68, 0.76, 0.95)
# Animación del layout del anillo y de la barra del Frame al reacomodar.
const LAYOUT_MS = 220
const RING_INTRO_MS = 260
const DRAG_PX = 8.0
# Distribución del anillo en espiral de ángulo áureo, con jitter determinista.
# Hasta esta cantidad, un solo círculo ordenado; más, espiral (bubbles).
const RING_CIRCLE_MAX = 7

# Íconos Sugar: los SVG traen un DOCTYPE con entidades &stroke_color;/&fill_color;.
# Se cargan como texto, se sustituyen por los colores pedidos y se rasterizan a una
# ImageTexture cacheada (el motor no expone load_svg_from_string en este árbol).
const SUGAR_DIR = "res://icons/sugar/"
const SUGAR_RASTER = 192  # px del SVG al rasterizar (se dibuja a ~120)
const SLUG_RASTER = 256   # px del SVG al renderizar con Slug (GLES3)
# Texto nítido: TTF cargado en runtime y horneado al tamaño exacto (ver _sync_ui_font).
const UI_FONT_FILE = "res://fonts/DejaVuSans.ttf"
const UI_FONT_PX = 16.0   # px a escala 1 (U=80); el resto sale de ui_scale
# Íconos nuevos (The Noun Project, ver icons/np/CREDITS.txt): PNG 200 px claros
# con transparencia. El rasterizador de Sugar no aplica (no son SVG con
# entidades), así que se cargan como ImageTexture y se cachean aparte.
const NP_DIR = "res://icons/np/"
const DEVICE_ICONS = {
	"desktop": "device-desktop",
	"laptop": "device-laptop",
	"tablet": "device-tablet",
	"mobile": "device-mobile",
	"tv": "device-tv",
}
# Actividades sin ícono XDG con un ícono Sugar razonable (el resto usa inicial).
const SUGAR_ACTIVITY_ICONS = {
	"Gears": "emblem-busy",
	"Deskflow": "network-wired",
	"Configuración": "preferences-system",
}
# Notificación de arranque estilo Sugar: pulso ~1.2 s hasta que aparece la ventana.
const STARTING_MAX_MS = 15000
const STARTING_PERIOD_S = 1.2


# Unidad de rejilla única del Hogar y del Frame: la pantalla se reparte en celdas
# cuadradas de U px. Se ata al lado CORTO (min) dividido 10, no a 16x10 fijo: así
# la escala es la misma en apaisado y en vertical. Antes usaba min(x/16, y/10), que
# en portrait (p. ej. 1440x2160) daba U=90 en vez de 144 y encogía bloques y fuentes.
# El mínimo de 80 garantiza que el ícono de 64 entre holgado en cualquier resolución.
# Todo bloque/salto del Hogar y del Frame sale de acá; no se repiten números.
func grid_unit(vp):
	return max(80.0, floor(min(vp.x, vp.y) / 10.0)) * ui_scale_factor


# Unidad base de la grilla: con U=80 la UI está a escala 1. La resolución ya escala
# los bloques; con el texto hay que hacer lo mismo o queda diminuto respecto de
# ellos (p. ej. 2160x1440 da U=135 y el font de 13 px se ve mini). Se ata a la
# grilla y se aplica a ImGui (font + estilo) y a los offsets del shell, que ya
# multiplican por get_imgui_scale().
const GRID_BASE = 80.0

func ui_scale(vp):
	return clamp(grid_unit(vp) / GRID_BASE, 0.5, 4.0)


# Mantiene la escala de UI sincronizada con el viewport (barato e idempotente).
func _sync_ui_scale():
	var want = ui_scale(get_viewport_rect().size)
	if abs(want - get_imgui_scale()) > 0.01:
		imgui_scale = want
	_sync_ui_font(want)


# TTF nítido: se hornea al tamaño exacto (px base * escala) y el motor queda con
# FontGlobalScale=1 (font_scale_override), así el atlas no se reescala al dibujar.
# La fuente por defecto de ImGui es un bitmap de 13 px y se ve borrosa al agrandar.
func _sync_ui_font(scale):
	var px = round(UI_FONT_PX * scale)
	if abs(px - ui_font_px) < 0.5:
		return
	if not File.new().file_exists(UI_FONT_FILE):
		return
	ui_font_px = px
	var idx = add_font(UI_FONT_FILE, px, "default")
	if idx >= 0:
		set_default_font(idx)
		# Recién con la fuente horneada al tamaño exacto se fija FontGlobalScale=1:
		# así el atlas no se reescala. Si el TTF no carga, se deja la fuente por
		# defecto escalada (borrosa pero del tamaño correcto). call() por si el
		# método no está en un binario viejo.
		if has_method("set_font_scale_override"):
			call("set_font_scale_override", 1.0)


# Ancho real del texto con la fuente activa (proporcional). Centrar estimando
# chars*7 desalineaba con el TTF. Fallback si el binario no trae calc_text_size.
func _text_w(s):
	if has_method("calc_text_size"):
		return call("calc_text_size", s).x
	return s.length() * 7.0 * get_imgui_scale()


# Alto de las barras del Frame (superior e inferior). Una unidad completa; si la
# pantalla es tan baja que dos barras de U tapan el área de apps, se usa media
# unidad (sin bajar de 64, el ícono más chico antes del caso extremo).
func frame_bar_h(vp):
	var u = grid_unit(vp)
	# Entero: una altura fraccionaria deja el borde pegado a la pantalla con
	# antialiasing parcial y se filtra 1 px de la app que está debajo.
	if vp.y >= 3.0 * u:
		return ceil(u)
	return max(64.0, floor(u * 0.5))


# --- K12/K19: hueco del Frame ------------------------------------------------
# Lados que el Frame RESERVA para las ventanas: sólo las barras fijadas (pin).
# Con autohide (default en ambas) no reserva nada y la barra se superpone a la
# ventana sin redimensionarla; una barra fijada ocupa su franja y la ventana no
# se coloca debajo/encima de ella. Lo decide el propio Frame (frame.reserved_edges).
func _frame_edges():
	if frame == null or not is_instance_valid(frame):
		return {}
	return frame.reserved_edges()


# Rect de las ventanas top-level y de los diálogos: el viewport menos las barras
# fijadas. No sigue el deslizamiento del autohide (por eso las ventanas no se
# redimensionan al mostrarse la barra).
func _tile_rect(vp):
	return CONTENT_LAYOUT.content_rect(vp, frame_bar_h(vp), _frame_edges())


# Área de los diálogos: el viewport menos un bloque por cada lado (siempre, no
# sólo lo que el Frame reserva). Los diálogos flotan sobre su ventana host dentro
# de este rect y conservan el tamaño natural que pide el cliente.
func _content_rect(vp):
	# Pantalla completa: sin Frame, los diálogos usan todo el viewport.
	if fullscreen_id >= 0:
		return Rect2(Vector2.ZERO, vp)
	return CONTENT_LAYOUT.dialog_area(vp, frame_bar_h(vp))


# --- K13: modo híbrido por ventana (flotante / mosaico) ----------------------
#
# Ya no hay modo global: cada ventana es "floating" (con chrome) o "tiled"
# (miembro de una unidad del mosaico). Default: flotante. Las flotantes viven en
# `float_layout` y quedan ancladas a su pantalla (`hybrid.anchor`).

# Modo de una ventana (sin id: la enfocada). Default flotante.
func is_floating(id = -1):
	if id < 0:
		id = focused_tile
	if id < 0:
		return true
	return hybrid.is_floating(id)


func is_tiled_window(id):
	return not hybrid.is_floating(id)


func wm_mode_label():
	return "Flotante" if is_floating() else "Mosaico"


# Cambia el modo de UNA ventana. Al pasar a mosaico la deja como unidad propia (o la
# une a su ancla); al volver a flotante recuerda su rect previo (float_memory).
func set_window_mode(id, mode, anchor = null):
	if id < 0 or not tiles.has(id):
		return
	var m = WM_HYBRID.normalize_mode(mode)
	if m == WM_HYBRID.FLOATING:
		if hybrid.is_tiled(id):
			_remember_float_geometry()
			WM_UNITS.remove(wm_units, id)
			wm_maximized.erase(id)
		# Al volver a flotante ningún flag de maximizado debe sobrevivir: si no, la
		# ventana queda "maximizada" stale (sin sombra, sin handles, restore roto).
		maximize_state.erase(id)
		var a = int(anchor) if anchor != null else hybrid.anchor(id, WM_HYBRID.ESCRITORIO)
		hybrid.set_floating(id, a, float_memory.get(id, null))
	else:
		if hybrid.is_floating(id):
			_remember_float_geometry()
		hybrid.set_tiled(id, hybrid.anchor(id, WM_HYBRID.ESCRITORIO))
		if not WM_UNITS.has(wm_units, id):
			WM_UNITS.solo(wm_units, id, -1, _default_axis())
		wm_maximized.erase(id)
	_focus_tile(id)
	wm_anim.clear()
	wm_switch_until = OS.get_ticks_msec() + WM_SWITCH_MS
	_reset_cursor()
	request_redraw()


func toggle_window_mode(id = -1):
	if id < 0:
		id = focused_tile
	if id < 0 or not tiles.has(id):
		return
	set_window_mode(id, WM_HYBRID.FLOATING if hybrid.is_tiled(id) else WM_HYBRID.TILED)


# Compatibilidad (Frame/atajos viejos): aplica el modo a todas las ventanas.
func set_wm_mode(mode):
	for id in tiles.duplicate():
		set_window_mode(id, mode)


func cycle_wm_mode():
	toggle_window_mode()


func _default_axis():
	return WM_UNITS.default_axis(_tile_rect(get_viewport_rect().size))


# Guarda la geometría flotante actual para restaurarla al volver a flotante. No
# pisa el rect de ventanas minimizadas (que ya no están en float_layout).
func _remember_float_geometry():
	for id in float_layout.rects.keys():
		float_memory[id] = float_layout.rects[id]


# "Acomodar ventanas": re-cascada de las flotantes; el mosaico conserva su reparto.
func arrange_windows():
	float_layout.reset()
	wm_maximized.clear()
	wm_anim.clear()
	wm_switch_until = OS.get_ticks_msec() + WM_SWITCH_MS
	request_redraw()


# Alto del chrome y bisel, escalados por la UI (mismos números base del modelo).
func _chrome_title_h():
	return WINDOW_CHROME.TITLE_H * get_imgui_scale()


func _chrome_border():
	return WINDOW_CHROME.BORDER * get_imgui_scale()


func _chrome_resize_h():
	return WINDOW_CHROME.RESIZE_H * get_imgui_scale()


# ¿La ventana se dibuja su propia decoración (CSD: GTK4, etc.)? En ese caso el shell
# no dibuja chrome ni reserva barra, y el arrastre llega por request_move/resize o
# por Super+clic.
func _is_csd(id):
	if compositor == null:
		return false
	# Clientes (GTK3, etc.) que nunca negocian xdg-decoration quedan como CSD por defecto
	# en wl_server.c y sin chrome; esta lista les fuerza el del shell por app_id.
	var app_id = String(compositor.get_app_id(id)).to_lower()
	for tok in SHELL_CHROME_APPS:
		if app_id.find(tok) >= 0:
			return false
	return compositor.is_csd(id)


# Nodo de decoración OpenStep de una ventana (window_deco.gd). Vive en `view`,
# intercalado sobre el contenido de su ventana (ver _compute_float_layout).
func _deco_node(id):
	var d = deco_nodes.get(id)
	if d != null and is_instance_valid(d):
		return d
	var script = Host.sc("res://window_deco.gd")
	if script == null:
		return null
	d = Control.new()
	d.name = "Deco" + str(id)
	d.set_script(script)
	d.shell = self
	d.id = id
	d.visible = false
	view.add_child(d)
	deco_nodes[id] = d
	return d


func _free_deco(id):
	_max_sent.erase(id)
	if csd_grip_show_id == id:
		csd_grip_show_id = -1
		csd_grip_reveal = 0.0
		csd_grip_dir = 0
	if csd_hover_id == id:
		csd_hover_id = -1
	var d = deco_nodes.get(id)
	if d != null and is_instance_valid(d):
		d.queue_free()
	deco_nodes.erase(id)


# Materializa la colocación FLOTANTE del frame actual: sincroniza float_layout con
# las ventanas flotantes, las desplaza a la pantalla de su ancla y deriva el rect de
# contenido (tile_rects, lo que ve el cliente). `float_layout` guarda rects LOCALES
# (los de la pantalla centrada); el offset por ancla los lleva a coords de pantalla.
# `units`/`s` se reaprovechan del layout de fila para no recomputarlos.
func _compute_float_layout(cr, units = null, s = 0.0):
	wm_box = cr
	if units == null:
		units = _units()
		s = _row_s(units)
	var vp = get_viewport_rect().size
	for id in float_layout.ids_z():
		if not tiles.has(id) or not hybrid.is_floating(id):
			float_layout.remove(id)
	var th = _chrome_title_h()
	var bd = _chrome_border()
	var rh = _chrome_resize_h()
	for id in tiles:
		if minimized.has(id) or not hybrid.is_floating(id):
			continue
		if not float_layout.has(id):
			# Restaura el lugar previo si lo recordamos; si no, cascada nueva.
			if float_memory.has(id) and float_memory[id] != null:
				float_layout.restore_one(id, float_memory[id], cr)
			else:
				float_layout.place_new(id, cr)
		else:
			float_layout.drag_to(id, float_layout.rect(id).position, cr)
		var local = float_layout.rect(id)
		if local == null:
			local = cr
		# Memoria por ventana: guarda el rect local (no el maximizado).
		float_memory[id] = local
		var ai = _anchor_index(units, id)
		var off = Vector2((float(ai) - s) * vp.x, 0.0)
		var fr = Rect2(local.position + off, local.size)
		if wm_maximized.has(id):
			fr = Rect2(cr.position.x + off.x, cr.position.y, cr.size.x, cr.size.y)
		window_rects[id] = fr
		# Con decoración del cliente (CSD: GTK4, etc.) no reservamos barra: el cliente
		# dibuja su propia barra dentro del rect; el shell sólo gestiona geometría.
		if _is_csd(id):
			tile_rects[id] = fr
		else:
			tile_rects[id] = WINDOW_CHROME.content_rect(fr, th, bd, rh)
		_deco_node(id)
		_sync_client_maximized(id, wm_maximized.has(id))
	# Un solo orden de apilado para flotantes y tiled: abajo las tiled nunca elevadas,
	# después las flotantes en su orden y encima lo elevado por clic/foco (z_stack), sea
	# flotante o tiled. Antes las flotantes iban siempre encima y clickear una tiled que
	# estaba debajo no la traía al frente.
	z_order_now = []
	for id in float_layout.ids_z():
		if not z_stack.has(id):
			z_order_now.append(id)
	for id in z_stack:
		if tiles.has(id) and not minimized.has(id):
			z_order_now.append(id)
	for id in z_order_now:
		var n = tile_nodes.get(id)
		if n != null and is_instance_valid(n):
			view.move_child(n, view.get_child_count() - 1)
			var d = deco_nodes.get(id)
			if d != null and is_instance_valid(d):
				if hybrid.is_floating(id):
					d.visible = true
				view.move_child(d, view.get_child_count() - 1)


# Índice de la unidad (en `_units()`) a la que está anclada una ventana flotante.
# El ancla se guarda como id-líder de la unidad (0 = Escritorio), así sobrevive a
# reordenamientos de la fila.
func _anchor_index(units, id):
	var a = int(hybrid.anchor(id, WM_HYBRID.ESCRITORIO))
	if a <= 0:
		return 0
	for i in range(1, units.size()):
		if units[i].has(a):
			return i
	return 0


# Estado xdg "maximized" del cliente (bordes/sombra y ícono restaurar). Sólo se
# envía si cambia; requiere WaylandCompositor.set_maximized(id, bool), que un binario
# anterior no expone (entonces no hace nada).
func _sync_client_maximized(id, maximized):
	if _max_sent.get(id, null) == maximized:
		return
	if not ClassDB.class_has_method("WaylandCompositor", "set_maximized"):
		return
	_max_sent[id] = maximized
	compositor.call("set_maximized", id, maximized)


# Estado xdg "fullscreen" del cliente: el shell sale de pantalla completa por muchos
# caminos (foco a otra ventana, Alt+F10/F11, un selector de archivos nuevo) y el
# cliente debe enterarse o se queda con su UI de fullscreen. Un solo punto, por frame.
# Requiere WaylandCompositor.set_fullscreen (un binario anterior no lo expone).
func _sync_client_fullscreen():
	if _fs_sent == fullscreen_id or compositor == null:
		return
	if compositor.has_method("set_fullscreen"):
		if _fs_sent >= 0 and _id_alive(_fs_sent):
			compositor.call("set_fullscreen", _fs_sent, false)
		if fullscreen_id >= 0 and _id_alive(fullscreen_id):
			compositor.call("set_fullscreen", fullscreen_id, true)
	_fs_sent = fullscreen_id


# Hover de las ventanas CSD: la de más arriba bajo el puntero (o cerca de su borde
# superior) muestra el asa de mover. Durante un arrastre se queda en esa ventana.
func _update_csd_hover(pos):
	var h = -1
	if chrome_drag != null:
		h = int(chrome_drag.get("id", -1)) if _is_csd(int(chrome_drag.get("id", -1))) else -1
	else:
		var scale = get_imgui_scale()
		var gin = grid_unit(get_viewport_rect().size)
		for id in _hit_order_ids():
			if id == fullscreen_id or minimized.has(id) or not tiles.has(id):
				continue
			var fr = window_rects.get(id, null)
			if fr == null:
				continue
			# Una maximizada no muestra asa; el cliente dibuja su barra y la ventana
			# llena el hueco. Pero un cliente CSD que no arrastra su propia barra
			# (Electron/VS Code) quedaría sin forma de restaurar salvo Super, así que
			# en maximizada el asa se muestra DENTRO del borde superior.
			var maximized = wm_maximized.has(id) or maximize_state.has(id)
			if WINDOW_CHROME.move_grip_hover(pos, fr, scale, gin, maximized):
				h = id if _is_csd(id) else -1
				break
	if h != csd_hover_id:
		csd_hover_id = h
		request_redraw()
	_update_csd_grip(h)

# Estado del asa de mover CSD: al apuntar una ventana se desliza desde detrás de su
# borde superior; al salir se repliega. Un solo asa visible a la vez (la de más arriba).
func _update_csd_grip(h):
	var now = OS.get_ticks_msec()
	if h >= 0:
		if h != csd_grip_show_id:
			csd_grip_show_id = h
			csd_grip_reveal = 0.0
			csd_grip_dir = 1
			csd_grip_from = 0.0
			csd_grip_since = now
			request_redraw()
		elif csd_grip_dir != 1:
			csd_grip_dir = 1
			csd_grip_from = csd_grip_reveal
			csd_grip_since = now
	elif csd_grip_show_id >= 0 and csd_grip_dir != -1:
		csd_grip_dir = -1
		csd_grip_from = csd_grip_reveal
		csd_grip_since = now


# Tick por frame del asa CSD (ver _process): sube/baja con ease-out.
func _tick_csd_grip(now):
	if csd_grip_dir == 0:
		return
	var to = 1.0 if csd_grip_dir > 0 else 0.0
	var k = clamp(float(now - csd_grip_since) / float(CSD_GRIP_MS), 0.0, 1.0)
	var e = 1.0 - pow(1.0 - k, 3.0)
	csd_grip_reveal = lerp(csd_grip_from, to, e)
	if k >= 1.0:
		csd_grip_reveal = to
		csd_grip_dir = 0
		if to <= 0.0:
			csd_grip_show_id = -1
	request_redraw()


# Orden de hit-test de las ventanas: flotantes de arriba hacia abajo (z-order),
# luego las tiled en el orden de `tiles`. Las que aún no están en el layout van al final.
func _hit_order_ids():
	var out = popup_owners.duplicate()  # sus menús van encima de todo (también al clic)
	var floats = z_order_now.duplicate()  # mismo apilado que el dibujo (ver _compute_float_layout)
	floats.invert()
	for id in floats:
		if not out.has(id):
			out.append(id)
	for id in tiles:
		if not out.has(id):
			out.append(id)
	return out


# Zona de chrome bajo el punto: la ventana flotante más arriba cuyo marco la
# contenga (excepto si el punto cae en el contenido, que va al cliente).
func _chrome_pick(pos):
	var th = _chrome_title_h()
	var bd = _chrome_border()
	var scale = get_imgui_scale()
	var btn = WINDOW_CHROME.BTN * scale
	var bhit = WINDOW_CHROME.BORDER_HIT * scale
	var rh = _chrome_resize_h()
	for id in _hit_order_ids():
		if id == fullscreen_id or minimized.has(id) or not tiles.has(id):
			continue
		if not hybrid.is_floating(id):
			# Una tiled elevada por encima tapa el chrome de las flotantes de abajo.
			var tr = tile_rects.get(id)
			if z_stack.has(id) and tr != null and tr.has_point(pos):
				return null
			continue
		var fr = window_rects.get(id, null)
		if fr == null:
			continue
		# CSD: el cliente dibuja su barra; su rect es contenido salvo el pill de mover
		# y la franja inferior de redimensión del shell. En una maximizada el cliente
		# no puede arrastrar su propia barra (p. ej. Electron no pide xdg move y la
		# ventana queda sin forma de restaurar salvo Super): el shell deja el asa
		# DENTRO del borde superior para poder tirar de ella y desmaximizar.
		if _is_csd(id):
			var maximized = wm_maximized.has(id) or maximize_state.has(id)
			var cpart = WINDOW_CHROME.csd_hit(pos, fr, scale,
				grid_unit(get_viewport_rect().size), maximized)
			if cpart != "":
				return {"id": id, "part": cpart}
			if Rect2(fr).has_point(pos):
				return null
			continue
		var part = WINDOW_CHROME.hit(pos, fr, th, bd, btn, bhit, rh)
		if part == "":
			continue
		# La ventana de arriba que contiene el punto manda: su contenido va al cliente
		# y no se busca chrome de ventanas de abajo.
		if part == "content":
			return null
		return {"id": id, "part": part}
	return null


# Ícono del equipo local: el mismo `kind` que publica el Vecindario (o "unknown",
# que cae al ícono de escritorio). Es el que va en el bloque Inicio del Frame y en
# la placa central del mapa, en lugar de una casita genérica.
func local_device_icon_tex():
	return device_icon_tex(local_device_kind())


# Ícono por kind de Vecindario (desktop/laptop/tablet/mobile/tv). Cae al ícono de
# escritorio para "unknown" o si el PNG del kind no está (nunca al XO).
func device_icon_tex(kind):
	var name = DEVICE_ICONS.get(String(kind), "device-desktop")
	var tex = _load_np_icon(name)
	if tex != null:
		return tex
	return _load_np_icon("device-desktop")


# Ícono del bloque Vecindario del Frame.
func neighborhood_icon_tex():
	var tex = _load_np_icon("wireless")
	if tex != null:
		return tex
	return _load_sugar_svg("network-wireless", SUGAR_STROKE, SUGAR_FILL)


# Tipo de equipo local resuelto una vez: override GDTK_DEVICE_KIND > chasis DMI >
# presencia de batería > unknown (ver device_kind.gd). Barato e idempotente.
var _local_kind = null

func local_device_kind():
	if _local_kind != null:
		return _local_kind
	var chassis = _read_sysfs_line("/sys/class/dmi/id/chassis_type")
	var product = _read_sysfs_line("/sys/class/dmi/id/product_name")
	_local_kind = DEVICE_KIND.detect(OS.get_environment("GDTK_DEVICE_KIND"), chassis, _has_battery(), product)
	return _local_kind


# Primera línea de un archivo sysfs, o "" si no existe/no se puede leer.
func _read_sysfs_line(path):
	var f = File.new()
	if not f.file_exists(path) or f.open(path, File.READ) != OK:
		return ""
	var text = f.get_as_text().strip_edges()
	f.close()
	return text


# ¿Hay alguna batería? Sólo un indicio para inferir portátil cuando el DMI no
# ayuda. No bloquea: lista un directorio acotado.
func _has_battery():
	var d = Directory.new()
	if d.open("/sys/class/power_supply") != OK:
		return false
	d.list_dir_begin(true, true)
	var found = false
	while true:
		var n = d.get_next()
		if n == "":
			break
		if n.begins_with("BAT"):
			found = true
			break
	d.list_dir_end()
	return found


func _ready():
	connect("imgui_frame", self, "_imgui_frame")
	compositor.connect("toplevel_added", self, "_on_toplevel_added")
	compositor.connect("toplevel_removed", self, "_on_toplevel_removed")
	compositor.connect("toplevel_activate", self, "_on_toplevel_activate")
	compositor.connect("toplevel_minimize", self, "_on_toplevel_minimize")
	compositor.connect("toplevel_maximize", self, "_on_toplevel_maximize")
	compositor.connect("toplevel_fullscreen", self, "_on_toplevel_fullscreen")
	compositor.connect("toplevel_move", self, "_on_toplevel_move")
	compositor.connect("toplevel_resize", self, "_on_toplevel_resize")
	# Lock de puntero pedido por un cliente (SDL relativo). has_signal mantiene la
	# compatibilidad con binarios viejos (sin el módulo recompilado).
	if compositor.has_signal("pointer_lock"):
		compositor.connect("pointer_lock", self, "_on_client_pointer_lock")
	# Cursor pedido por el cliente (surface NULL = oculto). has_signal mantiene la
	# compatibilidad con binarios viejos (sin el módulo recompilado).
	if compositor.has_signal("client_cursor_hidden"):
		compositor.connect("client_cursor_hidden", self, "_on_client_cursor_hidden")
	# Cursor que pide la app: forma (wp_cursor_shape_v1) o imagen (wl_pointer.set_cursor).
	if compositor.has_signal("client_cursor_shape"):
		compositor.connect("client_cursor_shape", self, "_on_client_cursor_shape")
	if compositor.has_signal("client_cursor_image"):
		compositor.connect("client_cursor_image", self, "_on_client_cursor_image")
	# Drag and drop nativo: el compositor avisa del icono y del estado del drag.
	# has_signal mantiene la compatibilidad con binarios viejos (sin recompilar).
	if compositor.has_signal("drag_icon_changed"):
		compositor.connect("drag_icon_changed", self, "_on_drag_icon_changed")
	if compositor.has_signal("drag_state_changed"):
		compositor.connect("drag_state_changed", self, "_on_drag_state_changed")
	# Cambios de ventanas: rearmar la UI (el Frame las lista, recovery espera la suya).
	compositor.connect("toplevel_added", self, "_redraw_on_signal")
	compositor.connect("toplevel_removed", self, "_redraw_on_signal")
	view_layer = CanvasLayer.new()
	view_layer.name = "ViewLayer"
	view_layer.layer = -1
	add_child(view_layer)
	view = Control.new()
	view.name = "View"
	view.visible = false
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	view.rect_clip_content = false
	view_layer.add_child(view)
	view.connect("gui_input", self, "_on_view_input")
	# Hijo después de Remote: su _input corre antes que el de ImGui (F6, Alt+Tab).
	# .new() sobre un script nulo aborta la expresión y saltaría el fail-fast, así
	# que se resuelve el script primero y se instancia sólo si compiló.
	var frame_script = Host.sc("res://frame.gd")
	if frame_script == null:
		push_error("gdtk: frame.gd no compiló; abortando el arranque")
		get_tree().quit(1)
		return
	frame = frame_script.new()
	# Fail-fast: si frame.gd no compila no hay UI; salir con código !=0 para que el
	# supervisor lo cuente como caída y pueda volver a la última versión buena.
	if frame == null or not is_instance_valid(frame):
		push_error("gdtk: frame.gd no compiló; abortando el arranque")
		get_tree().quit(1)
		return
	frame.name = "Frame"
	add_child(frame)
	# Vecindario: parser/estado del Wi-Fi. El hilo arranca al abrir la vista; este
	# nodo sigue dueño del resultado en memoria hasta que el shell se recarga.
	neighborhood = Host.sc("res://neighborhood.gd").new()
	neighborhood_ui = Control.new()
	neighborhood_ui.name = "NeighborhoodUI"
	neighborhood_ui.set_script(Host.sc("res://neighborhood_ui.gd"))
	neighborhood_ui.shell = self
	neighborhood_ui.model = neighborhood
	neighborhood_ui.visible = false
	view_layer.add_child(neighborhood_ui)
	# El Vecindario cachea desde el arranque: abrir la vista no debe disparar el
	# primer scan de Wi-Fi/hosts, sólo mostrar el snapshot ya disponible.
	neighborhood.start()
	# Brújula: carga local (sin red) y vuelca el modelo a la vista ya creada.
	_load_directions()
	_refresh_direction_views()
	# Configuración (K11a): puente a settings.json (lectura en Thread con TTL).
	# Se aplica antes de servicios y mDNS: Deskflow ajusta comando, rol publicado y
	# autoarranque desde Settings.
	settings_bridge = Host.sc("res://settings_bridge.gd").new()
	if settings_bridge != null:
		settings_bridge.reload_now()
		_apply_settings()
		ACTIVITIES.append({"name": "Configuración", "wayland": settings_bridge.launch_argv()})
	# Limpieza de arranque: si ya hay un deskflow-core del usuario (sesión previa,
	# lanzado a mano o dejado por una recarga), se mata ANTES de arrancar el worker
	# para no duplicar la instancia ni pelear por puerto/input. Sólo corre una vez,
	# acá en _ready; nunca en _process ni en el worker propio (§0/§14).
	_reap_stray_deskflow()
	# Servicios: worker de fondo que mide pgrep/kill -0 y publica un snapshot; el
	# dibujo y el portal RemoteInput sólo leen ese cache (nunca esperan al frame).
	_start_service_worker()
	# Si Settings pidió autoarrancar Deskflow, la primera aplicación sólo dejó el
	# comando/rol listos porque el worker aún no existía. Reaplicar acá hace la
	# escritura+arranque desde el ciclo normal de servicios.
	_apply_deskflow_settings()
	# Anuncio mDNS de la identidad local (gvd/Deskflow) fuera del frame; sin avahi
	# queda degradado y silencioso.
	_start_publishers()
	# Buzón del handshake de dirección: worker propio con TTL que publica el
	# resultado; el frame sólo copia (nunca ssh en el hilo de render, §14).
	_start_inbox()
	# Notificaciones y demás layer-shell, encima de todo (después del Frame: su _input va antes).
	add_child(Host.sc("res://layers.gd").new())

	# Capa de dialogos encima de la vista de la actividad.
	dialog_view = Control.new()
	dialog_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dialog_view.rect_clip_content = true
	dialog_view.visible = false
	view_layer.add_child(dialog_view)

	# Bordes de foco, títulos y tarjetas de exposé: se dibuja a mano (Control._draw) y no
	# captura input, así los clics siguen llegando a los tiles (una ventana ImGui sí lo haría).
	tiles_ui = Control.new()
	tiles_ui.name = "TilesUI"
	tiles_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tiles_ui.rect_clip_content = false
	tiles_ui.set_script(Host.sc("res://tiles_ui.gd"))
	tiles_ui.shell = self
	view_layer.add_child(tiles_ui)

	# Fondo de exposé: el mismo fondo del Hogar (degradado, sólido o imagen) en vez
	# del velo oscuro, detrás de los tiles (View) para no tapar las miniaturas.
	# Ver expose_bg.gd.
	var expose_script = Host.sc("res://expose_bg.gd")
	if expose_script != null:
		expose_bg = expose_script.new()
		expose_bg.shell = self
		expose_bg.visible = false
		view_layer.add_child(expose_bg)
		view_layer.move_child(expose_bg, 0)

	for arg in OS.get_cmdline_args():
		if arg.begins_with("--screenshot="):
			screenshot_path = arg.substr("--screenshot=".length())
		elif arg.begins_with("--open="):
			open_on_start = arg.substr("--open=".length())
		elif arg.begins_with("--type="):
			type_text = arg.substr("--type=".length())

	remote_input = Host.remote_input
	remote_input.connect("access_requested", self, "_on_input_access")
	if remote_input.has_signal("remote_left"):
		remote_input.connect("remote_left", self, "_on_remote_left")
	# Nodo hermano de la entrada de ImGui: permanece activo cuando `_set_capture_cursor`
	# apaga el _input de este canvas para que los clics no entren al Frame/Hogar.
	capture_input = CAPTURE_INPUT.new()
	capture_input.name = "CaptureInput"
	capture_input.shell = self
	add_child(capture_input)
	eis_cursor = _make_eis_cursor()
	# Volumen/brillo: el worker resuelve backends y lee el estado inicial; el OSD se
	# dibuja al final de _imgui_frame.
	system_osd = SYSTEM_OSD.new()
	system_osd.setup(self)

	# Sin redibujo continuo: ImGui se arma sólo con input (a input_hz), con
	# request_redraw() (commits Wayland, señales, control remoto) o al cambiar el minuto (reloj).
	# Los tests con --screenshot cuentan frames: ahí se deja el modo histórico.
	if screenshot_path == "":
		# Piso liviano para que el control remoto TCP y los workers sigan respirando
		# aun sin input ni commits Wayland. El sleep idle ya limita esto a ~4 Hz.
		update_hz = 4.0
		input_hz = 60.0
		_arm_clock()
	# El colector del HUD corría en cada vuelta del loop (60/s) aunque nada cambie.
	DebugHud.metrics.sample_hz = 4.0
	# Ni widget mini ni F1: el HUD completo se abre con Super+F6 (frame.gd).
	DebugHud.show_mini = false
	DebugHud.hotkeys = false

	# Las sesiones apagan audio/hidapi de SDL para el shell (hilos que despiertan sin
	# uso); vacías, las apps que lanza el compositor vuelven a los valores por defecto.
	for v in ["SDL_AUDIODRIVER", "SDL_JOYSTICK_HIDAPI", "SDL_HIDAPI_LIBUSB"]:
		OS.set_environment(v, "")

	if Host.live_reload:
		_adopt_windows()
	else:
		recovery.load(self)
	if open_on_start != "":
		_open_by_name(open_on_start)


# Guarda el layout (orden/unidades híbridas/foco/fullscreen/minimizadas) para
# restaurarlo tras una recarga en caliente (ver main.reload_shell).
func _save_layout():
	Host.layout = {"tiles": tiles.duplicate(),
		"units": WM_UNITS.serialize(wm_units),
		"hybrid": hybrid.serialize(),
		"minimized": minimized.keys(), "focused": focused_tile, "fullscreen": fullscreen_id,
		"maximize": maximize_state.duplicate(true)}


# Quita de `wm_units` los ids que ya no están vivos (p. ej. minimizadas), dejando
# registros con 2+ miembros. Los que quedan sueltos pasan a flotante/solas.
func _prune_units():
	for i in range(wm_units.size() - 1, -1, -1):
		var rec = wm_units[i]
		var members = []
		for m in rec["members"]:
			if tiles.has(m):
				members.append(m)
		if members.size() < 2:
			wm_units.remove(i)
			continue
		rec["members"] = members
		rec["id"] = members[0]


# Al recargar el shell, las apps siguen vivas en el compositor del Host: se rearma el
# estado (actividades y tiles) desde los toplevels existentes.
func _adopt_windows():
	var roots = []
	for id in compositor.get_ids():
		if compositor.get_parent_id(id) > 0:
			if not dialogs.has(id):
				dialogs.append(id)
		else:
			roots.append(id)
	for id in roots:
		var name = _unique_activity_name(_window_activity_name(id))
		wayland_ids[name] = id
		ACTIVITIES.append({"name": name, "wayland": [], "dynamic": true})
		_add_tile(id)
	var lay = Host.layout
	Host.layout = {}
	if typeof(lay) == TYPE_DICTIONARY and lay.get("tiles", []).size() > 0 and not roots.empty():
		var known = {}
		for id in roots:
			known[id] = true
		var order = []
		for id in lay["tiles"]:
			if known.has(id):
				order.append(id)
				known.erase(id)
		for id in known.keys():
			order.append(id)
		tiles = order
		for id in lay.get("minimized", []):
			if tiles.has(id):
				minimized[id] = true
				tiles.erase(id)
		wm_units = []
		if lay.has("units"):
			wm_units = WM_UNITS.parse(lay.get("units", []), _tile_rect(get_viewport_rect().size))
		else:
			# Migración del layout viejo {groups, weights}: mismo eje por orientación.
			wm_units = WM_UNITS.from_legacy(tiles, lay.get("groups", []), lay.get("weights", {}),
				_tile_rect(get_viewport_rect().size))
		_prune_units()
		hybrid = WM_HYBRID.new()
		if lay.has("hybrid"):
			hybrid.parse(lay.get("hybrid", {}))
		for id in tiles:
			if minimized.has(id):
				continue
			hybrid.ensure(id)
		for rec in wm_units:
			for m in rec["members"]:
				hybrid.set_tiled(m, hybrid.anchor(m))
		maximize_state = {}
		for k in lay.get("maximize", {}):
			maximize_state[int(k)] = lay["maximize"][k]
		var f = int(lay.get("focused", -1))
		_focus_tile(f if tiles.has(f) else (tiles[tiles.size() - 1] if not tiles.empty() else -1))
		fullscreen_id = int(lay.get("fullscreen", -1))
		if not tiles.has(fullscreen_id):
			fullscreen_id = -1
		# Deja `tiles` en orden de franja (miembros de un grupo contiguos) para que el
		# exposé muestre el mismo orden que los workspaces.
		_rebuild_tiles(_units())
		request_redraw()
		return
	if not roots.empty():
		_focus_tile(roots[roots.size() - 1])
	request_redraw()


# Diagnóstico: geometría y capas por ventana (para el mapeo de puntero).
func geom_state():
	var out = {}
	for id in tiles:
		var geo = compositor.get_geometry(id)
		var layers = compositor.get_layers(id)
		var mn = Vector2(1e9, 1e9)
		var mx = Vector2(-1e9, -1e9)
		var l0 = [0, 0, 0, 0]
		for i in range(layers.size()):
			var rt = layers[i].rect
			mn = Vector2(min(mn.x, rt.position.x), min(mn.y, rt.position.y))
			mx = Vector2(max(mx.x, rt.position.x + rt.size.x), max(mx.y, rt.position.y + rt.size.y))
			if i == 0:
				l0 = [rt.position.x, rt.position.y, rt.size.x, rt.size.y]
		out[str(id)] = {"geo": [geo.position.x, geo.position.y, geo.size.x, geo.size.y],
			"l0": l0, "union": [mn.x, mn.y, mx.x - mn.x, mx.y - mn.y], "n": layers.size()}
	return out


# Al ganar o perder el foco de teclado (cambio de VT, captura, otra ventana de sway) las
# sueltas que ocurran afuera nunca llegan a Godot: un Super "apretado" para siempre hace
# que cada clic sea Super+arrastre y la app no recibe clics. Se sueltan en Godot los
# modificadores que figuran apretados, y también en la app.
func _notification(what):
	if what == MainLoop.NOTIFICATION_WM_FOCUS_IN or what == MainLoop.NOTIFICATION_WM_FOCUS_OUT:
		_clear_stuck_mods()


func _clear_stuck_mods():
	var any = false
	for sc in MOD_KEYS:
		if Input.is_key_pressed(sc):
			any = true
			var ev = InputEventKey.new()
			ev.scancode = sc
			ev.physical_scancode = sc
			ev.pressed = false
			Input.parse_input_event(ev)
	if any:
		print("[key-sync] modificadores soltados al cambiar el foco de teclado")
		release_modifiers()


# Recupera modificadores pegados: reenvía sueltas de Ctrl/Shift/Alt/Super a la app y
# limpia el estado del shell (paneo/Super).
func release_modifiers():
	var id = _current_wayland_id()
	if id < 0:
		id = last_key_target
	if id >= 0:
		for sc in MOD_KEYS:
			var ev = InputEventKey.new()
			ev.scancode = sc
			ev.physical_scancode = sc
			ev.pressed = false
			compositor.key(ev)
	fwd_mods.clear()
	pan = 0.0
	pan_active = false
	if frame != null:
		frame.super_press = null
	request_redraw()


var last_commits = 0
# Loop del motor: sin input, commits ni animación por IDLE_MS, duerme más entre vueltas
# (60 -> 4 vueltas/s en reposo). El primer evento tras el reposo tarda hasta SLEEP_IDLE.
const IDLE_MS = 3000
const SLEEP_ACTIVE = 16000
const SLEEP_IDLE = 250000
# Un commit de una app (p. ej. htop que redibuja cada 1-2 s) sólo mantiene el bucle
# activo este rato; antes renovaba `last_activity` y el shell no entraba nunca en
# reposo (60 vueltas/s sin dibujar casi nada: ~15% de CPU en equipos chicos).
const COMMIT_ACTIVE_MS = 500
var last_activity = 0
var last_commit_ms = 0
# Presentaciones por el camino liviano (present-only: commit de ventana, sin rearmar ImGui)
# y por el completo. Se exponen por el RPC `state` para medir P1
# (SPEC-rendimiento-compositor).
var present_light = 0
var present_full = 0
# Logs de entrada en caliente ([cursor], arrastre Deskflow): sólo con GDTK_DEBUG_INPUT=1.
# Sin la variable no escriben a shell.log en cada cambio de cursor/motion del cliente.
var debug_input = OS.get_environment("GDTK_DEBUG_INPUT") != ""


# Un commit Wayland puede traer capas/texturas nuevas (y con dmabuf el VisualServer
# no se entera de que cambió el contenido): se rearma el frame siguiente.
func _process(_delta):
	var now = OS.get_ticks_msec()
	_sync_capture_cursor()
	# Asa de mover CSD: deslizamiento de entrada/salida (pide frames mientras anima).
	_tick_csd_grip(now)
	# Transición de zoom Hogar <-> Grupo <-> Vecindario (metáfora del ícono central).
	# `zoom_f` sigue al objetivo `zoom_level` con ZOOM_MS; el dibujo interpola el
	# ícono central y la escala/alfa de cada capa. `neighborhood_view` queda true en
	# todo el recorrido para que cualquier salida siga tratando la vista como zoom.
	if abs(zoom_f - float(zoom_level)) > 0.001:
		var zstep = (_delta * 1000.0) / ZOOM_MS
		if zstep <= 0.0:
			zstep = 0.15
		if zoom_f < float(zoom_level):
			zoom_f = min(float(zoom_level), zoom_f + zstep)
		else:
			zoom_f = max(float(zoom_level), zoom_f - zstep)
		neighborhood_view = zoom_level > 0 or zoom_f > 0.001
		request_redraw()
	elif zoom_f != float(zoom_level):
		zoom_f = float(zoom_level)
		neighborhood_view = zoom_level > 0
		request_redraw()
	if compositor.commit_count != last_commits:
		last_commits = compositor.commit_count
		last_commit_ms = now
		_present_commit()
	if activity_instance != null and activity_instance.get("animate"):
		last_activity = now
	# Vecindario: el hilo deja el último resultado; si cambió y la vista está a la
	# vista, se pide un frame (sin sondeo periódico en reposo).
	if neighborhood != null and neighborhood.running():
		neighborhood.poll()
		if neighborhood.version != nb_version:
			nb_version = neighborhood.version
			if neighborhood_view:
				request_redraw()
	# Servicios: copia el snapshot del worker (sin consultar procesos acá).
	_svc_poll()
	# Deskflow por defecto: reintenta el arranque si debía correr y no está.
	_deskflow_tick(now)
	_deskflow_watch(now)
	# Escrituras de dirección: reapea los Threads ya terminados (no bloquea).
	_dir_poll()
	# Buzón del handshake de dirección: aplica el snapshot del worker y reapea los
	# envíos ssh terminados (sin bloquear, sin I/O de disco acá).
	_inbox_poll()
	# Sesiones de pantalla gvd y escrituras de config de plan: sólo reap de Threads.
	_gvd_poll()
	_plan_poll()
	_clip_sync_poll()
	# Configuración: reapa el Thread de lectura y aplica acento/fondo del snapshot.
	settings_poll()
	# swaymsg de ajustes de entrada: reap de Threads one-shot (bloqueó a lo sumo su
	# propio Thread, no el frame).
	_sway_exec_poll()
	_reap_rotate()
	# Volumen/brillo: copia el estado del worker y mantiene vivo el OSD mientras se
	# desvanece (mismo patrón que el resto de los workers).
	if system_osd != null and system_osd.poll():
		request_redraw()
	if screenshot_path == "":
		var busy = now - last_activity <= IDLE_MS or now - last_commit_ms <= COMMIT_ACTIVE_MS
		var sleep = SLEEP_ACTIVE if busy else SLEEP_IDLE
		if OS.low_processor_usage_mode_sleep_usec != sleep:
			OS.low_processor_usage_mode_sleep_usec = sleep


# Re-muestra el contenido ya presente de las ventanas tras un commit, sin rearmar la UI
# ImGui: la textura de la ventana se actualiza in-place (dmabuf o shm) y alcanza con marcar
# el canvas sucio y mandar los frame callbacks de la presentación
# (SPEC-rendimiento-compositor P1). Si la UI está viva (exposé, animaciones, Vecindario) se
# usa el camino completo: ahí el commit tiene que rearmar el frame de ImGui.
func _present_commit():
	if expose or not tile_anim.empty() or not wm_anim.empty() or neighborhood_view:
		present_full += 1
		request_redraw()
		return
	present_light += 1
	if view != null and is_instance_valid(view):
		view.update()
	if compositor != null and compositor.has_method("send_frame_callbacks"):
		compositor.send_frame_callbacks()
	else:
		request_redraw()


func _arm_clock():
	var t = OS.get_time()
	get_tree().create_timer(60.05 - t.second).connect("timeout", self, "_on_minute")


func _on_minute():
	request_redraw()
	_arm_clock()


func _redraw_on_signal(_id):
	request_redraw()


func _imgui_frame():
	# Antes de dibujar: el texto sigue el tamaño de la grilla (fuentes escaladas).
	_sync_ui_scale()
	# Auto-rotación: arrancar el daemon una vez (sway o X11, según la sesión).
	_maybe_start_rotate()
	# X11 sin window manager: al rotar (xrandr) el root cambia de tamaño pero la
	# ventana no se redimensiona sola; el shell se ajusta.
	if OS.get_environment("GDTK_SESSION") == "x11":
		_x11_follow_screen()
	# Actividades internas animadas piden frames continuos.
	if activity_instance != null and activity_instance.get("animate"):
		request_redraw()
	recovery.tick(self)
	_process_unmanaged()
	# Flotantes cuyo escritorio cambió/desapareció: se reanclan al vecino en vez de
	# caer en silencio al Escritorio (maximizar/desmaximizar "cambiaba de pantalla").
	var cur_units = _units()
	hybrid.heal_anchors(_prev_units, cur_units)
	_prev_units = cur_units
	_sync_client_fullscreen()
	# Con los dedos quietos la animación del exposé no debe seguir sola por tiempo.
	if swipe_mode == "vchain" and swipe_live == SWIPE_SEG:
		_swipe_scrub(swipe_k, OS.get_ticks_msec())
	_tick_home_slide()
	# Fundido al cambiar de vista (ver frame.transition); 0 = ImGuiStyleVar_Alpha.
	# Si el Frame no cargó (p. ej. frame.gd no compila), no hay transición que
	# aplicar: se dibuja opaco en vez de reventar cada frame.
	var fade = frame.transition() if frame != null and is_instance_valid(frame) else 1.0
	# El Hogar no se desliza con la fila (el ícono central queda quieto): está fijo de
	# fondo y aparece con alfa a medida que el paneo/animación se acerca a su ranura.
	var home_a = 1.0
	if _home_anim_active() or pan_active:
		home_a = _home_vis(_units())
	if fade < 1.0:
		push_style_var_float(0, fade)
	# En exposé el ImGui no dibuja la vista de fondo (Hogar/actividad): las miniaturas
	# del escritorio van en la capa de abajo y el fondo oscuro las enmarca.
	if not expose:
		if current_activity == null:
			# El Hogar se dibuja siempre; con zoom activo _draw_home sólo pinta el
			# ícono central (ancla continua), y la capa Grupo/Vecindario entra encima.
			_draw_home_alpha(fade * home_a)
			if zoom_level > 0 or zoom_f > 0.001:
				neighborhood_ui.refresh()
		else:
			_draw_activity()
			if (_home_anim_active() or pan_active) and home_a > 0.01:
				_draw_home_alpha(fade * home_a)
	if fade < 1.0:
		pop_style_var()

	# Tiling: con alguna ventana abierta y una actividad wayland activa se muestran todos
	# los tiles a la vez; en Home o en una actividad de script, la vista se oculta. La
	# vista también se muestra para el paneo/animación que trae o lleva al Hogar.
	tile_mode = current_activity != null and current_activity.has("wayland") and not tiles.empty()
	var row = tile_mode or (not tiles.empty() and (_home_anim_active() or pan_active))
	# Exposé: las miniaturas necesitan la vista visible aunque no haya una actividad
	# wayland enfocada (p. ej. abierto desde el Hogar), para poder elegir/cerrar.
	if expose and not tiles.empty():
		row = true
	view.visible = row
	# Zoom (Grupo/Vecindario): la capa neighborhood_ui se usa para ambos niveles y se
	# transforma según su nivel (escala/alfa de capa), visible también al cerrar.
	var nb_vp = get_viewport_rect().size
	neighborhood_ui.visible = current_activity == null and not expose and (zoom_level > 0 or zoom_f > 0.001)
	if neighborhood_ui.visible:
		var lt = ZOOM.layer_transform(zoom_level, zoom_f)
		neighborhood_ui.rect_pivot_offset = nb_vp * 0.5
		neighborhood_ui.rect_scale = Vector2(float(lt.scale), float(lt.scale))
		neighborhood_ui.modulate = Color(1, 1, 1, clamp(float(lt.alpha), 0.0, 1.0))
		# Al cerrar sigue visible para animar, pero no debe capturar el mouse.
		neighborhood_ui.mouse_filter = Control.MOUSE_FILTER_STOP if zoom_level > 0 else Control.MOUSE_FILTER_IGNORE
	if row:
		_update_tiles()
	instant_switch = false  # ya se reubicaron sin animación en este frame
	var id = _current_wayland_id()
	_update_dialogs(id)
	if tiles_ui != null:
		tiles_ui.rect_size = get_viewport_rect().size
		tiles_ui.refresh()
	# Decoración por ventana (OpenStep): se redibuja con el tamaño de la vista.
	for did in deco_nodes.keys():
		var dnode = deco_nodes.get(did)
		if dnode != null and is_instance_valid(dnode):
			dnode.refresh(view.rect_size)
	if expose_bg != null:
		expose_bg.rect_size = get_viewport_rect().size
		expose_bg.visible = expose
		if expose:
			expose_bg.refresh()
	# El Frame (sus barras) sigue a la vista en exposé: es el borde del escritorio al
	# que se vuelve. El menú de ventana no aplica (las miniaturas no lo usan).
	frame.draw(self)
	if not expose:
		_draw_window_menu()
	_update_ghosts(OS.get_ticks_msec())

	_draw_input_requests()
	# HUD de debug global (autoload DebugHud): Super+F6 lo abre en cualquier actividad (frame.gd).
	DebugHud.draw(self)
	# OSD de volumen/brillo, por encima de todo y efímero.
	if system_osd != null:
		system_osd.draw(self)

	frame_count += 1
	_run_test_logic()


# --- Pantallas: una fila horizontal; cada pantalla puede tener varias apps ---

# Registro de unidad que contiene `id` (o null).
func _record_of(id):
	for rec in wm_units:
		if rec["members"].has(id):
			return rec
	return null


# El grupo (franja con varias apps) que contiene la ventana, o null si va suelta.
func _group_of(id):
	var rec = _record_of(id)
	if rec != null and rec["members"].size() >= 2:
		return rec["members"]
	return null


# Miembros de la pantalla de una ventana: su grupo, o ella sola.
func _unit_members(id):
	var g = _group_of(id)
	return g if g != null else [id]


# Unidades en orden de `tiles`: la ranura Escritorio (índice 0, sin miembros tiled)
# y luego cada grupo una vez (en la posición de su primer miembro).
func _units():
	var out = [[]]  # Escritorio: ranura virtual que aloja flotantes, sin mosaico
	var seen = {}
	for id in tiles:
		if seen.has(id):
			continue
		if hybrid.is_floating(id):
			seen[id] = true  # las flotantes no forman unidad: se dibujan ancladas
			continue
		var rec = _record_of(id)
		if rec != null:
			var members = []
			for m in rec["members"]:
				if tiles.has(m) and not seen.has(m):
					members.append(m)
					seen[m] = true
			if not members.empty():
				out.append(members)
		else:
			out.append([id])
			seen[id] = true
	return out


# Índice de la unidad enfocada. Si la ventana enfocada es flotante, manda su ancla.
func _focused_unit_index(units):
	if focused_tile >= 0:
		for i in range(units.size()):
			if units[i].has(focused_tile):
				return i
		if hybrid.is_floating(focused_tile):
			return _anchor_index(units, focused_tile)
	return 0


# La fila incluye una ranura extra: el Hogar, siempre al final (índice units.size()).
# ¿La pantalla actual es el Hogar? (el Hogar no es una actividad ni un toplevel).
func _at_home():
	return current_activity == null


func _home_anim_active():
	return home_slide_since >= 0


# Índice continuo de la fila (0..units.size(), donde units.size() es el Hogar): la
# pantalla ancla (la enfocada, o el Hogar) más el offset de paneo o de la animación.
func _row_s(units):
	var n = units.size()
	if home_slide_since >= 0:
		var k = clamp(float(OS.get_ticks_msec() - home_slide_since) / TILE_ANIM_MS, 0.0, 1.0)
		return lerp(home_slide_from, home_slide_to, _ease(k))
	var vp = get_viewport_rect().size
	var a = float(n) if _at_home() else float(_focused_unit_index(units))
	var s = a + pan / max(vp.x, 1.0)
	# Desde el Hogar hacia "siguiente" la fila da la vuelta: entra por la izquierda.
	var span = float(n) - _row_lo_v(units)
	if s > float(n) and span > 0.0:
		s -= span
	return s


# Ranura virtual del Hogar a la IZQUIERDA de la primera pantalla: la del Escritorio
# (0) sólo existe si tiene flotantes; si no, a la izquierda de la 1 está el Hogar
# (antes había una pantalla gris vacía). El Hogar también es la ranura n (derecha).
func _row_lo_v(units):
	return -1.0 if _unit_has_windows(units, 0) else 0.0


# Visibilidad del Hogar (0..1): está fijo de fondo (no se desliza: el ícono central
# no se mueve) y aparece a medida que la fila se acerca a cualquiera de sus ranuras.
func _home_vis(units):
	var s = _row_s(units)
	var d = min(abs(float(units.size()) - s), abs(s - _row_lo_v(units)))
	return clamp(1.0 - d, 0.0, 1.0)


# Límites del paneo (px) desde la ranura `a`: hasta el Hogar por ambos lados; desde el
# Hogar, una vuelta entera en cada sentido.
func _pan_limits(units, a):
	var vp = get_viewport_rect().size
	if _at_home():
		return Vector2.ZERO  # el Hogar se deja por la cadena vertical, no por los costados
	var n = float(units.size())
	var first = _row_lo_v(units) + 1.0
	return Vector2(min(0.0, (first - a) * vp.x), max(0.0, (n - 1.0 - a) * vp.x))


# Ranura de la última pantalla que tuvo el foco (para volver desde el Hogar).
func _last_focus_unit(units):
	var ui = _focused_unit_index_of(units, focused_tile)
	if ui < 0:
		ui = units.size() - 1
	return ui


func _draw_home_alpha(alpha):
	if alpha >= 0.999:
		_draw_home(0.0)
		return
	# El fondo usa primitivas del draw list, que no respetan el Alpha de estilo.
	home_bg_alpha = alpha
	push_style_var_float(0, alpha)
	_draw_home(0.0)
	pop_style_var()
	home_bg_alpha = 1.0


# x del Hogar dentro de la fila: 0 = centrado en pantalla, ±ancho = fuera de vista.
func _home_x(units):
	var vp = get_viewport_rect().size
	return (float(units.size()) - _row_s(units)) * vp.x


# La fila completa: la pantalla enfocada (o el Hogar) en (0,0) y el resto a ±ancho.
# Index 0 es la ranura Escritorio (aloja flotantes). Las unidades tiled reparten su
# área por eje; las flotantes se dibujan ancladas a su pantalla (float_layout local
# + offset por ancla). El Hogar es la ranura extra al final (índice units.size()).
func _compute_slide_layout():
	tile_rects.clear()
	var units = _units()
	var vp = get_viewport_rect().size
	# Pantalla completa: la ventana ocupa todo; el resto queda fuera de pantalla.
	if fullscreen_id >= 0 and tiles.has(fullscreen_id):
		for id in tiles:
			tile_rects[id] = Rect2(0.0, 0.0, vp.x, vp.y) if id == fullscreen_id else Rect2(vp.x * 2.0, 0.0, vp.x, vp.y)
		window_rects.clear()
		return
	var cr = _tile_rect(vp)
	window_rects.clear()
	var s = _row_s(units)
	# Mosaico: cada unidad tiled reparte su área (una sola ocupa todo).
	for u in range(units.size()):
		var members = units[u]
		if members.empty():
			continue
		var area = Rect2(cr.position.x + (float(u) - s) * vp.x, cr.position.y, cr.size.x, cr.size.y)
		if members.size() == 1:
			tile_rects[members[0]] = area
		else:
			_split_rects(members, area)
		for m in members:
			_sync_client_maximized(m, maximize_state.has(m))
	# Flotantes: encima de su pantalla ancla.
	_compute_float_layout(cr, units, s)
	# El chrome de las tiled no se dibuja: sólo las flotantes llevan decoración.
	for id in tiles:
		if minimized.has(id) or hybrid.is_floating(id):
			continue
		var d = deco_nodes.get(id)
		if d != null and is_instance_valid(d):
			d.visible = false


# Peso de reparto de una ventana dentro de su franja (default 1: partes iguales).
func _weight(id):
	return WM_UNITS.weight_of(wm_units, id, 1.0)


# Registro filtrado a `members` con el eje/pesos guardados (o default X/1).
func _rect_record(members):
	var weights = {}
	for m in members:
		weights[m] = _weight(m)
	var rec = _record_of(members[0]) if not members.empty() else null
	var axis = String(rec["axis"]) if rec != null else WM_UNITS.AXIS_X
	return {"members": members, "axis": axis, "weights": weights}


# Las apps de una franja se reparten según el eje de su unidad: X = columnas
# (ancho), Y = filas (alto). El asa de borde ajusta los pesos (sólo eje X).
func _split_rects(members, area):
	if members.empty():
		return
	var rects = WM_UNITS.member_rects(_rect_record(members), area, TILE_GAP)
	for id in rects.keys():
		tile_rects[id] = rects[id]


# Asas de la franja enfocada (sólo si tiene varias apps y su eje es X): coordenada x
# del borde entre cada par, para dibujar/arrastrar la redimensión.
func _compute_handles():
	handles = []
	if expose or fullscreen_id >= 0 or _at_home() or _home_anim_active():
		hover_handle = null
		resize_handle = null
		return
	var units = _units()
	if units.empty():
		return
	var fi = _focused_unit_index(units)
	if fi <= 0 or fi >= units.size():
		hover_handle = null
		resize_handle = null
		return
	var u = units[fi]
	if u.size() < 2:
		return
	var rec = _record_of(u[0])
	if rec != null and String(rec.get("axis", WM_UNITS.AXIS_X)) == WM_UNITS.AXIS_Y:
		hover_handle = null
		resize_handle = null
		return
	var vp = get_viewport_rect().size
	for i in range(u.size() - 1):
		var r = tile_rects.get(u[i])
		if r == null:
			continue
		var x = r.position.x + r.size.x + TILE_GAP * 0.5
		if x < -8.0 or x > vp.x + 8.0:
			continue
		handles.append({"x": x, "y": r.position.y, "h": r.size.y, "i": i, "left": u[i], "right": u[i + 1]})
	# Reapunta las asas activas a las entradas nuevas: si no, la dibujada queda con la
	# posición vieja y parece que no sigue al mouse (los rects sí se recalculan).
	hover_handle = _find_handle(hover_handle)
	resize_handle = _find_handle(resize_handle)


func _find_handle(h):
	if h == null:
		return null
	for nh in handles:
		if nh.left == h.left and nh.right == h.right:
			return nh
	return null


func _handle_at(pos):
	for h in handles:
		if abs(pos.x - h.x) <= HANDLE_HIT and pos.y >= h.y and pos.y <= h.y + h.h:
			return h
	return null


# Transform de contenido por ventana, para el control remoto (claves string = JSON).
func fits_state():
	var out = {}
	for id in tile_fit.keys():
		var fit = tile_fit[id]
		out[str(id)] = {"scale": fit.scale, "offset": [fit.offset.x, fit.offset.y]}
	return out


# Mueve el borde hasta mouse_x repartiendo el ancho combinado de las dos ventanas.
func _resize_to(h, mouse_x):
	var rl = tile_rects.get(h.left)
	var rr = tile_rects.get(h.right)
	if rl == null or rr == null:
		return
	var rec = _record_of(h.left)
	if rec == null:
		return
	var left = rl.position.x
	var right = rr.position.x + rr.size.x
	var frac = clamp((mouse_x - left) / max(right - left, 1.0), 0.12, 0.88)
	var wsum = _weight(h.left) + _weight(h.right)
	rec["weights"][h.left] = wsum * frac
	rec["weights"][h.right] = wsum * (1.0 - frac)


# Rects de las ventanas de UNA pantalla en coordenadas locales del workspace (origen
# (0,0), tamaño del viewport), sin depender del estado de paneo. Misma partición que
# _split_rects: una ventana ocupa el área de contenido; una franja partida reparte
# según su eje con TILE_GAP. Lo usa el exposé para escalar cada ventana a su lugar real.
func _unit_local_layout(members):
	var out = {}
	var vp = get_viewport_rect().size
	var area = _tile_rect(vp)
	if members.size() == 1:
		out[members[0]] = area
		return out
	if members.empty():
		return out
	return WM_UNITS.member_rects(_rect_record(members), area, TILE_GAP)


# Exposé = "zoom out" del escritorio: cada workspace (pantalla) se dibuja como una
# miniatura completa del viewport y sus ventanas se reparten DENTRO del marco en una
# grilla sin solapes (las grandes arriba; ver expose_layout.arrange). TODOS los
# workspaces van en una fila en su orden espacial (el mismo del paneo), escalados para
# entrar a la vista. La lógica de escalado/grilla vive en expose_layout.gd (pura).
func _compute_expose_layout():
	expose_cards.clear()
	expose_unit_cards = []
	var all_units = _units()
	# Sólo las unidades con contenido: los escritorios vacíos no se muestran (tampoco
	# la vieja ranura final "Nuevo escritorio"; el destino de arrastre es el hueco).
	var flags = []
	for i in range(all_units.size()):
		flags.append(_unit_has_windows(all_units, i))
	var units = []
	var src = []
	for s in EXPOSE_LAYOUT.visible_slots(flags):
		units.append(all_units[s])
		src.append(s)
	expose_units = units
	expose_unit_src = src
	var n = units.size()
	if n == 0:
		expose_sel = 0
		return
	expose_sel = int(clamp(expose_sel, 0, max(tiles.size() - 1, 0)))
	var vp = get_viewport_rect().size
	var box = _tile_rect(vp)
	var local = []
	for u in range(n):
		var l = _unit_local_layout(units[u])
		# Las flotantes de esta pantalla también entran en la miniatura, en su
		# posición local real (dentro de su unidad).
		if src[u] >= 0:
			for id in tiles:
				if minimized.has(id) or not hybrid.is_floating(id):
					continue
				if _anchor_index(all_units, id) != src[u]:
					continue
				if not float_layout.has(id):
					if float_memory.has(id) and float_memory[id] != null:
						float_layout.restore_one(id, float_memory[id], box)
					else:
						float_layout.place_new(id, box)
				var lr = float_layout.rect(id)
				if lr != null:
					l[id] = lr
		local.append(l)
	var plan = EXPOSE_LAYOUT.plan(vp, local, EXPOSE_PAD, EXPOSE_GAP, EXPOSE_MAX_SCALE)
	expose_unit_cards = plan["units"]
	expose_cards = plan["cards"]
	# Un poco de aire entre ventanas: se encoge cada tarjeta (el shell centra la
	# miniatura en su tarjeta, así que el hueco queda simétrico).
	for id in expose_cards.keys():
		expose_cards[id] = expose_cards[id].grow(-EXPOSE_CARD_INSET)
	# tile_rects queda con la geometría REAL local de cada ventana: la necesita
	# _update_tile para reescalar la miniatura sin distorsionar el contenido.
	for u in range(n):
		for id in local[u].keys():
			tile_rects[id] = local[u][id]


# ¿La unidad i tiene ventanas? Cuenta las tiled de la unidad y las flotantes ancladas
# a ella: una ranura sin nada no se muestra en exposé.
func _unit_has_windows(units, i):
	if not units[i].empty():
		return true
	for id in tiles:
		if minimized.has(id) or not hybrid.is_floating(id):
			continue
		if _anchor_index(units, id) == i:
			return true
	return false


# Índice de la ranura de exposé que contiene a `id` (-1 si no está).
func _expose_index_of_window(id):
	for i in range(expose_units.size()):
		if expose_units[i].has(id):
			return i
	var all_units = _units()
	var ai = _anchor_index(all_units, id)
	for i in range(expose_unit_src.size()):
		if expose_unit_src[i] == ai:
			return i
	return -1


# Ranura de exposé bajo el punto (-1 si ninguna).
func _expose_unit_at(pos):
	for i in range(expose_unit_cards.size()):
		if expose_unit_cards[i].has_point(pos):
			return i
	return -1


# Hueco de inserción de exposé bajo el punto (-1 si cae sobre una tarjeta). Los huecos
# son los espacios entre marcos (y los márgenes extremos): ahí se crea un escritorio
# nuevo al soltar.
func _expose_gap_at(pos):
	return EXPOSE_LAYOUT.gap_at(expose_unit_cards, pos.x)


# Rect (coords de vista) de la barra vertical de inserción del hueco `gap` (null si no
# es válido). Se extiende a lo alto de la fila de marcos.
func _expose_gap_bar_rect(gap):
	if gap < 0 or expose_unit_cards.empty():
		return null
	var x = EXPOSE_LAYOUT.gap_x(expose_unit_cards, gap)
	if is_nan(x):
		return null
	var y0 = INF
	var y1 = -INF
	for r in expose_unit_cards:
		y0 = min(y0, r.position.y)
		y1 = max(y1, r.end.y)
	var w = 4.0
	return Rect2(x - w * 0.5, y0 - 6.0, w, (y1 - y0) + 12.0)


# ¿`id` es una unidad tiled con un solo miembro? (Se usa para no reordenar al soltar
# en el hueco que es su propia posición.) Una flotante no pertenece a ninguna unidad:
# soltarla en un hueco sí debe crear un escritorio.
func _unit_is_solo(id):
	if hybrid.is_floating(id) or not WM_UNITS.has(wm_units, id):
		return false
	return WM_UNITS.members_of(wm_units, id).size() <= 1


# Suelta la miniatura `id` en el hueco `gap` (0..n): crea un escritorio NUEVO en esa
# posición del orden de unidades, con esa ventana. Tiled: la saca de su unidad como
# unidad sola y la inserta en ese índice. Flotante: la vuelve tiled, unidad sola, en la
# misma posición. Soltar en el hueco pegado a su propia tarjeta no reordena nada.
func _expose_insert(id, gap):
	var n = expose_unit_cards.size()
	if id < 0 or gap < 0 or gap > n or not tiles.has(id):
		return
	var cur = _expose_index_of_window(id)
	if _unit_is_solo(id) and (gap == cur or gap == cur + 1):
		# Es su propia posición: no hay nada que mover (y evita saltar al final).
		request_redraw()
		return
	# La unidad que debe quedar a la derecha del nuevo escritorio, si la hay. Se toma
	# un miembro distinto de `id` para que el ancla sobreviva a su extracción.
	var all_units = _units()
	var anchor_id = -1
	if gap < expose_unit_src.size():
		var r = int(expose_unit_src[gap])
		if r >= 1 and r < all_units.size():
			for m in all_units[r]:
				if m != id:
					anchor_id = m
					break
	_insert_solo(id, anchor_id, gap == 0)
	expose_sel = max(tiles.find(id), 0)
	expose_drag = null
	expose_drag_target = -1
	expose_drag_gap = -1
	# Invalida el layout cacheado: las posiciones/tamaños de las tarjetas cambian.
	_compute_expose_layout()
	request_redraw()


# Crea un escritorio NUEVO sólo con `id` (misma operación que el hueco del exposé y
# de la tira del Frame). Se inserta antes de la unidad de `anchor_id` si se da; si no,
# al principio si `at_start`, o al final. Tiled: extrae `id` como unidad sola.
# Flotante: la vuelve tiled en su propia unidad. Limpia el estado de maximizado.
func _insert_solo(id, anchor_id, at_start):
	if id < 0 or not tiles.has(id):
		return
	var axis = _default_axis()
	if hybrid.is_floating(id):
		_remember_float_geometry()
		float_layout.remove(id)
		hybrid.set_tiled(id, id)
	if anchor_id >= 0:
		WM_UNITS.solo_before(wm_units, id, anchor_id, axis)
	elif at_start:
		# Extremo izquierdo: lo más a la izquierda posible (tras el Escritorio virtual).
		WM_UNITS.solo(wm_units, id, 0, axis)
	else:
		WM_UNITS.solo(wm_units, id, -1, axis)
	hybrid.set_tiled(id, id)
	wm_maximized.erase(id)
	maximize_state.erase(id)
	_rebuild_tiles_preserving_floats()
	_focus_tile(id)


# Rearma `tiles` con las tiled en orden de unidad (miembros contiguos) y conserva las
# flotantes/minimizadas restantes. `_rebuild_tiles(_units())` las descartaría porque
# `_units()` no incluye flotantes.
func _rebuild_tiles_preserving_floats():
	var out = []
	var placed = {}
	for u in wm_units:
		for m in u["members"]:
			if tiles.has(m) and not placed.has(m):
				out.append(m)
				placed[m] = true
	for id in tiles:
		if not placed.has(id):
			out.append(id)
			placed[id] = true
	tiles = out
	request_redraw()


# Suelta la miniatura `id` en la ranura `target`: reancla la flotante (o une/reubica
# la tiled) al escritorio destino y deja el exposé abierto.
func _expose_drop(id, target):
	if id < 0 or target < 0 or target >= expose_units.size():
		return
	if _expose_index_of_window(id) == target:
		return
	var tid = -1
	if expose_unit_src[target] <= 0:
		tid = WM_HYBRID.ESCRITORIO
	elif not expose_units[target].empty():
		tid = expose_units[target][0]
	if tid < 0:
		return
	_join_into(id, tid, "right")
	expose_sel = max(tiles.find(id), 0)
	expose_drag = null
	expose_drag_target = -1
	expose_drag_gap = -1
	# Invalida el layout cacheado: las posiciones/tamaños de las tarjetas cambian.
	_compute_expose_layout()
	request_redraw()


# Escritorio/unidad destino de una ventana o del propio Escritorio: su id-líder.
# Flotante -> su ancla; tiled -> el líder de su unidad; Escritorio -> 0; -1 si no hay.
func _desktop_anchor_of(target_id):
	if target_id == WM_HYBRID.ESCRITORIO:
		return WM_HYBRID.ESCRITORIO
	if target_id < 0 or not tiles.has(target_id):
		return -1
	if hybrid.is_floating(target_id):
		return int(hybrid.anchor(target_id, WM_HYBRID.ESCRITORIO))
	var rec = _record_of(target_id)
	return int(rec["id"]) if rec != null else target_id


# Une/reancla `id` al escritorio de `target_id` (misma operación que el drop del
# exposé y de la tira del Frame). `target_id` puede ser una ventana (tiled o
# flotante) o el propio Escritorio (WM_HYBRID.ESCRITORIO). Flotante: reancla y
# reencaja en su caja. Tiled: se suma a la unidad del destino por el lado pedido
# ("left"/"right"); si el destino es el Escritorio, queda sola al final anclada a él.
func _join_into(id, target_id, side):
	if id < 0 or target_id < 0 or id == target_id:
		return
	if not tiles.has(id):
		return
	var s = String(side)
	if s != "left" and s != "right":
		s = "right"
	# El destino es una ventana flotante (o el propio Escritorio): la unidad es el
	# escritorio de su ancla, no una unidad tiled con miembros.
	var target_is_floating = target_id == WM_HYBRID.ESCRITORIO or hybrid.is_floating(target_id)
	if hybrid.is_floating(id):
		var anchor = _desktop_anchor_of(target_id)
		if anchor < 0:
			return
		hybrid.reanchor(id, anchor)
		# Coloca la flotante dentro del área del destino (todos los escritorios
		# comparten la caja local): encaja sin deformar y la sube al tope.
		var box = _tile_rect(get_viewport_rect().size)
		var lr = float_layout.rect(id)
		if lr != null:
			float_layout.restore_one(id, lr, box)
		return
	# Tiled: se suma a la unidad destino. Si el destino es tiled se une a ESA ventana
	# (así reordena al lado pedido cuando ya comparten unidad); si es flotante, a la
	# unidad de su ancla; si el ancla es el Escritorio, queda sola al final.
	var jt = int(target_id)
	if target_is_floating:
		var anchor = _desktop_anchor_of(target_id)
		if anchor < 0:
			return
		if anchor == WM_HYBRID.ESCRITORIO:
			WM_UNITS.solo(wm_units, id, -1, _default_axis())
			hybrid.set_tiled(id, WM_HYBRID.ESCRITORIO)
			_rebuild_tiles_preserving_floats()
			return
		jt = anchor
	WM_UNITS.join(wm_units, id, jt, s)
	var rec = _record_of(id)
	hybrid.set_tiled(id, int(rec["id"]) if rec != null else jt)
	_rebuild_tiles_preserving_floats()


# --- Tira de ventanas del Frame: usan el mismo modelo de unidades que el exposé ----

# Clave estable del escritorio/unidad de una ventana para la tira del Frame: el
# id-líder de su unidad; las flotantes caen en el escritorio de su ancla; el
# Escritorio virtual es 0. Coincide con el formato de `frame.strip_drop_target`.
func frame_strip_unit(id):
	if id < 0 or not tiles.has(id):
		return -1
	if hybrid.is_floating(id):
		var all_units = _units()
		var ai = _anchor_index(all_units, id)
		return 0 if ai <= 0 else int(all_units[ai][0])
	var rec = _record_of(id)
	return int(rec["id"]) if rec != null else id


# Miembro de la unidad `unit_key` distinto de `id`, para usarlo de ancla al crear un
# escritorio nuevo antes de esa unidad (-1 si no hay o la clave es el Escritorio).
func _strip_anchor_member(unit_key, id):
	if unit_key <= 0:
		return -1
	for u in _units():
		if int(u[0]) == unit_key:
			for m in u:
				if m != id:
					return m
			break
	return -1


# Suelta una tesela de la tira en un hueco: crea un escritorio NUEVO sólo con `id`
# (misma semántica que el hueco del exposé). `right_unit_key` es el escritorio que
# queda a la derecha (null = al final); `at_start` lo deja lo más a la izquierda.
func frame_strip_new(id, right_unit_key, at_start):
	if id < 0 or not tiles.has(id):
		return
	var rkey = -1 if right_unit_key == null else int(right_unit_key)
	# Ya está sola justo a la izquierda de esa unidad: es su propia posición.
	if _unit_is_solo(id) and rkey == int(frame_strip_unit(id)):
		return
	_insert_solo(id, _strip_anchor_member(rkey, id), at_start)


# Suelta una tesela sobre otra: la une al escritorio de `target_id` por `side`
# ("left"/"right"), o reancla la flotante a ese escritorio. Misma semántica que el
# drop del exposé; el destino puede ser una unidad ya compartida (reordena el lado).
func frame_strip_onto(id, target_id, side):
	if id < 0 or target_id < 0 or id == target_id:
		return
	if not tiles.has(id) or not tiles.has(target_id):
		return
	_join_into(id, target_id, side)
	_focus_tile(id)
	request_redraw()


# Tarjeta de la miniatura arrastrada en exposé con el tamaño que tendrá al soltar:
# {"card": Rect2 en la vista, "local": tamaño real de la ventana}; null si `id` no se
# está arrastrando. Hueco -> escritorio nuevo (área entera); otro escritorio -> su
# parte de la franja con `id` sumada a la derecha (como _expose_drop); flotante
# sobre un escritorio conserva su tamaño. Escala = la de la miniatura del destino.
func _expose_drag_card(id):
	var d = expose_drag
	if d == null or not d.moved or int(d.id) != id or expose_unit_cards.empty():
		return null
	var vp = get_viewport_rect().size
	var cur = tile_rects.get(id, Rect2(Vector2.ZERO, vp))
	var local = cur.size
	var ui = _expose_index_of_window(id)
	if expose_drag_gap >= 0:
		local = _tile_rect(vp).size  # escritorio nuevo: tiled sola, área entera
		ui = int(clamp(expose_drag_gap - 1, 0, expose_unit_cards.size() - 1))
	elif expose_drag_target >= 0 and expose_drag_target != ui and expose_drag_target < expose_units.size():
		ui = expose_drag_target
		if not hybrid.is_floating(id):
			if expose_unit_src[ui] <= 0 or expose_units[ui].empty():
				local = _tile_rect(vp).size
			else:
				var lay = _unit_local_layout(expose_units[ui] + [id])
				if lay.has(id):
					local = lay[id].size
	ui = int(clamp(ui, 0, expose_unit_cards.size() - 1))
	var k = expose_unit_cards[ui].size.x / max(vp.x, 1.0)
	var size = local * k
	var c0 = expose_cards.get(id, Rect2(d.from - d.grab, size))
	var frac = Vector2(d.grab.x / max(c0.size.x, 1.0), d.grab.y / max(c0.size.y, 1.0))
	return {"card": Rect2(d.pos - frac * size, size), "local": local}


# Salida pública del exposé (la usa el Frame): delega en el toggle existente.
func exit_expose():
	if expose:
		_toggle_expose(false)


# Rueda en exposé: como todo entra en pantalla, navega la selección (no hace scroll).
func _expose_scroll_by(px):
	_expose_move(1 if px > 0.0 else -1)


# Ventana bajo el punto en exposé (-1 si ninguna).
func _expose_hit(pos):
	for id in tiles:
		var card = expose_cards.get(id)
		if card != null and card.has_point(pos):
			return id
	return -1


# Rect del botón de cerrar de una ventana en exposé (arriba a la derecha), ajustado al
# tamaño de la miniatura. null si la ventana no está en exposé o es muy chica.
func _expose_close_rect(id):
	var card = expose_cards.get(id)
	if card == null or card.size.x < 12.0 or card.size.y < 12.0:
		return null
	var d = clamp(min(card.size.x, card.size.y) * 0.20, 12.0, EXPOSE_CLOSE_MAX)
	var m = max(2.0, d * 0.14)
	return Rect2(card.end.x - d - m, card.position.y + m, d, d)


func _expose_close_hit(pos):
	for id in tiles:
		var r = _expose_close_rect(id)
		if r != null and r.grow(2.0).has_point(pos):
			return id
	return -1


func _tile_node(id):
	var node = tile_nodes.get(id)
	if node == null or not is_instance_valid(node):
		_ensure_premult_material()
		node = Control.new()
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Sin recorte: los popups (menús) son capas del mismo nodo y pueden salir de la
		# ventana; recortados quedaban inaccesibles (menú de Firefox flotante).
		node.rect_clip_content = false
		view.add_child(node)
		tile_nodes[id] = node
	return node


# Un TextureRect por capa del árbol del toplevel, reusado por índice (raíz -> popups).
# `scale`/`offset` mapean las coords del cliente al slot: si el cliente es más chico o
# más grande que su slot, se escala y centra para que llene (ver _content_fit).
func _fill_nodes(box, layers, scale, offset):
	_ensure_premult_material()
	while box.get_child_count() < layers.size():
		var t = TextureRect.new()
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.expand = true
		t.stretch_mode = TextureRect.STRETCH_SCALE
		t.material = premult_material
		t.visible = false
		box.add_child(t)
	for i in range(layers.size()):
		var node = box.get_child(i)
		var layer = layers[i]
		var size = layer.rect.size
		if (size.x <= 0.0 or size.y <= 0.0) and layer.texture != null:
			size = layer.texture.get_size()
		node.texture = layer.texture
		node.rect_position = layer.rect.position * scale + offset
		node.rect_size = size * scale
		node.visible = layer.texture != null
	for i in range(layers.size(), box.get_child_count()):
		box.get_child(i).visible = false


# Offset (local al nodo del slot) para mostrar el contenido del cliente (tamaño `csize`,
# origen `cpos`) dentro del slot `ssize`. No escala nunca: 1:1 y centrado. Si el cliente
# es más chico que el slot, queda centrado; si es más grande, se lo recorta el slot
# (rect_clip_content). El redimensionado real lo hace compositor.set_size.
# ¿El cliente todavía no tiene el tamaño de su slot porque se lo acabamos de cambiar?
# (animación de reacomodo en curso, o pedido de set_size reciente). Acotado en el
# tiempo: una app de tamaño fijo que no acepta el pedido no queda estirada para siempre.
func _resize_pending(id, geo, rect, now):
	if expose or geo.size.x <= 0.0 or geo.size.y <= 0.0:
		return false
	if geo.size.distance_to(rect.size) < 2.0:
		return false
	if tile_anim.has(id) or wm_anim.has(id):
		return true
	return now - int(resize_since.get(id, -100000)) < RESIZE_STRETCH_MS


# Le dice al compositor dónde pueden caer los popups de la ventana: la vista entera
# en coords del buffer raíz. Él no sabe dónde dibuja el shell la ventana (una flotante
# corrida no está en 0,0) y acomodaba los menús fuera de pantalla o recortados.
# ¿Alguna capa secundaria (popup) sale de la geometría de la ventana? Las subsuperficies
# (video, etc.) quedan dentro y no cuentan: sólo lo que sobresale puede quedar tapado.
func _layers_overflow(layers, geo):
	if layers.size() < 2 or geo.size.x <= 0.0 or geo.size.y <= 0.0:
		return false
	var box = geo.grow(2.0)
	for i in range(1, layers.size()):
		var lr = layers[i].rect
		if lr.size.x > 0.0 and lr.size.y > 0.0 and not box.encloses(lr):
			return true
	return false


# Una ventana con un menú abierto va arriba de todo: si no, su popup quedaba tapado por
# una vecina (tiled) o una flotante que estuviera encima. Su chrome queda justo debajo.
func _raise_popup_owners():
	for id in popup_owners:
		var n = tile_nodes.get(id)
		if n == null or not is_instance_valid(n):
			continue
		var d = deco_nodes.get(id)
		if d != null and is_instance_valid(d):
			view.move_child(d, view.get_child_count() - 1)
		view.move_child(n, view.get_child_count() - 1)


# ¿`pos` cae en alguna capa de popup (índice >= 1) de la ventana `id`?
func _popup_layer_hit(id, r, fit, pos):
	var layers = compositor.get_layers(id)
	for i in range(1, layers.size()):
		var lr = layers[i].rect
		if lr.size.x <= 0.0 or lr.size.y <= 0.0:
			continue
		if Rect2(r.position + lr.position * fit.scale + fit.offset, lr.size * fit.scale).has_point(pos):
			return true
	return false


func _sync_popup_bounds(id, rect, fit):
	if compositor == null or not compositor.has_method("set_popup_bounds"):
		return
	var sc = max(float(fit.scale), 0.001)
	var box = Rect2((-rect.position - fit.offset) / sc, view.rect_size / sc)
	var prev = popup_bounds_sent.get(id)
	if prev != null and prev.position.distance_to(box.position) < 1.0 and prev.size == box.size:
		return
	popup_bounds_sent[id] = box
	compositor.set_popup_bounds(id, box)


func _content_fit(csize, ssize, cpos):
	if csize.x <= 0.0 or csize.y <= 0.0:
		return {"scale": 1.0, "offset": -cpos}
	return {"scale": 1.0, "offset": -cpos + (ssize - csize) * 0.5}


func _update_tiles():
	view.rect_size = get_viewport_rect().size
	compositor.default_size = _tile_rect(view.rect_size).size
	if expose:
		_compute_expose_layout()
	else:
		_compute_slide_layout()
	_compute_handles()
	for id in tile_nodes.keys():
		if not tiles.has(id):
			var node = tile_nodes[id]
			tile_nodes.erase(id)
			z_stack.erase(id)
			_free_deco(id)
			tile_rects.erase(id)
			expose_cards.erase(id)
			if expose_hover == id:
				expose_hover = -1
			tile_anim.erase(id)
			tile_fade.erase(id)
			tile_intro.erase(id)
			view_anim.erase(id)
			tile_fit.erase(id)
			if node != null and is_instance_valid(node):
				node.queue_free()
	var now = OS.get_ticks_msec()
	popup_owners = []
	for id in tiles:
		if _id_alive(id):
			_update_tile(id, now)
			if expose:
				compositor.get_layers(id)  # cuenta como dibujado: la miniatura sigue viva
	_raise_popup_owners()


func _update_tile(id, now):
	var node = _tile_node(id)
	var geo = compositor.get_geometry(id)
	var layers = compositor.get_layers(id)
	var rect = tile_rects.get(id, Rect2(Vector2.ZERO, view.rect_size))
	# Arrastre en exposé: la miniatura toma ya el tamaño que tendrá al soltar (pantalla
	# entera sobre un hueco, su parte de la franja sobre otro escritorio) y la app se
	# redimensiona en vivo para que el contenido acompañe.
	var drag_card = _expose_drag_card(id) if expose else null
	if drag_card != null:
		rect = Rect2(Vector2.ZERO, drag_card.local)
		_request_client_size(id, rect, geo)
	elif expose and geo.size.x > 0.0 and geo.size.y > 0.0:
		# La miniatura es la ventana COMPLETA escalada: con el slot del layout, un
		# cliente más grande que su lugar (o que no aceptó el tamaño) se recortaba al
		# centro (_content_fit es 1:1) y en exposé se veía sólo una parte.
		rect = Rect2(rect.position, geo.size)
	# El cliente puede no ocupar el slot (elige tamaño propio, o se achica al cambiar
	# de fuente): se centra 1:1 y, si es más grande que el slot, se reduce para que entre.
	var fit = _content_fit(geo.size, rect.size, geo.position)
	if _resize_pending(id, geo, rect, now):
		# Maximizar/reacomodar: se estira la textura que el cliente ya tiene al slot
		# nuevo (antes quedaba 1:1 centrada y crecía recién al llegar el buffer: "primero
		# la centra y después la agranda"). Se reemplaza sola cuando el cliente commitea.
		var st = Vector2(rect.size.x / geo.size.x, rect.size.y / geo.size.y)
		_fill_nodes(node, layers, st, -geo.position * st)
	else:
		_fill_nodes(node, layers, fit.scale, fit.offset)
	tile_fit[id] = fit
	if not expose:
		_sync_popup_bounds(id, rect, fit)
		if not minimized.has(id) and _layers_overflow(layers, geo):
			popup_owners.append(id)  # un popup sale de la ventana (ver _raise_popup_owners)

	# Transición de modo tiled<->flotante (K13): interpola desde el rect visual
	# previo hacia `rect`. Se deja para después de exposé/intro/zoom.
	var wm_on = false
	var wm_from = rect
	var wm_e = 1.0
	if not expose and not view_anim.has(id) and not tile_intro.has(id):
		var t = _wm_transition(id, rect, node, now)
		wm_on = bool(t.active)
		wm_from = t.from
		wm_e = float(t.e)

	if expose:
		# Miniatura: se escala el nodo entero (la app conserva su tamaño de tile) y se
		# centra en su tarjeta. La escala NO se topea en 1.0: también CRECE cuando la
		# tarjeta es mayor que el tamaño real (p. ej. una flotante chica); si no, la
		# miniatura quedaba en su tamaño real y no se redimensionaba al cambiar de
		# escritorio ni al entrar al exposé.
		var card = expose_cards.get(id, Rect2(Vector2.ZERO, view.rect_size))
		if drag_card != null:
			card = drag_card.card
		# Selección sin borde: la elegida se agranda un poco y se aclara (ver _draw_expose).
		var sel = expose_sel >= 0 and expose_sel < tiles.size() and tiles[expose_sel] == id
		var bright = EXPOSE_SEL_BRIGHT if sel else 1.0
		var s = EXPOSE_LAYOUT.thumb_scale(card, rect)
		if sel:
			s *= EXPOSE_SEL_SCALE
		var fp = Rect2(card.position + (card.size - rect.size * s) * 0.5, rect.size * s)
		node.rect_size = rect.size
		if drag_card != null:
			# Sigue al puntero sin la animación de reacomodo; el cambio de tamaño se
			# suaviza acercándose un tramo por frame.
			view_anim.erase(id)
			var v = EXPOSE_LAYOUT.lerp_rect(expose_drag.get("vis", _node_footprint(node)), fp, 0.35)
			expose_drag["vis"] = v
			node.rect_position = v.position
			node.rect_scale = _scale_for(v, rect.size)
			if not _footprint_near(v, fp):
				request_redraw()
			node.modulate = Color(bright, bright, bright, 1.0)
			node.visible = true
			return
		var a = view_anim.get(id)
		if a == null:
			# Reacomodo (drop/inserción, cambio de selección, layout nuevo): parte de
			# la transformación VISIBLE actual y anima suavemente a la tarjeta nueva.
			var cur = _node_footprint(node)
			if not _footprint_near(cur, fp):
				a = {"from": cur, "since": now}
				view_anim[id] = a
		if a != null:
			var e = _view_anim_e(a, now)
			var f = EXPOSE_LAYOUT.lerp_rect(a.from, fp, e)
			node.rect_position = f.position
			node.rect_scale = _scale_for(f, rect.size)
			if float(now - a.since) >= EXPOSE_MS:
				view_anim.erase(id)
			else:
				request_redraw()
		else:
			node.rect_position = fp.position
			node.rect_scale = _scale_for(fp, rect.size)
		node.modulate = Color(bright, bright, bright, 1.0)
		node.visible = true
		return

	# Vuelta de exposé: se interpola desde la tarjeta (footprint visible) hasta su rect
	# de pantalla; el set_size real se pide recién al terminar, no en cada frame.
	if view_anim.has(id):
		var a = view_anim[id]
		var e = _view_anim_e(a, now)
		var f = EXPOSE_LAYOUT.lerp_rect(a.from, rect, e)
		node.rect_position = f.position
		node.rect_scale = _scale_for(f, rect.size)
		node.rect_size = rect.size
		node.visible = true
		node.modulate = Color(1, 1, 1, 1)
		if float(now - a.since) >= EXPOSE_MS:
			view_anim.erase(id)
			_request_client_size(id, rect, geo)
		else:
			request_redraw()
		return

	# Entrada: escala y se traslada desde el ícono que la lanzó; si no se conoce el
	# ícono, genie desde el centro del rect final (0.2 -> 1 con fade). El placeholder
	# con spinner lo dibuja tiles_ui hasta que llega la primera textura. El set_size
	# real del cliente se pide al terminar (nada de re-render durante la animación).
	if tile_intro.has(id):
		var info = tile_intro[id]
		if layers.size() > 0 and layers[0].texture != null:
			info["ready"] = true
		var k = clamp(float(now - info.since) / INTRO_MS, 0.0, 1.0)
		var e = _ease(k)
		var from = info.get("from")
		if from == null:
			if info.get("scale_in", false):
				# Desminimizar: crece en su lugar (sin traslación desde el borde).
				var s0 = 0.78
				from = Rect2(rect.position + rect.size * (0.5 - 0.5 * s0), rect.size * s0)
			else:
				from = EXPOSE_LAYOUT.intro_from(rect, null, now, 0, 0, 0.2)
		var f = EXPOSE_LAYOUT.lerp_rect(from, rect, e)
		node.rect_size = rect.size
		node.rect_position = f.position
		node.rect_scale = _scale_for(f, rect.size)
		node.visible = true
		node.modulate = Color(1, 1, 1, min(e, 1.0))
		info["rect"] = f
		if k >= 1.0:
			tile_intro.erase(id)
			node.rect_scale = Vector2.ONE
			node.rect_position = rect.position
			_request_client_size(id, rect, geo)
		else:
			request_redraw()
		return

	# Desliza desde donde estaba a su celda nueva (reacomodar, cambiar de pantalla).
	# Durante el paneo (Super+rueda) se posiciona directo, sin animación, para que el
	# movimiento continuo no pelee con el easing.
	if wm_on:
		# Animación de modo: se escala el contenido (sin realloc) mientras la ventana
		# viaja del rect previo al nuevo. El set_size real se hace al terminar (abajo,
		# en la siguiente actualización), así no hay tearing por frame.
		tile_anim.erase(id)
		var sc = Vector2(wm_from.size.x / max(rect.size.x, 1.0),
			wm_from.size.y / max(rect.size.y, 1.0)).linear_interpolate(Vector2.ONE, wm_e)
		var fc = wm_from.position + wm_from.size * 0.5
		var tc = rect.position + rect.size * 0.5
		var c = fc.linear_interpolate(tc, wm_e)
		node.rect_scale = sc
		node.rect_position = c - rect.size * sc * 0.5
		node.rect_size = rect.size
		node.visible = true
		node.modulate = Color(1, 1, 1, 1)
		# El chrome sigue a la ventana (window_deco usa rect_scale) y aparece/desaparece
		# con un fade: al entrar a flotante se funde in; al salir, out.
		var wd = deco_nodes.get(id)
		if wd != null and is_instance_valid(wd):
			wd.visible = true
			wd.modulate = Color(1, 1, 1, wm_e if hybrid.is_floating(id) else (1.0 - wm_e))
		request_redraw()
		return
	var pos = rect.position
	var animating = false
	if pan_active or instant_switch or home_slide_since >= 0:
		# Paneo/deslizamiento: la ventana va pegada a su rect (que ya incluye el
		# offset de la fila). Sin esto sólo se movía la capa de divisiones.
		tile_anim.erase(id)
		node.rect_scale = Vector2.ONE
		node.rect_position = rect.position
		node.rect_size = rect.size
	elif tile_anim.has(id):
		var a = tile_anim[id]
		var k = clamp(float(now - a.since) / TILE_ANIM_MS, 0.0, 1.0)
		var f = EXPOSE_LAYOUT.lerp_rect(a.from, rect, _ease(k))
		node.rect_size = rect.size
		node.rect_scale = _scale_for(f, rect.size)
		node.rect_position = f.position
		pos = f.position
		if k >= 1.0:
			tile_anim.erase(id)
		else:
			animating = true
			request_redraw()
	else:
		var cur = _node_footprint(node)
		if not _footprint_near(cur, rect):
			# Reacomodo (tile/untile, maximizar, cambio de pantalla): interpola
			# posición Y tamaño desde lo visible, sin set_size hasta terminar.
			tile_anim[id] = {"from": cur, "since": now}
			animating = true
			node.rect_size = rect.size
			node.rect_scale = _scale_for(cur, rect.size)
			node.rect_position = cur.position
			request_redraw()
		else:
			node.rect_scale = Vector2.ONE
			node.rect_position = rect.position
			node.rect_size = rect.size
	# Al terminar la transición de modo, el chrome queda a opacidad plena.
	var wd = deco_nodes.get(id)
	if wd != null and is_instance_valid(wd) and wd.modulate.a != 1.0:
		wd.modulate = Color(1, 1, 1, 1)
	# Sólo se dibuja la pantalla que asoma: las demás quedan fuera (±ancho/±alto).
	var vp = view.rect_size
	node.visible = pos.x + rect.size.x > 0.0 and pos.x < vp.x and pos.y + rect.size.y > 0.0 and pos.y < vp.y
	node.modulate = Color(1, 1, 1, 1)

	# Ajuste 1:1: se le pide al cliente el tamaño del slot (texto nítido). Se reafirma
	# cuando el cliente se achica solo (p. ej. al cambiar la fuente) y no molesta si el
	# cliente no acepta (sólo se reintenta cuando su tamaño cambia). No se pide mientras
	# la animación está en curso: eso re-renderiza y produce tearing.
	if not animating:
		_request_client_size(id, rect, geo)
	if tex_ready_frame < 0 and id == focused_tile and layers.size() > 0 and layers[0].texture != null:
		tex_ready_frame = frame_count


# Pide al cliente el tamaño del slot una sola vez (cuando cambió o derivó). Durante
# las animaciones no se llama: recién al terminar.
func _request_client_size(id, rect, geo):
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var drifted = geo.size != Vector2.ZERO and geo.size != rect.size and last_geo.get(id) != geo.size
	if requested_sizes.get(id) != rect.size or drifted:
		requested_sizes[id] = rect.size
		resize_since[id] = OS.get_ticks_msec()
		compositor.set_size(id, rect.size)
	last_geo[id] = geo.size


# Rect VISIBLE actual de una ventana (posición + tamaño ya escalado). Es el punto de
# partida de toda animación: se arranca desde lo que se ve, no desde el destino.
func _node_footprint(node):
	return Rect2(node.rect_position, node.rect_size * node.rect_scale)


func _footprint_near(a, b):
	return a.position.distance_to(b.position) <= 0.5 \
		and abs(a.size.x - b.size.x) <= 0.5 and abs(a.size.y - b.size.y) <= 0.5


# Escala del nodo para que su footprint (contenido ya encajado en `slot`) mida `fp`.
# Compensa que el tamaño local del slot cambie a mitad de camino, sin saltos.
func _scale_for(fp, slot):
	return Vector2(fp.size.x / max(slot.x, 1.0), fp.size.y / max(slot.y, 1.0))


# Easing con rebote leve (ease-out-back): arranca rápido, se pasa un poco del destino
# y vuelve. k normalizado 0..1 (puede devolver >1 por el overshoot).
func _ease(k):
	k = clamp(k, 0.0, 1.0)
	var c1 = 1.20158
	var c3 = c1 + 1.0
	return 1.0 + c3 * pow(k - 1.0, 3.0) + c1 * pow(k - 1.0, 2.0)


# Avanza la transición tiled<->flotante de una ventana. Devuelve
# {"active", "from": Rect2 visual de origen, "e": ease}. Al empezar toma el rect
# visual actual del nodo (incluyendo un scale en curso); al terminar limpia y deja
# que _update_tile aplique la geometría final y el único set_size.
func _wm_transition(id, rect, node, now):
	if wm_switch_until <= 0:
		return {"active": false, "from": rect, "e": 1.0}
	var a = wm_anim.get(id)
	if a == null:
		if now > wm_switch_until:
			wm_switch_until = -1
			return {"active": false, "from": rect, "e": 1.0}
		var from = Rect2(node.rect_position, node.rect_size * node.rect_scale)
		if from.size.x <= 0.0 or from.size.y <= 0.0:
			return {"active": false, "from": rect, "e": 1.0}
		a = {"from": from, "since": now}
		wm_anim[id] = a
	var k = clamp(float(now - a.since) / float(WM_SWITCH_MS), 0.0, 1.0)
	if k >= 1.0:
		wm_anim.erase(id)
		if wm_anim.empty():
			wm_switch_until = -1
		return {"active": false, "from": rect, "e": 1.0}
	request_redraw()
	return {"active": true, "from": a.from, "e": _ease(k)}


# Rect del ítem de la ventana en el Frame (si está dibujado); si no, un punto arriba.
# Es el destino de las animaciones de minimizar/cerrar (la ventana vuelve a su ítem).
func _panel_rect_for(id):
	if frame != null:
		var r = frame.item_rect(id)
		if r != null:
			return r
	return Rect2(Vector2(view.rect_size.x * 0.5 - 60.0, 2.0), Vector2(120.0, 24.0))


# Congela el cuadro on-screen de la ventana y lo anima hacia `to_rect` (o arriba si es
# null), encogiéndose. Se usa un snapshot del viewport para no depender de que el cliente
# siga teniendo vivo su buffer (dmabuf). Sirve para cerrar y para minimizar.
func _spawn_ghost(id, to_rect):
	if not view.visible:
		return
	var rect = tile_rects.get(id)
	if rect == null:
		return
	var vp = get_viewport_rect().size
	var vis = Rect2(Vector2.ZERO, vp).clip(rect)
	if vis.size.x < 8.0 or vis.size.y < 8.0:
		return
	var img = get_viewport().get_texture().get_data()
	if img == null:
		return
	img.flip_y()
	img = img.get_rect(Rect2(vis.position, vis.size))
	if img == null or img.get_width() <= 0 or img.get_height() <= 0:
		return
	if to_rect == null:
		to_rect = Rect2(Vector2(vis.position.x + vis.size.x * 0.5 - 30.0, 2.0), Vector2(60.0, 20.0))
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	var node = TextureRect.new()
	node.texture = tex
	node.expand = true
	node.stretch_mode = TextureRect.STRETCH_SCALE
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.rect_size = vis.size
	node.rect_position = vis.position
	if ghost_layer == null:
		ghost_layer = CanvasLayer.new()
		ghost_layer.layer = 1
		add_child(ghost_layer)
	ghost_layer.add_child(node)
	ghosts.append({"node": node, "from": vis, "to": to_rect, "since": OS.get_ticks_msec()})
	request_redraw()


# Anima los fantasmas: interpola posición y tamaño desde la ventana hasta el ícono, con
# alfa 1 -> 0.
func _update_ghosts(now):
	for i in range(ghosts.size() - 1, -1, -1):
		var g = ghosts[i]
		var k = clamp(float(now - g.since) / GHOST_MS, 0.0, 1.0)
		var e = _ease(k)
		var from = g.from
		var to = g.to
		var pos = from.position.linear_interpolate(to.position, e)
		var size = from.size.linear_interpolate(to.size, e)
		g.node.rect_position = pos
		g.node.rect_size = size
		g.node.modulate = Color(1, 1, 1, 1.0 - k)
		if k >= 1.0:
			g.node.queue_free()
			ghosts.remove(i)
		else:
			request_redraw()


# Un binario anterior al parámetro `raise` expone focus(id): llamarlo con dos
# argumentos falla y el cliente nunca recibe el foco de teclado (todo modo).
var _focus_has_raise = null


func _compositor_focus(id, raise_window):
	if _focus_has_raise == null:
		_focus_has_raise = false
		for m in ClassDB.class_get_method_list("WaylandCompositor", true):
			if m.name == "focus":
				_focus_has_raise = m.args.size() >= 2
	if _focus_has_raise:
		compositor.focus(id, raise_window)
	else:
		compositor.focus(id)


func _focus_tile(id, raise_window = true):
	if id < 0 or not _id_alive(id):
		return
	if focused_tile != id and _pantalla_window_ids().has(focused_tile):
		_window_input_reset()
	# Enfocar a mano cancela cualquier deslizamiento/hogar en curso y cierra la
	# grilla de Apps: el flag no debe sobrevivir al volver de la grilla a una app.
	pan = 0.0
	pan_active = false
	home_slide_since = -1
	apps_view = false
	# Ir a una app sale del Grupo/Vecindario al instante: si no, `neighborhood_view`
	# seguía en true (o mientras se animaba zoom_f) y las teclas de la app se descartaban.
	if zoom_level > 0 or zoom_f > 0.0:
		_set_zoom(0)
		zoom_f = 0.0
		neighborhood_view = false
	# Enfocar una minimizada la restaura (así el teclado puede traerlas de vuelta);
	# la vuelta usa entrada por escala (no deslizamiento desde el borde/Frame).
	var restoring = minimized.has(id)
	if restoring:
		minimized.erase(id)
	if not tiles.has(id):
		tiles.append(id)
		tile_intro[id] = _new_intro(restoring)
	# Enfocar otra ventana sale de pantalla completa.
	if fullscreen_id >= 0 and fullscreen_id != id:
		fullscreen_id = -1
	focused_tile = id
	# En flotante, elevar es una consecuencia del foco explícito (clic, selector,
	# atajo), no del mero cambio de foco. Lazy focus pasa false para conservar Z.
	if raise_window:
		z_stack.erase(id)
		z_stack.append(id)  # al frente del apilado común (flotante o tiled)
		if hybrid.is_floating(id) and float_layout.has(id):
			float_layout.raise(id)
	focus_flash = OS.get_ticks_msec()
	# Memoriza el miembro enfocado de la pantalla (para volver a él desde otra).
	for u in _units():
		if u.has(id):
			unit_focus[u[0]] = id
			break
	var name = _activity_for_window(id)
	var i = _activity_named(name)
	if i >= 0:
		current_activity = ACTIVITIES[i]
	_compositor_focus(id, raise_window)
	request_redraw()


# Navegación de pantallas (una sola fila por default, con el Hogar al final).
# dir: -1 izq, 1 der. ←/→ cambian de pantalla (franja); desde la última, → llega al
# Hogar y desde el Hogar, ← vuelve a la última pantalla que tuvo el foco.
func _focus_dir(dir):
	if dir != -1 and dir != 1:
		return
	if _home_anim_active():
		return
	pan = 0.0
	pan_active = false
	var units = _units()
	var n = units.size()
	if _at_home():
		if dir < 0 and n > 0:
			_start_home_leave(units, _last_focus_unit(units))
		request_redraw()
		return
	if not tile_mode or tiles.empty():
		return
	if fullscreen_id >= 0:
		return
	var ui = _focused_unit_index(units)
	if dir > 0 and ui >= n - 1:
		_start_home_enter(units)
	else:
		_focus_unit(units, ui + dir)


# Entrada al Hogar (desde la última pantalla): anima la fila hasta la ranura n y al
# terminar confirma el cambio con _go_home (ver _tick_home_slide).
func _start_home_enter(units):
	home_slide_from = _row_s(units)
	home_slide_to = float(units.size())
	home_slide_since = OS.get_ticks_msec()
	request_redraw()


# Salida del Hogar (hacia la pantalla u): anima la fila desde la ranura n.
func _start_home_leave(units, u):
	home_slide_from = float(units.size())
	home_slide_to = float(u)
	home_slide_since = OS.get_ticks_msec()
	request_redraw()


# Cierra la animación del Hogar: entra (confirma Home) o sale (enfoca la pantalla).
func _tick_home_slide():
	if home_slide_since < 0:
		return
	var k = clamp(float(OS.get_ticks_msec() - home_slide_since) / TILE_ANIM_MS, 0.0, 1.0)
	if k < 1.0:
		request_redraw()
		return
	var to = home_slide_to
	home_slide_since = -1
	fade_skip_until = OS.get_ticks_msec() + 200  # ver frame.transition
	var units = _units()
	var n = units.size()
	if int(round(to)) >= n or to <= _row_lo_v(units) + 0.01:
		if not _at_home():
			_go_home()
	elif n > 0:
		_focus_unit(units, int(clamp(round(to), 0.0, float(n - 1))))
	request_redraw()


# Super+rueda: desplaza la franja de forma continua (signo +1 = siguiente). Llega hasta
# el Hogar (y desde el Hogar vuelve a las ventanas). No cambia el foco hasta soltar
# Super (_snap_pan).
func _pan_by(amount):
	if _home_anim_active():
		return
	var units = _units()
	var n = units.size()
	if n == 0:
		return
	if not (tile_mode or _at_home()):
		return
	if fullscreen_id >= 0:
		return
	var vp = get_viewport_rect().size
	var a = float(n) if _at_home() else float(_focused_unit_index(units))
	pan_active = true
	var lim = _pan_limits(units, a)
	pan = clamp(pan + amount * vp.x * 0.18, lim.x, lim.y)
	request_redraw()


# Swipe de 3 dedos continuo (estilo GNOME): horizontal arrastra la fila de pantallas
# siguiendo los dedos; vertical abre (arriba) o cierra (abajo) el exposé arrastrando
# su animación. Al soltar, swipe_model decide el snap (mitad del recorrido o fling).
func _on_swipe(event):
	var now = OS.get_ticks_msec()
	var vp = get_viewport_rect().size
	var kind = int(event.device) / SWIPE_DEVICE
	if kind == 1 and not swipe.active:
		swipe.begin(int(event.device) % SWIPE_DEVICE, now)
		swipe_mode = ""
		swipe_k = 0.0
		return
	if not swipe.active:
		return
	var size = vp.x if swipe.axis == "x" else vp.y
	if kind == 1:
		swipe.update(event.delta, now)
		if swipe.axis == "":
			return
		size = vp.x if swipe.axis == "x" else vp.y
		var p = swipe.progress(size)
		if swipe_mode == "":
			swipe_mode = _swipe_start(p)
		if swipe_mode == "pan":
			_swipe_pan(p)
		elif swipe_mode == "vchain":
			_swipe_vchain(p, now)
		return
	var r = swipe.end(kind == 3, now, size)
	var mode = swipe_mode
	swipe_mode = ""
	print("swipe fin: ", mode, " eje=", r.axis, " p=", stepify(r.progress, 0.01), " v=", stepify(r.velocity, 0.01), " paso=", r.step, " cancelado=", kind == 3)
	if mode == "pan":
		# Dedos a la izquierda (step -1) = pantalla siguiente.
		_snap_pan(-int(r.step))
	elif mode == "vchain":
		_swipe_vchain_end(SWIPE_MODEL.vertical_target(swipe_levels, swipe_start_level, r.progress, int(r.step)), now)
	request_redraw()


func _swipe_start(p):
	if swipe.axis == "x":
		if expose or fullscreen_id >= 0 or _home_anim_active() or not tile_mode:
			return "none"  # el Hogar ya no está a los costados: se llega por la cadena vertical
		return "pan"
	if fullscreen_id >= 0 or _home_anim_active():
		return "none"
	swipe_levels = SWIPE_MODEL.vertical_levels(not tiles.empty())
	swipe_start_level = _vlevel()
	if swipe_levels.find(swipe_start_level) < 0:
		return "none"
	swipe_live = swipe_start_level
	return "vchain"


# Nivel actual en la cadena vertical (ver swipe_model.vertical_levels).
func _vlevel():
	if zoom_level > 0:
		return -zoom_level
	if expose:
		return 1
	if _at_home():
		return 3 if apps_view else 2
	return 0


# Rueda sobre un ancla (bloques Vecindario/Grupo/Hogar del Frame o ícono central): un
# paso de la cadena vertical del gesto de 3 dedos, con las mismas transiciones
# (_apply_vlevel). dir +1 = rueda arriba = dedos arriba. Una muesca = un nivel; las
# ráfagas (rueda rápida, scroll de touchpad) se recortan con WHEEL_VCHAIN_MS.
const WHEEL_VCHAIN_MS = 300
var wheel_vchain_until = 0


func _wheel_vchain(dir):
	var now = OS.get_ticks_msec()
	if now < wheel_vchain_until or swipe.active or fullscreen_id >= 0 or _home_anim_active():
		return
	var levels = SWIPE_MODEL.vertical_levels(not tiles.empty())
	var i = levels.find(_vlevel())
	if i < 0:
		return
	var j = int(clamp(i + int(dir), 0, levels.size() - 1))
	if j == i:
		return
	wheel_vchain_until = now + WHEEL_VCHAIN_MS
	swipe_live = levels[j]
	_apply_vlevel(levels[j])


# ¿El punto cae sobre el ícono central (Hogar, Grupo o Vecindario)? Mismo rect que
# dibuja _draw_home con zoom_model.center_icon_rect.
func _over_center_icon(p):
	if not ((_at_home() and not apps_view) or zoom_level > 0):
		return false
	var vp = get_viewport_rect().size
	return ZOOM.center_icon_rect(zoom_f, vp, grid_unit(vp) * 0.90).has_point(p)


# Lleva la vista a un nivel de la cadena (salto discreto, con sus animaciones propias).
func _apply_vlevel(level):
	match int(level):
		-2:
			_go_neighborhood()
		-1:
			_go_group()
		0:
			if expose:
				_toggle_expose(false)
			if _at_home() or zoom_level > 0:
				_set_zoom(0)
				apps_view = false
				var units = _units()
				if not units.empty():
					_start_home_leave(units, _last_focus_unit(units))
		1:
			if zoom_level > 0:
				_set_zoom(0)
			apps_view = false
			if not expose:
				_toggle_expose(true)
		2:
			_go_home()
		3:
			_go_home()
			apps_view = true
	request_redraw()


# Gesto vertical en curso. El tramo pantalla<->exposé sigue a los dedos (scrub de su
# animación); el resto de la cadena cambia de vista al cruzar la mitad de cada tramo.
func _swipe_vchain(p, now):
	var pos = SWIPE_MODEL.vertical_pos(swipe_levels, swipe_start_level, p)
	var i0 = swipe_levels.find(0)
	if i0 >= 0 and pos >= float(i0) and pos <= float(i0 + 1) and (swipe_live == 0 or swipe_live == 1 or swipe_live == SWIPE_SEG):
		var frac = pos - float(i0)
		if swipe_live != SWIPE_SEG:
			swipe_seg_from = swipe_live
			swipe_live = SWIPE_SEG
			# Desde la pantalla se abre el exposé; desde el exposé, se cierra.
			_toggle_expose(swipe_seg_from == 0)
		swipe_k = frac if swipe_seg_from == 0 else 1.0 - frac
		_swipe_scrub(swipe_k, now)
		return
	if swipe_live == SWIPE_SEG:
		# Salió del tramo continuo: queda del lado por el que salió y sigue discreto.
		var out_up = i0 >= 0 and pos > float(i0 + 1)
		swipe_live = 1 if out_up else 0
		if expose == out_up:
			_seed_view_anim(now)  # completa la animación desde donde quedó
		else:
			_toggle_expose(out_up)
	var target = swipe_levels[int(round(pos))]
	if target != swipe_live:
		swipe_live = target
		_apply_vlevel(target)


func _swipe_vchain_end(target, now):
	if swipe_live == SWIPE_SEG:
		var want = int(target) >= 1
		if expose == want:
			_seed_view_anim(now)  # termina con easing desde donde quedó, sin tirón
		else:
			_toggle_expose(want)
		swipe_live = 1 if want else 0
	if int(target) != swipe_live:
		_apply_vlevel(target)
	swipe_live = int(target)


# Paneo absoluto de la fila según el avance del gesto (en pantallas, + = dedos a la
# derecha = pantalla anterior). Mismo estado `pan` que Super+rueda.
func _swipe_pan(p):
	var units = _units()
	var n = units.size()
	if n == 0:
		return
	var vp = get_viewport_rect().size
	var a = float(n) if _at_home() else float(_focused_unit_index(units))
	pan_active = true
	var lim = _pan_limits(units, a)
	pan = clamp(-p * vp.x, lim.x, lim.y)
	request_redraw()


# Arrastra la animación de entrada/salida del exposé: la fija en la fracción `k`
# corriendo su inicio (view_anim usa tiempo transcurrido / EXPOSE_MS).
func _swipe_scrub(k, now):
	var t = clamp(k, 0.0, 0.98) * EXPOSE_MS
	for id in view_anim.keys():
		view_anim[id]["since"] = now - int(t)
		view_anim[id]["lin"] = true
	request_redraw()


# Al soltar Super: cae a la pantalla más cercana según el paneo acumulado (incluido el
# Hogar, si el paneo lo alcanzó).
func _snap_pan(step = null):
	if not pan_active:
		return
	var units = _units()
	var n = units.size()
	var vp = get_viewport_rect().size
	var a = float(n) if _at_home() else float(_focused_unit_index(units))
	# `step` (gesto de 3 dedos) decide el destino por snap/fling; si no, el más cercano.
	var delta = int(step) if step != null else int(round(pan / max(vp.x, 1.0)))
	var lo_v = _row_lo_v(units)
	var from_s = _row_s(units)
	var target = a + float(delta)
	if not _at_home():
		target = clamp(target, lo_v + 1.0, float(n) - 1.0)  # sin Hogar a los costados
	target = clamp(target, lo_v, float(n))
	pan_active = false
	pan = 0.0
	var to_home = target >= float(n) or target <= lo_v
	if to_home or _at_home():
		# El Hogar entra/sale con el deslizamiento animado desde donde quedó la fila.
		home_slide_from = from_s
		home_slide_to = target
		home_slide_since = OS.get_ticks_msec()
	elif int(target) != int(a) and n > 0:
		_focus_unit(units, int(target))
	request_redraw()


# Super+←/→: tilea la ventana enfocada contra una pantalla vecina (mitad
# izquierda/derecha); si ya está en una franja la reordena. Sin vecina, deja la
# flotante a media pantalla (snap contextual). Maximizar es Alt+F10 / Super+F.
func _snap_tile(dir):
	if not tile_mode or focused_tile < 0:
		return
	var units = _units()
	var ui = _focused_unit_index(units)
	if ui > 0 and units[ui].has(focused_tile) and units[ui].size() >= 2:
		# Ya está en una franja: la reordena para quedar a la izquierda/derecha.
		var members = units[ui]
		var i = members.find(focused_tile)
		if i < 0:
			return
		var j = 0 if dir < 0 else members.size() - 1
		var rec = _record_of(focused_tile)
		if rec != null and i != j:
			rec["members"].remove(i)
			rec["members"].insert(j, focused_tile)
			rec["id"] = rec["members"][0]
			_rebuild_tiles(_units())
		for m in members:
			WM_UNITS.set_weight(wm_units, m, 1.0)
		_focus_tile(focused_tile)
		return
	# Suelta: la tilea con otra pantalla vecina (crea la primera unidad).
	var other = -1
	for k in range(units.size()):
		if k == ui or units[k].empty():
			continue
		other = units[k][0]
		break
	if other < 0:
		_float_half(focused_tile, dir)
		return
	if dir < 0:
		_tile_drop(other, focused_tile)  # enfocada primero = izquierda
	else:
		_tile_drop(focused_tile, other)  # enfocada segunda = derecha


# Deja una ventana flotante a media pantalla (mitad izq/der) dentro del hueco.
func _float_half(id, dir):
	if id < 0 or not tiles.has(id):
		return
	if hybrid.is_tiled(id):
		set_window_mode(id, WM_HYBRID.FLOATING)
	var box = wm_box if wm_box.size.x > 0.0 else _tile_rect(get_viewport_rect().size)
	if not float_layout.has(id):
		if float_memory.has(id) and float_memory[id] != null:
			float_layout.restore_one(id, float_memory[id], box)
		else:
			float_layout.place_new(id, box)
	var rect = WM_DRAG.snap_rect("left" if dir < 0 else "right", box)
	if rect.size.x > 0.0:
		float_layout.resize_to(id, rect, box)
	wm_maximized.erase(id)
	_focus_tile(id)
	_maybe_fuse_snapped_floats(id)
	request_redraw()


# ¿La pantalla centrada tiene miembros tiled? Decide el snap contextual: con
# mosaico inserta; sin mosaico redimensiona la flotante.
func _centered_unit_has_tiled():
	var units = _units()
	var fi = _focused_unit_index(units)
	if fi <= 0 or fi >= units.size():
		return false
	return not units[fi].empty()


# Snap de mitad contra la pantalla centrada: suma `id` a su unidad tiled en el lado
# `dir` ("left"/"right"). Si no hay unidad, cae a media pantalla flotante.
func _snap_tile_to(id, dir):
	var units = _units()
	var fi = _focused_unit_index(units)
	if fi <= 0 or fi >= units.size() or units[fi].empty():
		_float_half(id, dir if dir == "right" else -1)
		return
	var target = units[fi][0]
	WM_UNITS.join(wm_units, id, target, dir)
	var rec = _record_of(target)
	var anchor = int(rec["id"]) if rec != null else target
	if rec != null:
		for m in rec["members"]:
			hybrid.set_tiled(m, anchor)
	hybrid.set_tiled(id, anchor)
	wm_maximized.erase(id)
	_rebuild_tiles(_units())
	_focus_tile(id)
	request_redraw()


# Si al snapear una flotante queda otra flotante de la MISMA pantalla ocupando el
# lado complementario (mismo alto, lado a lado), se fusionan en una unidad tiled
# conservando la proporción del snap. Con una sola ventana no hace nada.
func _maybe_fuse_snapped_floats(id):
	if id < 0 or not tiles.has(id) or not hybrid.is_floating(id):
		return false
	var r = float_layout.rect(id)
	if r == null:
		return false
	var units = _units()
	var ai = _anchor_index(units, id)
	for oid in tiles:
		if oid == id or minimized.has(oid) or not hybrid.is_floating(oid):
			continue
		if _anchor_index(units, oid) != ai:
			continue
		var orr = float_layout.rect(oid)
		if orr == null:
			continue
		# Cubren el mismo alto (snap a media pantalla) y están lado a lado.
		var v = min(r.end.y, orr.end.y) - max(r.position.y, orr.position.y)
		if v < min(r.size.y, orr.size.y) * 0.6:
			continue
		if r.end.x <= orr.position.x + 4.0 or orr.end.x <= r.position.x + 4.0:
			return _fuse_floats(id, oid)
	return false


# Fusiona dos flotantes lado a lado en una unidad tiled (eje X) con pesos por ancho,
# así la vista pasa a mosaico y aparece el asa de frontera en vez del chrome flotante.
func _fuse_floats(a, b):
	var ra = float_layout.rect(a)
	var rb = float_layout.rect(b)
	if ra == null or rb == null:
		return false
	var snapped = a
	var left = a
	var right = b
	if ra.position.x > rb.position.x:
		left = b
		right = a
		var t = ra
		ra = rb
		rb = t
	_remember_float_geometry()
	WM_UNITS.remove(wm_units, left)
	WM_UNITS.remove(wm_units, right)
	WM_UNITS.join(wm_units, right, left, "right")
	var rec = _record_of(left)
	var anchor = int(rec["id"]) if rec != null else left
	hybrid.set_tiled(left, anchor)
	hybrid.set_tiled(right, anchor)
	if rec != null:
		rec["weights"][left] = max(ra.size.x, 1.0)
		rec["weights"][right] = max(rb.size.x, 1.0)
	float_layout.remove(left)
	float_layout.remove(right)
	wm_maximized.erase(left)
	wm_maximized.erase(right)
	_rebuild_tiles(_units())
	_focus_tile(snapped)
	request_redraw()
	return true


func _move_window_to(dragged, anchor, before):
	if dragged < 0 or anchor < 0 or dragged == anchor:
		return
	if not tiles.has(dragged) or not tiles.has(anchor):
		return
	if not WM_UNITS.has(wm_units, dragged) or not WM_UNITS.has(wm_units, anchor):
		return
	WM_UNITS.move_unit(wm_units, dragged, anchor, before)
	_rebuild_tiles(_units())
	_focus_tile(dragged)


# Gesto de touchpad reenviado por sway (bindgesture → session/gdtk-gesture → RPC).
# Swipe de 3 dedos: izquierda/derecha navegan pantallas (mismo camino que Super+←/→);
# arriba/abajo entran/salen del exposé. Idempotente: repetir el gesto no rompe estado.
func gesture(kind, direction, fingers = 3):
	if String(kind) != "swipe":
		return false
	match String(direction):
		"left":
			_focus_dir(1)
		"right":
			_focus_dir(-1)
		"up":
			if not expose:
				_toggle_expose(true)
		"down":
			if expose:
				_toggle_expose(false)
		_:
			return false
	request_redraw()
	return true


# Pinch del touchpad reenviado por sway (bindgesture pinch:2 → gdtk-gesture → RPC).
# Arma un ciclo begin→update→end para el cliente con foco del compositor embebido
# (protocolo zwp_pointer_gesture_pinch_v1: Firefox/Nautilus lo usan para zoom).
func gesture_pinch(phase, scale = 1.0, fingers = 2):
	if compositor == null or not compositor.has_method("gesture_pinch"):
		return false
	match String(phase):
		"begin":
			compositor.gesture_pinch(0, fingers, 1.0)
		"update":
			compositor.gesture_pinch(1, fingers, scale)
		"end":
			compositor.gesture_pinch(2, fingers, 1.0)
		"cancel":
			compositor.gesture_pinch(3, fingers, 1.0)
		_:
			return false
	return true


func _focused_unit_index_of(units, id):
	for i in range(units.size()):
		if units[i].has(id):
			return i
	return -1


# Enfoca la pantalla u (recordando su último miembro enfocado). El Escritorio (u=0)
# no tiene miembros tiled: enfoca la flotante más arriba anclada ahí (o suelta el foco).
func _focus_unit(units, u):
	if u < 0 or u >= units.size():
		return
	var members = units[u]
	if members.empty():
		var fid = -1
		for id in float_layout.ids_z():
			if hybrid.is_floating(id) and _anchor_index(units, id) == u:
				fid = id
		if fid >= 0:
			_focus_tile(fid)
		else:
			focused_tile = -1
			request_redraw()
		return
	var want = unit_focus.get(members[0], members[0])
	if not members.has(want):
		want = members[0]
	_focus_tile(want)


# Intercambia pantallas en la fila (←/→). El Escritorio (índice 0) queda fijo.
func _swap_dir(dir):
	if _at_home() or _home_anim_active():
		return
	if not tile_mode or tiles.empty():
		return
	if dir != -1 and dir != 1:
		return
	var units = _units()
	var ui = _focused_unit_index(units)
	if ui <= 0 or ui + dir <= 0:
		return
	_swap_units(units, ui, ui + dir)


func _swap_units(units, a, b):
	if a <= 0 or b <= 0 or a >= units.size() or b >= units.size() or a == b:
		return
	var tmp = units[a]
	units[a] = units[b]
	units[b] = tmp
	_rebuild_tiles(units)


func _rebuild_tiles(units):
	var out = []
	for u in units:
		out.append_array(u)
	tiles = out
	request_redraw()


func _toggle_expose(on):
	expose = on
	expose_hover = -1
	expose_drag = null
	expose_drag_target = -1
	expose_drag_gap = -1
	_reset_cursor()
	if on:
		# Ningún cliente (pointer lock) ni captura remota debe quedarse con el mouse:
		# en exposé todo el mouse va al shell, o el arrastre entre escritorios se pierde.
		if client_pointer_locked:
			_set_client_pointer_lock(false)
		if mouse_locked:
			_set_capture_cursor(false)
		expose_sel = max(tiles.find(focused_tile), 0)
		release_modifiers()  # no dejar Ctrl/Shift pegados en la app al entrar
	# El pasaje se anima: cada ventana arranca desde su transform actual (pantalla o tarjeta).
	var now = OS.get_ticks_msec()
	_seed_view_anim(now)
	request_redraw()


# Arranca la animación exposé<->pantalla de cada ventana desde lo que se ve ahora.
func _seed_view_anim(now):
	for id in tiles:
		var node = tile_nodes.get(id)
		if node != null and is_instance_valid(node):
			view_anim[id] = {"from": _node_footprint(node), "since": now}


# Avance de una animación de view_anim: lineal mientras la arrastran los dedos (el
# rebote de _ease adelantaba la imagen al progreso real y daba un tirón al soltar).
func _view_anim_e(a, now):
	var k = clamp(float(now - a.since) / EXPOSE_MS, 0.0, 1.0)
	return k if a.get("lin", false) else _ease(k)


func _expose_move(step):
	if tiles.empty():
		return
	expose_sel = posmod(expose_sel + step, tiles.size())
	request_redraw()


func _expose_commit():
	var id = -1
	if expose_sel >= 0 and expose_sel < tiles.size():
		id = tiles[expose_sel]
	_toggle_expose(false)
	if id >= 0:
		_focus_tile(id)
	request_redraw()


# --- Unidades (pantallas partidas) y minimizar ---

# Saca `id` de su unidad: si la unidad queda con un solo miembro, ese vuelve a ser
# una unidad suelta (sigue tiled).
func _remove_from_group(id):
	WM_UNITS.remove(wm_units, id)
	request_redraw()


# Pantalla partida: `a` se suma a la pantalla de `b` (drag en el Frame, o teclado) y
# pasa a mosaico anclada a esa unidad. Quedan contiguas (orden de fila b, a).
func _tile_drop(a, b):
	if a < 0 or b < 0 or a == b:
		return
	if not tiles.has(a) or not tiles.has(b):
		return
	WM_UNITS.join(wm_units, a, b, "right")
	var rec = _record_of(b)
	var anchor = int(rec["id"]) if rec != null else b
	if rec != null:
		for m in rec["members"]:
			hybrid.set_tiled(m, anchor)
	hybrid.set_tiled(a, anchor)
	hybrid.set_tiled(b, anchor)
	# Quedan contiguas (la pantalla sale en orden b, a).
	tiles.erase(a)
	var at = tiles.find(b)
	tiles.insert((at + 1) if at >= 0 else tiles.size(), a)
	unit_focus[b] = a
	wm_maximized.erase(a)
	_focus_tile(a)


# Saca la ventana de su grupo y la devuelve a flotante (conserva su geometría).
func _untile_window(id):
	if id < 0 or not tiles.has(id) or not WM_UNITS.has(wm_units, id):
		return
	_remove_from_group(id)
	set_window_mode(id, WM_HYBRID.FLOATING)
	_focus_tile(id)


func _minimize_window(id):
	if id < 0 or not tiles.has(id):
		return
	# La ventana se encoge hacia su ítem del Frame mientras se minimiza (animación
	# fantasma: deja claro que pasó algo). El bloque atenuado queda en el Frame y el
	# anillo del Hogar marca la actividad como minimizada.
	_spawn_ghost(id, _panel_rect_for(id))
	if fullscreen_id == id:
		fullscreen_id = -1
	_remove_from_group(id)
	maximize_state.erase(id)
	wm_maximized.erase(id)
	if chrome_drag != null and int(chrome_drag.id) == id:
		chrome_drag = null
		drag_overlay = null
		window_dragging = false
	minimized[id] = true
	tiles.erase(id)
	tile_fade.erase(id)
	tile_intro.erase(id)
	tile_anim.erase(id)
	wm_anim.erase(id)
	view_anim.erase(id)
	# Se libera ya el nodo: si `tiles` queda vacío no habrá _update_tiles() que lo
	# limpie y podría quedar un cuadro fantasma de la ventana minimizada.
	var node = tile_nodes.get(id)
	if node != null and is_instance_valid(node):
		node.queue_free()
	tile_nodes.erase(id)
	_free_deco(id)
	tile_rects.erase(id)
	tile_fit.erase(id)
	expose_cards.erase(id)
	if focused_tile == id:
		focused_tile = -1
		if tiles.empty():
			_go_home()
		else:
			_focus_tile(tiles[tiles.size() - 1])
	request_redraw()


func _restore_window(id):
	if id < 0 or not _id_alive(id):
		return
	_focus_tile(id)  # ya limpia `minimized` y reinserta


# Alt+M: minimiza la ventana enfocada; si ya está minimizada, la restaura. No depende
# de que el Frame esté a la vista (ver frame.gd/_input).
func _toggle_minimize_focused():
	var id = focused_tile
	if id < 0 or not _id_alive(id):
		return
	if minimized.has(id):
		_restore_window(id)
	elif current_activity != null and tiles.has(id):
		_minimize_window(id)
	request_redraw()


# Super+W / botón de cerrar del exposé: cierre educado (xdg_toplevel.close). La app
# puede preguntar antes de irse.
func _close_window_id(id):
	if id >= 0 and _id_alive(id):
		# Cerrar la «Pantalla compartida» = la persona deja de mirar: corta al emisor.
		# (gvd recv por sí solo reinicia su ventana, así que también se lo termina.)
		if _pantalla_sender != "" and _pantalla_window_ids().has(id):
			_pantalla_closed_here()
		compositor.close(id)
	request_redraw()


# Cierra la ventana enfocada (mismo efecto que Alt+F4). Sin foco de ventana, prueba la
# wayland actual; si no hay, no hace nada.
func _close_focused():
	var id = focused_tile
	if id < 0 or not _id_alive(id):
		id = _current_wayland_id()
	_close_window_id(id)


# Alt+F11: pantalla completa de la ventana enfocada (ocupa todo, se esconde el Frame).
func _toggle_fullscreen():
	if fullscreen_id >= 0:
		fullscreen_id = -1
	elif focused_tile >= 0 and tiles.has(focused_tile):
		fullscreen_id = focused_tile
	if frame != null:
		frame.set_visible(false)
	request_redraw()


# Alt+F10 / botón max de la app: maximizar = sacar la ventana de su franja partida
# para que ocupe todo el workspace (el hueco central del Frame, K12). Se recuerda la
# franja previa (miembros y pesos) para poder deshacerlo con _restore_maximized_window.
# Pantalla completa (todo el viewport, sin Frame) sigue siendo Alt+F11.
func _maximize_window(id):
	if id < 0 or not tiles.has(id):
		return
	fullscreen_id = -1
	# En flotante, maximizar es ocupar todo el hueco central conservando la geometría
	# flotante recordada (se restaura con _restore_maximized_window).
	if hybrid.is_floating(id):
		wm_maximized[id] = true
		_focus_tile(id)
		request_redraw()
		return
	var g = _group_of(id)
	if g != null:
		var weights = {}
		for m in g:
			weights[m] = _weight(m)
		maximize_state[id] = {"members": g.duplicate(), "weights": weights}
		_remove_from_group(id)
	else:
		# Ya sola en su pantalla: maximizar no cambia nada visible, pero se marca para
		# que desmaximizar (-> flotante) tenga a qué responder.
		maximize_state[id] = {"members": [id], "weights": {}}
	_focus_tile(id)
	request_redraw()


# Desmaximizar: rearma la franja partida que la ventana ocupaba antes de maximizar.
# Los miembros que se cerraron entretanto simplemente no vuelven.
func _restore_maximized_window(id):
	if id < 0:
		return
	if hybrid.is_floating(id):
		wm_maximized.erase(id)
		_focus_tile(id)
		request_redraw()
		return
	var st = maximize_state.get(id)
	maximize_state.erase(id)
	if st == null or not tiles.has(id):
		return
	var weights = st.get("weights", {})
	var members = []
	for m in st.get("members", []):
		if tiles.has(m):
			members.append(m)
	if members.size() >= 2:
		# Por si el usuario retileó a mano mientras estaba maximizada: se saca a cada
		# miembro de su grupo actual antes de rearmar la franja guardada.
		for m in members:
			_remove_from_group(m)
		for m in range(1, members.size()):
			WM_UNITS.join(wm_units, members[m], members[0], "right")
		for m in members:
			WM_UNITS.set_weight(wm_units, m, float(weights.get(m, 1.0)))
		_rebuild_tiles(_units())
	else:
		# Desmaximizar en mosaico deja la ventana en modo flotante (mismo cambio que el
		# Super+arrastre); el rect flotante lo restaura float_memory o la cascada.
		set_window_mode(id, WM_HYBRID.FLOATING)
	_focus_tile(id)
	request_redraw()


# Alt+F10 / botón de la app: alterna maximizar y desmaximizar.
func _toggle_maximize_window(id):
	if id < 0 or not tiles.has(id):
		return
	if wm_maximized.has(id) or maximize_state.has(id):
		_restore_maximized_window(id)
	else:
		_maximize_window(id)


# K18: la ventana de pantalla compartida se reconoce por su título fijo
# ("Pantalla compartida"). Este helper reutiliza la lógica de maximizar
# existente (`_maximize_window`, Alt+F10) para llevarla al hueco central de K12
# y restaurarla; cualquier UI (bloque/ventana) o gesto puede invocarlo sin
# duplicar el cálculo del layout. Devuelve true si encontró la ventana.
func maximize_window_by_title(title):
	var want = String(title).strip_edges().to_lower()
	if want == "":
		return false
	for id in tiles:
		if _id_alive(id) and compositor.get_title(id).to_lower().find(want) >= 0:
			if fullscreen_id == id:
				fullscreen_id = -1
			else:
				_maximize_window(id)
			return true
	return false


# Teclado: tilea la ventana enfocada con la siguiente (arma una pantalla partida sin mouse).
func _tile_with_next():
	if not tile_mode or focused_tile < 0:
		return
	var units = _units()
	var i = _focused_unit_index(units)
	var next_id = -1
	for k in range(i + 1, units.size()):
		for m in units[k]:
			if m != focused_tile:
				next_id = m
				break
		if next_id >= 0:
			break
	if next_id >= 0:
		_tile_drop(focused_tile, next_id)


func _ensure_premult_material():
	if premult_material == null:
		premult_material = CanvasItemMaterial.new()
		premult_material.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA


# --- Dialogos: capas centradas sobre la vista de su toplevel raiz ---

func _update_dialogs(root_id):
	if dialog_view == null:
		return
	if expose:
		dialog_view.visible = false
		return
	# K12: los diálogos se recortan al hueco central del Frame, no a toda la pantalla.
	var cr = _content_rect(view.rect_size)
	dialog_view.rect_position = cr.position
	dialog_view.rect_size = cr.size

	for i in range(dialogs.size() - 1, -1, -1):
		if not _id_alive(dialogs[i]):
			dialogs.remove(i)
	for d in dialog_boxes.keys():
		if not _id_alive(d):
			var box = dialog_boxes[d]
			dialog_boxes.erase(d)
			dialog_fit_req.erase(d)
			if box != null and is_instance_valid(box):
				box.queue_free()

	var any_visible = false
	for d in dialogs:
		var box = dialog_boxes.get(d)
		if box == null:
			box = _new_dialog_box(d)
		var visible = root_id >= 0 and _root_of(d) == root_id
		box.visible = visible
		if visible:
			any_visible = true
			_layout_dialog(box, d)
	dialog_view.visible = any_visible and view.visible


func _new_dialog_box(d):
	var box = Control.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.rect_clip_content = true
	box.visible = false
	dialog_view.add_child(box)
	dialog_boxes[d] = box
	return box


# Centra la geometria del dialogo en la vista (sin sombras: la caja recorta).
func _layout_dialog(box, d):
	_ensure_premult_material()
	var geo = _dialog_geo(d)
	_fit_dialog(d, geo)
	var layers = compositor.get_layers(d)
	# `_dialog_rect` devuelve coords de pantalla; la caja se posiciona local a la
	# capa de diálogos (que ahora está recortada al hueco central de K12).
	box.rect_position = _dialog_rect(d).position - dialog_view.rect_position
	box.rect_size = geo.size
	while box.get_child_count() < layers.size():
		var child = TextureRect.new()
		child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		child.expand = true
		child.stretch_mode = TextureRect.STRETCH_SCALE
		child.material = premult_material
		child.visible = false
		box.add_child(child)
	for i in range(layers.size()):
		var node = box.get_child(i)
		var layer = layers[i]
		var size = layer.rect.size
		if (size.x <= 0.0 or size.y <= 0.0) and layer.texture != null:
			size = layer.texture.get_size()
		node.texture = layer.texture
		node.rect_position = layer.rect.position - geo.position
		node.rect_size = size
		node.visible = layer.texture != null
	for i in range(layers.size(), box.get_child_count()):
		box.get_child(i).visible = false


# Un diálogo más grande que el hueco central (p. ej. el selector de archivos de GTK,
# que recuerda su último tamaño) quedaba recortado por la capa. Se le pide a la app
# un tamaño que quepa; GTK lo respeta hasta su mínimo. Una vez por tamaño pedido.
func _fit_dialog(d, geo):
	if geo.size.x <= 0.0 or geo.size.y <= 0.0:
		return
	var cr = _content_rect(view.rect_size)
	var want = CONTENT_LAYOUT.fit_size(geo.size, cr.size)
	if want == geo.size:
		return
	if dialog_fit_req.get(d) == want:
		return
	dialog_fit_req[d] = want
	compositor.set_size(d, want)


func _dialog_geo(d):
	var geo = compositor.get_geometry(d)
	if geo.size.x > 0.0 and geo.size.y > 0.0:
		return geo
	# Fallback: caja de las capas si el cliente aun no publico geometria.
	var layers = compositor.get_layers(d)
	if layers.size() == 0:
		return geo
	var mn = Vector2(1e9, 1e9)
	var mx = Vector2(-1e9, -1e9)
	for layer in layers:
		mn.x = min(mn.x, layer.rect.position.x)
		mn.y = min(mn.y, layer.rect.position.y)
		mx.x = max(mx.x, layer.rect.position.x + layer.rect.size.x)
		mx.y = max(mx.y, layer.rect.position.y + layer.rect.size.y)
	return Rect2(mn, mx - mn)


# K12: centra el diálogo sobre la ventana de su raíz, pero siempre dentro del hueco
# central del Frame; si no cabe, se alinea arriba-izquierda y lo recorta la capa.
func _dialog_rect(d):
	var geo = _dialog_geo(d)
	var cr = _content_rect(view.rect_size)
	var base = tile_rects.get(_root_of(d), cr)
	var centered = base.position + base.size * 0.5 - geo.size * 0.5 - geo.position
	return Rect2(CONTENT_LAYOUT.clamp_inside(cr, centered, geo.size), geo.size)


func _root_of(id):
	var guard = 0
	while id > 0 and guard < 32:
		var parent = compositor.get_parent_id(id)
		if parent <= 0:
			break
		id = parent
		guard += 1
	return id


# Bisel clásico del Hogar (claro arriba/izq, oscuro abajo/der); `pressed` lo
# invierte. Mismo lenguaje que los bloques del Frame. `r` en coords de pantalla.
# El grosor escala con la UI y el factor de Apariencia (antes 2 px fijos, que en
# pantallas densas quedaba como un hilo).
func _home_bevel_w():
	return max(1.0, round(HOME_BEVEL * get_imgui_scale() * float(appearance.get("bevel", 1.0))))


func _draw_home_bevel(r, face, pressed):
	imgui_draw_rect_filled(r, face, 0.0)
	var b = _home_bevel_w()
	var light = HOME_BLOCK_DARK if pressed else HOME_BLOCK_LIGHT
	var dark = HOME_BLOCK_LIGHT if pressed else HOME_BLOCK_DARK
	imgui_draw_rect_filled(Rect2(r.position, Vector2(r.size.x, b)), light, 0.0)
	imgui_draw_rect_filled(Rect2(r.position, Vector2(b, r.size.y)), light, 0.0)
	imgui_draw_rect_filled(Rect2(Vector2(r.position.x, r.end.y - b), Vector2(r.size.x, b)), dark, 0.0)
	imgui_draw_rect_filled(Rect2(Vector2(r.end.x - b, r.position.y), Vector2(b, r.size.y)), dark, 0.0)


# `offset` corre el Hogar dentro de la fila de pantallas: 0 en su lugar, ±ancho fuera
# de vista. Así el paneo lo dibuja deslizándose junto a las ventanas, no de un salto.
func _draw_home(offset = 0.0):
	var now = OS.get_ticks_msec()
	_tick_starting(now)
	# Tab solo alterna Anillo/Grilla en el Hogar. Ctrl+Tab NO es un atajo del shell:
	# las apps lo usan para cambiar de pestaña, así que la tecla debe llegarles.
	if is_key_pressed(KEY_TAB) and not Input.is_key_pressed(KEY_CONTROL):
		apps_view = not apps_view
	if apps_view:
		_draw_apps(offset)
		return
	var vp = get_viewport_rect().size
	set_next_window_pos(Vector2(offset, 0.0), true)
	set_next_window_size(vp, true)
	var flags = WINDOW_NO_DECORATION | WINDOW_NO_BACKGROUND | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS | WINDOW_NO_BRING_TO_FRONT_ON_FOCUS
	# En Grupo/Vecindario esta ventana cubre la pantalla sólo para dibujar el ícono
	# central: fuera de él no debe querer el mouse, o ImGuiCanvas marca el clic como
	# manejado y la capa neighborhood_ui (menús, arrastre) nunca lo recibe.
	if zoom_level > 0 and not _over_center_icon(get_viewport().get_mouse_position()):
		flags |= IMGUI_WINDOW_NO_MOUSE_INPUTS
	# Sin padding el fondo y las posiciones absolutas coinciden con la vista.
	push_style_var_vec2(STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	if begin("##home", flags):
		# Fondo: degradado sobrio, color sólido o imagen configurada (K11a). Con zoom
		# activo no se pinta: lo aporta la capa Grupo/Vecindario.
		if zoom_f <= 0.001:
			_draw_home_background(vp)

		home_icon_loads = 8
		var u = grid_unit(vp)
		var pad = 0.0  # bloques pegados al borde, igual que el Frame (sin margen de 1px)
		var btn_size = Vector2(u * 1.25, u * 1.25)
		var entries = _ring_entries()
		var layout = _orbit_layout(vp, entries.size(), entries)
		_ring_prune(entries)

		# El ícono central (figura XO/monitor) ya no es decorativo: abre el menú de
		# sesión (Salir/Recargar), porque 'Salir' dejó de ser actividad del anillo.
		var cc = vp * 0.5
		# Escala continua según el zoom: es el ancla visible del Hogar <-> Grupo <->
		# Vecindario (Hogar 1.0 -> Grupo 0.6 -> Vecindario 0.35).
		var monitor = ZOOM.center_icon_rect(zoom_f, vp, u * 0.90)
		set_cursor_pos(monitor.position)
		push_style_color(COL_BUTTON, Color(0, 0, 0, 0))
		push_style_color(COL_BUTTON_HOVERED, Color(0, 0, 0, 0))
		push_style_color(COL_BUTTON_ACTIVE, Color(0, 0, 0, 0))
		push_style_var_float(STYLE_VAR_FRAME_ROUNDING, 0.0)
		button("##home_center", monitor.size)
		# K9: el menú de sesión se abre con el botón derecho; el izquierdo no lo abre.
		var center_right = is_item_clicked(1)
		var center_hover = is_item_hovered()
		pop_style_var()
		pop_style_color(3)
		var center_face = HOME_BLOCK_LIGHT
		if center_hover:
			center_face = center_face.linear_interpolate(Color(1, 1, 1, center_face.a), 0.10)
		if center_hover:
			set_tooltip("Este equipo · Configuración / Sesión")
		# Mismo ícono y placa que el centro del Vecindario: un solo "Este equipo".
		var cr = min(monitor.size.x, monitor.size.y) * 0.5 - 2.0
		var ka = Color(1, 1, 1, home_bg_alpha)
		imgui_draw_circle_filled(cc + Vector2(0.0, 3.0), cr, Color(0, 0, 0, 0.35) * ka, 0)
		# En Grupo/Vecindario «Este equipo» lleva su acento, como los demás equipos el
		# suyo (neighborhood_ui._draw_node); en el Hogar entra con el zoom.
		var acc_k = clamp(zoom_f, 0.0, 1.0)
		var center_ring = HOME_BLOCK_DARK.linear_interpolate(accent, acc_k)
		center_face = center_face.linear_interpolate(Color(accent.r, accent.g, accent.b,
			center_face.a), 0.35 * acc_k)
		imgui_draw_circle_filled(cc, cr, center_face * ka, 0)
		imgui_draw_circle(cc, cr, center_ring * ka, 0, 2.0)
		var dev_tex = local_device_icon_tex()
		if dev_tex != null:
			var ds = cr * 1.20
			set_cursor_pos(cc - Vector2(ds, ds) * 0.5)
			image(dev_tex, Vector2(ds, ds))
		else:
			set_cursor_pos(cc - Vector2(7.0, 13.0) * 0.5)
			text_colored(HOME_BLOCK_TEXT, "H")
		if center_right:
			open_popup("##home_session")
		MENU_STYLE.begin(self)
		if begin_popup("##home_session"):
			MENU_STYLE.chrome(self, "Este equipo")
			if MENU_STYLE.item(self, "Configuración"):
				_open_by_name("Configuración")
			separator()
			if _rotate_has_sensor() and begin_menu("Pantalla"):
				if MENU_STYLE.item(self, "Rotar a la izquierda"):
					_rotate_screen("left")
				if MENU_STYLE.item(self, "Rotar a la derecha"):
					_rotate_screen("right")
				separator()
				var auto_on = _rotate_auto_on()
				if MENU_STYLE.item(self, "Auto-rotación", "", auto_on):
					_rotate_set_auto(not auto_on)
				end_menu()
			if MENU_STYLE.item(self, "Salir"):
				recovery.quit(self)
			if MENU_STYLE.item(self, "Recargar el shell"):
				# Recarga GDScript conservando Host/compositor y todas las ventanas.
				# recovery.restart reinicia el proceso y desconecta VS Code/Codex.
				Host.call_deferred("reload_shell")
			end_popup()
		MENU_STYLE.end(self)

		# Con zoom activo el Hogar aporta sólo su ícono central (ya dibujado arriba,
		# una sola vez): el anillo y los bloques los reemplaza la capa Grupo/Vecindario.
		if zoom_f > 0.001:
			end()
			pop_style_var()
			return

		# Anillo de sólo lectura: actividades abiertas + atajos del Frame, con
		# reacomodo animado al entrar/salir ítems.
		ring_layout = []
		# Paneo/deslizamiento hacia el Hogar: mientras las ventanas siguen en pantalla
		# sólo se ven fondo e ícono central (el draw list no respeta el alfa: las
		# burbujas aparecían opacas antes de tiempo). Al llegar, entran con su animación.
		if home_bg_alpha < 0.999:
			home_ring_hidden = true
			end()
			pop_style_var()
			return
		if home_ring_hidden:
			home_ring_hidden = false
			for e in entries:
				ring_intro[e.name] = now
		var slide = Vector2(offset, 0.0)
		for i in range(entries.size()):
			var e = entries[i]
			var pos = _ring_show(e.name, layout[i], now)
			var screen = pos + slide
			var label = e.name
			# Ventana que llega de otro equipo: «título @equipo» como en el Frame.
			var rwid = int(wayland_ids.get(e.name, -1))
			if rwid >= 0 and window_peer_icon(rwid) != null:
				label = window_title(rwid)
			if e.activity != null and e.activity.has("service") and _service_running(e.name):
				label += " *"
			var clicked = _draw_ring_item(pos, btn_size, _ring_tex(e), label,
				_ring_state(e), e.id, starting.get(e.name, -1), _ring_appear(e.name, now))
			ring_layout.append({"entry": e, "screen": screen, "size": btn_size})
			if clicked:
				_ring_activate(e, pos, btn_size)

		# Bloque Apps: tesela U x U con bisel, como los bloques del Frame.
		var apps_side = u
		var apps_pos = Vector2(vp.x - apps_side - pad, frame_bar_h(vp) + pad)
		set_cursor_pos(apps_pos)
		var apps_screen = get_cursor_screen_pos()
		push_style_color(COL_BUTTON, Color(0, 0, 0, 0))
		push_style_color(COL_BUTTON_HOVERED, Color(0, 0, 0, 0))
		push_style_color(COL_BUTTON_ACTIVE, Color(0, 0, 0, 0))
		push_style_var_float(STYLE_VAR_FRAME_ROUNDING, 0.0)
		var apps_clicked = button("##apps_btn", Vector2(apps_side, apps_side))
		var apps_held = is_item_active()
		var apps_hover = is_item_hovered()
		pop_style_var()
		pop_style_color(3)
		var apps_face = HOME_BLOCK_FACE
		if apps_hover and not apps_held:
			apps_face = apps_face.linear_interpolate(Color(1.0, 1.0, 1.0, apps_face.a), 0.08)
		_draw_home_bevel(Rect2(apps_screen, Vector2(apps_side, apps_side)), apps_face, apps_held)
		var apps_cw = 7.0 * get_imgui_scale()
		set_cursor_pos(apps_pos + Vector2((apps_side - 4.0 * apps_cw) * 0.5, (apps_side - 13.0 * get_imgui_scale()) * 0.5))
		text_colored(HOME_BLOCK_TEXT, "Apps")
		if apps_clicked:
			apps_view = true

		if activity_error != "":
			# Sobre la barra inferior, no dentro (en 800x600 la barra mide 80 px).
			set_cursor_pos(Vector2(pad, vp.y - frame_bar_h(vp) - 20.0))
			text(activity_error)
	end()
	pop_style_var()


# --- Rotación de pantalla (menú del anillo) --------------------------------------
# Delega en session/gdtk-rotate (ver SPEC/session/DEPS): `left`/`right` rotan 90° y
# `hold` pausa el modo auto; `auto` sigue el sensor y arranca activo por defecto. El
# estado "auto activo" es la ausencia de $XDG_RUNTIME_DIR/gdtk/rotate.hold.

func _rotate_runtime_dir():
	var d = OS.get_environment("XDG_RUNTIME_DIR")
	if d == "":
		d = "/tmp"
	return d + "/gdtk"


func _rotate_script():
	var home = OS.get_environment("GDTK_HOME")
	if home == "":
		home = OS.get_environment("HOME") + "/gdtk"
	return home + "/session/gdtk-rotate"


func _rotate_run(args):
	var exe = _rotate_script()
	if not File.new().file_exists(exe):
		return
	_reap_rotate()
	if args.size() > 0 and String(args[0]) == "auto":
		# Daemon de instancia única y larga vida: tiene que quedar desacoplado del
		# shell (bloqueante lo colgaría para siempre). El resto son one-shot: van
		# por Thread con execute bloqueante para no dejar hijos sin reap.
		OS.execute(exe, args, false)
		return
	var state = {"done": false}
	var th = Thread.new()
	_rotate_threads.append(th)
	_rotate_states.append(state)
	th.start(self, "_rotate_run_work", {"exe": exe, "args": args, "state": state})


func _rotate_run_work(userdata):
	OS.execute(String(userdata.get("exe", "")), userdata.get("args", []), true)
	_rotate_exec_mutex.lock()
	userdata.get("state", {}).done = true
	_rotate_exec_mutex.unlock()


func _reap_rotate():
	for i in range(_rotate_threads.size() - 1, -1, -1):
		_rotate_exec_mutex.lock()
		var done = _rotate_states[i].get("done", false)
		_rotate_exec_mutex.unlock()
		if done:
			_rotate_threads[i].wait_to_finish()
			_rotate_threads.remove(i)
			_rotate_states.remove(i)


# ¿Hay acelerómetro? Se consulta una vez y se cachea. No se lee el sysfs con File:
# los archivos de sysfs reportan tamaño 0 y get_as_text() devuelve vacío (además
# ensucia el log con "r != len"); grep sí lee el contenido.
func _rotate_has_sensor():
	if _rotate_sensor != null:
		return _rotate_sensor
	_rotate_sensor = false
	var out = []
	var rc = OS.execute("sh",
		["-c", "grep -qs accel /sys/bus/iio/devices/iio:device*/name 2>/dev/null"],
		true, out)
	_rotate_sensor = (rc == 0)
	return _rotate_sensor


func _rotate_auto_on():
	return not File.new().file_exists(_rotate_runtime_dir() + "/rotate.hold")


# Gesto manual: rota y pausa el auto, para que el sensor no lo pise enseguida.
func _rotate_screen(direction):
	_rotate_run([direction])
	_rotate_run(["hold", "on"])


func _rotate_set_auto(on):
	if on:
		_rotate_run(["hold", "off"])
		_rotate_run(["auto"])   # instancia única: no duplica el daemon
	else:
		_rotate_run(["hold", "on"])


# Arranca el daemon de auto-rotación una sola vez, si hay sensor y el auto está activo.
# Lo hace el shell (no sway.conf) para que funcione en cualquier sesión: el script
# elige el backend sway/xrandr según el entorno.
func _maybe_start_rotate():
	if rotate_autostarted:
		return
	rotate_autostarted = true
	if _rotate_has_sensor() and _rotate_auto_on():
		_rotate_run(["auto"])


# En X11 sin WM la ventana no sigue el tamaño del root al rotar; se ajusta acá.
func _x11_follow_screen():
	var scr = OS.get_screen_size()
	if scr.x > 0.0 and scr != get_viewport_rect().size:
		OS.window_size = scr
		OS.window_position = Vector2.ZERO


# --- Anillo: entradas y layout animado -------------------------------------------

func _app_by_id(id):
	if not apps.scanned:
		apps.scan()
	var want = String(id)
	for a in apps.apps:
		if a.id == want:
			return a
	# Tolerante: el prefijo del id puede cambiar entre escaneos/versiones. Se acepta
	# el mismo nombre de archivo base o el mismo nombre visible.
	var base = want.get_file()
	for a in apps.apps:
		if String(a.id).get_file() == base or String(a.name) == want:
			return a
	return null


# Entrada de favorito a partir de un id, aunque la app no se resuelva: así el
# favorito SIEMPRE aparece en el anillo (con monograma si no hay ícono). `app`
# mínima con las claves que espera el resto (tex/icon_tried/cmd/exec).
func _favorite_entry(id):
	var app = _app_by_id(id)
	if app != null:
		return app
	var nm = String(id).get_file().get_basename()
	if nm == "":
		nm = String(id)
	return {
		"id": String(id), "name": nm, "exec": "", "cmd": "", "icon": "",
		"categories": "", "key": nm.to_lower(), "wm_class": "", "tex": null,
		"icon_tried": true, "unresolved": true,
	}


# Entradas del anillo, DINÁMICAS y de SOLO LECTURA: actividades abiertas ahora
# (ordenadas por último uso) más los atajos fijados en el Frame (pines de las dos
# barras). No se edita directamente: para cambiar el anillo se fijan/quitan bloques
# en el Frame. "Configuración" vive en el submenú del ícono central.
func _ring_entries():
	var out = []
	var seen = {}
	var open = []
	for act in ACTIVITIES:
		if act.has("quit") and act.quit:
			continue
		if String(act.name) == "Configuración":
			continue
		if _activity_state(act) == "closed" and not starting.has(act.name):
			continue
		if seen.has(act.name):
			continue
		seen[act.name] = true
		open.append(act)
	open.sort_custom(self, "_mru_before")
	for act in open:
		out.append({"kind": "activity", "id": act.name, "name": act.name, "activity": act, "app": null})
	if not apps.scanned:
		apps.scan()
	if frame != null:
		for id in frame.pinned_ids():
			var app = _favorite_entry(id)
			if seen.has(app.name):
				continue
			seen[app.name] = true
			out.append({"kind": "favorite", "id": app.id, "name": app.name, "activity": null, "app": app})
	return out


# Comparador MRU para sort_custom: el más reciente primero (final de activity_mru).
func _mru_before(a, b):
	var ia = activity_mru.find(String(a.name))
	var ib = activity_mru.find(String(b.name))
	return ia > ib


func _ring_tex(e):
	if e.kind == "favorite":
		return _activity_icon_of(e.app)
	return _activity_tex(e.activity)


func _ring_state(e):
	if e.kind == "favorite":
		return "favorite"
	return _activity_state(e.activity)


# Posición mostrada por nombre, animada hacia el objetivo con ease-out (~LAYOUT_MS).
# Entrada nueva: arranca en su destino y se le registra el instante de entrada para
# el fade/escala; retarget a mitad de camino continúa desde la posición actual.
func _ring_show(name, target, now):
	var cur = ring_pos.get(name)
	if cur == null:
		ring_pos[name] = target
		ring_anim.erase(name)
		ring_intro[name] = now
		return target
	var anim = ring_anim.get(name)
	if anim == null:
		if cur.distance_to(target) <= 0.5:
			ring_pos[name] = target
			return target
		anim = {"from": cur, "to": target, "since": now}
		ring_anim[name] = anim
	elif (anim.to as Vector2).distance_to(target) > 0.5:
		anim = {"from": cur, "to": target, "since": now}
		ring_anim[name] = anim
	var k = clamp(float(now - anim.since) / LAYOUT_MS, 0.0, 1.0)
	var p = (anim.from as Vector2).linear_interpolate(target, _ease_out(k))
	ring_pos[name] = p
	if k >= 1.0:
		ring_anim.erase(name)
	else:
		request_redraw()
		last_activity = now
	return p


func _ring_appear(name, now):
	var since = ring_intro.get(name, -1)
	if since < 0:
		return 1.0
	var k = clamp(float(now - since) / RING_INTRO_MS, 0.0, 1.0)
	if k < 1.0:
		request_redraw()
		last_activity = now
	return _ease_out(k)


# Descarta estado de animación de entradas que ya no están en el anillo.
func _ring_prune(entries):
	var keep = {}
	for e in entries:
		keep[e.name] = true
	for k in ring_pos.keys():
		if not keep.has(k):
			ring_pos.erase(k)
			ring_anim.erase(k)
			ring_intro.erase(k)


# Ease-out cúbico (sin overshoot): para reacomodos de layout no queremos rebote.
func _ease_out(k):
	k = clamp(k, 0.0, 1.0)
	return 1.0 - pow(1.0 - k, 3.0)


# Activar una entrada: favorito -> lanzar la app; actividad -> _activate con el pulso
# de arranque de las wayland cerradas.
func _ring_activate(e, pos, size):
	if e.kind == "favorite":
		if String(e.app.get("cmd", "")) == "":
			# Favorito sin app resuelta (no instalada o id desactualizado): no hay
			# comando para lanzar; se intenta por nombre y si no, queda el aviso.
			_open_by_name(e.name)
			return
		_launch_app(e.app, Rect2(pos, size))
		return
	var i = _activity_named(e.name)
	if i < 0:
		return
	var act = ACTIVITIES[i]
	if act.has("wayland") and _activity_state(act) == "closed":
		_remember_origin(act.name, Rect2(pos, size))
		pending_origin = Rect2(pos, size)
		pending_origin_since = OS.get_ticks_msec()
		starting[act.name] = OS.get_ticks_msec()
	_activate(i)


# Posiciones de las actividades en órbitas alrededor de la computadora.
func _home_layout(vp):
	return _orbit_layout(vp, ACTIVITIES.size(), ACTIVITIES)


# Distribución del anillo: pocas → un círculo ordenado alrededor del equipo central;
# muchas → espiral de ángulo áureo con dispersión orgánica (burbujas). El orden es
# el de `entries` (ya viene por último uso). Limita cada posición al lienzo.
func _orbit_layout(vp, n, entries = []):
	return RING_LAYOUT.orbit_layout(vp, n, entries, grid_unit(vp), frame_bar_h(vp), RING_CIRCLE_MAX)


# Notificación de arranque: mantiene el pulso mientras la actividad no tenga
# ventana/estado abierto y lo corta a los STARTING_MAX_MS o al llegar la ventana.
func _tick_starting(now):
	for name in starting.keys():
		if now - starting[name] > STARTING_MAX_MS:
			starting.erase(name)
			continue
		var i = _activity_named(name)
		if i < 0 or _activity_state(ACTIVITIES[i]) != "closed":
			starting.erase(name)
	if not starting.empty():
		request_redraw()


# Carga (y cachea) un PNG de shell/icons/np como ImageTexture. A diferencia de
# Sugar no hay entidades de color: el color viene horneado en el asset.
func _load_np_icon(name):
	var key = "np:" + String(name)
	if sugar_icons.has(key):
		return sugar_icons[key]
	var path = NP_DIR + String(name) + ".png"
	var img = Image.new()
	if img.load(path) != OK or img.get_width() == 0:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	sugar_icons[key] = tex
	return tex


# Rasteriza un SVG de Sugar a ImageTexture cacheada. Reemplaza las entidades
# &stroke_color;/&fill_color; por los colores XO, quita el DOCTYPE y lo carga.
# Slug dibuja el SVG como vector (nítido a cualquier escala) y sólo funciona en
# GLES3. Se rinde en un Viewport transparente y su ViewportTexture se usa como ícono
# en ImGui (image() ya flipea las ViewportTexture). En GLES2 se cae al rasterizado.
func _slug_ok():
	return ClassDB.class_exists("SlugVector") and ClassDB.class_exists("SlugVector2D") \
		and OS.get_current_video_driver() == OS.VIDEO_DRIVER_GLES3


func _load_sugar_slug(name, stroke, fill):
	var key = name + "|" + stroke.to_html(false) + "|" + fill.to_html(false)
	if slug_icons.has(key):
		return slug_icons[key]
	var vector = ClassDB.instance("SlugVector")
	vector.set_svg_path(SUGAR_DIR + name + ".svg")
	# Los SVG Sugar marcan los paints con las entidades &fill_color;/&stroke_color;,
	# que Slug reconoce: se recolorean sin reescribir el archivo.
	vector.set_fill_color(fill)
	vector.set_stroke_color(stroke)
	if not vector.is_valid():
		return null
	var vp = Viewport.new()
	vp.size = Vector2(SLUG_RASTER, SLUG_RASTER)
	vp.usage = Viewport.USAGE_2D
	vp.transparent_bg = true
	vp.render_target_update_mode = Viewport.UPDATE_ALWAYS
	var icon = ClassDB.instance("SlugVector2D")
	icon.set_vector(vector)
	icon.set_size(float(SLUG_RASTER))
	icon.set_centered(true)
	icon.position = Vector2(SLUG_RASTER, SLUG_RASTER) * 0.5
	vp.add_child(icon)
	add_child(vp)
	slug_vectors[key] = vector
	var tex = vp.get_texture()
	slug_icons[key] = tex
	return tex


func _load_sugar_svg(name, stroke, fill):
	var key = name + "|" + stroke.to_html(false) + "|" + fill.to_html(false)
	if sugar_icons.has(key):
		return sugar_icons[key]
	if _slug_ok():
		var slug = _load_sugar_slug(name, stroke, fill)
		if slug != null:
			sugar_icons[key] = slug
			return slug
	var text = _sugar_svg_text(name, stroke, fill)
	if text == "":
		return null
	var img = Image.new()
	var ok = false
	if img.has_method("load_svg_from_string"):
		ok = img.load_svg_from_string(text, 1.0) == OK
	if not ok and img.has_method("load_svg_from_buffer"):
		ok = img.load_svg_from_buffer(text.to_utf8(), 1.0) == OK
	if not ok:
		# Fallback: este motor no expone load_svg_from_string; se escribe el SVG ya
		# sustituido en user:// y lo rasteriza el loader SVG del motor.
		ok = _load_sugar_file(img, key, text)
	if not ok or img.get_width() == 0:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	sugar_icons[key] = tex
	return tex


func _load_sugar_file(img, key, text):
	var dir = "user://sugar-icons"
	Directory.new().make_dir_recursive(dir)
	var path = dir + "/" + key.md5_text() + ".svg"
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		return false
	f.store_string(text)
	f.close()
	return img.load(path) == OK


# Texto del SVG sin DOCTYPE, con width/height agrandados y las entidades ya resueltas.
func _sugar_svg_text(name, stroke, fill):
	var f = File.new()
	if f.open(SUGAR_DIR + name + ".svg", File.READ) != OK:
		return ""
	var s = f.get_as_text()
	f.close()
	var d = s.find("<!DOCTYPE")
	if d >= 0:
		var e = s.find("]>", d)
		if e < 0:
			e = s.find(">", d) - 1
		if e >= d:
			s = s.substr(0, d) + s.substr(e + 2, s.length() - e - 2)
	var size = str(SUGAR_RASTER)
	s = s.replace('height="55px"', 'height="' + size + '"').replace('width="55px"', 'width="' + size + '"')
	s = s.replace('height="55"', 'height="' + size + '"').replace('width="55"', 'width="' + size + '"')
	s = s.replace("&stroke_color;", "#" + stroke.to_html(false))
	s = s.replace("&fill_color;", "#" + fill.to_html(false))
	return s


# Estado de una actividad en el anillo: cerrado / abierto / minimizado / enfocado.
func _activity_state(activity):
	if current_activity != null and current_activity.name == activity.name:
		return "focused"
	if activity.has("wayland") and wayland_ids.has(activity.name) and _id_alive(wayland_ids[activity.name]):
		return "minimized" if minimized.has(wayland_ids[activity.name]) else "open"
	if activity.has("script") and script_instances.has(activity.name):
		return "open"
	if activity.has("service") and _service_running(activity.name):
		return "open"
	return "closed"


# Botón circular del anillo: placa, borde por estado, ícono XDG/Sugar y etiqueta.
# `starting_since` >= 0: notificación de arranque, el ícono pulsa (escala y borde).
# `appear` (0..1): entrada nueva, escala/fade breve (ver _ring_appear).
func _draw_ring_item(pos, size, tex, label, state, id, starting_since = -1, appear = 1.0):
	appear = clamp(appear, 0.0, 1.0)
	var scale = lerp(0.72, 1.0, appear)
	set_cursor_pos(pos)
	var sp = get_cursor_screen_pos()
	var c = sp + size * 0.5
	var base_radius = size.x * 0.5 - 2.0
	var pulse = 1.0
	var glow = 0.0
	if starting_since >= 0:
		var ph = float(OS.get_ticks_msec() - starting_since) / 1000.0
		var w = sin(TAU * ph / STARTING_PERIOD_S)
		pulse = 1.0 + 0.1 * w  # escala 0.9..1.1
		glow = clamp(0.5 + 0.5 * w, 0.0, 1.0)
	var radius = base_radius * pulse * scale
	var border = RING_CLOSED
	var thickness = 1.5
	if starting_since >= 0:
		# Arrancando: además del pulso, borde más grueso y brillante.
		border = Color(1.0, 0.82, 0.40, 0.5 + 0.5 * glow)
		thickness = 2.0 + 2.5 * glow
	elif state == "focused":
		border = accent
		thickness = 3.5
	elif state == "minimized":
		border = RING_MIN
		thickness = 2.0
	elif state == "open":
		border = RING_OPEN
		thickness = 2.5
	elif state == "favorite":
		border = RING_FAVORITE
		thickness = 2.0
	if (get_mouse_pos() - c).length() <= radius:
		border = Color(border.r, border.g, border.b, 1.0)
	var plate = RING_PLATE
	plate.a *= appear
	var edge = border
	edge.a *= appear
	# Relieve de burbuja flotante (Apariencia → relieve): sombra proyectada
	# abajo-derecha y brillo especular arriba-izquierda antes de la placa.
	var relief = bool(appearance.get("emboss", true))
	if relief:
		imgui_draw_circle_filled(c + Vector2(radius * 0.16, radius * 0.20), radius,
			Color(0.0, 0.0, 0.0, 0.34 * appear), 0)
	imgui_draw_circle_filled(c, radius, plate, 0)
	if relief:
		imgui_draw_circle_filled(c - Vector2(radius * 0.28, radius * 0.32), radius * 0.58,
			Color(0.82, 0.90, 1.0, 0.10 * appear), 0)
	if starting_since >= 0:
		imgui_draw_circle(c, radius + 4.0, Color(1.0, 0.85, 0.45, (0.20 + 0.35 * glow) * appear), 0, 2.0)
	if state == "focused":
		imgui_draw_circle(c, radius + 3.0, Color(accent.r, accent.g, accent.b, 0.35 * appear), 0, 2.0)
	imgui_draw_circle(c, radius, edge, 0, thickness)
	if state == "open":
		# Señal de abierto además del color.
		var dot = RING_OPEN
		dot.a *= appear
		imgui_draw_circle_filled(c + Vector2(radius * 0.72, radius * 0.72), 4.0, dot, 0)

	# Área pulsable completa (mismo tamaño que la grilla anterior), sin fondo azul.
	push_style_color(COL_BUTTON, Color(0, 0, 0, 0))
	push_style_color(COL_BUTTON_HOVERED, Color(1, 1, 1, 0.05))
	push_style_color(COL_BUTTON_ACTIVE, Color(1, 1, 1, 0.12))
	push_style_var_float(STYLE_VAR_FRAME_ROUNDING, base_radius)
	var clicked = button("##ring_" + id, size)
	pop_style_var()
	pop_style_color(3)

	var cw = 7.0 * get_imgui_scale()
	if tex != null:
		# Ícono dentro del círculo de 1.25U, centrado y escalado con la UI: el tope
		# fijo de 72 px dejaba el ícono chico en bloques grandes (portrait/densas).
		var ts = get_imgui_scale()
		var side = clamp(size.x * 0.56, 64.0 * ts, 72.0 * ts) * pulse * scale
		var icon_size = Vector2(side, side)
		set_cursor_pos(pos + (size - icon_size) * 0.5)
		image(tex, icon_size)
	else:
		set_cursor_pos(pos + Vector2((size.x - cw) * 0.5, (size.y - 13.0 * get_imgui_scale()) * 0.5))
		text_colored(Color(0.95, 0.85, 0.95, 1.0), label.substr(0, 1).to_upper())

	if state == "minimized":
		# Distinto de "abierta" más allá del color: ícono atenuado + contorno punteado.
		imgui_draw_circle_filled(c, radius, Color(0.05, 0.06, 0.09, 0.45 * appear), 0)
		var seg = 18
		var min_col = RING_MIN
		min_col.a *= appear
		for i in range(seg):
			if i % 2 == 1:
				var ang = TAU * float(i) / float(seg)
				imgui_draw_circle_filled(c + Vector2(cos(ang), sin(ang)) * radius, 2.0, min_col, 0)

	var lab = RING_LABEL if (state != "closed" and state != "minimized") else RING_LABEL_DIM
	lab.a *= appear
	set_cursor_pos(pos + Vector2((size.x - _text_w(label)) * 0.5, size.y + 3.0))
	text_colored(lab, label)
	return clicked


# Ícono XDG de una actividad: primero por programa de la ventana, luego por nombre.
func _activity_tex(activity):
	# «Pantalla compartida»: el ícono que mandó el equipo de origen.
	var awid = int(wayland_ids.get(String(activity.get("name", "")), -1))
	if awid >= 0 and _pantalla_icon != null:
		var peer_icon = window_peer_icon(awid)
		if peer_icon != null:
			return peer_icon
	if not apps.scanned:
		apps.scan()
	var prog = ""
	if activity.has("wayland") and activity.wayland.size() > 0:
		prog = activity.wayland[0]
	# El app_id de Wayland puede variar en capitalización ("Alacritty" vs
	# "alacritty"), ser reverse-DNS (org.gnome.Nautilus) o llevar sufijo.
	# apps.match_window_apps pliega y prueba StartupWMClass, el id del .desktop y el
	# binario del Exec usando el ÚLTIMO segmento (no tras el primer punto).
	for a in apps.match_window_apps(prog):
		if _activity_icon_of(a) != null:
			return a.tex
	# Sólo apps reales buscan por nombre; las internas usan monograma.
	if activity.has("wayland"):
		var want = apps.fold(activity.name)
		for a in apps.apps:
			if apps.fold(a.name) == want and _activity_icon_of(a) != null:
				return a.tex
	# Sin ícono XDG: algunos ítems del anillo tienen uno de Sugar razonable.
	return _sugar_icon_for(activity.name)


# Ícono de una ventana sin actividad cargada (o cuya actividad no tiene ícono):
# primero el XDG del programa por el app_id del toplevel; si no hay, el Sugar por
# nombre; y por último un genérico de computadora (antes usaba "document-send",
# que es el ícono de enviar de Sugar, y varias ventanas lo mostraban por error).
func _window_icon(id, name):
	if id >= 0:
		var app_id = compositor.get_app_id(id)
		if app_id != "":
			var tex = _activity_tex({"name": name, "wayland": [app_id]})
			if tex != null:
				return tex
	var sugar = _sugar_icon_for(name)
	if sugar != null:
		return sugar
	return null   # sin ícono: el Frame dibuja la inicial (nunca el XO)


func _sugar_icon_for(name):
	var icon = SUGAR_ACTIVITY_ICONS.get(name, "")
	if icon == "":
		return null
	return _load_sugar_svg(icon, SUGAR_STROKE, SUGAR_FILL)


func _activity_icon_of(app):
	if not app.icon_tried:
		if home_icon_loads <= 0:
			request_redraw()
			return null
		home_icon_loads -= 1
		apps._load_icon(app)
	return app.tex


func _draw_apps(offset = 0.0):
	var vp = get_viewport_rect().size
	# Una celda libre a cada lado y sobre/bajo la zona desplazable.
	var u = grid_unit(vp)
	set_next_window_pos(Vector2(offset + u, u), true)
	set_next_window_size(Vector2(vp.x - 2.0 * u, vp.y - 2.0 * u), true)
	if begin("##apps", WINDOW_NO_DECORATION | WINDOW_NO_BACKGROUND | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS | WINDOW_NO_BRING_TO_FRONT_ON_FOCUS):
		if button("Anillo"):
			apps_view = false
		same_line()
		var app = apps.draw(self)
		if activity_error != "":
			text(activity_error)
		if app != null:
			_launch_app(app, apps.chosen_rect)
	end()


# Una app de la grilla se abre como actividad wayland dinámica: sale en el
# anillo mientras viva su ventana (ver _on_toplevel_removed).
func _launch_app(app, origin = null):
	apps.query = ""
	var i = _activity_named(app.name)
	if i < 0:
		ACTIVITIES.append({"name": app.name, "wayland": ["sh", "-c", app.cmd], "dynamic": true})
		i = ACTIVITIES.size() - 1
	var act = ACTIVITIES[i]
	# Igual que el anillo: si la actividad está cerrada se registra el pulso de
	# arranque; la ventana entra animada desde el ícono que la lanzó cuando llegue.
	if act.has("wayland") and _activity_state(act) == "closed":
		act["match"] = [apps._program(app.exec), app.name]
		# Origen explícito (grilla, anillo); si no vino, el del pin/ítem del Frame.
		var from = origin
		if from == null:
			from = _frame_origin_for_app(app)
		if from != null:
			_remember_origin(app.name, from)
			pending_origin = from
			pending_origin_since = OS.get_ticks_msec()
	_activate(i)
	# La grilla vuelve al anillo de Hogar: ahí se ve el pulso de arranque del ícono
	# hasta que llegue la ventana (la vista no salta a la actividad al lanzarla).
	apps_view = false
	apps.watch(self, app.name, last_launch_pid)
	# Si no se pudo lanzar, no queda colgada en el anillo.
	if not _pending_has(app.name) and not wayland_ids.has(app.name) and ACTIVITIES[i].get("dynamic", false):
		ACTIVITIES.remove(i)


# Rect (coords de vista) del ícono de `app` en el Frame: pin de barra o ítem del strip
# de ventanas. Lee frame.bar_layout/items_layout sin tocar frame.gd; null si no está.
func _frame_origin_for_app(app):
	if frame == null or not is_instance_valid(frame):
		return null
	for zone in ["top", "dock"]:
		for e in frame.bar_layout.get(zone, []):
			if String(e.get("kind", "")) == "p" and String(e.get("id", "")) == String(app.id):
				var r = e.get("rect", null)
				if r != null:
					return Rect2(r)
	for it in frame.items_layout:
		if String(it.get("name", "")) == String(app.name):
			var sz = Vector2(float(it.get("w", 0.0)), float(it.get("h", 0.0)))
			if sz.x > 0.0 and sz.y > 0.0:
				return Rect2(Vector2(float(it.get("x", 0.0)), float(it.get("y", 0.0))), sz)
	return null


func _draw_activity():
	# Sin barra fija: la actividad usa toda la pantalla y el Frame va encima.
	var vp = get_viewport_rect().size
	if current_activity == null:
		return
	if current_activity.has("script") and activity_instance != null and activity_instance.has_method("draw"):
		set_next_window_pos(Vector2.ZERO, true)
		set_next_window_size(vp, true)
		var body_flags = WINDOW_NO_DECORATION | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS
		if begin("##activity", body_flags):
			activity_instance.draw(self)
		end()


# Marca una actividad como la más reciente (para el orden del anillo).
func _touch_mru(name):
	var n = String(name)
	if n == "":
		return
	activity_mru.erase(n)
	activity_mru.append(n)
	# Tope defensivo: no hace falta recordar más que lo que puede mostrarse.
	while activity_mru.size() > 64:
		activity_mru.pop_front()


func _activate(index):
	var activity = ACTIVITIES[index]
	_touch_mru(activity.name)
	if activity.has("quit") and activity.quit:
		recovery.quit(self)
		return
	if activity.has("script"):
		_release_activity()
		if not script_instances.has(activity.name):
			script_instances[activity.name] = load(activity.script).new()
		activity_instance = script_instances[activity.name]
		current_activity = activity
		activity_error = ""
		return
	if activity.has("wayland"):
		_open_wayland(activity)
	if activity.has("service"):
		_toggle_service(activity)


# --- Estado de servicios en segundo plano ------------------------------------
# El hilo de render NUNCA consulta procesos (SPEC-screen-share-compass §0): un
# worker (Thread + Mutex, como neighborhood.gd) recorre cada ~1 s las actividades
# con "service", mide con pgrep y publica un snapshot atómico
# {name -> {"running": bool, "pids": [int]}}. `_draw_home`/`_activity_state` sólo
# copian ese snapshot; `service_pids` (para el portal RemoteInput) se reconcilia en
# el hilo principal desde ese snapshot. Tras un lanzamiento hay una ventana de
# hasta ~1 s hasta que el worker confirma; el estado optimista ya es visible en el
# frame siguiente y `service_pids` se actualiza en el siguiente `_svc_poll()`.
const SERVICE_REFRESH_MS = 1000        # cadencia del worker de servicios
const SERVICE_SLEEP_STEP_MS = 100      # granularidad para que stop() no espere de más
const SERVICE_LAUNCH_GRACE_MS = 2000   # sostiene "running" mientras el proceso arranca
const SERVICE_STOP_GRACE_MS = 2000     # ignora pids residuales hasta que mueran
# Deskflow por defecto: xdg-desktop-portal se reinicia al arrancar la sesión y eso
# tumba la sesión InputCapture recién abierta. El primer arranque espera a que se
# asiente y, si el proceso muere igual, se reintenta con cooldown acotado.
const DESKFLOW_BOOT_DELAY_MS = 15000
const DESKFLOW_RETRY_MS = 6000
const DESKFLOW_RETRY_MAX_MS = 60000

var service_pids = {}               # name -> pid primario (portal RemoteInput), bajo _svc_mutex
var _svc_mutex = Mutex.new()
var _svc_thread = null
var _svc_targets = []               # [{name, cmd}] fijado antes de arrancar el hilo
var _svc_snapshot = {}              # name -> {"running": bool, "pids": [int]}
var _svc_launch_until = {}          # name -> ticks_ms de la gracia de arranque
var _svc_stop_until = {}            # name -> ticks_ms de la gracia tras parar
var _svc_errors = {}                # name -> mensaje de fallo de lanzamiento
var _svc_version = 0
var _svc_version_seen = -1
var _svc_want_stop = false
var _svc_launch_threads = []        # Threads de un solo uso, reapeados en _svc_poll
var _svc_launch_states = []         # {"done": bool} por Thread (is_active() no baja en este motor)


func _service_cmd(activity):
	return activity.service.replace("~/", OS.get_environment("HOME") + "/")


# Arranca el worker una sola vez (idempotente).
func _start_service_worker():
	if _svc_thread != null:
		return
	# Las actividades con "service" son fijas de configuración; se copian acá para
	# que el worker no lea ACTIVITIES (que el hilo principal muta con apps dinámicas).
	_refresh_service_targets()
	_svc_want_stop = false
	_svc_thread = Thread.new()
	_svc_thread.start(self, "_service_work")


func _refresh_service_targets():
	var targets = []
	for a in ACTIVITIES + SERVICES:
		if a.has("service"):
			targets.append({"name": a.name, "cmd": _service_cmd(a)})
	_svc_mutex.lock()
	_svc_targets = targets
	_svc_mutex.unlock()


func _stop_service_worker():
	_svc_mutex.lock()
	_svc_want_stop = true
	_svc_mutex.unlock()
	if _svc_thread != null:
		_svc_thread.wait_to_finish()
		_svc_thread = null
	for th in _svc_launch_threads:
		th.wait_to_finish()
	_svc_launch_threads = []
	_svc_launch_states = []


func _svc_stop_requested():
	_svc_mutex.lock()
	var s = _svc_want_stop
	_svc_mutex.unlock()
	return s


# Hilo del worker: mide y publica; nunca dibuja ni toca nodos.
func _service_work(_userdata):
	while true:
		if _svc_stop_requested():
			return
		var observed = {}
		_svc_mutex.lock()
		var targets = _svc_targets.duplicate(true)
		_svc_mutex.unlock()
		for t in targets:
			observed[t.name] = _pgrep_pids(t.cmd)
		var now = OS.get_ticks_msec()
		_svc_mutex.lock()
		var merged = SERVICE_STATE.merge_service_snapshot(observed, _svc_snapshot, now,
			_svc_launch_until, _svc_stop_until)
		if not SERVICE_STATE.snapshot_equal(merged, _svc_snapshot):
			_svc_snapshot = merged
			_svc_version += 1
		_svc_mutex.unlock()
		var waited = 0
		while waited < SERVICE_REFRESH_MS:
			OS.delay_msec(SERVICE_SLEEP_STEP_MS)
			waited += SERVICE_SLEEP_STEP_MS
			if _svc_stop_requested():
				return


# Consulta regular de procesos: pgrep corre sólo en el worker de servicios.
func _pgrep_pids(cmd):
	var out = []
	if OS.execute("pgrep", ["-u", OS.get_environment("USER"), "-f", "-x", cmd], true, out) != 0 or out.empty():
		return []
	return SERVICE_STATE.parse_pgrep_pids(out[0])


# Pids del usuario cuyo NOMBRE de ejecutable coincide exactamente (pgrep -x sin -f):
# sirve para barrer deskflow-core sin depender de la línea de comandos completa (que
# cambia entre client/server y configs). comando seguro, sin sh ni shell injection.
func _pgrep_name_pids(name):
	var out = []
	if OS.execute("pgrep", ["-u", OS.get_environment("USER"), "-x", name], true, out) != 0 or out.empty():
		return []
	return SERVICE_STATE.parse_pgrep_pids(out[0])


# Arranque: saca cualquier deskflow-core ajeno antes de que gdtk monitoree o lance el
# propio. El ciclo de vida propio sigue siendo `_toggle_service`/`service_pids`;
# esto sólo limpia los que ya venían de antes y no duplica lógica.
func _reap_stray_deskflow():
	for proc in ["deskflow-core", "deskflow"]:
		for pid in SERVICE_STATE.stray_deskflow_pids(_pgrep_name_pids(proc), service_pids.values()):
			OS.kill(pid)

# Copia el snapshot del worker al hilo principal y reconcilia `service_pids`.
# No bloquea: sólo toma el Mutex un instante.
func _svc_poll():
	# Reapea los Threads de lanzamiento ya terminados (wait_to_finish no bloquea si acabaron).
	for i in range(_svc_launch_threads.size() - 1, -1, -1):
		# En este motor `is_active()` sigue true hasta wait_to_finish(); el fin lo
		# publica el propio Thread con el flag `done` (bajo Mutex), sin bloquear.
		var st = _svc_launch_states[i]
		_svc_mutex.lock()
		var done = st.done
		_svc_mutex.unlock()
		if done:
			_svc_launch_threads[i].wait_to_finish()
			_svc_launch_threads.remove(i)
			_svc_launch_states.remove(i)
	_svc_mutex.lock()
	var version = _svc_version
	for name in _svc_snapshot:
		var e = _svc_snapshot[name]
		if e.running and not e.pids.empty():
			service_pids[name] = e.pids[0]
		else:
			service_pids.erase(name)
	for name in _svc_errors:
		activity_error = _svc_errors[name]
	_svc_errors.clear()
	_svc_mutex.unlock()
	if version != _svc_version_seen:
		_svc_version_seen = version
		request_redraw()


# Marca parada optimista: evita que un clic inmediato posterior (que aún leería
# "running" del snapshot) dispare un relanzamiento; el worker confirma en <= 1 s.
func _svc_mark_stopped(name):
	_svc_mutex.lock()
	_svc_snapshot[name] = {"running": false, "pids": []}
	_svc_stop_until[name] = OS.get_ticks_msec() + SERVICE_STOP_GRACE_MS
	_svc_launch_until.erase(name)
	service_pids.erase(name)
	_svc_version += 1
	_svc_mutex.unlock()


# Lanzamiento asíncrono: un Thread de un solo uso ejecuta la captura "sh ... & echo $!"
# y publica el pid bajo Mutex; el hilo de render no espera.
func _svc_launch_async(activity):
	var name = activity.name
	var cmd = _service_cmd(activity)
	var log_path = OS.get_environment("XDG_RUNTIME_DIR").plus_file("gdtk-" + name.to_lower() + ".log")
	# Marca optimista ya mismo: un segundo clic pare en vez de relanzar.
	_svc_mutex.lock()
	_svc_snapshot[name] = {"running": true, "pids": []}
	_svc_launch_until[name] = OS.get_ticks_msec() + SERVICE_LAUNCH_GRACE_MS
	_svc_stop_until.erase(name)
	_svc_version += 1
	_svc_mutex.unlock()
	var th = Thread.new()
	var state = {"done": false}
	_svc_launch_threads.append(th)
	_svc_launch_states.append(state)
	th.start(self, "_svc_launch_work", {"name": name, "cmd": cmd, "log_path": log_path, "state": state})


func _svc_launch_work(userdata):
	var name = userdata.name
	var cmd = userdata.cmd
	var log_path = userdata.log_path
	var out = []
	# Vía sh + & para que el proceso quede colgado de init: si lo lanzara Godot directo, al
	# morir quedaría zombie y pgrep lo seguiría dando por vivo.
	# Con output, Godot 3 pasa el comando por popen (otro sh, args entre comillas dobles):
	# sin escapar, ese sh externo expande $! a vacío antes de llegar al nuestro.
	OS.execute("sh", ["-c", cmd + " >" + log_path + " 2>&1 & echo \\$!"], true, out)
	var pid = int(String(out[0]).strip_edges()) if out.size() > 0 else 0
	_svc_mutex.lock()
	if pid > 0:
		service_pids[name] = pid
		_svc_snapshot[name] = {"running": true, "pids": [pid]}
		_svc_launch_until[name] = OS.get_ticks_msec() + SERVICE_LAUNCH_GRACE_MS
		_svc_errors.erase(name)
	else:
		_svc_snapshot[name] = {"running": false, "pids": []}
		_svc_errors[name] = name + ": no se pudo lanzar"
	userdata.state.done = true
	_svc_version += 1
	_svc_mutex.unlock()


func _toggle_service(activity):
	var name = activity.name
	if _service_running(name):
		# Parar: pids cacheados + OS.kill (barato) + estado false optimista.
		for pid in _service_processes(name):
			OS.kill(pid)
		_svc_mark_stopped(name)
		if name == "Deskflow":
			_deskflow_want = false   # parada deliberada: no reintentar
			_deskflow_retry_at = 0
		activity_error = ""
		return
	if activity.has("session") and OS.get_environment("GDTK_SESSION") != activity.session:
		activity_error = name + ": sólo en la sesión " + activity.session.to_upper()
		return
	if String(activity.get("service", "")).strip_edges() == "":
		activity_error = name + ": apagado o no disponible en esta sesión"
		return
	if name == "Deskflow":
		_deskflow_want = true
	_svc_launch_async(activity)


# Lectura del snapshot (sin I/O): el dibujo y el portal sólo copian el cache.
func _service_running(name):
	_svc_mutex.lock()
	var e = _svc_snapshot.get(name, null)
	var running = e != null and e.running
	_svc_mutex.unlock()
	return running


func _service_processes(name):
	_svc_mutex.lock()
	var e = _svc_snapshot.get(name, null)
	var pids = []
	if e != null:
		for p in e.pids:
			pids.append(p)
	_svc_mutex.unlock()
	return pids


# --- Publicador mDNS del Vecindario -------------------------------------------
# Al arrancar (nunca en _process/refresh) se anuncian los servicios gvd y
# Deskflow con avahi-publish-service. Cada anuncio se lanza en un Thread de un
# solo uso (mismo patrón que _svc_launch_async) que captura el pid vía
# `sh ... & echo $!`; los pids viven en `service_pids` y se matan en _exit_tree.
# Sin avahi no se hace nada: estado degradado, sin error.

var _publisher = null       # instancia única de neighborhood_publish.gd
var _publish_names = []     # nombres de anuncio en curso (claves en service_pids)
var _publish_started = false


# Hostname local como etiqueta; /etc/hostname es el respaldo si el entorno no lo
# trae. Sólo se usa para `name`; el `hid` público es opaco (ver PUBLISH_PLAN).
func _local_hostname():
	var host = OS.get_environment("HOSTNAME").strip_edges()
	if host == "":
		var f = File.new()
		if f.file_exists("/etc/hostname") and f.open("/etc/hostname", File.READ) == OK:
			host = f.get_as_text().strip_edges()
			f.close()
	return host


# Arranca los anuncios una sola vez. No bloquea: detect_avahi sólo mira el PATH
# con File y cada proceso se lanza en un Thread.
var _published_accent = ""


func _start_publishers():
	if _publish_started:
		return
	_publish_started = true
	_publisher = PUBLISH_MODEL.new()
	var avahi = _publisher.detect_avahi()
	if not avahi.available:
		return   # degradado, sin error
	_reap_stray_publishers()
	var identity = PUBLISH_PLAN.local_identity(_local_hostname(), local_device_kind())
	# Endpoint del canal peer (LAN, sin ssh) para que un vecino nos pida abrir el
	# receptor de pantalla. Vacío si el canal no está escuchando.
	if Host.peer_control != null and Host.peer_control.listening():
		identity["ctl"] = str(Host.peer_control.port)
	# Acento: los vecinos pintan este equipo con él en Grupo/Vecindario y en la
	# «Pantalla compartida» que les mandamos.
	_published_accent = "#" + accent.to_html(false)
	identity["accent"] = _published_accent
	var caps = {"gvd": true, "gvd_port": 5600, "deskflow": true, "deskflow_port": 24800,
		"deskflow_role": _deskflow_role}
	var plan = PUBLISH_PLAN.new().build(identity, caps, avahi.path)
	for entry in plan.services:
		_publish_launch(entry)


func _reap_stray_publishers():
	var user = OS.get_environment("USER")
	if user == "":
		return
	OS.execute("pkill", ["-TERM", "-u", user, "-f",
		"avahi-publish-service gdtk (gvd|deskflow|clip)"], true)


# Lanza un anuncio sin bloquear; el pid queda en `service_pids` bajo _svc_mutex y
# el Thread se reapea en _svc_poll (misma lista que los servicios).
func _publish_launch(entry):
	var name = "publish:" + String(entry.capability)
	_svc_mutex.lock()
	if _publish_names.has(name):
		_svc_mutex.unlock()
		return
	_publish_names.append(name)
	_svc_mutex.unlock()
	var argv = [String(entry.prog)]
	for a in entry.args:
		argv.append(String(a))
	var th = Thread.new()
	var state = {"done": false}
	_svc_launch_threads.append(th)
	_svc_launch_states.append(state)
	th.start(self, "_publish_launch_work", {"name": name, "argv": argv, "state": state})


func _publish_launch_work(userdata):
	var cmd = ""
	for part in userdata.argv:
		cmd += (" " if cmd != "" else "") + _shell_quote(part)
	var out = []
	# Mismo truco que _svc_launch_work: sh + & desprende el proceso para que su
	# muerte no deje zombie en Godot, y `echo $!` devuelve el pid sin bloquear.
	OS.execute("sh", ["-c", cmd + " >/dev/null 2>&1 & echo \\$!"], true, out)
	var pid = int(String(out[0]).strip_edges()) if out.size() > 0 else 0
	_svc_mutex.lock()
	if pid > 0:
		service_pids[userdata.name] = pid
	userdata.state.done = true
	_svc_mutex.unlock()


# Cita un argumento para `sh -c` (comillas simples, escapando la propia comilla).
func _shell_quote(s):
	return "'" + String(s).replace("'", "'\\''") + "'"


# Mata los anuncios vivos al cerrar/recargar el shell. Los lanzamientos en curso
# ya quedaron esperados por _stop_service_worker() antes de llamar acá.
func _stop_publishers():
	_svc_mutex.lock()
	var pids = []
	for name in _publish_names:
		var pid = int(service_pids.get(name, 0))
		service_pids.erase(name)
		if pid > 0:
			pids.append(pid)
	_publish_names = []
	_svc_mutex.unlock()
	for pid in pids:
		OS.kill(pid)


func _open_by_name(name):
	for i in range(ACTIVITIES.size()):
		if ACTIVITIES[i].name == name:
			_activate(i)
			return
	activity_error = "Actividad desconocida: " + name


# --- Cola de lanzamientos pendientes -----------------------------------------
# Varias actividades wayland pueden estar esperando su toplevel a la vez. Al llegar
# una ventana se intenta casar su app_id/título con el `expect` de algún pendiente;
# si el compositor no publica ese dato (o nada coincide) se usa la más reciente, que
# es el comportamiento histórico.

func _pending_has(name):
	for p in pending_launches:
		if p.name == name:
			return true
	return false


func _pending_add(name, expect = []):
	for p in pending_launches:
		if p.name == name:
			p["expect"] = expect
			p["since"] = OS.get_ticks_msec()
			pending_wayland = name
			return
	pending_launches.append({"name": name, "expect": expect, "since": OS.get_ticks_msec()})
	pending_wayland = name


func _pending_remove(name):
	for i in range(pending_launches.size() - 1, -1, -1):
		if pending_launches[i].name == name:
			pending_launches.remove(i)
	if pending_wayland == name:
		pending_wayland = pending_launches[pending_launches.size() - 1].name if not pending_launches.empty() else ""


func _pending_clear():
	pending_launches = []
	pending_wayland = ""


# Tokens para casar la ventana de una actividad: el programa lanzado (si no es el
# envoltorio `sh`), el nombre de la actividad y, cuando la grilla lo sabe, `match`.
func _expect_for(activity):
	var toks = []
	if activity.has("match"):
		for t in activity.match:
			toks.append(str(t))
	if activity.has("wayland") and activity.wayland.size() > 0:
		var prog = str(activity.wayland[0])
		if prog != "sh":
			toks.append(prog)
	var nm = str(activity.get("name", ""))
	if nm != "":
		toks.append(nm)
	return toks


# Pendiente al que corresponde el toplevel `id`, o "" si no hay app_id ni título
# (sin dato no se inventa: el llamador cae al comportamiento actual).
func _match_pending(id):
	var app_id = compositor.get_app_id(id)
	var title = compositor.get_title(id)
	if app_id == "" and title == "":
		return ""
	var aid = app_id.to_lower()
	var tit = title.to_lower()
	for k in range(pending_launches.size() - 1, -1, -1):
		for t in pending_launches[k].expect:
			var tok = str(t).to_lower()
			if tok == "":
				continue
			var base = tok.get_file() if tok.find("/") >= 0 else tok
			if base == "":
				continue
			var hit = aid != "" and (aid.find(base) >= 0 or base.find(aid) >= 0)
			if not hit and tit != "":
				hit = tit.find(base) >= 0
			if hit:
				return pending_launches[k].name
	return ""


func _open_wayland(activity):
	var name = activity.name
	activity_error = ""

	var id = -1
	if wayland_ids.has(name) and _id_alive(wayland_ids[name]):
		id = wayland_ids[name]

	if id >= 0:
		# Ya tenía ventana: se le sale de cualquier actividad previa y se enfoca, sin
		# pulso ni animación de entrada (no es un arranque nuevo).
		_release_activity()
		activity_instance = null
		pending_origin = null
		_pending_remove(name)
		starting.erase(name)
		current_activity = activity
		_focus_tile(id)
		return

	# Lanzamiento nuevo (actividad cerrada): la vista SE QUEDA EN HOGAR y el ícono
	# pulsa (starting / _tick_starting) hasta que llegue su toplevel. No se toca
	# current_activity, así el compositor no muestra el contenido de OTRA ventana en
	# el intervalo; cuando la ventana aparece, _on_toplevel_added enfoca y hace la
	# ampliación desde pending_origin. Si no llega en STARTING_MAX_MS el pulso se corta.
	if _pending_has(name):
		# Ya se está lanzando esta misma actividad: no lanzar un segundo proceso.
		return
	# Se conservan los otros pendientes (pueden seguir abriendo su ventana).
	_pending_add(name, _expect_for(activity))
	starting[name] = OS.get_ticks_msec()

	var vp = get_viewport_rect().size
	view.rect_position = Vector2.ZERO
	view.rect_size = vp
	view.rect_clip_content = true
	compositor.default_size = _tile_rect(vp).size

	var cmd = activity.wayland[0]
	var args = PoolStringArray()
	for i in range(1, activity.wayland.size()):
		args.push_back(activity.wayland[i])

	var pid = compositor.launch(cmd, args)
	last_launch_pid = pid
	if pid < 0:
		_pending_remove(name)
		starting.erase(name)
		activity_error = "No se pudo lanzar " + cmd
		_go_home()
	else:
		print("launched ", cmd, " pid ", pid)


func _go_home():
	release_modifiers()  # no dejar modificadores pegados en la app que sale de foco
	home_slide_since = -1
	apps_view = false  # el Hogar muestra siempre la fila de favoritos, no la grilla
	_set_zoom(0)
	neighborhood_ui.selected = ""
	_release_activity()
	current_activity = null
	activity_instance = null
	_pending_clear()
	typed = false
	type_queue = []
	type_done_frame = -1
	tex_ready_frame = -1
	expose = false
	view.visible = false  # los tiles siguen vivos: se vuelven a ver al enfocar una ventana


# --- Configuración (K11a) -----------------------------------------------------

func _apply_settings():
	if settings_bridge != null:
		accent = settings_bridge.accent
		# Acento nuevo => re-anunciar (los anuncios mDNS son de una sola vez).
		if _publish_started and _published_accent != "" \
				and _published_accent != "#" + accent.to_html(false):
			_stop_publishers()
			_publish_started = false
			_start_publishers()
		appearance = settings_bridge.appearance()
		ui_scale_factor = settings_bridge.ui_scale()
		_apply_ui_scale_env()
		_apply_input_settings()
		_apply_deskflow_settings()


# Exporta la escala de UI a los toolkits para que las apps (Firefox, GTK, Qt) no
# queden diminutas en pantallas densas. `OS.set_environment` alcanza a los procesos
# que el shell lanza después (wayland/actividades). Requiere reabrir las apps ya
# abiertas para que tomen la variable.
func _apply_ui_scale_env():
	if settings_bridge == null or settings_bridge.model == null:
		return
	var env = settings_bridge.model.ui_scale_env(settings_bridge.settings.get("ui_scale", 1.0))
	for k in env.keys():
		OS.set_environment(String(k), String(env[k]))


# Aplica en vivo al compositor (sway) los ajustes de entrada cuando cambia
# settings.json, sin reiniciar la sesión: hoy el scroll natural, que no es sólo de
# touchpad sino también del mouse/TrackPoint (`type:pointer`). Sólo sway; sin
# SWAYSOCK no hace nada (el valor igual queda para el próximo arranque).
func _apply_input_settings():
	if settings_bridge == null or settings_bridge.model == null:
		return
	if OS.get_environment("SWAYSOCK").strip_edges() == "":
		return
	var nat = settings_bridge.model.nat_scroll(
		settings_bridge.settings.get("natural_scroll", null))
	for cmd in settings_bridge.model.natural_scroll_cmds(nat):
		_sway_exec_async(cmd)


# swaymsg fuera del frame (ajustes de entrada en vivo): un Thread one-shot por
# tandita con OS.execute bloqueante adentro; el reap corre en _process. No bloquear
# el frame, no dejar hijos sin recolectar.
func _sway_exec_async(argv):
	if typeof(argv) != TYPE_ARRAY or argv.empty():
		return
	var state = {"done": false}
	var th = Thread.new()
	_sway_exec_threads.append(th)
	_sway_exec_states.append(state)
	th.start(self, "_sway_exec_work", {"argv": argv, "state": state})


func _sway_exec_work(userdata):
	var argv = userdata.get("argv", [])
	if argv.size() > 0:
		# Bloqueante dentro del Thread: Godot recolecta al terminar (wait_to_finish
		# en _sway_exec_poll); nada queda como hijo sin reap del shell.
		OS.execute("swaymsg", argv, true)
	_sway_exec_mutex.lock()
	userdata.state.done = true
	_sway_exec_mutex.unlock()


func _sway_exec_poll():
	for i in range(_sway_exec_threads.size() - 1, -1, -1):
		var state = _sway_exec_states[i]
		_sway_exec_mutex.lock()
		var done = state.done
		_sway_exec_mutex.unlock()
		if done:
			_sway_exec_threads[i].wait_to_finish()
			_sway_exec_threads.remove(i)
			_sway_exec_states.remove(i)


func _apply_deskflow_settings():
	if settings_bridge == null or settings_bridge.model == null:
		return
	var cfg = settings_bridge.model.deskflow(settings_bridge.settings.get("deskflow", {}))
	# Portal InputCapture: publica los rangos parciales por borde (ver
	# eis_server.c::barrier_crossed). El binario sin este método se ignora por
	# has_method; el rango por defecto (0..100) queda inerte.
	if Host.remote_input != null and Host.remote_input.has_method("set_capture_ranges"):
		Host.remote_input.set_capture_ranges(_deskflow_capture_ranges())
	var mode = String(cfg.get("mode", "off"))
	var effective_mode = mode
	# El gate se pregunta en cada aplicación de settings, pero el resultado se cachea
	# en deskflow_server_available(): el portal lo sube RemoteInput al arrancar y ahí
	# queda, así que el cacheo no puede quedar viejo respecto a lo que hay en el bus.
	if mode == "share_here" and not deskflow_server_available():
		effective_mode = "off"
		activity_error = "Deskflow servidor requiere el portal InputCapture y el shell no pudo registrarlo (ver RemoteInput en shell.log)."
	elif activity_error.begins_with("Deskflow servidor requiere el portal InputCapture"):
		activity_error = ""
	_deskflow_role = "server" if effective_mode == "share_here" else "client"
	var home = OS.get_environment("HOME")
	if home == "":
		return
	var local = _deskflow_local_name(String(cfg.get("name", "")))
	var service = _deskflow_service_for(effective_mode, home)
	# Sólo una baja explícita (mode off) desarma el autoarranque; si el portal todavía
	# no está listo (effective_mode off por disponibilidad) el tick sigue reintentando.
	if String(service).strip_edges() == "" and mode == "off":
		_deskflow_want = false
	var activity = _deskflow_activity()
	if activity != null and String(activity.get("service", "")) != service:
		activity.service = service
		_refresh_service_targets()
	var key = effective_mode + "|" + String(cfg.get("host", "")) + "|" + str(int(cfg.get("port", 24800))) \
		+ "|" + local + "|" + service + "|auto=" + str(bool(cfg.get("auto", false))) \
		+ "|" + _settings_layout_key()
	var writes = _deskflow_config_writes(effective_mode, cfg, home, local)
	if writes.empty():
		if _svc_thread != null and _service_running("Deskflow"):
			_toggle_service_by_name("Deskflow")
		return
	var auto_key = key + "|auto=" + str(bool(cfg.get("auto", false)))
	var auto = bool(cfg.get("auto", false))
	if auto and _svc_thread == null:
		_write_texts_async(writes)
		return
	if key == _deskflow_settings_key:
		# Ajustes sin cambios: sólo rearma el deseo de autoarranque (el tick arranca).
		if auto and auto_key != _deskflow_auto_key:
			_deskflow_auto_key = auto_key
			_deskflow_arm()
		elif not auto:
			_deskflow_want = false
		return
	_deskflow_settings_key = key
	if auto:
		if auto_key != _deskflow_auto_key:
			_deskflow_auto_key = auto_key
		_deskflow_arm()
	else:
		_deskflow_want = false
	_write_texts_async(writes)


# Marca que el autoarranque quiere el servicio corriendo y difiere el primer intento
# para que xdg-desktop-portal termine de reiniciarse al arrancar la sesión.
func _deskflow_arm():
	_deskflow_want = true
	if _deskflow_retry_at == 0:
		_deskflow_retry_at = OS.get_ticks_msec() + DESKFLOW_BOOT_DELAY_MS


# Reintenta el arranque por defecto: si el servicio debía correr y no está (p. ej. lo
# tumbó el reinicio del portal), lo relanza con cooldown acotado. No bloquea: usa el
# mismo ciclo de vida que la UI (_toggle_service_by_name).
func _deskflow_tick(now):
	# Re-deriva la intención de los settings vigentes: si auto sigue activo y el modo
	# no es off, el servicio debe correr. Así un snapshot transitorio que lo apagó se
	# corrige solo en el próximo frame.
	if settings_bridge != null and settings_bridge.model != null:
		var cfg = settings_bridge.model.deskflow(settings_bridge.settings.get("deskflow", {}))
		if bool(cfg.get("auto", false)) and String(cfg.get("mode", "off")) != "off":
			if not _deskflow_want:
				_deskflow_arm()
		else:
			_deskflow_want = false
	if not _deskflow_want:
		return
	if _service_running("Deskflow"):
		_deskflow_retries = 0
		return
	if now < _deskflow_retry_at:
		return
	# Backoff exponencial acotado: nunca se rinde (el portal puede tardar), pero deja
	# de insistir rápido si algo está mal configurado.
	var shift = _deskflow_retries if _deskflow_retries < 5 else 5
	_deskflow_retries += 1
	_deskflow_retry_at = now + min(DESKFLOW_RETRY_MS * (1 << shift), DESKFLOW_RETRY_MAX_MS)
	_toggle_service_by_name("Deskflow")


# Teclado y mouse compartidos según el servicio global (lo que configura Pantallas), no
# sólo los pares marcados en host_deskflow: share_here = este equipo controla a los
# vecinos de la topología; use_remote = este equipo es controlado por `host`. Lo usa la
# dockapp "Compartiendo" para aparecer aunque sólo se comparta el teclado.
func deskflow_input_sessions():
	var out = []
	if settings_bridge == null or settings_bridge.model == null or not _service_running("Deskflow"):
		return out
	var cfg = settings_bridge.model.deskflow(settings_bridge.settings.get("deskflow", {}))
	var mode = String(cfg.get("mode", "off"))
	if mode == "share_here":
		var local = _deskflow_local_name(String(cfg.get("name", "")))
		var side_of = {"up": "north", "down": "south", "right": "east", "left": "west"}
		for e in SCREEN_LAYOUT.topology(settings_bridge.settings.get("screens", {}), local):
			if String(e.get("screen", "")) != local:
				continue
			var peer = String(e.get("peer", ""))
			if peer != "":
				out.append({"peer_name": peer, "side": String(side_of.get(String(e.get("edge", "")), "north")),
					"direction": "out"})
	elif mode == "use_remote":
		var host = String(cfg.get("host", "")).strip_edges()
		if host != "":
			out.append({"peer_name": host, "side": "north", "direction": "in"})
	return out


# Red de seguridad del puntero compartido: si la captura está activa pero el equipo al
# que se fue el puntero se cayó (y Deskflow no pidió Release), se suelta acá. Sólo lee la
# cola del log del servidor mientras hay captura (cada 300 ms). Caso frecuente: se toca un
# borde con barrera, Deskflow pide Release en el mismo instante (lo ignoramos 250 ms para que
# el cruce no rebote) y después NO cruza (tramo sin equipo vinculado): la captura quedaba.
# ponytail: depende del texto del log de Deskflow; si cambia, el vigía no dispara (y queda
# Ctrl+Alt+Esc). Un canal de estado del propio Deskflow lo reemplazaría.
func _deskflow_watch(now):
	if remote_input == null or not remote_input.has_method("release_capture") or now < _df_watch_at:
		return
	_df_watch_at = now + 300  # rescate en < 1 s (dos chequeos seguidos)
	if not remote_input.is_capturing():
		_df_mismatch = 0
		return
	var f = File.new()
	if f.open(OS.get_environment("XDG_RUNTIME_DIR").plus_file("gdtk-deskflow.log"), File.READ) != OK:
		return
	var n = f.get_len()
	f.seek(int(max(0, n - 16384)))
	var tail = f.get_buffer(int(min(n, 16384))).get_string_from_utf8()
	f.close()
	var name = ""
	if settings_bridge != null and settings_bridge.model != null:
		name = String(settings_bridge.model.deskflow(settings_bridge.settings.get("deskflow", {})).get("name", ""))
	var local = _deskflow_local_name(name)
	var gone = DESKFLOW_WATCH.stuck_on(tail, local)
	# Discordancia: el servidor ya volvió al local pero la captura sigue activa. Se exige
	# en dos chequeos seguidos (~1 s): al cruzar, la línea "switch" llega ms después.
	var mismatch = DESKFLOW_WATCH.server_local(tail, local)
	_df_mismatch = _df_mismatch + 1 if mismatch else 0
	var why = ""
	if gone != "":
		why = gone + " se cayó con el puntero allá"
	elif _df_mismatch >= 2:
		why = "Deskflow volvió a este equipo sin soltar la captura"
	if why != "" and remote_input.release_capture():
		var t = OS.get_time()
		print("[deskflow] %02d:%02d:%02d " % [t.hour, t.minute, t.second], why, ": suelto la captura")
		_df_mismatch = 0
		_set_capture_cursor(false)
		request_redraw()


func _deskflow_activity():
	for a in SERVICES:
		if a.has("service") and String(a.get("name", "")) == "Deskflow":
			return a
	return null


func _deskflow_service_for(mode, home):
	match String(mode):
		"share_here":
			return "deskflow-core server --new-instance -s " \
				+ home.plus_file("gdtk").plus_file("deskflow-server-settings.ini")
		"use_remote":
			return "deskflow-core client --new-instance -s " \
				+ home.plus_file("gdtk").plus_file("deskflow-client.conf")
	return ""


func _deskflow_config_writes(mode, cfg, home, local):
	var writes = []
	var port = int(cfg.get("port", 24800))
	match String(mode):
		"use_remote":
			var text = DESKFLOW_SETTINGS.build_client_settings(local, String(cfg.get("host", "")), port)
			if text != "":
				writes.append({"path": home.plus_file("gdtk").plus_file("deskflow-client.conf"), "text": text})
		"share_here":
			var layout_path = _deskflow_layout_path()
			var layout_text = _settings_deskflow_topology_text(local)
			var settings_text = DESKFLOW_SETTINGS.build_server_settings(local, layout_path, port)
			if layout_text != "" and settings_text != "":
				writes.append({"path": layout_path, "text": layout_text})
				writes.append({"path": home.plus_file("gdtk").plus_file("deskflow-server-settings.ini"),
					"text": settings_text})
	return writes


func _deskflow_layout_path():
	var base = OS.get_environment("XDG_CONFIG_HOME")
	if base == "":
		base = OS.get_environment("HOME").plus_file(".config")
	return base.plus_file("Deskflow").plus_file("deskflow-server.conf")


func _deskflow_local_name(requested):
	var name = String(requested).strip_edges()
	if name == "":
		name = _local_hostname()
	if not LAYOUT_MODEL.valid_peer(name):
		name = "gdtk-local"
	return name


func _settings_deskflow_links():
	if settings_bridge == null:
		return []
	var layout = settings_bridge.settings.get("screens", {})
	var links = SCREEN_LAYOUT.local_links(layout)
	var lay = SCREEN_LAYOUT.normalize_layout(layout)
	var out = []
	for l in links:
		var p = String(l.get("peer", "")).strip_edges()
		var d = String(l.get("direction", ""))
		if not (LAYOUT_MODEL.valid_direction(d) and LAYOUT_MODEL.valid_peer(p)):
			continue
		var item = {"direction": d, "peer": p}
		# Rango porcentual del tramo compartido (como el Deskflow original) para que
		# vincular pantallas de distinta resolución sea lógico.
		var peer_sc = SCREEN_LAYOUT.screen_by_id(lay, p)
		if peer_sc != null and lay.local != null:
			var r = SCREEN_LAYOUT.link_ranges(lay.local, peer_sc)
			if not r.empty() and String(r.get("direction", "")) == d:
				item["local_range"] = r.local_range
				item["peer_range"] = r.peer_range
		out.append(item)
	return out


# Rangos porcentuales por borde donde el portal InputCapture puede activarse, para
# que Deskflow (que arma barreras de borde COMPLETO aunque el layout use tramos
# parciales como down(0,67)) no capture fuera del tramo con vecino: sin esto el
# puntero queda clavado/oculto y el cursor de Deskflow hace hover/clicks en la
# pantalla equivocada. Orden:
# [left_lo,left_hi, right_lo,right_hi, top_lo,top_hi, bottom_lo,bottom_hi].
func _deskflow_capture_ranges():
	# Las direcciones con gvd extendido quedan deshabilitadas: el input no cruza
	# (SPEC-screen-share-compass §4/§7), así Deskflow no rapta el teclado en ese borde.
	var disabled = []
	for hid in _gvd_link_suspended.keys():
		var d = String(_gvd_link_suspended[hid]).strip_edges()
		if d != "" and d != "none":
			disabled.append(d)
	return GVD_LAUNCH.capture_ranges(_settings_deskflow_links(), disabled)


# Conf del server con la topología COMPLETA del layout de Pantallas: todas las
# adyacencias entre pantallas (no sólo desde la local), con rangos %. La local usa
# `local_name`; los vecinos su campo `peer`.
func _settings_deskflow_topology_text(local_name):
	if settings_bridge == null:
		return ""
	var layout = settings_bridge.settings.get("screens", {})
	var lay = SCREEN_LAYOUT.normalize_layout(layout)
	var topo = SCREEN_LAYOUT.topology(lay, String(local_name))
	var names = []
	for s in SCREEN_LAYOUT.all_screens(lay):
		var nm = String(local_name) if s.local else (String(s.peer) if String(s.peer) != "" else String(s.id))
		if nm != "" and not names.has(nm):
			names.append(nm)
	return CONF_MODEL.build_topology_conf(names, topo)


func _settings_layout_key():
	if settings_bridge == null:
		return ""
	return SCREEN_LAYOUT.to_json(settings_bridge.settings.get("screens", {}))


# Reapa el Thread de lectura del puente y aplica el snapshot si cambió. Sin I/O acá.
func settings_poll():
	if settings_bridge == null:
		return
	settings_bridge.poll()
	if settings_bridge.revision == settings_rev:
		return
	settings_rev = settings_bridge.revision
	_apply_settings()
	request_redraw()


# Fondo del Hogar: degradado por defecto, color sólido o imagen estirada por modo.
# La imagen la carga el puente en un Thread; acá sólo se dibuja el snapshot cacheado.
# Colores del degradado del Hogar, para que el fondo del exposé (CanvasItem, no
# ImGui) use exactamente el mismo par que _draw_home_background.
func home_bg_colors():
	return [HOME_BG_TOP, HOME_BG_BOTTOM]


func _draw_home_background(vp):
	var mode = "gradient"
	if settings_bridge != null:
		mode = String(settings_bridge.settings.get("wallpaper", {}).get("mode", "gradient"))
	if mode != "gradient" and mode != "solid" and settings_bridge != null and settings_bridge.has_wallpaper_image():
		set_cursor_pos(Vector2.ZERO)
		var r = settings_bridge.wallpaper_rect(vp)
		set_cursor_pos(r.position)
		image(settings_bridge.wallpaper_texture(), r.size)
		# Velo tenue para que las etiquetas del anillo sigan legibles sobre la foto.
		imgui_draw_rect_filled(Rect2(Vector2.ZERO, vp), Color(0.0, 0.0, 0.0, 0.30 * home_bg_alpha))
		return
	var ka = Color(1, 1, 1, home_bg_alpha)
	if mode == "solid" and settings_bridge != null and settings_bridge.model != null:
		imgui_draw_rect_filled(Rect2(Vector2.ZERO, vp), settings_bridge.model.color_of_hex(settings_bridge.settings.get("wallpaper", {}).get("color", "")) * ka, 0.0)
		return
	imgui_draw_rect_filled_multicolor(Rect2(Vector2.ZERO, vp), HOME_BG_TOP * ka, HOME_BG_TOP * ka, HOME_BG_BOTTOM * ka, HOME_BG_BOTTOM * ka)


# --- Zoom Sugar (Hogar / Grupo / Vecindario) ---------------------------------

# Fija el nivel de zoom objetivo (Hogar 0, Grupo 1, Vecindario 2). Ajusta la capa
# neighborhood_ui al modo correcto (otro agente le agrega set_mode/draw_center) y
# delega el ícono central al shell. La animación la interpola _process con ZOOM_MS.
func _set_zoom(level):
	zoom_level = int(clamp(float(level), 0.0, 2.0))
	neighborhood_view = zoom_level > 0
	if zoom_level > 0:
		expose = false
	if neighborhood_ui != null:
		if zoom_level > 0 and neighborhood_ui.has_method("set_mode"):
			neighborhood_ui.set_mode("group" if zoom_level == 1 else "neighborhood")
		# El centro lo dibuja el shell una sola vez (con zoom_model.center_icon_rect).
		if "draw_center" in neighborhood_ui:
			neighborhood_ui.set("draw_center", false)
	request_redraw()


# Rueda vertical / pinch: acerca (+1) o aleja (-1) un nivel, con tope 0..2.
func _zoom_step(delta):
	_set_zoom(ZOOM.step(zoom_level, delta))


# Abrir la vista Vecindario (nivel 2) desde el bloque del Frame o con F1.
func _go_neighborhood():
	_enter_zoom(2)


# Abrir la vista Grupo (nivel 1) con F2.
func _go_group():
	_enter_zoom(1)


# Entrar a un nivel de zoom desde cualquier estado (cierra actividad/grilla primero).
func _enter_zoom(level):
	if current_activity != null or apps_view:
		_go_home()
	_set_zoom(level)
	if neighborhood != null:
		neighborhood.poll()
	_refresh_direction_views()
	neighborhood_ui.refresh(true)
	request_redraw()


# Volver al Hogar desde el Vecindario/Grupo (Esc, el bloque Inicio o el mismo bloque).
func _close_neighborhood():
	_set_zoom(0)
	neighborhood_ui.selected = ""
	neighborhood_ui.selected_host = ""
	request_redraw()


# El hilo de refresco no debe quedar vivo al recargar/cerrar el shell.
func _exit_tree():
	if neighborhood != null:
		neighborhood.stop()
		neighborhood = null
	# Volumen/brillo: detiene el worker y espera a que termine.
	if system_osd != null:
		system_osd.shutdown()
		system_osd = null
	_stop_service_worker()
	# Anuncios mDNS: sus Threads ya terminaron con el worker; matar los pids vivos.
	_stop_publishers()
	# Buzón del handshake: detiene el worker y espera los envíos ssh en curso.
	_stop_inbox()
	for th in _bg_threads:
		th.wait_to_finish()
	_bg_threads = []
	# Audio enviado: devolver la salida local, si no quedaría sonando en el otro equipo.
	if not _audio_send.empty():
		_audio_work({})
	# Pantallazo pendiente: espera a que termine de codificar/guardar.
	if _shot_thread != null:
		_shot_thread.wait_to_finish()
		_shot_thread = null
	# No perder la última escritura de direcciones: ambas son cortas y locales.
	for th in _dir_write_threads:
		th.wait_to_finish()
	_dir_write_threads = []
	_dir_write_states = []
	# Sesiones de pantalla: mata los pids vivos y espera los lanzamientos en curso.
	_gvd_mutex.lock()
	var gvd_pids = gvd_session_pids.values()
	gvd_session_pids.clear()
	_gvd_mutex.unlock()
	for pid in gvd_pids:
		var p = int(pid)
		if p > 0:
			OS.kill(p)
	for th in _gvd_launch_threads:
		th.wait_to_finish()
	_gvd_launch_threads = []
	_gvd_launch_states = []
	for th in _gvd_peer_threads:
		th.wait_to_finish()
	_gvd_peer_threads = []
	_gvd_peer_states = []
	_window_input_reset()
	_window_input_poll()
	if _window_input_thread != null:
		_window_input_thread.wait_to_finish()
		_window_input_thread = null
		_window_input_state = null
	# Escrituras de config de plan pendientes: no dejarlas a medias.
	for th in _plan_write_threads:
		th.wait_to_finish()
	_plan_write_threads = []
	_plan_write_states = []
	# Configuración: espera el Thread de lectura/carga del puente.
	if settings_bridge != null:
		settings_bridge.stop()
		settings_bridge = null


# --- Dirección por host (brújula) --------------------------------------------
# Cablea el modelo puro de Kilo A con la vista (Kilo E) y la persistencia local.
# El hilo de render nunca consulta: sólo normaliza (barato), vuelca el estado ya
# disponible y delega la escritura a un Thread de un solo uso (patrón _svc_launch_async).

# Ruta del archivo de direcciones: $XDG_CONFIG_HOME/gdtk/neighborhood-directions.json
# (~/.config/gdtk/neighborhood-directions.json por defecto). "" si no hay HOME ni
# XDG_CONFIG_HOME: sin base no se adivina una ruta.
func _directions_path():
	var base = OS.get_environment("XDG_CONFIG_HOME")
	if base == "":
		var home = OS.get_environment("HOME")
		if home == "":
			return ""
		base = home + "/.config"
	return base + "/gdtk/neighborhood-directions.json"


# Carga inicial: texto local -> modelo normalizado. Sin archivo o inválido -> {}.
func _load_directions():
	host_directions = {}
	var path = _directions_path()
	if path == "":
		return
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return
	var txt = f.get_as_text()
	f.close()
	host_directions = DIRECTIONS_MODEL.parse(txt)


# Fija o borra la dirección de un host. Pura salvo la escritura diferida.
func _set_host_direction(host_id, dir):
	var id = String(host_id)
	if id == "":
		return
	var d = String(dir).strip_edges()
	if d == "none":
		host_directions.erase(id)
	else:
		var entry = DIRECTIONS_MODEL.sanitize_entry({"direction": d, "confirm": "unconfirmed"})
		if entry.direction == "none":
			host_directions.erase(id)   # dirección inválida: se borra, no se guarda
		else:
			host_directions[id] = entry
	_refresh_direction_views()
	_persist_directions()
	request_redraw()


# El equipo se soltó en un ángulo alrededor del local (vista Grupo): lado + posición a lo
# largo del borde (0..1). Conserva el resto de la entrada (modo, etc.) y queda confirmado;
# Configuración → Pantallas lo usa para ubicar la pantalla.
func _set_host_placement(host_id, side, along):
	var id = String(host_id)
	if id == "":
		return
	var base = host_directions.get(id, {})
	base = base.duplicate() if typeof(base) == TYPE_DICTIONARY else {}
	base["direction"] = String(side)
	base["along"] = clamp(float(along), 0.0, 1.0)
	base["confirm"] = "confirmed"
	if not base.has("mode"):
		base["mode"] = "extend"
	var entry = DIRECTIONS_MODEL.sanitize_entry(base)
	if String(entry.get("direction", "none")) == "none":
		return
	host_directions[id] = entry
	_refresh_direction_views()
	_persist_directions()
	request_redraw()


# Vuelca el estado ya disponible a la vista (nunca consulta red/procesos/disco).
func _refresh_direction_views():
	# Ángulo de cada equipo alrededor del local (Grupo y dockapp radial "Compartiendo").
	group_placements = GROUP_MODEL.placements(host_directions)
	var conflicts = DIRECTIONS_MODEL.edge_conflicts(host_directions)
	if neighborhood_ui == null:
		return
	# Godot 3 no admite `"directions" in obj`; get() devuelve null si falta la var.
	if neighborhood_ui.get("directions") != null:
		neighborhood_ui.directions = host_directions
	if neighborhood_ui.get("direction_conflicts") != null:
		neighborhood_ui.direction_conflicts = conflicts


# Serializa en el hilo principal (puro y barato) y escribe en un Thread de un solo
# uso; el hilo de render no espera. Sin ruta válida no hay nada que persistir.
func _persist_directions():
	var path = _directions_path()
	if path == "":
		return
	var text = DIRECTIONS_MODEL.to_json(host_directions)
	var state = {"done": false}
	var th = Thread.new()
	_dir_write_threads.append(th)
	_dir_write_states.append(state)
	th.start(self, "_write_directions_work", {"path": path, "text": text, "state": state})


# Sólo escribe el archivo (tmp + rename atómico); nunca toca nodos ni red.
func _write_directions_work(userdata):
	var path = String(userdata.get("path", ""))
	var text = String(userdata.get("text", "{}"))
	if path != "":
		Directory.new().make_dir_recursive(path.get_base_dir())
		var tmp = path + ".tmp"
		var w = File.new()
		if w.open(tmp, File.WRITE) != OK:
			printerr("shell: no se pudo escribir ", tmp)
		else:
			w.store_string(text)
			w.close()
			if Directory.new().rename(tmp, path) != OK:
				printerr("shell: no se pudo renombrar ", tmp, " a ", path)
	# Marca de fin: publica la completitud sin que el hilo de render espere.
	_dir_mutex.lock()
	userdata.state.done = true
	_dir_mutex.unlock()


# Reapea los Threads de escritura ya terminados. En este motor `is_active()` sigue
# en true hasta `wait_to_finish()`, así que el fin se publica con el flag `done`
# bajo Mutex; `wait_to_finish()` sólo se llama cuando el hilo ya terminó (no bloquea).
func _dir_poll():
	for i in range(_dir_write_threads.size() - 1, -1, -1):
		var state = _dir_write_states[i]
		_dir_mutex.lock()
		var done = state.done
		_dir_mutex.unlock()
		if done:
			_dir_write_threads[i].wait_to_finish()
			_dir_write_threads.remove(i)
			_dir_write_states.remove(i)


# --- Buzón del handshake de dirección (K3) ------------------------------------
# Transporte del acuerdo N/S/E/O entre hosts por ssh (SPEC §6/§9/§14). El worker
# escanea el buzón local (~/.config/gdtk/direction-inbox) cada INBOX_POLL_MS,
# decodifica con handshake.decode y publica la decisión pura de cada archivo; el
# hilo principal sólo aplica con handshake.apply sobre host_directions y persiste
# con _persist_directions. Proponer/responder también va en Threads: nunca ssh ni
# I/O de disco en los callbacks de render. Sin secretos.

const INBOX_POLL_MS = 5000
const INBOX_SLEEP_STEP_MS = 100


func _start_inbox():
	if _inbox_thread != null:
		return
	_inbox_mutex.lock()
	_inbox_want_stop = false
	_inbox_mutex.unlock()
	_inbox_thread = Thread.new()
	_inbox_thread.start(self, "_inbox_work")


func _stop_inbox():
	_inbox_mutex.lock()
	_inbox_want_stop = true
	_inbox_mutex.unlock()
	if _inbox_thread != null:
		_inbox_thread.wait_to_finish()
		_inbox_thread = null
	# Los envíos ssh en curso son cortos (ConnectTimeout=3): se esperan al cerrar.
	for th in _inbox_send_threads:
		th.wait_to_finish()
	_inbox_send_threads = []
	_inbox_send_states = []


func _inbox_stopped():
	_inbox_mutex.lock()
	var s = _inbox_want_stop
	_inbox_mutex.unlock()
	return s


func _inbox_work(_userdata):
	while true:
		if _inbox_stopped():
			return
		var found = _inbox_scan()
		if not found.empty():
			_inbox_mutex.lock()
			_inbox_entries = found
			_inbox_version += 1
			_inbox_mutex.unlock()
		var waited = 0
		while waited < INBOX_POLL_MS:
			OS.delay_msec(INBOX_SLEEP_STEP_MS)
			waited += INBOX_SLEEP_STEP_MS
			if _inbox_stopped():
				return


# Directorio del buzón local, con la misma base que las direcciones.
func _inbox_dir():
	var base = OS.get_environment("XDG_CONFIG_HOME")
	if base == "":
		var home = OS.get_environment("HOME")
		if home == "":
			return ""
		base = home + "/.config"
	return INBOX_MODEL.inbox_dir(base)


# hid local opaco (no publica el hostname real). Vacío si no hay hostname.
func _local_hid():
	return String(PUBLISH_PLAN.local_identity(_local_hostname()).hid)


# Sólo I/O de disco local en el worker: lee el buzón, decodifica y consume (borra)
# cada archivo del handshake. NO aplica estado: publica decisiones para el frame.
func _inbox_scan():
	var dir = _inbox_dir()
	if dir == "":
		return []
	var d = Directory.new()
	if d.open(dir) != OK:
		return []
	d.list_dir_begin(true, true)   # oculta .tmp.* de la escritura atómica
	var names = []
	var name = d.get_next()
	while name != "":
		if not d.current_is_dir():
			names.append(name)
		name = d.get_next()
	d.list_dir_end()
	var local = _local_hid()
	var out = []
	var remove = []
	for n in names:
		var f = File.new()
		if f.open(dir.plus_file(n), File.READ) != OK:
			continue
		var txt = f.get_as_text()
		f.close()
		var decoded = HANDSHAKE.decode(txt)
		var plan = INBOX_MODEL.plan_file(n, decoded, local)
		if bool(plan.delete):
			remove.append(n)
		if String(plan.action) != "ignore":
			out.append({"action": String(plan.action), "message": decoded})
	for n in remove:
		d.remove(n)
	return out


# Copia el último lote del worker (una sola vez por versión), lo aplica con
# handshake.apply y reapea los envíos ssh terminados. Nunca espera un hilo vivo.
func _inbox_poll():
	_inbox_mutex.lock()
	var version = _inbox_version
	var entries = []
	if version != _inbox_consumed:
		_inbox_consumed = version
		entries = _inbox_entries.duplicate()
	_inbox_mutex.unlock()
	for i in range(_inbox_send_threads.size() - 1, -1, -1):
		var st = _inbox_send_states[i]
		_inbox_mutex.lock()
		var done = st.done
		var code = int(st.code)
		_inbox_mutex.unlock()
		if done:
			_inbox_send_threads[i].wait_to_finish()
			_inbox_send_threads.remove(i)
			_inbox_send_states.remove(i)
			if code != 0:
				activity_error = "vecindario: no se pudo entregar el handshake por ssh"
	if entries.empty():
		return
	var changed = false
	for e in entries:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var msg = e.get("message", {})
		var hid = String(msg.get("from", "")).strip_edges()
		if hid == "":
			continue
		host_directions[hid] = HANDSHAKE.apply(host_directions.get(hid, {}), msg)
		changed = true
	if changed:
		_refresh_direction_views()
		_persist_directions()
		request_redraw()


# Host del Vecindario ya descubierto (host_id -> entry del modelo). Sin poll: el
# `_process` mantiene copiado el snapshot del hilo de discovery.
func _neighborhood_host(host_id):
	if neighborhood == null:
		return null
	var id = String(host_id)
	for h in neighborhood.hosts:
		if String(h.get("id", "")) == id:
			return h
	return null


# Destino ssh del peer, resuelto de sus servicios DNS-SD.
func _inbox_peer_for(host_id):
	var host = _neighborhood_host(host_id)
	if host == null:
		return {"ok": false, "peer": "", "error": "host no está en el Vecindario"}
	return INBOX_MODEL.ssh_target(host)


# Propone una dirección al peer por su buzón ssh. Deja el entry local en
# "proposed" (la UI ya lo muestra) y persiste; nunca bloquea el render.
func propose_direction(host_id, direction):
	var id = String(host_id).strip_edges()
	if id == "":
		return
	var entry = DIRECTIONS_MODEL.sanitize_entry({"direction": direction, "confirm": "proposed"})
	if String(entry.get("direction", "none")) == "none":
		return
	var local = _local_hid()
	if local == "":
		return
	host_directions[id] = entry
	_refresh_direction_views()
	_persist_directions()
	request_redraw()
	var target = _inbox_peer_for(id)
	if not bool(target.ok):
		activity_error = "vecindario: " + String(target.error)
		return
	_send_inbox(String(target.peer), INBOX_MODEL.proposal_name(local),
		HANDSHAKE.encode(HANDSHAKE.proposal(local, id, entry.direction)))


# Responde la propuesta de `host_id`: acepta (confirma local) o rechaza (retira la
# dirección) y escribe el response en el buzón ssh del proponente.
func answer_direction(host_id, accepted):
	var id = String(host_id).strip_edges()
	if id == "":
		return
	var entry = host_directions.get(id, {})
	if typeof(entry) != TYPE_DICTIONARY:
		return
	var direction = String(entry.get("direction", "none"))
	if direction == "none":
		return
	var local = _local_hid()
	if local == "":
		return
	if bool(accepted):
		var confirmed = DIRECTIONS_MODEL.sanitize_entry(entry)
		confirmed.confirm = "confirmed"
		host_directions[id] = confirmed
	else:
		host_directions.erase(id)
	_refresh_direction_views()
	_persist_directions()
	request_redraw()
	var target = _inbox_peer_for(id)
	if not bool(target.ok):
		activity_error = "vecindario: " + String(target.error)
		return
	_send_inbox(String(target.peer), INBOX_MODEL.response_name(local),
		HANDSHAKE.encode(HANDSHAKE.response(local, id, direction, bool(accepted))))


# Lanza el envío ssh (ya con argv seguro del modelo puro) en un Thread de un solo
# uso, reapeado en _inbox_poll. Un fallo de entrega no revierte el estado local.
func _send_inbox(peer, remote_name, payload):
	var plan = INBOX_MODEL.ssh_write_argv(peer, remote_name, payload)
	if not bool(plan.ok):
		activity_error = "vecindario: " + String(plan.error)
		return
	var state = {"done": false, "code": -1}
	var th = Thread.new()
	_inbox_send_threads.append(th)
	_inbox_send_states.append(state)
	th.start(self, "_inbox_send_work", {"cmd": String(plan.cmd), "args": plan.args, "state": state})


func _inbox_send_work(userdata):
	var out = []
	var code = OS.execute(String(userdata.get("cmd", "ssh")), userdata.get("args", []), true, out)
	_inbox_mutex.lock()
	userdata.state.done = true
	userdata.state.code = code
	_inbox_mutex.unlock()


# --- Acciones del Vecindario: despacho real, sin bloquear el render -------------
# La vista sólo registra la acción; `_run_host_plan` la conecta con lo que ya
# existe (ciclo de vida de servicios, actividad "Pantalla") y nunca ejecuta I/O en
# el hilo de render: escrituras y lanzamientos van a Threads de un solo uso y el
# estado se lee de caches (SPEC-screen-share-compass §0, §5–§8, §14).

# Clasificación pura de planes (mecanismo + argv) y helpers de Deskflow viven en
# host_dispatch.gd: se delegan para poder testearse headless sin cargar el shell.
# Punto de entrada de las acciones del Vecindario. No bloquea: escrituras y
# lanzamientos se difieren a Threads; el estado sale de caches.
func _run_host_plan(host_id, action):
	if typeof(action) != TYPE_DICTIONARY:
		return
	if not bool(action.get("enabled", false)):
		return
	var id = String(host_id)
	# Grupo (G4b): sumar/quitar del grupo no lleva plan de proceso; se resuelve con
	# el modelo puro + persistencia y (al quitar) limpieza de tokens y pantalla.
	var aid = String(action.get("id", ""))
	if aid == "add_to_group":
		_group_add(id)
		request_redraw()
		return
	if aid == "remove_from_group":
		_group_remove(id)
		request_redraw()
		return
	var plan = action.get("plan", null)
	var d = HOST_DISPATCH.dispatch_of(plan, String(action.get("id", "")))
	match String(d.mechanism):
		"deskflow":
			_run_deskflow_plan(id, plan)
		"gvd_recv":
			# "Ver su escritorio aquí": receptor local en un tile + emisor remoto
			# por ssh (buzón). El mismo punto corta si ya hay sesión.
			if _screen_session_active(id):
				_stop_gvd_screen(id)
			else:
				_start_gvd_screen(id, action)
		"gvd_send":
			# "Extender mi escritorio a él": emisor local (si es GNOME) + receptor
			# remoto por ssh; suspende el vínculo Deskflow hacia esa dirección.
			if _screen_session_active(id):
				_stop_gvd_screen(id)
			else:
				_start_gvd_screen(id, action)
		_:
			print("vecindario: ", id, " · ", String(action.get("label", "")),
				" (acción sin plan ejecutable)")
	request_redraw()


# Deskflow (kind "service_toggle"): el `mode` del plan decide el camino.
#   "client": reusa la actividad "Deskflow" (toggle global) tal como hoy.
#   "server": NO usa la actividad cliente; escribe el layout y lanza el argv del
#             propio plan de forma rastreada (clave distinta por host).
func _run_deskflow_plan(host_id, plan):
	if HOST_DISPATCH.deskflow_dispatch_mode(plan) == "server":
		_run_deskflow_server(host_id, plan)
		return
	var name = "Deskflow"
	if typeof(plan) == TYPE_DICTIONARY and String(plan.get("activity", "")) != "":
		name = String(plan.activity)
	# Intención optimista por host (la actividad/servicio Deskflow es global).
	host_deskflow[String(host_id)] = not bool(_service_running(name))
	if typeof(plan) == TYPE_DICTIONARY and String(plan.get("config", "")) != "" \
			and String(plan.get("settings_text", "")) != "":
		# Ajustes nuevos antes del toggle: se escriben en un Thread y el toggle se
		# dispara cuando la escritura atómica termina (sin esperar en el render).
		_write_text_async(String(plan.config), String(plan.settings_text), name)
		return
	_toggle_service_by_name(name)


# Servidor Deskflow local: el mismo botón corta la sesión si ya vive para ese host.
# Escribe DOS archivos si vienen en el plan: el layout barrier en `plan.layout_path`
# y los ajustes (con `externalConfigFile` apuntando al layout) en `plan.config`;
# al terminar las escrituras atómicas lanza el argv `plan.cmd`/`plan.args` en un
# Thread rastreado. Nunca bloquea el render.
func _run_deskflow_server(host_id, plan):
	var id = String(host_id)
	var key = HOST_DISPATCH.deskflow_session_key(id)
	if _has_tracked(key):
		_stop_tracked(key)
		_share_notify(id, "input", "stopped")
		return
	if typeof(plan) != TYPE_DICTIONARY:
		return
	var launch = HOST_DISPATCH.deskflow_server_argv(plan)
	if String(launch.cmd) == "":
		return
	# K17: recuerda el argv para poder restaurar el vínculo si la pantalla lo
	# suspende temporalmente al extender el escritorio hacia ese vecino.
	_deskflow_server_launch[id] = {"cmd": String(launch.cmd), "args": launch.args}
	var then_launch = {"key": key, "cmd": String(launch.cmd), "args": launch.args}
	var writes = []
	if String(plan.get("config", "")) != "" and String(plan.get("settings_text", "")) != "":
		writes.append({"path": String(plan.config), "text": String(plan.settings_text)})
	if String(plan.get("layout_path", "")) != "" and String(plan.get("layout_text", "")) != "":
		writes.append({"path": String(plan.layout_path), "text": String(plan.layout_text)})
	if not writes.empty():
		_share_notify(id, "input", "starting")
		_write_texts_async(writes, "", then_launch)
		return
	_launch_tracked(key, String(launch.cmd), launch.args)
	_share_notify(id, "input", "starting")


# --- Aplicar layout de Deskflow (K5) -----------------------------------------
# Recibe el payload del editor puro: links {direction, peer, host} y, para las
# direcciones que se quitaron, {direction:"none", host}. Persiste las MISMAS
# direcciones en host_directions (fuente única: de ahí derivan gvd y Deskflow)
# con estado "confirmed", regenera ~/.config/Deskflow/deskflow-server.conf (con
# backup .bak) y reinicia el servicio. Nunca bloquea el hilo de render: la
# escritura va a un Thread de un solo uso reapeado por _plan_poll, que al
# terminar reinicia con el ciclo de vida existente (_service_running/
# _toggle_service_by_name), sin crear uno paralelo.
func apply_deskflow_layout(links):
	if typeof(links) != TYPE_ARRAY:
		return
	var clean = []
	var dirs = {}
	for l in links:
		if typeof(l) != TYPE_DICTIONARY:
			continue
		var d = String(l.get("direction", "")).strip_edges()
		var hid = String(l.get("host", l.get("hid", ""))).strip_edges()
		if d == "none":
			if hid != "":
				dirs[hid] = DIRECTIONS_MODEL.sanitize_entry({"direction": "none"})
			continue
		var p = String(l.get("peer", "")).strip_edges()
		if not LAYOUT_MODEL.valid_direction(d) or not LAYOUT_MODEL.valid_peer(p):
			continue
		clean.append({"direction": d, "peer": p})
		if hid != "":
			dirs[hid] = DIRECTIONS_MODEL.sanitize_entry({
				"direction": d, "confirm": "confirmed", "mode": "extend",
				"link": "deskflow+gvd",
			})
	# K17: mientras gvd extiende hacia una dirección, su vínculo Deskflow queda
	# suspendido (se restaura al cortar la pantalla); no se reintroduce acá.
	if not _gvd_link_suspended.empty():
		var suspended = _gvd_link_suspended.values()
		var kept = []
		for l in clean:
			if not suspended.has(String(l.get("direction", ""))):
				kept.append(l)
		clean = kept
	if clean.empty() and dirs.empty():
		activity_error = "layout: sin direcciones válidas"
		return
	# Fuente única: host_directions manda; el conf se deriva de lo mismo.
	host_directions = DIRECTIONS_MODEL.merge(host_directions, dirs)
	_refresh_direction_views()
	_persist_directions()
	activity_error = ""
	if clean.empty():
		request_redraw()
		return
	var local = _local_hostname()
	if not LAYOUT_MODEL.valid_peer(local):
		local = "gdtk-local"
	var text = CONF_MODEL.build_server_conf(local, clean)
	if text == "":
		activity_error = "layout: no se pudo generar deskflow-server.conf"
		return
	var base = OS.get_environment("XDG_CONFIG_HOME")
	if base == "":
		var home = OS.get_environment("HOME")
		if home == "":
			activity_error = "layout: sin HOME/XDG_CONFIG_HOME para Deskflow"
			return
		base = home + "/.config"
	var path = base + "/Deskflow/deskflow-server.conf"
	var state = {"done": false, "then_restart_deskflow": true}
	var th = Thread.new()
	_plan_write_threads.append(th)
	_plan_write_states.append(state)
	th.start(self, "_apply_deskflow_work", {"path": path, "text": text, "state": state})
	request_redraw()


# Sólo I/O de archivos: backup .bak del conf previo, escritura temporal y rename
# atómico. Nunca toca nodos, red ni procesos.
func _apply_deskflow_work(userdata):
	var path = String(userdata.get("path", ""))
	var text = String(userdata.get("text", ""))
	if path != "":
		Directory.new().make_dir_recursive(path.get_base_dir())
		if File.new().file_exists(path):
			Directory.new().copy(path, path + ".bak")
		var tmp = path + ".tmp"
		var w = File.new()
		if w.open(tmp, File.WRITE) != OK:
			printerr("shell: no se pudo escribir ", tmp)
		else:
			w.store_string(text)
			w.close()
			if Directory.new().rename(tmp, path) != OK:
				printerr("shell: no se pudo renombrar ", tmp, " a ", path)
	_plan_mutex.lock()
	userdata.state.done = true
	_plan_mutex.unlock()


# ¿Este equipo puede publicar servidor Deskflow local? Se resuelve UNA vez si
# `deskflow-core` está en $PATH (sólo File, sin OS.execute) y se cachea: el frame
# nunca reescanea el PATH. En sesión gdtk el portal InputCapture lo implementa
# este mismo proceso (RemoteInput), así que el chequeo real es si la interfaz
# quedó registrada en el bus, no si existe el .portal.
func deskflow_server_available():
	if not _deskflow_probed:
		_deskflow_probed = true
		_deskflow_core = _which("deskflow-core")
		_deskflow_input_capture = _input_capture_portal_available()
	return _deskflow_core != "" and _deskflow_input_capture


func _input_capture_portal_available():
	var desktop = OS.get_environment("XDG_CURRENT_DESKTOP").to_lower()
	if desktop.find("gdtk") < 0:
		return true
	# El .portal sólo declara interfaces: lo que atiende Deskflow es lo que hay en
	# el bus. RemoteInput registra InputCapture sólo si sd-bus levantó bien (ver
	# eis_server_error). Se consulta Host.remote_input y no `remote_input` porque
	# el shell lo asigna recién al final de su setup, después del primer gate.
	return Host.remote_input != null and Host.remote_input.has_input_capture()


# Ruta absoluta de un ejecutable en $PATH, o "" si no está. Sólo File, sin shell
# (mismo patrón que applet_keyboard._which).
func _which(prog):
	var name = String(prog)
	for d in OS.get_environment("PATH").split(":", false):
		if d != "" and File.new().file_exists(d + "/" + name):
			return d + "/" + name
	return ""


# Alterna el servicio por nombre de actividad, buscando la que tenga "service".
func _toggle_service_by_name(name):
	var want = String(name)
	for a in ACTIVITIES + SERVICES:
		if a.has("service") and String(a.get("name", "")) == want:
			_toggle_service(a)
			return
	activity_error = "Servicio desconocido: " + want


# --- Escrituras de config de plan (Thread de un solo uso, tmp + rename) --------

func _write_text_async(path, text, then_toggle = "", then_launch = null):
	var p = String(path)
	var t = String(then_toggle)
	var launch = then_launch if typeof(then_launch) == TYPE_DICTIONARY else {}
	if p == "":
		if t != "":
			_toggle_service_by_name(t)
		elif not launch.empty():
			_launch_tracked(String(launch.get("key", "")), String(launch.get("cmd", "")),
				launch.get("args", []))
		return
	var state = {"done": false, "then_toggle": t, "then_launch": launch, "path": p}
	var th = Thread.new()
	_plan_write_threads.append(th)
	_plan_write_states.append(state)
	th.start(self, "_write_text_work", {"path": p, "text": String(text), "state": state})


func _write_text_work(userdata):
	_write_file_atomic(String(userdata.get("path", "")), String(userdata.get("text", "")))
	_plan_mutex.lock()
	userdata.state.done = true
	_plan_mutex.unlock()


# Varias escrituras atómicas en un solo Thread (servidor Deskflow: layout barrier +
# ajustes). Mismo reap en _plan_poll que _write_text_async.
func _write_texts_async(entries, then_toggle = "", then_launch = null):
	var writes = []
	if typeof(entries) == TYPE_ARRAY:
		for e in entries:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var p = String(e.get("path", ""))
			if p != "":
				writes.append({"path": p, "text": String(e.get("text", ""))})
	var t = String(then_toggle)
	var launch = then_launch if typeof(then_launch) == TYPE_DICTIONARY else {}
	if writes.empty():
		if t != "":
			_toggle_service_by_name(t)
		elif not launch.empty():
			_launch_tracked(String(launch.get("key", "")), String(launch.get("cmd", "")),
				launch.get("args", []))
		return
	var state = {"done": false, "then_toggle": t, "then_launch": launch}
	var th = Thread.new()
	_plan_write_threads.append(th)
	_plan_write_states.append(state)
	th.start(self, "_write_texts_work", {"writes": writes, "state": state})


func _write_texts_work(userdata):
	var writes = userdata.get("writes", [])
	if typeof(writes) == TYPE_ARRAY:
		for e in writes:
			if typeof(e) == TYPE_DICTIONARY:
				_write_file_atomic(String(e.get("path", "")), String(e.get("text", "")))
	_plan_mutex.lock()
	userdata.state.done = true
	_plan_mutex.unlock()


# Escritura atómica (tmp + rename) creando el directorio destino. Sólo I/O.
func _write_file_atomic(path, text):
	var p = String(path)
	if p == "":
		return
	Directory.new().make_dir_recursive(p.get_base_dir())
	var tmp = p + ".tmp"
	var w = File.new()
	if w.open(tmp, File.WRITE) != OK:
		printerr("shell: no se pudo escribir ", tmp)
		return
	w.store_string(String(text))
	w.close()
	if Directory.new().rename(tmp, p) != OK:
		printerr("shell: no se pudo renombrar ", tmp, " a ", p)


# Reapea las escrituras de plan y ejecuta el toggle diferido una vez completadas.
func _plan_poll():
	for i in range(_plan_write_threads.size() - 1, -1, -1):
		var state = _plan_write_states[i]
		_plan_mutex.lock()
		var done = state.done
		_plan_mutex.unlock()
		if done:
			_plan_write_threads[i].wait_to_finish()
			_plan_write_threads.remove(i)
			_plan_write_states.remove(i)
			var then_toggle = String(state.get("then_toggle", ""))
			if then_toggle != "":
				_toggle_service_by_name(then_toggle)
			elif bool(state.get("then_restart_deskflow", false)):
				# Reinicia reusando el ciclo de vida: parar (si vive) y arrancar.
				var was_running = _service_running("Deskflow")
				if was_running:
					_toggle_service_by_name("Deskflow")
				_toggle_service_by_name("Deskflow")
			else:
				var then_launch = state.get("then_launch", {})
				if typeof(then_launch) == TYPE_DICTIONARY and not then_launch.empty():
					_launch_tracked(String(then_launch.get("key", "")),
						String(then_launch.get("cmd", "")), then_launch.get("args", []))


# --- Sesiones rastreadas: gvd send y servidor Deskflow (Threads de un solo uso) -
# Una clave por host/mecanismo: host_id para gvd, "deskflow:"+host_id para el
# servidor Deskflow. La UI nunca consulta procesos: lee `gvd_session_pids`.

func _has_tracked(key):
	var k = String(key)
	_gvd_mutex.lock()
	var pid = int(gvd_session_pids.get(k, 0))
	_gvd_mutex.unlock()
	return pid > 0


# Corta una sesión rastreada: olvida y termina su pid. SIGTERM (no SIGKILL) para
# que procesos con limpieza — gvd desmonta su monitor virtual headless — la hagan.
func _stop_tracked(key):
	var k = String(key)
	_gvd_mutex.lock()
	var pid = int(gvd_session_pids.get(k, 0))
	gvd_session_pids.erase(k)
	_gvd_mutex.unlock()
	if pid > 0:
		OS.execute("kill", ["-TERM", str(pid)], true)


func _gvd_has_session(host_id):
	return _has_tracked(String(host_id))


func _stop_gvd_session(host_id):
	_stop_tracked(String(host_id))


# --- K17: automatización del monitor virtual (gvd) ---------------------------
# El shell lanza/corta gvd solo: emisor local si puede capturar, receptor remoto
# por ssh (buzón), receptor local en un tile (actividad "Pantalla") y
# `--position` del mapa; además suspende y restaura el vínculo
# Deskflow de esa dirección. Nada bloquea el render: los procesos van por
# _launch_tracked (Threads) y el estado se lee de caches.

func _screen_keys(host_id):
	return GVD_LAUNCH.session_keys(host_id)


func _screen_session_active(host_id):
	var id = String(host_id)
	_gvd_mutex.lock()
	for st in _gvd_peer_states:
		if String(st.get("key", "")) == id and not bool(st.get("done", false)) \
				and not bool(st.get("cancelled", false)):
			_gvd_mutex.unlock()
			return true
	_gvd_mutex.unlock()
	for k in _screen_keys(host_id):
		if _has_tracked(k):
			return true
	return false


func _stop_gvd_screen(host_id):
	var id = String(host_id)
	_group_unshare_window(id)
	_gvd_mutex.lock()
	for st in _gvd_peer_states:
		if String(st.get("key", "")) == id:
			st.cancelled = true
	_gvd_mutex.unlock()
	for k in _screen_keys(id):
		_stop_tracked(k)
	_close_pantalla_window()
	_restore_deskflow_link(id)
	_share_notify(id, "screen", "stopped")


func _close_pantalla_window():
	for id in _pantalla_window_ids():
		compositor.close(id)
	_pending_remove("Pantalla")
	starting.erase("Pantalla")
	_kill_pantalla_receivers()


func _pantalla_window_ids():
	var out = []
	for name in wayland_ids.keys():
		var id = int(wayland_ids[name])
		if not _id_alive(id):
			continue
		# gvd recv recrea su ventana al cambiar el tamaño: vuelve como actividad dinámica
		# con el título («Pantalla compartida»), no como «Pantalla».
		if String(name) == "Pantalla" or String(name) == "Pantalla compartida" \
				or _is_pantalla_window(id):
			out.append(id)
	for id in compositor.get_ids():
		if compositor.get_parent_id(id) > 0 or out.has(id):
			continue
		if _is_pantalla_window(id):
			out.append(id)
	return out


func _is_pantalla_window(id):
	return String(compositor.get_title(id)) == "Pantalla compartida" \
		or String(compositor.get_app_id(id)) == "gvd.SharedScreen"


func _kill_pantalla_receivers():
	var user = OS.get_environment("USER")
	if user == "":
		return
	OS.execute("pkill", ["-TERM", "-u", user, "-f", "gvd.py recv"], true)


# Abre el receptor local en un tile: reutiliza la actividad wayland "Pantalla"
# con el argv calculado.
func _open_pantalla_window(gvd_path, has_sway, port):
	var plan = GVD_LAUNCH.local_recv_argv(gvd_path, has_sway, port)
	if not bool(plan.get("ok", false)):
		activity_error = "pantalla: " + String(plan.get("error", ""))
		return
	for i in range(ACTIVITIES.size()):
		if String(ACTIVITIES[i].get("name", "")) == "Pantalla":
			var wl = [String(plan.get("cmd", ""))]
			for a in plan.get("args", []):
				wl.append(String(a))
			ACTIVITIES[i]["wayland"] = wl
			_activate(i)
			return
	activity_error = "pantalla: actividad no disponible"


# --- Canal peer (LAN, sin ssh): tokens por-par y acciones de pantalla -----------

func _peer_port():
	var p = int(OS.get_environment("GDTK_PEER_PORT"))
	return p if p > 0 else 7788


func _gvd_path_local():
	var cands = GVD_LAUNCH.ACTIONS.gvd_path_candidates(OS.get_environment("HOME"),
		OS.get_environment("GDTK_HOME"))
	var exists = {}
	var f = File.new()
	for c in cands:
		var p = String(c)
		if p.begins_with("/") and f.file_exists(p):
			exists[p] = true
	return GVD_LAUNCH.ACTIONS.resolve_gvd_path(cands, exists)


func _peer_tokens_path():
	var base = OS.get_environment("XDG_CONFIG_HOME")
	if base == "":
		base = OS.get_environment("HOME").plus_file(".config")
	return base.plus_file("gdtk").plus_file("peer-tokens.json")


func _peer_tokens_load():
	var f = File.new()
	if f.open(_peer_tokens_path(), File.READ) != OK:
		return {}
	var d = JSON.parse(f.get_as_text()).result
	f.close()
	return d if typeof(d) == TYPE_DICTIONARY else {}


func _peer_token_get(peer_id):
	return String(_peer_tokens_load().get("cli:" + String(peer_id), ""))


func _peer_token_set(peer_id, tok):
	var d = _peer_tokens_load()
	d["cli:" + String(peer_id)] = String(tok)
	var f = File.new()
	if f.open(_peer_tokens_path(), File.WRITE) == OK:
		f.store_string(JSON.print(d))
		f.close()


# ¿El hid es un vecino confirmado? (gate del TOFU del canal peer)
func _peer_is_confirmed(hid):
	var h = String(hid)
	if h == "":
		return false
	var entry = host_directions.get(h, null)
	if typeof(entry) == TYPE_DICTIONARY and String(entry.get("confirm", "")) == "confirmed":
		return true
	return host_directions.has(h)


# Llama al canal peer del vecino. Devuelve true si ejecutó. Si es la primera vez,
# el vecino provisiona y devuelve su token (TOFU) y lo guardamos para la próxima.
func _peer_endpoint_for(host_id):
	var host = _neighborhood_host(host_id)
	if host == null:
		return {"ok": false, "peer": "", "port": 0, "error": "host no está en el Vecindario"}
	var port = int(host.get("ctl", 0))
	if port <= 0:
		return {"ok": false, "peer": "", "port": 0, "error": "sin canal peer"}
	var target = INBOX_MODEL.ssh_target(host)
	if not bool(target.get("ok", false)):
		return {"ok": false, "peer": "", "port": 0, "error": "host sin dirección"}
	return {"ok": true, "peer": String(target.get("peer", "")), "port": port, "error": ""}


func _peer_call_result(peer_host, peer_id, method, params = {}, ctl_port = 0):
	var out = {"ok": false, "error": "", "response": {}}
	var host = String(peer_host).strip_edges()
	if host == "":
		out.error = "vecino sin dirección"
		return out
	if host.find(".") < 0 and not host.is_valid_ip_address():
		host = host + ".local"
	var port = int(ctl_port)
	if port <= 0:
		port = _peer_port()
	var r = PEER_CALL.request_status(host, port, _local_hid(),
		_peer_token_get(peer_id), method, params)
	var resp = r.get("response", {})
	if resp.empty():
		out.error = String(r.get("error", "sin respuesta"))
		return out
	if not bool(resp.get("ok", false)):
		out.error = String(resp.get("error", "rechazado"))
		return out
	if resp.has("token"):
		_peer_token_set(peer_id, String(resp.token))
	out.ok = true
	out.response = resp
	return out


func _peer_call(peer_host, peer_id, method, params = {}):
	return bool(_peer_call_result(peer_host, peer_id, method, params).ok)


# --- Acciones que ejecuta el canal peer en ESTE host ----------------------------

# Equipo que nos está transmitiendo (canal peer `gvd_recv`): si la persona cierra la
# «Pantalla compartida», se le avisa con share_stop para que deje de emitir.
var _pantalla_sender = ""
var _pantalla_meta = {}   # {title, accent, icon} de la ventana que nos comparten (gvd_meta)
var _pantalla_icon = null  # ImageTexture del ícono recibido


# PNG en base64 (ya validado por peer_link.video_meta) -> textura de hasta 256 px.
func _icon_from_b64(b64):
	if b64 == "":
		return null
	var img = Image.new()
	if img.load_png_from_buffer(Marshalls.base64_to_raw(b64)) != OK or img.is_empty() \
			or img.get_width() > 256 or img.get_height() > 256:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	return tex


# Ícono que mandó el equipo de origen para esta «Pantalla compartida», o null.
func window_peer_icon(id):
	if _pantalla_icon == null or _pantalla_sender == "" or not _pantalla_window_ids().has(id):
		return null
	return _pantalla_icon
var _pantalla_video = Vector2()   # tamaño anunciado por el emisor (ventana compartida)
var _pantalla_fitted = {}         # id -> video al que ya se ajustó


# Lo que el marco agrega al contenido de una ventana (0 con CSD: gvd recv lo es).
func _chrome_extra(id):
	if _is_csd(id):
		return Vector2()
	var probe = Rect2(0, 0, 1000, 1000)
	return probe.size - WINDOW_CHROME.content_rect(probe, _chrome_title_h(), _chrome_border(),
		_chrome_resize_h()).size


# Handler peer `gvd_size`: la ventana original cambió de tamaño y el video con ella.
func _peer_gvd_size(hid, video):
	if String(hid) != _pantalla_sender or video == _pantalla_video:
		return true
	_pantalla_video = video   # el poll reajusta (las ya ajustadas, desde su centro)
	request_redraw()
	return true


# La persona soltó un resize de la «Pantalla compartida»: el alto sigue la proporción
# del video para que no queden franjas (el emisor no cambia).
func _pantalla_snap_aspect(id, box):
	if _pantalla_video == Vector2() or not _pantalla_window_ids().has(id) or not float_layout.has(id):
		return
	var r = GVD_LAUNCH.aspect_snap_rect(float_layout.rect(id), _pantalla_video, box, _chrome_extra(id))
	float_layout.resize_to(id, r, box)
	_pantalla_fitted[id] = _pantalla_video


# La «Pantalla compartida» toma el tamaño del video (contenido 1:1, sin franjas), también
# cada vez que gvd recv recrea su ventana o el emisor redimensiona (`gvd_size`), en este
# caso conservando su centro.
func _pantalla_fit_poll():
	if _pantalla_video == Vector2():
		return
	for id in _pantalla_window_ids():
		if _pantalla_fitted.get(id) == _pantalla_video or not tiles.has(id):
			continue
		if hybrid.is_tiled(id):
			set_window_mode(id, WM_HYBRID.FLOATING)
		var box = wm_box if wm_box.size.x > 0.0 else _tile_rect(get_viewport_rect().size)
		var center = null
		if float_layout.has(id) and _pantalla_fitted.has(id):
			var cur = float_layout.rect(id)
			center = cur.position + cur.size * 0.5
		if not float_layout.has(id):
			float_layout.place_new(id, box)
		var r = GVD_LAUNCH.receiver_frame_rect(_pantalla_video, box, _chrome_extra(id), center)
		if r.size.x > 0.0:
			float_layout.resize_to(id, r, box)
			wm_maximized.erase(id)
			print("pantalla: ", id, " ajustada al video ", _pantalla_video, " -> ", r)
		_pantalla_fitted[id] = _pantalla_video
		request_redraw()


# Handler peer `gvd_meta`: título y acento de la ventana que nos comparten.
func _peer_gvd_meta(hid, meta):
	if String(hid) != _pantalla_sender:
		return false
	if String(meta.get("icon", "")) != String(_pantalla_meta.get("icon", "")):
		_pantalla_icon = _icon_from_b64(String(meta.get("icon", "")))
	_pantalla_meta = meta
	request_redraw()
	return true


# Título a mostrar (Frame, exposé, decoración): la «Pantalla compartida» lleva el de la
# ventana original y «@equipo» al final; el resto, el que pone el cliente.
func window_title(id):
	if _pantalla_sender != "" and _pantalla_window_ids().has(id):
		var t = String(_pantalla_meta.get("title", ""))
		if t == "":
			t = "Pantalla compartida"
		return t + " @" + _peer_name_for(_pantalla_sender)
	return compositor.get_title(id)


# Acento del equipo que nos transmite esta «Pantalla compartida»: el que mandó por
# `gvd_meta` y, si no, el de su TXT mDNS; null si la ventana es local o no hay color.
# Lo usan window_deco (marco/asa) y el Frame (bloque de la ventana).
func window_peer_accent(id):
	if _pantalla_sender == "" or not _pantalla_window_ids().has(id):
		return null
	var sent = String(_pantalla_meta.get("accent", ""))
	if sent != "":
		return Color(sent)
	var host = _neighborhood_host(_pantalla_sender)
	if neighborhood_ui == null or not is_instance_valid(neighborhood_ui) \
			or not neighborhood_ui.has_method("node_accent"):
		return null
	return neighborhood_ui.node_accent({"host": host if typeof(host) == TYPE_DICTIONARY else {}})


func _pantalla_closed_here():
	var hid = _pantalla_sender
	_window_input_reset()
	_pantalla_sender = ""
	var ep = _peer_endpoint_for(hid)
	if bool(ep.get("ok", false)):
		_peer_send_async([{"id": hid, "host": String(ep.peer), "port": int(ep.port),
			"token": _peer_token_get(hid)}], "share_stop", {"type": "screen"})
	print("pantalla: cerrada acá; aviso a ", hid)
	_kill_pantalla_receivers()


func _peer_gvd_open(port, _from, hid = "", video = Vector2()):
	_pantalla_sender = String(hid)
	_pantalla_meta = {}
	_pantalla_icon = null
	_pantalla_video = video
	_pantalla_fitted = {}
	var path = _gvd_path_local()
	if path == "":
		return false
	if _pantalla_window_ids().empty():
		_pending_remove("Pantalla")
		starting.erase("Pantalla")
	_open_pantalla_window(path, _has_sway_socket(), int(port))
	return true


func _peer_gvd_stop():
	_window_input_reset()
	_pantalla_sender = ""   # lo cortó el emisor: no hay que avisarle
	_close_pantalla_window()
	return true


func _peer_gvd_active():
	return not _pantalla_window_ids().empty()


func _peer_gvd_send(_port, _target):
	return false


# --- Teclado y mouse del Grupo (única entrada a Deskflow) --------------------
# El interruptor del Grupo marca `input` en host_directions y deriva de ahí el modo del
# servicio global: algún equipo encendido -> "share_here" (servidor con la topología de
# Pantallas), ninguno -> "off". El otro equipo se entera por `share_notify` y se pone
# solo como cliente (_deskflow_follow). Lo escribe en settings["deskflow"], así el
# ciclo existente (autoarranque, reintentos, vigía) es el único que lanza procesos.
# ponytail: la topología incluye todas las pantallas ubicadas, no sólo las encendidas;
# un vecino apagado no conecta su cliente, así que no recibe el puntero.
func _group_input_on(host_id):
	var e = host_directions.get(String(host_id), {})
	return typeof(e) == TYPE_DICTIONARY and bool(e.get("input", false))


func _group_input_set(host_id, on):
	var id = String(host_id)
	var e = host_directions.get(id, null)
	if typeof(e) != TYPE_DICTIONARY:
		return
	e = e.duplicate()
	if on:
		e["input"] = true
	else:
		e.erase("input")
	host_directions[id] = DIRECTIONS_MODEL.sanitize_entry(e)
	_persist_directions()
	var any = false
	for k in host_directions.keys():
		if _group_input_on(k):
			any = true
			break
	_deskflow_write("share_here" if any else "off", "")
	_share_notify(id, "input", "starting" if on else "stopped")
	request_redraw()


# Lado controlado: el que comparte su teclado avisó; este equipo se vuelve cliente de él
# (o deja de serlo). Sólo si no es servidor de nadie (Deskflow es uno u otro).
func _deskflow_follow(hid, state):
	if settings_bridge == null or settings_bridge.model == null:
		return
	var cfg = settings_bridge.model.deskflow(settings_bridge.settings.get("deskflow", {}))
	var ep = _peer_endpoint_for(hid)
	var host = String(ep.get("peer", ""))
	if host != "" and host.find(".") < 0 and not host.is_valid_ip_address():
		host += ".local"
	if state == "stopped":
		if String(cfg.get("mode", "")) == "use_remote" and (host == "" or String(cfg.get("host", "")) == host):
			_deskflow_write("off", "")
	elif host != "" and String(cfg.get("mode", "")) != "share_here":
		_deskflow_write("use_remote", host)


# Escribe settings["deskflow"] (misma escritura atómica que Configuración) y lo aplica.
func _deskflow_write(mode, host):
	if settings_bridge == null or settings_bridge.model == null:
		return
	var cfg = settings_bridge.model.deskflow(settings_bridge.settings.get("deskflow", {}))
	if String(cfg.get("mode", "")) == String(mode) and String(cfg.get("host", "")) == String(host):
		return
	cfg["mode"] = String(mode)
	cfg["host"] = String(host)
	cfg["auto"] = String(mode) != "off"
	settings_bridge.settings["deskflow"] = settings_bridge.model.deskflow(cfg)
	settings_bridge.write_atomic(settings_bridge.settings_path(),
		settings_bridge.model.to_json(settings_bridge.settings))
	_apply_deskflow_settings()


# --- Portapapeles del Grupo ---------------------------------------------------
# Cada copia local nueva (applet Portapapeles) va a todos los equipos del Grupo con
# canal peer vivo, sin opción que activar (SPEC-sugar-group-2026-10 «Portapapeles»).
# El envío corre en un Thread; los tokens nuevos (TOFU) se guardan al reapear.
var _clip_states = []
var _clip_mutex = Mutex.new()


func _clip_sync_poll():
	_clip_mutex.lock()
	for i in range(_clip_states.size() - 1, -1, -1):
		var st = _clip_states[i]
		if bool(st.done):
			st.thread.wait_to_finish()
			for t in st.tokens:
				_peer_token_set(t.id, t.token)
			_clip_states.remove(i)
	_clip_mutex.unlock()
	if frame == null or frame.get("clipboard") == null:
		return
	# El vigía corre aunque el applet no esté en ninguna barra (el Frame sólo refresca
	# los applets ubicados); refresh() arranca el worker la primera vez.
	if frame.clipboard.get("_thread") == null:
		frame.clipboard.refresh()
	var texts = frame.clipboard.take_outbox()
	if texts.empty():
		return
	var ids = _peer_token_hids()
	for k in host_directions.keys():
		if not ids.has(String(k)):
			ids.append(String(k))
	var targets = []
	for hid in ids:
		var ep = _peer_endpoint_for(hid)
		if not bool(ep.get("ok", false)):
			continue
		var host = String(ep.peer)
		if host.find(".") < 0 and not host.is_valid_ip_address():
			host += ".local"
		targets.append({"id": hid, "host": host, "port": int(ep.port), "token": _peer_token_get(hid)})
	if targets.empty():
		return
	_peer_send_async(targets, "clip_set", {"text": String(texts[texts.size() - 1])})


# Envía `method` a cada destino {id, host, port, token} en un Thread de un solo uso;
# los tokens nuevos (TOFU) se guardan al reapear en _clip_sync_poll.
func _peer_send_async(targets, method, params):
	var st2 = {"done": false, "tokens": [], "thread": Thread.new()}
	_clip_mutex.lock()
	_clip_states.append(st2)
	_clip_mutex.unlock()
	st2.thread.start(self, "_peer_send_work", {"state": st2, "targets": targets,
		"method": String(method), "params": params, "hid": _local_hid()})


func _peer_send_work(u):
	var tokens = []
	for t in u.targets:
		var r = PEER_CALL.request_status(t.host, t.port, u.hid, t.token, u.method, u.params)
		if not bool(r.get("ok", false)) or not bool(r.get("response", {}).get("ok", false)):
			print("peer: ", u.method, " a ", t.id, " falló: ", String(r.get("error", "")),
				" ", String(r.get("response", {}).get("error", "")))
		var resp = r.get("response", {})
		if bool(resp.get("ok", false)) and resp.has("token"):
			tokens.append({"id": t.id, "token": String(resp.token)})
	_clip_mutex.lock()
	u.state.tokens = tokens
	u.state.done = true
	_clip_mutex.unlock()


# Handler del método peer `clip_set`: lo copiado en otro equipo del Grupo pasa a
# ser el portapapeles de acá.
func _peer_clip_set(text):
	if frame == null or frame.get("clipboard") == null:
		return false
	return bool(frame.clipboard.receive(String(text)))


# --- Grupo: enviar audio y ventanas a otro equipo -----------------------------
# Audio: túnel PulseAudio/PipeWire (`pactl`, modelo audio_send.gd). El receptor abre
# module-native-protocol-tcp sólo para la IP del emisor; el emisor crea un
# module-tunnel-sink hacia él, lo pone por omisión y muda los streams. Un destino a la
# vez, no se persiste. Todo lo bloqueante (peer, pactl) corre en Threads de un solo uso (_bg).
var _audio_mutex = Mutex.new()
var _audio_send = {}   # emisor: {hid, module, sink, prev}
var _audio_recv = {}   # receptor: {hid, module}
var _bg_threads = []


func _bg(method, arg):
	var t = Thread.new()
	_bg_threads.append(t)
	t.start(self, method, arg)


func _bg_reap():
	for i in range(_bg_threads.size() - 1, -1, -1):
		if not _bg_threads[i].is_alive():
			_bg_threads[i].wait_to_finish()
			_bg_threads.remove(i)


func _pactl(argv):
	if argv.empty():
		return ""
	var out = []
	OS.execute("pactl", argv, true, out)
	return String(out[0]) if not out.empty() else ""


# Descarga los módulos de una corrida anterior del shell que quedaron vivos (el
# puerto quedaría ocupado o un túnel huérfano).
func _audio_unload_stale(marker):
	for line in _pactl(["list", "short", "modules"]).split("\n"):
		if line.find(marker) >= 0:
			_pactl(AUDIO_SEND.unload_argv(line.split("\t")[0]))


# El interruptor del menú del Grupo lee _group_audio_on: redibujar al cambiar.
func _audio_status_changed():
	request_redraw()


func _group_audio_on(host_id):
	_audio_mutex.lock()
	var on = String(_audio_send.get("hid", "")) == String(host_id)
	_audio_mutex.unlock()
	return on


func _group_audio_set(host_id, on):
	var target = {}
	if on:
		var ep = _peer_endpoint_for(String(host_id))
		if not bool(ep.get("ok", false)):
			activity_error = "audio: " + String(ep.get("error", ""))
			return
		var host = String(ep.peer)
		if host.find(".") < 0 and not host.is_valid_ip_address():
			host += ".local"
		target = {"id": String(host_id), "host": host, "port": int(ep.port),
			"token": _peer_token_get(host_id), "me": _local_hid()}
	_bg("_audio_work", target)


# Thread: apaga el envío actual (si hay) y, si `t` trae destino, enciende hacia él.
func _audio_work(t):
	_audio_mutex.lock()
	var cur = _audio_send.duplicate()
	_audio_mutex.unlock()
	if not cur.empty():
		var back = String(cur.get("prev", ""))
		_pactl(["set-default-sink", back])
		for argv in AUDIO_SEND.move_argvs(AUDIO_SEND.parse_sink_inputs(
				_pactl(["list", "short", "sink-inputs"])), back):
			_pactl(argv)
		_pactl(AUDIO_SEND.unload_argv(int(cur.get("module", 0))))
		var ep = cur.get("ep", {})
		var rs = PEER_CALL.request_status(ep.host, ep.port, ep.me, ep.token, "audio_stop")
		if not bool(rs.get("ok", false)):
			print("audio: ", cur.get("hid", ""), " no confirmó audio_stop: ", rs.get("error", ""))
		_audio_mutex.lock()
		_audio_send = {}
		_audio_mutex.unlock()
		print("audio: dejé de enviar a ", cur.get("hid", ""))
		call_deferred("_audio_status_changed")
	if t.empty():
		call_deferred("_bg_reap")
		return
	var r = PEER_CALL.request_status(t.host, t.port, t.me, t.token, "audio_recv")
	var resp = r.get("response", {})
	if resp.has("token"):
		t.token = String(resp.token)   # el audio_stop posterior lo necesita
		call_deferred("_peer_token_set", t.id, t.token)
	var ip = IP.resolve_hostname(t.host, IP.TYPE_IPV4)
	var argv = AUDIO_SEND.tunnel_load_argv(ip, int(resp.get("port", 0)), t.id)
	if not bool(resp.get("ok", false)) or argv.empty():
		print("audio: ", t.id, " no acepta audio: ", r.get("error", ""), " ", ip)
		call_deferred("_bg_reap")
		return
	var sink = AUDIO_SEND.sink_name(t.id)
	_audio_unload_stale("sink_name=" + sink)
	var prev = AUDIO_SEND.parse_default_sink(_pactl(["info"]))
	var module = AUDIO_SEND.parse_module_id(_pactl(argv))
	if module <= 0:
		print("audio: no pude crear el túnel hacia ", t.id)
		PEER_CALL.request_status(t.host, t.port, t.me, t.token, "audio_stop")
		call_deferred("_bg_reap")
		return
	# PipeWire crea el sink del túnel después de que load-module vuelve: esperarlo
	# (hasta ~3 s) o set-default-sink/move fallan en silencio.
	for _i in range(30):
		if _pactl(["list", "short", "sinks"]).find("\t" + sink + "\t") >= 0:
			break
		OS.delay_msec(100)
	_pactl(["set-default-sink", sink])
	for mv in AUDIO_SEND.move_argvs(AUDIO_SEND.parse_sink_inputs(
			_pactl(["list", "short", "sink-inputs"])), sink):
		_pactl(mv)
	_audio_mutex.lock()
	_audio_send = {"hid": t.id, "module": module, "sink": sink, "prev": prev, "ep": t}
	_audio_mutex.unlock()
	print("audio: enviando a ", t.id, " (", ip, ")")
	call_deferred("_audio_status_changed")
	call_deferred("_bg_reap")


# Handler peer `audio_recv`: abre el puerto de audio sólo para `ip`. Devuelve el
# puerto o 0. ponytail: pactl corre en el hilo principal (decenas de ms, una vez).
func _peer_audio_recv(hid, ip):
	_peer_audio_stop("")
	_audio_unload_stale("port=" + str(AUDIO_SEND.RECV_PORT))
	var module = AUDIO_SEND.parse_module_id(_pactl(AUDIO_SEND.recv_load_argv(String(ip))))
	if module <= 0:
		return 0
	_audio_recv = {"hid": String(hid), "module": module}
	print("audio: recibiendo de ", hid, " (", ip, ")")
	return AUDIO_SEND.RECV_PORT


func _peer_audio_stop(_hid):
	if not _audio_recv.empty():
		_pactl(AUDIO_SEND.unload_argv(int(_audio_recv.get("module", 0))))
		_audio_recv = {}
	return true


# --- Grupo: compartir una ventana por gvd (arrastrar y soltar) -----------------
# Soltar el bloque de una ventana del Frame sobre un equipo de la vista Grupo la
# transmite en vivo (espejo: sigue acá). window_cast.gd la vuelca a un archivo de
# frames y `gvd send --capture shm` la codifica; del otro lado se abre la misma
# «Pantalla compartida» que al extender. Se deja de compartir sólo cerrando la ventana:
# la original acá o la «Pantalla compartida» allá (avisa con share_stop). Un equipo
# recibe una sola cosa por vez (un receptor por puerto).
const WINDOW_CAST = preload("res://window_cast.gd")
var _casts = {}   # hid -> {node, wid, sent}
var _window_input_mutex = Mutex.new()
var _window_input_queue = []
var _window_input_motion = null
var _window_input_thread = null
var _window_input_state = null
var _window_input_buttons = {}
var _window_input_keys = {}
var _window_input_last_send = 0
var _window_input_last_keepalive = 0
const WINDOW_INPUT_KEEPALIVE_MS = 500
const WINDOW_INPUT_STALE_MS = 1800


func _window_input_is_hold_button(button):
	return [BUTTON_LEFT, BUTTON_RIGHT, BUTTON_MIDDLE, BUTTON_XBUTTON1, BUTTON_XBUTTON2].has(int(button))


func _cast_key(hid):
	return "win:" + String(hid)


func _group_drop_target(global_pos):
	if neighborhood_ui == null or not is_instance_valid(neighborhood_ui) \
			or not neighborhood_ui.has_method("group_drop_target"):
		return {}
	return neighborhood_ui.group_drop_target(global_pos)


# Lo llama el Frame al soltar el bloque de una ventana. true = el Grupo lo consumió.
func _group_drop_window(wid, global_pos):
	var t = _group_drop_target(global_pos)
	if t.empty():
		return false
	if String(t.kind) == "self":
		return false   # se deja de compartir cerrando la ventana (acá o allá), no con un gesto
	if not bool(t.online):
		activity_error = "compartir: " + String(t.name) + " está apagado"
		return true
	_group_share_window(String(t.id), int(wid))
	return true


func _group_share_window(hid, wid):
	var gvd_path = _gvd_path_local()
	var target = _peer_endpoint_for(hid)
	if gvd_path == "" or not bool(target.get("ok", false)):
		activity_error = "compartir: " + ("no se encontró el programa de pantalla" if gvd_path == ""
			else String(target.get("error", "sin canal peer")))
		return
	# Una ventana por equipo: reemplaza la anterior. Su gvd_stop no sale en un hilo
	# aparte (si llegaba después del gvd_recv cerraba el receptor nuevo): va en el mismo
	# hilo que el gvd_recv, antes (pre_stop).
	var replacing = _casts.has(hid)
	_group_unshare_window(hid, false)
	var dir = OS.get_environment("XDG_RUNTIME_DIR").plus_file("gdtk")
	Directory.new().make_dir_recursive(dir)
	var path = dir.plus_file("win-" + AUDIO_SEND.sink_name(hid).replace("gdtk_send_", "") + ".frames")
	var cast = WINDOW_CAST.new()
	add_child(cast)
	if not cast.start(compositor, wid, path, 20):
		cast.queue_free()
		activity_error = "compartir: la ventana todavía no tiene tamaño"
		return
	var sp = GVD_LAUNCH.window_send_argv(gvd_path, String(target.peer), path, 20)
	if not bool(sp.get("ok", false)):
		cast.stop()
		cast.queue_free()
		activity_error = "compartir: " + String(sp.get("error", ""))
		return
	_casts[hid] = {"node": cast, "wid": wid, "sent": cast.size}
	_queue_gvd_peer_launch(hid, String(target.peer), int(target.port), "gvd_recv",
		{"port": 0, "from": _local_hostname(), "w": int(cast.size.x), "h": int(cast.size.y)},
		String(sp.cmd), sp.args, "", _cast_key(hid), replacing)
	_share_notify(hid, "screen", "active")
	print("compartir: ventana ", wid, " -> ", hid)


# Corta sólo la parte de ventana (el resto lo hace _stop_gvd_screen, que la llama).
func _group_unshare_window(hid, notify = true):
	var c = _casts.get(String(hid))
	if c == null:
		return
	_window_input_release_cast(c)
	_casts.erase(String(hid))
	_gvd_mutex.lock()
	for st in _gvd_peer_states:
		if String(st.get("key", "")) == _cast_key(hid):
			st.cancelled = true
	_gvd_mutex.unlock()
	_stop_tracked(_cast_key(hid))
	if is_instance_valid(c.node):
		c.node.stop()
		c.node.queue_free()
	var ep = _peer_endpoint_for(hid)
	if notify and bool(ep.get("ok", false)):
		_peer_send_async([{"id": hid, "host": String(ep.peer), "port": int(ep.port),
			"token": _peer_token_get(hid)}], "gvd_stop", {})
	print("compartir: dejé de compartir con ", hid)


# El receptor manda input sólo al peer que originó la «Pantalla compartida». Motion
# se coalesce; los cambios de botón/tecla conservan el orden y fuerzan delante la
# última posición. La red se atiende en un único Thread, nunca desde el render.
func _window_input_enqueue(event):
	if _pantalla_sender == "":
		return false
	_window_input_mutex.lock()
	if String(event.get("kind", "")) == "motion":
		_window_input_motion = event
	else:
		if _window_input_motion != null:
			_window_input_queue.append(_window_input_motion)
			_window_input_motion = null
		_window_input_queue.append(event)
	_window_input_mutex.unlock()
	return true


func _window_input_reset():
	if _pantalla_sender == "":
		_window_input_buttons.clear()
		_window_input_keys.clear()
		return
	if not _window_input_buttons.empty() or not _window_input_keys.empty():
		_window_input_enqueue({"kind": "reset"})
	_window_input_buttons.clear()
	_window_input_keys.clear()


func _window_input_pointer(event):
	if _pantalla_sender == "" or not (event is InputEventMouseMotion \
			or event is InputEventMouseButton):
		return false
	var hit = _view_hit_test(event.position)
	var over = int(hit.get("id", -1)) >= 0 and _pantalla_window_ids().has(int(hit.id))
	if event is InputEventMouseMotion:
		if not over:
			return not _window_input_buttons.empty()
		var video = _pantalla_video
		if video.x < 2.0 or video.y < 2.0:
			return false
		var x = clamp(float(hit.pos.x) / video.x, 0.0, 1.0)
		var y = clamp(float(hit.pos.y) / video.y, 0.0, 1.0)
		_window_input_enqueue({"kind": "motion", "x": x, "y": y})
		return true
	var button = int(event.button_index)
	if not event.pressed and _window_input_buttons.has(button):
		_window_input_enqueue({"kind": "button", "button": button, "pressed": false})
		_window_input_buttons.erase(button)
		return true
	if not over:
		return false
	# El clic enfoca el marco receptor para que las teclas siguientes vuelvan al wid.
	if event.pressed:
		_focus_tile(int(hit.id))
	_window_input_enqueue({"kind": "button", "button": button,
		"pressed": bool(event.pressed)})
	if event.pressed and _window_input_is_hold_button(button):
		_window_input_buttons[button] = true
	return true


func _window_input_poll():
	if _window_input_thread != null:
		_window_input_mutex.lock()
		var done = bool(_window_input_state.get("done", false))
		_window_input_mutex.unlock()
		if not done:
			return
		_window_input_thread.wait_to_finish()
		var token = String(_window_input_state.get("token", ""))
		var hid = String(_window_input_state.get("hid", ""))
		if token != "":
			_peer_token_set(hid, token)
		_window_input_thread = null
		_window_input_state = null
	var now = OS.get_ticks_msec()
	if (not _window_input_buttons.empty() or not _window_input_keys.empty()) \
			and now - _window_input_last_keepalive >= WINDOW_INPUT_KEEPALIVE_MS:
		_window_input_enqueue({"kind": "keepalive"})
		_window_input_last_keepalive = now
	if now - _window_input_last_send < 16:
		return
	_window_input_mutex.lock()
	if _window_input_queue.empty() and _window_input_motion != null:
		_window_input_queue.append(_window_input_motion)
		_window_input_motion = null
	var events = []
	while not _window_input_queue.empty() and events.size() < 64:
		events.append(_window_input_queue.pop_front())
	_window_input_mutex.unlock()
	if events.empty() or _pantalla_sender == "":
		return
	var hid = _pantalla_sender
	var ep = _peer_endpoint_for(hid)
	if not bool(ep.get("ok", false)):
		return
	var state = {"done": false, "token": "", "hid": hid}
	_window_input_state = state
	_window_input_thread = Thread.new()
	_window_input_last_send = now
	_window_input_thread.start(self, "_window_input_work", {"state": state,
		"host": String(ep.peer), "port": int(ep.port), "hid": hid,
		"token": _peer_token_get(hid), "events": events})


var _window_input_last_err = ""   # bajo _window_input_mutex


func _window_input_work(u):
	var host = String(u.host)
	if host.find(".") < 0 and not host.is_valid_ip_address():
		host += ".local"
	var r = PEER_CALL.request_status(host, int(u.port), _local_hid(), String(u.token),
		"window_input", {"events": u.events}, 1000)
	var resp = r.get("response", {})
	_window_input_mutex.lock()
	if bool(resp.get("ok", false)) and resp.has("token"):
		u.state.token = String(resp.token)
	# Un rechazo (p. ej. «bad request» de un equipo con el shell viejo) se registra una
	# vez por error distinto: antes el control fallaba en silencio.
	var err = "" if bool(resp.get("ok", false)) else String(resp.get("error", r.get("error", "")))
	if err != _window_input_last_err:
		_window_input_last_err = err
		if err != "":
			print("pantalla: el otro equipo rechaza el control (", err,
				"); si dice «bad request», reiniciá su shell")
	u.state.done = true
	_window_input_mutex.unlock()


# Origen: el token identifica al peer y `_casts[hid]` fija el único wid permitido.
func _peer_window_input(hid, events):
	var c = _casts.get(String(hid))
	if c == null or not _id_alive(int(c.wid)):
		return false
	var id = int(c.wid)
	if not c.has("input_buttons"):
		c.input_buttons = {}
		c.input_keys = {}
	c.input_seen = OS.get_ticks_msec()
	for ev in events:
		match String(ev.kind):
			"motion":
				var geo = compositor.get_geometry(id)
				var pos = Vector2(float(ev.x) * max(1.0, geo.size.x - 1.0),
					float(ev.y) * max(1.0, geo.size.y - 1.0)) + geo.position
				compositor.pointer_motion(id, pos)
			"button":
				compositor.pointer_button(int(ev.button), bool(ev.pressed))
				if bool(ev.pressed) and _window_input_is_hold_button(int(ev.button)):
					c.input_buttons[int(ev.button)] = true
				else:
					c.input_buttons.erase(int(ev.button))
			"key":
				_compositor_focus(id, false)
				var key = InputEventKey.new()
				key.physical_scancode = int(ev.physical)
				key.scancode = int(ev.physical)
				key.pressed = bool(ev.pressed)
				key.echo = bool(ev.get("echo", false))
				compositor.key(key)
				if key.pressed:
					c.input_keys[int(ev.physical)] = true
				else:
					c.input_keys.erase(int(ev.physical))
			"reset":
				_window_input_release_cast(c)
			"keepalive":
				pass
	return true


func _window_input_release_cast(c):
	for button in c.get("input_buttons", {}).keys():
		compositor.pointer_button(int(button), false)
	for physical in c.get("input_keys", {}).keys():
		var key = InputEventKey.new()
		key.physical_scancode = int(physical)
		key.scancode = int(physical)
		key.pressed = false
		compositor.key(key)
	c.input_buttons = {}
	c.input_keys = {}


# Título/acento actuales de la ventana compartida; true (y los guarda en meta_sent) si
# cambiaron desde el último gvd_meta.
func _cast_meta_changed(c):
	var wid = int(c.wid)
	# El ícono (PNG 64 px en base64) se arma una vez por app: sólo se reintenta mientras
	# todavía no cargó (los íconos se cargan de a poco por frame).
	var app = String(compositor.get_app_id(wid))
	if c.get("icon_app", null) != app or String(c.get("icon_b64", "")) == "":
		c.icon_app = app
		c.icon_b64 = _icon_png_b64(_window_icon(wid, _window_activity_name(wid)))
	var meta = {"title": String(compositor.get_title(wid)),
		"accent": "#" + accent.to_html(false), "icon": String(c.icon_b64)}
	if c.get("meta_sent", {}) == meta:
		return false
	c.meta_sent = meta
	return true


# Textura -> PNG de a lo sumo 64 px en base64 ("" si no hay datos de CPU, p. ej. SVG
# vectorial). Lo usa gvd_meta para mandar el ícono de la ventana compartida.
func _icon_png_b64(tex):
	if tex == null or not tex.has_method("get_data"):
		return ""
	var img = tex.get_data()
	if img == null or img.is_empty():
		return ""
	if img.is_compressed():
		img.decompress()
	var side = max(img.get_width(), img.get_height())
	if side > 64:
		img.resize(int(img.get_width() * 64 / side), int(img.get_height() * 64 / side),
			Image.INTERPOLATE_BILINEAR)
	var b64 = Marshalls.raw_to_base64(img.save_png_to_buffer())
	return b64 if b64.length() <= PEER_LINK.ICON_B64_MAX else ""


func _group_casting(wid):
	for hid in _casts.keys():
		if int(_casts[hid].wid) == int(wid):
			return true
	return false


# Ventana cerrada => se deja de compartir; ventana redimensionada => se avisa el tamaño
# nuevo al receptor (gvd ya rearma su video solo). Tick barato, desde _gvd_poll.
func _casts_poll():
	for hid in _casts.keys():
		var c = _casts[hid]
		if (not c.get("input_buttons", {}).empty() or not c.get("input_keys", {}).empty()) \
				and OS.get_ticks_msec() - int(c.get("input_seen", 0)) > WINDOW_INPUT_STALE_MS:
			_window_input_release_cast(c)
			print("compartir: input remoto liberado por desconexión de ", hid)
		if not _id_alive(int(c.wid)):
			_stop_gvd_screen(hid)
		elif is_instance_valid(c.node) and _cast_meta_changed(c):
			var ep_m = _peer_endpoint_for(hid)
			if bool(ep_m.get("ok", false)):
				_peer_send_async([{"id": hid, "host": String(ep_m.peer), "port": int(ep_m.port),
					"token": _peer_token_get(hid)}], "gvd_meta", c.meta_sent)
		elif is_instance_valid(c.node) and c.node.size != c.sent:
			c.sent = c.node.size
			var ep = _peer_endpoint_for(hid)
			if bool(ep.get("ok", false)):
				_peer_send_async([{"id": hid, "host": String(ep.peer), "port": int(ep.port),
					"token": _peer_token_get(hid)}], "gvd_size",
					{"w": int(c.sent.x), "h": int(c.sent.y)})
			print("compartir: ventana ", c.wid, " ahora ", c.sent)


# --- Dockapp "Compartiendo": avisos de lado compartido (G5) --------------------
# Avisa al otro equipo qué lado quedó compartido y en qué estado, por el canal peer
# ya existente (token cli:, TOFU). Sin canal/token se ignora en silencio (sólo log
# con GDTK_DEBUG), igual que las demás acciones on-demand.
func _share_notify(host_id, type, state):
	var id = String(host_id)
	var d = _direction_for(id)
	if d == "":
		return
	var target = _peer_endpoint_for(id)
	if not bool(target.get("ok", false)):
		if OS.get_environment("GDTK_DEBUG") == "1":
			print("compartir: sin canal hacia ", id, " (", String(target.get("error", "")), ")")
		return
	var side = DIRECTIONS_MODEL.inverse(d)
	# Nunca en el hilo de render: un vecino que no responde congelaba el shell 1,5 s+.
	_peer_send_async([{"id": id, "host": String(target.get("peer", "")),
		"port": int(target.get("port", 0)), "token": _peer_token_get(id)}],
		"share_notify", {"type": String(type), "side": side, "state": String(state)})


# Nombre visible del equipo por hid, sin exponer el id opaco ni jerga.
func _peer_name_for(hid):
	var host = _neighborhood_host(String(hid))
	if host != null:
		var label = String(host.get("label", "")).strip_edges()
		if label != "":
			return label
	return String(hid)


# Handler del método peer `share_notify`: guarda/actualiza el lado que el otro
# equipo comparte hacia este (el `side` ya viene invertido por el emisor) o lo
# borra al recibir "stopped". Upsert por (hid, tipo).
func _peer_share_notify(hid, params):
	var id = String(hid).strip_edges()
	if id == "" or typeof(params) != TYPE_DICTIONARY:
		return false
	var type = String(params.get("type", "")).strip_edges()
	if type != "screen" and type != "input":
		return false
	var state = String(params.get("state", "active")).strip_edges()
	if type == "input":
		_deskflow_follow(id, state)
	if state == "stopped":
		for i in range(remote_shares.size() - 1, -1, -1):
			var old = remote_shares[i]
			if typeof(old) == TYPE_DICTIONARY and String(old.get("host", "")) == id \
					and String(old.get("type", "")) == type:
				remote_shares.remove(i)
		request_redraw()
		return true
	var side = String(params.get("side", "")).strip_edges()
	if not DIRECTIONS_MODEL.valid_direction(side) or side == "none":
		return false
	if state != "starting" and state != "active" and state != "error":
		state = "active"
	var entry = {"host": id, "peer_name": _peer_name_for(id), "type": type,
		"side": side, "state": state}
	var found = false
	for i in range(remote_shares.size()):
		var old2 = remote_shares[i]
		if typeof(old2) == TYPE_DICTIONARY and String(old2.get("host", "")) == id \
				and String(old2.get("type", "")) == type:
			remote_shares[i] = entry
			found = true
			break
	if not found:
		remote_shares.append(entry)
	request_redraw()
	return true


# Handler del método peer `share_stop`: detiene la sesión LOCAL de ese tipo hacia
# hid (pantalla: receptor/emisor rastreado; teclado y mouse: servidor del host).
func _peer_share_stop(hid, params):
	var id = String(hid).strip_edges()
	if id == "":
		return false
	var type = String(params.get("type", "")).strip_edges() if typeof(params) == TYPE_DICTIONARY else ""
	if type == "screen":
		_stop_gvd_screen(id)
		return true
	if type == "input":
		host_deskflow[id] = false
		var key = HOST_DISPATCH.deskflow_session_key(id)
		if _has_tracked(key):
			_stop_tracked(key)
		request_redraw()
		return true
	return false


# Ventanas de pantalla extendida para el diagrama: [{id, title, peer_name, maximized}].
# Sólo lee caches/consultas baratas del compositor, sin procesos.
func _share_windows():
	var out = []
	var peer = ""
	for hid in host_directions.keys():
		if _gvd_has_session(String(hid)):
			peer = _peer_name_for(String(hid))
			break
	for id in _pantalla_window_ids():
		var wid = int(id)
		out.append({
			"id": str(wid),
			"title": String(window_title(wid)),
			"peer_name": peer,
			"maximized": bool(maximize_state.has(wid) or wm_maximized.has(wid)),
		})
	return out


# hids con token peer (cli: o srv:) en peer-tokens.json, sin copiar los valores.
func _peer_token_hids():
	var out = []
	var d = _peer_tokens_load()
	for k in d.keys():
		var key = String(k)
		if not (key.begins_with("cli:") or key.begins_with("srv:")):
			continue
		var hid = key.substr(4).strip_edges()
		if hid != "" and not out.has(hid):
			out.append(hid)
	out.sort()
	return out


# Suma host_id al Grupo (entrada sin ubicar) y persiste. Si ya existe un vínculo de
# dirección para ese equipo, se reenvía la propuesta del handshake de pareo actual
# (sin bloquear: el envío va a un Thread del buzón).
func _group_add(host_id):
	var id = String(host_id).strip_edges()
	if id == "":
		return
	host_directions = GROUP_MODEL.add_member(host_directions, id)
	_refresh_direction_views()
	_persist_directions()
	var entry = host_directions.get(id, {})
	if typeof(entry) == TYPE_DICTIONARY:
		var d = String(entry.get("direction", "")).strip_edges()
		if DIRECTIONS_MODEL.valid_direction(d) and d != "none":
			propose_direction(id, d)
	request_redraw()


# Quita host_id del Grupo: borra su dirección, sus tokens peer (cli: y srv:, en
# memoria y en disco) y su pantalla de settings["screens"]. Nunca bloquea el render.
func _group_remove(host_id):
	var id = String(host_id).strip_edges()
	if id == "":
		return
	var name = _peer_name_for(id)
	var _plan = GROUP_MODEL.removal_plan(id, name)
	host_directions = GROUP_MODEL.remove_member(host_directions, id)
	_refresh_direction_views()
	_persist_directions()
	_peer_token_forget(id)
	_screen_forget(id, name)
	request_redraw()


# Olvida los tokens peer del hid en memoria (peer_control) y en disco. Si el canal
# peer no está vivo, escribe el archivo directamente con lo que ya había.
func _peer_token_forget(hid):
	var id = String(hid)
	var pc = Host.peer_control
	if pc != null and pc is Object:
		pc.tokens.erase("cli:" + id)
		pc.tokens.erase("srv:" + id)
		if pc.has_method("_save_tokens"):
			pc._save_tokens()
		return
	var d = _peer_tokens_load()
	d.erase("cli:" + id)
	d.erase("srv:" + id)
	var f = File.new()
	if f.open(_peer_tokens_path(), File.WRITE) == OK:
		f.store_string(JSON.print(d))
		f.close()


# Quita la pantalla configurada del equipo (por id o nombre) de settings["screens"],
# con la misma escritura atómica que usa la app de Configuración.
func _screen_forget(id, name):
	if settings_bridge == null or settings_bridge.model == null:
		return
	var raw = settings_bridge.settings.get("screens", {})
	if typeof(raw) != TYPE_DICTIONARY or raw.empty():
		return
	var lay = SCREEN_LAYOUT.normalize_layout(raw)
	var kept = []
	var removed = false
	for sc in lay.screens:
		var sid = String(sc.get("id", "")).strip_edges()
		var label = String(sc.get("label", "")).strip_edges()
		var peer = String(sc.get("peer", "")).strip_edges()
		if sid == id or label == name or peer == name:
			removed = true
			continue
		kept.append(sc)
	if not removed:
		return
	lay.screens = kept
	settings_bridge.settings["screens"] = lay
	settings_bridge.write_atomic(settings_bridge.settings_path(),
		settings_bridge.model.to_json(settings_bridge.settings))


func _direction_for(host_id):
	var entry = host_directions.get(String(host_id), {})
	if typeof(entry) != TYPE_DICTIONARY:
		return ""
	var d = String(entry.get("direction", "none")).strip_edges()
	return d if DIRECTIONS_MODEL.valid_direction(d) else ""


func _has_sway_socket():
	return OS.get_environment("SWAYSOCK").strip_edges() != ""


# ¿Hay canal peer autorizado hacia este host para abrir su receptor? Es el mismo
# canal que usa `_start_gvd_screen`; pantalla on-demand no cae a ssh.
func provision_channel_for(host_id):
	return bool(_peer_endpoint_for(String(host_id)).get("ok", false))


# Arranca una sesión de pantalla hacia `host_id`. `share_my_screen` emite local y
# abre el receptor del peer por el canal peer LAN; `use_as_screen` abre el receptor
# local en un tile y pide al peer que emita. Nunca bloquea.
func _start_gvd_screen(host_id, action):
	var id = String(host_id)
	var plan = action.get("plan", null) if typeof(action) == TYPE_DICTIONARY else null
	var gvd_path = GVD_LAUNCH.gvd_path_of(plan)
	if gvd_path == "":
		activity_error = "pantalla: no se encontró el programa de pantalla"
		return
	var direction = _direction_for(id)
	var target = _peer_endpoint_for(id)
	var aid = String(action.get("id", "")) if typeof(action) == TYPE_DICTIONARY else ""
	if aid == "share_my_screen":
		if not GVD_LAUNCH.local_can_emit(OS.get_environment("XDG_CURRENT_DESKTOP"),
				OS.get_environment("XDG_SESSION_TYPE")):
			activity_error = "pantalla: este equipo no puede emitir su escritorio"
			return
		# Mismo destino que el canal peer (IPv4 primero, ver neighborhood_inbox.ssh_target):
		# la dirección del plan puede ser la IPv6 global que mDNS anuncia primero.
		var peer = String(target.get("peer", "")) if bool(target.get("ok", false)) \
			else GVD_LAUNCH.target_host_of(plan)
		# gdtk/sway (wlroots): captura por wlr-screencopy. Con sway se extiende de
		# verdad creando un monitor headless (--virtual); GNOME usa su Meta-*.
		var backend = GVD_LAUNCH.local_emit_backend(
			OS.get_environment("XDG_CURRENT_DESKTOP"),
			OS.get_environment("XDG_SESSION_TYPE"))
		var wlr_virtual = backend == "wlr" and _has_sway_socket()
		# Reintentar no debe apilar emisores: varios gvd send al mismo peer:puerto
		# se pisarían. Se corta la sesión previa (SIGTERM: desmonta su monitor).
		if _has_tracked(id):
			_stop_tracked(id)
		if _has_tracked(GVD_LAUNCH.remote_recv_key(id)):
			_stop_tracked(GVD_LAUNCH.remote_recv_key(id))
		var sp = GVD_LAUNCH.local_send_argv(gvd_path, peer,
			GVD_LAUNCH.port_of_plan(plan), GVD_LAUNCH.position_for(direction), wlr_virtual)
		if not bool(sp.get("ok", false)):
			activity_error = "pantalla: " + String(sp.get("error", ""))
			return
		if not bool(target.get("ok", false)):
			activity_error = "pantalla: " + String(target.get("error", "sin canal peer"))
			return
		var peer_host = String(target.get("peer", ""))
		var port = GVD_LAUNCH.port_of_plan(plan)
		# Canal peer (LAN, sin ssh): pedirle al vecino que abra su receptor antes
		# de crear el monitor virtual local. Así no se anuncia "activo" sin ventana
		# del otro lado.
		_queue_gvd_peer_launch(id, peer_host, int(target.get("port", 0)),
			"gvd_recv", {"port": port, "from": _local_hostname()},
			String(sp.get("cmd", "")), sp.get("args", []), direction)
		_share_notify(id, "screen", "starting")
	else:
		_open_pantalla_window(gvd_path, _has_sway_socket(), GVD_LAUNCH.port_of_plan(plan))
		if bool(target.get("ok", false)):
			var peer_host2 = String(target.get("peer", ""))
			var port2 = GVD_LAUNCH.port_of_plan(plan)
			var sent = _peer_call_result(peer_host2, id, "gvd_send",
				{"port": port2, "target": _local_hostname()}, int(target.get("port", 0)))
			if not bool(sent.ok):
				_close_pantalla_window()
				activity_error = "pantalla: el vecino no pudo emitir (" + String(sent.error) + ")"
			else:
				_share_notify(id, "screen", "starting")
		else:
			_close_pantalla_window()
			activity_error = "pantalla: " + String(target.get("error", "sin canal peer"))
	request_redraw()


# Suspende el vínculo Deskflow hacia la dirección extendida: si había una sesión
# de servidor Deskflow viva para ese host, se corta y se recuerda su argv para
# restaurarla al cortar la pantalla. La dirección queda marcada para que un
# layout posterior no la reintroduzca (ver apply_deskflow_layout).
func _suspend_deskflow_link(host_id, direction):
	var id = String(host_id)
	_gvd_link_suspended[id] = String(direction)
	# El borde extendido deja de capturar input de inmediato (portal InputCapture),
	# sin tocar los demás vecinos ni reiniciar el servicio Deskflow.
	_apply_capture_ranges()
	var key = HOST_DISPATCH.deskflow_session_key(id)
	if _has_tracked(key):
		_stop_tracked(key)
		if _deskflow_server_launch.has(id):
			_gvd_link_restore[id] = true


func _restore_deskflow_link(host_id):
	var id = String(host_id)
	_gvd_link_suspended.erase(id)
	_apply_capture_ranges()
	if not bool(_gvd_link_restore.get(id, false)):
		return
	_gvd_link_restore.erase(id)
	var saved = _deskflow_server_launch.get(id, null)
	if typeof(saved) != TYPE_DICTIONARY:
		return
	var cmd = String(saved.get("cmd", ""))
	if cmd == "":
		return
	_launch_tracked(HOST_DISPATCH.deskflow_session_key(id), cmd, saved.get("args", []))


# Publica los rangos del portal InputCapture al RemoteInput del compositor (barato,
# sin I/O): refleja altas/bajas de la suspensión por extensión de pantalla.
func _apply_capture_ranges():
	if Host.remote_input != null and Host.remote_input.has_method("set_capture_ranges"):
		Host.remote_input.set_capture_ranges(_deskflow_capture_ranges())


func _queue_gvd_peer_launch(host_id, peer_host, ctl_port, method, params, cmd, args, direction,
		key = "", pre_stop = false):
	var id = String(host_id)
	var state = {
		"done": false,
		"cancelled": false,
		"key": String(key) if String(key) != "" else id,
		"peer_id": id,
		"peer_host": String(peer_host),
		"ctl_port": int(ctl_port),
		"local_hid": _local_hid(),
		"token": _peer_token_get(id),
		"method": String(method),
		"params": params if typeof(params) == TYPE_DICTIONARY else {},
		"cmd": String(cmd),
		"args": args if typeof(args) == TYPE_ARRAY else [],
		"direction": String(direction),
		"pre_stop": bool(pre_stop),
		"ok": false,
		"error": "",
		"response": {},
	}
	var th = Thread.new()
	_gvd_mutex.lock()
	_gvd_peer_threads.append(th)
	_gvd_peer_states.append(state)
	_gvd_mutex.unlock()
	th.start(self, "_gvd_peer_work", {"state": state})
	request_redraw()


func _gvd_peer_work(userdata):
	var state = userdata.state
	if bool(state.get("pre_stop", false)):
		# Reemplazo: cerrar el receptor anterior ANTES de pedir el nuevo, en este hilo.
		PEER_CALL.request_status(String(state.peer_host), int(state.ctl_port),
			String(state.local_hid), String(state.token), "gvd_stop", {}, 2000)
	var r = PEER_CALL.request_status(String(state.peer_host), int(state.ctl_port),
		String(state.local_hid), String(state.token), String(state.method),
		state.params, 4500)
	var resp = r.get("response", {})
	_gvd_mutex.lock()
	state.response = resp
	if resp.empty():
		state.error = String(r.get("error", "sin respuesta"))
	elif not bool(resp.get("ok", false)):
		state.error = String(resp.get("error", "rechazado"))
	else:
		state.ok = true
	state.done = true
	_gvd_mutex.unlock()


func _finish_gvd_peer_state(state):
	if bool(state.get("cancelled", false)):
		return
	var resp = state.get("response", {})
	if typeof(resp) == TYPE_DICTIONARY and resp.has("token"):
		_peer_token_set(String(state.get("peer_id", "")), String(resp.token))
	if not bool(state.get("ok", false)):
		activity_error = "pantalla: el vecino no abrió el receptor (" \
			+ String(state.get("error", "sin respuesta")) + ")"
		print(activity_error, " [", state.get("key", ""), "]")
		return
	print("pantalla: receptor listo en ", state.get("peer_id", ""), "; lanzo ", state.get("key", ""))
	_launch_tracked(String(state.get("key", "")), String(state.get("cmd", "")),
		state.get("args", []))
	# Sólo extender la pantalla toca el borde de Deskflow; compartir una ventana no.
	if String(state.get("key", "")) == String(state.get("peer_id", "")):
		_suspend_deskflow_link(String(state.get("key", "")), String(state.get("direction", "")))


# Lanza un plan (gvd send, servidor Deskflow) en un Thread de un solo uso; captura
# el pid y lo publica en `gvd_session_pids` bajo `key`. Nunca en el hilo de render.
func _launch_tracked(key, cmd, args):
	var k = String(key)
	var c = String(cmd).strip_edges()
	if k == "" or c == "":
		return
	var state = {"done": false, "key": k, "pid": 0, "error": ""}
	var th = Thread.new()
	_gvd_mutex.lock()
	_gvd_launch_threads.append(th)
	_gvd_launch_states.append(state)
	_gvd_mutex.unlock()
	th.start(self, "_tracked_launch_work", {"key": k, "cmd": c, "args": args, "state": state})


# Compatibilidad: el emisor gvd usa la clave host_id (misma maquinaria rastreada).
func _launch_gvd_send(host_id, cmd, args):
	_launch_tracked(String(host_id), cmd, args)


func _tracked_launch_work(userdata):
	var args = userdata.get("args", [])
	if typeof(args) != TYPE_ARRAY:
		args = []
	var pid = int(OS.execute(String(userdata.get("cmd", "")), args, false))
	var err = ""
	if pid <= 0:
		err = "no se pudo lanzar " + String(userdata.get("cmd", ""))
	_gvd_mutex.lock()
	if pid > 0:
		gvd_session_pids[String(userdata.key)] = pid
	userdata.state.pid = pid
	userdata.state.error = err
	userdata.state.done = true
	_gvd_mutex.unlock()


# Reapea los Threads de lanzamiento terminados (no bloquea).
func _gvd_poll():
	_window_input_poll()
	if not _casts.empty():
		_casts_poll()
	_pantalla_fit_poll()
	var reaped = false
	for i in range(_gvd_peer_threads.size() - 1, -1, -1):
		var pstate = _gvd_peer_states[i]
		_gvd_mutex.lock()
		var pdone = bool(pstate.get("done", false))
		_gvd_mutex.unlock()
		if pdone:
			_gvd_peer_threads[i].wait_to_finish()
			_gvd_peer_threads.remove(i)
			_gvd_peer_states.remove(i)
			_finish_gvd_peer_state(pstate)
			reaped = true
	for i in range(_gvd_launch_threads.size() - 1, -1, -1):
		var state = _gvd_launch_states[i]
		_gvd_mutex.lock()
		var done = state.done
		_gvd_mutex.unlock()
		if done:
			_gvd_launch_threads[i].wait_to_finish()
			_gvd_launch_threads.remove(i)
			_gvd_launch_states.remove(i)
			reaped = true
	if reaped:
		request_redraw()


# Estado de sesión del host para la UI, leído SÓLO de caches (sin consultar
# procesos ni disco): "idle" | "starting" | "active". Cuenta las sesiones gvd
# (emisor local, receptor/emisor remoto; ver GVD_LAUNCH.session_keys) y el
# servidor Deskflow (clave "deskflow:"+host_id).
func _host_session_state(host_id):
	var id = String(host_id)
	var session_keys = GVD_LAUNCH.session_keys(id)
	var df_key = HOST_DISPATCH.deskflow_session_key(id)
	_gvd_mutex.lock()
	var active = int(gvd_session_pids.get(df_key, 0)) > 0
	if not active:
		for k in session_keys:
			if int(gvd_session_pids.get(k, 0)) > 0:
				active = true
				break
	var starting = false
	for st in _gvd_peer_states:
		if bool(st.get("done", false)) or bool(st.get("cancelled", false)):
			continue
		if String(st.get("key", "")) == id:
			starting = true
			break
	for st in _gvd_launch_states:
		if bool(st.get("done", false)):
			continue
		var k = String(st.get("key", ""))
		if k == df_key or session_keys.has(k):
			starting = true
			break
	_gvd_mutex.unlock()
	if active:
		return "active"
	if starting:
		return "starting"
	if bool(host_deskflow.get(id, false)) and _service_running("Deskflow"):
		return "active"
	return "idle"


# Conectar una red: siempre por nmtui en la actividad Terminal, sin pasar secretos.
func _open_nmtui():
	_close_neighborhood()
	var name = _unique_activity_name("Terminal")
	ACTIVITIES.append({"name": name, "wayland": ["alacritty", "-e", "nmtui", "connect"], "dynamic": true})
	var i = ACTIVITIES.size() - 1
	_activate(i)
	if not _pending_has(name) and not wayland_ids.has(name):
		ACTIVITIES.remove(i)


# Encender la radio desde el estado vacío: acción explícita, nunca en silencio.
# No bloqueante: el worker de Vecindario detecta la lista nueva en su próximo ciclo.
func _wifi_radio_on():
	OS.execute("nmcli", ["radio", "wifi", "on"], false)
	request_redraw()


# Conectar a una red desde el Vecindario. Red abierta: nmcli directo. Red con
# seguridad: nmtui (pide la clave en su propia TUI; NUNCA pasamos secretos por
# argv). Sin nmcli cae a nmtui. No bloquea: ejecuta en segundo plano.
func _wifi_connect(ssid, security):
	var s = String(ssid).strip_edges()
	if s == "" or s.begins_with("-"):
		return
	if _which("nmcli") == "":
		_open_nmtui()
		return
	var sec = String(security).strip_edges()
	if sec == "" or sec == "--":
		OS.execute("nmcli", ["device", "wifi", "connect", s], false)
	else:
		_open_nmtui()


# Desconectar la red (por perfil). No bloquea.
func _wifi_disconnect(ssid):
	var s = String(ssid).strip_edges()
	if s == "" or s.begins_with("-"):
		return
	if _which("nmcli") == "":
		return
	OS.execute("nmcli", ["connection", "down", "id", s], false)


# --- Bluetooth (proveedor del Vecindario) ------------------------------------
# Acciones con bluetoothctl, no bloqueantes: el worker de Vecindario relee el
# estado en el próximo refresco (que se pide explícitamente tras cada acción).
# Sin bluetoothctl en $PATH no se hace nada. La dirección se valida para no
# confundirla con una opción de bluetoothctl.

func _bt_connect(addr):
	_bt_cmd(["connect", addr])


func _bt_disconnect(addr):
	_bt_cmd(["disconnect", addr])


# Vincular: pair + trust, y luego connect (el worker refleja el resultado).
func _bt_pair(addr):
	if not _bt_valid(addr):
		return
	_bt_run(["pair", addr])
	_bt_run(["trust", addr])
	_bt_run(["connect", addr])
	_bt_after()


func _bt_forget(addr):
	_bt_cmd(["remove", addr])


# Buscar dispositivos cercanos (scan acotado por --timeout).
func _bt_scan():
	if _which("bluetoothctl") == "":
		return
	OS.execute(_which("bluetoothctl"), ["--timeout", "8", "scan", "on"], false)
	_bt_after()


func _bt_cmd(args):
	if not _bt_valid(String(args[1])):
		return
	_bt_run(args)
	_bt_after()


func _bt_run(args):
	var bin = _which("bluetoothctl")
	if bin == "":
		return
	OS.execute(bin, args, false)


# Pide al worker del Vecindario un refresco y repinta (la barra y el mapa).
func _bt_after():
	if neighborhood != null and neighborhood.has_method("request_refresh"):
		neighborhood.request_refresh()
	request_redraw()


func _bt_valid(addr):
	var a = String(addr).strip_edges()
	return a != "" and not a.begins_with("-") and a.length() <= 64


# Las actividades tipo script pueden tener recursos propios (p.ej. un viewport
# 3D). Se les da la opcion de liberarlos al salir de la actividad; la
# instancia (su estado) sigue en script_instances y los recrea al volver.
func _release_activity():
	if activity_instance != null and activity_instance.has_method("cleanup"):
		activity_instance.cleanup()


# Cerrar desde el Frame: se descarta la instancia (la actividad pierde su estado).
func _close_script_activity(name):
	if current_activity != null and current_activity.name == name:
		_go_home()
	var inst = script_instances.get(name)
	script_instances.erase(name)
	if inst != null and inst.has_method("cleanup"):
		inst.cleanup()


func _current_wayland_id():
	if not tile_mode:
		return -1
	if focused_tile >= 0 and _id_alive(focused_tile):
		return focused_tile
	return -1


func _id_alive(id):
	return compositor.get_ids().has(id)


func _on_toplevel_added(id):
	print("toplevel_added ", id)
	# Un toplevel con padre es un dialogo: no se asigna a ninguna actividad.
	if compositor.get_parent_id(id) > 0:
		_add_dialog(id)
		return
	if pending_wayland != "" or not pending_launches.empty():
		# Con app_id/título se asocia SÓLO con el pendiente cuyo comando coincide (así
		# una ventana fuera de orden se ata a su lanzamiento, no a la más reciente).
		# Sin app_id ni título no hay dato: se usa la pendiente más reciente, el
		# comportamiento histórico. Con dato pero sin coincidencia no se inventa:
		# la ventana se trata como suelta (actividad dinámica).
		var has_data = compositor.get_app_id(id) != "" or compositor.get_title(id) != ""
		var name = _match_pending(id)
		if name == "" and not has_data:
			name = pending_wayland
		if name != "":
			_pending_remove(name)
			starting.erase(name)  # llegó la ventana: se corta la notificación de arranque
			wayland_ids[name] = id
			# Si veníamos de una actividad de script, se sueltan sus recursos transitorios
			# (la instancia se conserva); recién acá se cambia de vista, no al lanzar.
			_release_activity()
			activity_instance = null
			_add_tile(id, name)
			_focus_tile(id)
			return
	# Sin actividad (o sin coincidencia con app_id/título): se creara una dinamica.
	unmanaged.append(id)
	unmanaged_since[id] = OS.get_ticks_msec()


# xdg-activation (p.ej. clic en una notificación): la ventana pasa al frente.
func _on_toplevel_activate(id):
	var name = _activity_for_window(_root_of(id))
	if name != "":
		_open_by_name(name)
		compositor.focus(id)
		request_redraw()


# La propia app pide minimizarse desde su decoración (CSD) o vía iconify X11: se
# reenvía a la minimización del shell. Sólo aplica a ventanas gestionadas (raíz en
# `tiles`); un diálogo o una ventana no adoptada no se minimiza.
func _on_toplevel_minimize(id):
	var root = _root_of(id)
	if not tiles.has(root) or minimized.has(root):
		return
	_minimize_window(root)
	request_redraw()


# La app pide maximizar/desmaximizar desde su decoración (CSD): se alterna el workspace
# entero con su franja partida. Sólo aplica a ventanas gestionadas (raíz en `tiles`).
func _on_toplevel_maximize(id, maximized):
	# El compositor ya le confirmó ese estado al cliente: la caché debe saberlo, o al
	# pasar a flotante (Super+arrastre) no se le mandaría el "desmaximizar".
	_max_sent[id] = maximized != 0
	var root = _root_of(id)
	if not tiles.has(root):
		return
	if maximized == 0:
		_restore_maximized_window(root)
	else:
		_maximize_window(root)
	request_redraw()


# La app pide pantalla completa (video de YouTube, etc.): la ventana ocupa todo el
# viewport y se esconde el Frame (mismo estado que Alt+F11). Al salir vuelve a su
# pantalla. Sólo aplica a ventanas gestionadas (raíz en `tiles`).
func _on_toplevel_fullscreen(id, fullscreen):
	var root = _root_of(id)
	if not tiles.has(root):
		return
	if fullscreen == 0:
		if fullscreen_id == root:
			fullscreen_id = -1
		request_redraw()
		return
	if focused_tile != root:
		_focus_tile(root)
	fullscreen_id = root
	if frame != null:
		frame.set_visible(false)
	request_redraw()


# El cliente pide mover su ventana (arrastre de su barra CSD, p. ej. GTK4): el shell
# hace el arrastre interactivo, igual que con nuestra barra de título.
func _on_toplevel_move(id):
	_begin_client_drag(_root_of(id), "move", "")


# El cliente pide redimensionar por un borde (CSD): se traduce el bitfield WLR_EDGE_*
# a una zona del chrome y se inicia el arrastre de redimensión.
func _on_toplevel_resize(id, edges):
	_begin_client_drag(_root_of(id), "resize", WM_DRAG.edges_zone(edges))


# Arrastre pedido por el cliente (o por Super+clic): mover o redimensionar la ventana
# `id` en flotante, reutilizando el mismo chrome_drag que el arrastre de la barra.
func _begin_client_drag(id, kind, edge):
	if chrome_drag != null or expose or not hybrid.is_floating(id):
		return
	if not tiles.has(id) or minimized.has(id) or id == fullscreen_id:
		return
	var box = wm_box if wm_box.size.x > 0.0 else _tile_rect(get_viewport_rect().size)
	var was_max = wm_maximized.has(id) or maximize_state.has(id)
	if was_max:
		# Un arrastre pedido por el cliente sobre una maximizada la desmaximiza.
		wm_maximized.erase(id)
		maximize_state.erase(id)
	if not float_layout.has(id):
		if float_memory.has(id) and float_memory[id] != null:
			float_layout.restore_one(id, float_memory[id], box)
		else:
			float_layout.place_new(id, box)
	_focus_tile(id)
	var big = window_rects.get(id, box)
	var fr = float_layout.rect(id) if was_max else big
	if fr == null:
		fr = box
	var m = last_pointer_pos if last_pointer_pos != null else fr.position + fr.size * 0.5
	if kind == "move":
		var grab = Vector2(m) - fr.position
		if was_max:
			grab = WM_DRAG.proportional_grab(Vector2(m) - big.position, big.size, fr.size)
		chrome_drag = {"id": id, "kind": "move", "grab": grab,
			"was_maximized": false, "client": true}
		_apply_cursor(Input.CURSOR_MOVE)
	else:
		chrome_drag = {"id": id, "kind": "resize", "edge": edge,
			"start": fr, "from": Vector2(m), "was_maximized": false, "client": true}
		_apply_cursor(_cursor_for_part(edge))
	window_dragging = true
	request_redraw()


# id de la ventana flotante más arriba que contiene `pos` (chrome o contenido).
func _window_at(pos):
	for id in _hit_order_ids():
		if id == fullscreen_id or minimized.has(id) or not tiles.has(id):
			continue
		if not hybrid.is_floating(id):
			continue
		var fr = window_rects.get(id, null)
		if fr != null and Rect2(fr).has_point(pos):
			return id
	return -1


# Super+clic: mover (izquierdo) o redimensionar (derecho, desde la esquina más cercana)
# la ventana bajo el puntero, sin reenviar el clic a la app. Una tiled pasa a flotante
# y sigue al puntero desde el primer motion.
func _begin_super_drag(pos, button):
	var hit = _view_hit_test(pos)
	var probe = int(hit.id)
	var was_tiled = probe >= 0 and tiles.has(probe) and hybrid.is_tiled(probe)
	var id = -1
	var old_rect = null
	if was_tiled:
		if button != BUTTON_LEFT:
			return false
		id = probe
		old_rect = tile_rects.get(id, null)
	else:
		id = _window_at(pos)
	if id < 0:
		return false
	# Estado maximizado (flotante wm_maximized o tiled maximize_state): al comenzar
	# el arrastre se desmaximiza. Ningún flag puede quedar stale.
	var was_max = wm_maximized.has(id) or maximize_state.has(id)
	# El drag es del shell: que frame.gd no interprete la suelta de Super como un
	# toque (abriría exposé) ni mande Super a la app al soltar el botón.
	if frame != null:
		frame.super_press = null
	if was_tiled:
		# La ventana agarrada pasa a flotante y debe seguir al puntero desde el primer
		# motion: sin transición global.
		set_window_mode(id, WM_HYBRID.FLOATING)
		wm_anim.clear()
		wm_switch_until = -1
	elif was_max:
		wm_maximized.erase(id)
		maximize_state.erase(id)
	var box = wm_box if wm_box.size.x > 0.0 else _tile_rect(get_viewport_rect().size)
	if not float_layout.has(id):
		# Restaura el rect previo si lo recordamos (tamaño anterior, no una cascada);
		# si no, cascada nueva (~74% del área).
		if float_memory.has(id) and float_memory[id] != null:
			float_layout.restore_one(id, float_memory[id], box)
		else:
			float_layout.place_new(id, box)
	_focus_tile(id)
	# Tras desprender del mosaico (o desmaximizar) window_rects aún describe el
	# frame anterior; la geometría autoritativa ya está materializada en float_layout.
	var fr = float_layout.rect(id) if (was_tiled or was_max) else window_rects.get(id, box)
	if fr == null:
		fr = box
	if button == BUTTON_LEFT:
		var grab = pos - fr.position
		if was_tiled or was_max:
			# Puntero proporcional: la fracción bajo el cursor en el rect grande
			# (maximizado/celda) se conserva en el rect restaurado más chico.
			var src = Rect2(old_rect) if old_rect != null else Rect2(window_rects.get(id, box))
			grab = WM_DRAG.proportional_grab(pos - src.position, src.size, fr.size)
			float_layout.drag_to(id, pos - grab, box)
		chrome_drag = {"id": id, "kind": "move", "grab": grab,
			"was_maximized": false, "super": true, "button": button}
		_apply_cursor(Input.CURSOR_MOVE)
	else:
		var zone = WM_DRAG.quadrant_zone(pos, fr)
		chrome_drag = {"id": id, "kind": "resize", "edge": zone, "start": fr, "from": pos,
			"was_maximized": false, "super": true, "button": button}
		_apply_cursor(_cursor_for_part(zone))
	window_dragging = true
	request_redraw()
	return true


func _add_dialog(id):
	if not dialogs.has(id):
		dialogs.append(id)
	focused_dialog = id
	compositor.focus(id)


# Toplevels sueltos: nombre = app_id capitalizado sin dominio, si no el titulo,
# si no "Ventana <id>". Se crea la actividad, se le asigna el id y se abre
# (una ventana nueva pasa al frente). El nombre debe ser unico en el anillo.
func _process_unmanaged():
	for i in range(unmanaged.size() - 1, -1, -1):
		var id = unmanaged[i]
		if not _id_alive(id):
			unmanaged.remove(i)
			unmanaged_since.erase(id)
			continue
		# El padre llega en el commit inicial, despues de `added`: si aparecio,
		# es un dialogo, no una actividad dinamica. Los dialogos de otro proceso
		# (portal) pueden declararlo (xdg-foreign) un frame despues: se espera
		# una gracia corta antes de decidir que es una ventana suelta.
		if compositor.get_parent_id(id) > 0:
			unmanaged.remove(i)
			unmanaged_since.erase(id)
			_add_dialog(id)
			continue
		var app_id = compositor.get_app_id(id)
		var title = compositor.get_title(id)
		if app_id == "" and title == "":
			continue
		if OS.get_ticks_msec() - int(unmanaged_since.get(id, 0)) < DIALOG_GRACE_MS:
			continue
		unmanaged.remove(i)
		unmanaged_since.erase(id)
		if _activity_for_window(id) != "":
			continue
		_open_unmanaged_window(id)


func _open_unmanaged_window(id):
	var name = _unique_activity_name(_window_activity_name(id))
	var cmd = compositor.get_app_id(id)
	if cmd == "":
		cmd = name
	var activity = {"name": name, "wayland": [cmd], "dynamic": true}
	ACTIVITIES.append(activity)
	wayland_ids[name] = id

	var vp = get_viewport_rect().size
	view.rect_position = Vector2.ZERO
	view.rect_size = vp
	view.rect_clip_content = true
	compositor.default_size = _tile_rect(vp).size

	current_activity = activity
	activity_instance = null
	activity_error = ""
	_pending_clear()
	_add_tile(id)
	_focus_tile(id)
	print("actividad dinamica ", name, " para toplevel ", id)


# Ancla flotante del escritorio virtual actual: el líder de la pantalla centrada
# (o el Escritorio si estamos en el Hogar / no hay mosaico). Así una ventana nueva
# nace en la pantalla actual en vez de en una nueva.
func _current_float_anchor():
	if _at_home():
		return WM_HYBRID.ESCRITORIO
	var units = _units()
	var i = _focused_unit_index(units)
	if i <= 0 or i >= units.size():
		return WM_HYBRID.ESCRITORIO
	var members = units[i]
	return int(members[0]) if not members.empty() else WM_HYBRID.ESCRITORIO


func _add_tile(id, origin_name = ""):
	if not tiles.has(id):
		# La nueva flotante se ancla al escritorio virtual en pantalla.
		if hybrid.is_floating(id):
			hybrid.set_floating(id, _current_float_anchor())
		tiles.append(id)
		tile_intro[id] = _new_intro(false, origin_name)
	request_redraw()


# Guarda el rect (coords de vista) del ícono que lanzó la actividad `name`. Se usa al
# mapear su ventana para la entrada genie; expira a los pocos segundos.
func _remember_origin(name, rect):
	if String(name) == "" or rect == null:
		return
	launch_origins[String(name)] = {"rect": Rect2(rect), "since": OS.get_ticks_msec()}
	for k in launch_origins.keys():
		if OS.get_ticks_msec() - int(launch_origins[k].since) > LAUNCH_ORIGIN_MS:
			launch_origins.erase(k)


# Origen recordado para `name` (lo consume), o null si no hay o venció.
func _take_origin(name):
	var key = String(name)
	var o = launch_origins.get(key, null)
	launch_origins.erase(key)
	if o != null and OS.get_ticks_msec() - int(o.since) <= LAUNCH_ORIGIN_MS:
		return o.rect
	return null


# Origen pendiente global (fallback cuando la ventana no se pudo mapear a un nombre).
func _consume_pending_origin():
	var from = null
	if pending_origin != null and OS.get_ticks_msec() - pending_origin_since < LAUNCH_ORIGIN_MS:
		from = pending_origin
	pending_origin = null
	return from


# Entrada animada: si hay un ícono de origen reciente (el de su actividad mapada o el
# último pendiente) escala desde él; si no, genie desde el centro del rect final con
# fade (ver EXPOSE_LAYOUT.intro_from). `ready` pasa a true con la primera textura.
# `scale_in`: crece en su lugar (desminimizar), sin traslación.
func _new_intro(scale_in = false, origin_name = ""):
	var from = null
	if not scale_in:
		from = _take_origin(origin_name)
		if from != null:
			pending_origin = null  # el pendiente global ya se usó (match por nombre)
		else:
			from = _consume_pending_origin()
	return {"from": from, "since": OS.get_ticks_msec(), "ready": false, "rect": Rect2(), "scale_in": scale_in}


func _activity_for_window(id):
	for name in wayland_ids.keys():
		if wayland_ids[name] == id:
			return name
	return ""


func _window_activity_name(id):
	var app_id = compositor.get_app_id(id)
	if app_id != "":
		var base = app_id
		var dot = base.rfind(".")
		if dot >= 0:
			base = base.substr(dot + 1, base.length() - dot - 1)
		if base != "":
			return base.substr(0, 1).to_upper() + base.substr(1, base.length() - 1)
	var title = compositor.get_title(id)
	if title != "":
		return title
	return "Ventana " + str(id)


func _unique_activity_name(name):
	var candidate = name
	var n = 2
	while _activity_named(candidate) >= 0:
		candidate = name + " " + str(n)
		n += 1
	return candidate


func _activity_named(name):
	for i in range(ACTIVITIES.size()):
		if str(ACTIVITIES[i].get("name", "")) == name:
			return i
	return -1


func _on_toplevel_removed(id):
	print("toplevel_removed ", id)
	var didx = dialogs.find(id)
	if didx >= 0:
		dialogs.remove(didx)
		if dialog_boxes.has(id):
			var box = dialog_boxes[id]
			dialog_boxes.erase(id)
			if box != null and is_instance_valid(box):
				box.queue_free()
		if focused_dialog == id:
			_refocus_dialog()
		return

	unmanaged.erase(id)
	unmanaged_since.erase(id)
	var removed_name = ""
	for name in wayland_ids.keys():
		if wayland_ids[name] == id:
			removed_name = name
			wayland_ids.erase(name)
			break
	if removed_name == "":
		return
	starting.erase(removed_name)
	# Las actividades dinamicas se van con su ventana; las fijas quedan.
	var index = _activity_named(removed_name)
	if index >= 0 and ACTIVITIES[index].get("dynamic", false):
		ACTIVITIES.remove(index)
	# Sale de las pantallas: congela su cuadro para la animación de cierre, limpia
	# grupo/minimizado y, si era la enfocada y no estamos en una actividad de script,
	# pasa el foco al vecino.
	var had_tile = tiles.has(id)
	if had_tile:
		_spawn_ghost(id, _panel_rect_for(id))
	if fullscreen_id == id:
		fullscreen_id = -1
	_remove_from_group(id)
	maximize_state.erase(id)
	wm_maximized.erase(id)
	if chrome_drag != null and int(chrome_drag.id) == id:
		chrome_drag = null
		drag_overlay = null
		window_dragging = false
	float_memory.erase(id)
	hybrid.forget(id)
	float_layout.remove(id)
	wm_anim.erase(id)
	minimized.erase(id)
	unit_focus.erase(id)
	tiles.erase(id)
	if had_tile:
		request_redraw()
	var script_active = current_activity != null and not current_activity.has("wayland")
	if focused_tile == id:
		focused_tile = -1
		if not script_active:
			if tiles.empty():
				_go_home()
			else:
				_focus_tile(tiles[tiles.size() - 1])
	elif not script_active and current_activity != null and current_activity.name == removed_name:
		if tiles.empty():
			_go_home()
		else:
			_focus_tile(tiles[tiles.size() - 1])


# Al cerrarse un dialogo el foco vuelve al que quede arriba: otro dialogo o la raiz.
func _refocus_dialog():
	focused_dialog = 0
	var root = _current_wayland_id()
	for i in range(dialogs.size() - 1, -1, -1):
		if _root_of(dialogs[i]) == root:
			focused_dialog = dialogs[i]
			break
	if focused_dialog > 0:
		compositor.focus(focused_dialog)
	elif root >= 0:
		compositor.focus(root)


# Entrada del exposé (mouse): hover del botón cerrar, press para levantar la
# miniatura, motion para el fantasma y el resaltado del destino, release para
# moverla de escritorio (o seleccionar/salir si no hubo movimiento). Nunca
# reenvía a la app: el exposé es dueño total del mouse.
func _on_expose_input(event):
	# Zoom out del escritorio: hover para el botón de cerrar; arrastrar una
	# miniatura entre escritorios; clic para elegirla; clic en la X para cerrar.
	if event is InputEventMouseMotion:
		if expose_drag != null:
			var d = expose_drag
			d["pos"] = event.position
			if not d.moved and event.position.distance_to(d.from) > EXPOSE_DRAG_PX:
				d["moved"] = true
			if d.moved:
				# El hueco (barra de inserción) gana sobre la tarjeta: son zonas
				# excluyentes, pero el hueco puede invadir unos px si el gap es chico.
				expose_drag_gap = _expose_gap_at(event.position)
				expose_drag_target = -1 if expose_drag_gap >= 0 else _expose_unit_at(event.position)
			request_redraw()
			return
		var over = _expose_hit(event.position)
		if over != expose_hover:
			expose_hover = over
			request_redraw()
		return
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			var cid = _expose_close_hit(event.position)
			if cid >= 0:
				_close_window_id(cid)
				expose_hover = -1
				return
			var hit = _expose_hit(event.position)
			if hit >= 0:
				expose_sel = tiles.find(hit)
				var card = expose_cards.get(hit)
				expose_drag = {"id": hit, "from": event.position,
					"grab": event.position - card.position if card != null else Vector2.ZERO,
					"pos": event.position, "moved": false}
				expose_drag_target = -1
				expose_drag_gap = -1
				request_redraw()
			return
		if expose_drag != null:
			var d = expose_drag
			expose_drag = null
			expose_drag_target = -1
			expose_drag_gap = -1
			if d.moved:
				var gap = _expose_gap_at(event.position)
				if gap >= 0:
					_expose_insert(int(d.id), gap)
				else:
					var target = _expose_unit_at(event.position)
					if target >= 0:
						_expose_drop(int(d.id), target)
					else:
						request_redraw()
			else:
				_expose_commit()
			return
	return


func _on_view_input(event):
	# El exposé se atiende ANTES de los guards de pointer-lock y captura remota: si
	# un cliente quedó con lock (o Deskflow captura), esos caminos se tragaban el
	# press/motion/drop y el arrastre entre escritorios nunca arrancaba.
	if expose:
		_on_expose_input(event)
		return
	if client_pointer_locked:
		# El lock del cliente ya consume el mouse en _input (CaptureInput).
		return
	if _capture_remote_input_event(event):
		return
	# K13: en modo flotante, la barra de título y los botones de la ventana se
	# resuelven antes que el contenido del cliente (y antes del arrastre al Frame).
	if _on_chrome_input(event):
		return
	if window_dragging:
		return
	# Deskflow se resolvió arriba y tiene prioridad. Si no capturó, una Pantalla
	# compartida recibe input de retorno sin entregárselo al reproductor gvd local.
	if _window_input_pointer(event):
		get_tree().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		last_pointer_pos = event.position
		_sync_drag_icon()
		var hit = _view_hit_test(event.position)
		hover_handle = _handle_at(event.position) if resize_handle == null else null
		# UNA decisión de cursor por motion: sobre una app, el que ella pidió; si no,
		# flecha. Godot inyecta un motion falso en cada cambio de forma, así que dos
		# caminos que se pisaban (app -> flecha -> app...) colgaban el shell.
		if hit.id >= 0 and resize_handle == null and hover_handle == null:
			_apply_client_cursor()
		else:
			_reset_cursor()
		# Asa de redimensión de la franja: primero la arrastra, después sólo la insinúa.
		if resize_handle != null:
			_resize_to(resize_handle, event.position.x)
			request_redraw()
			return
		if hover_handle != null:
			request_redraw()
			return
		if hit.id < 0:
			# Drag nativo sobre el escritorio: limpiar el foco para que el drop no
			# caiga en la última ventana; el botón que cierre el drag llega abajo.
			if client_drag_active:
				compositor.pointer_clear_focus()
			return
		_focus_follow(hit)
		compositor.pointer_motion(hit.id, hit.pos)
	elif event is InputEventMouseButton:
		# Super+clic: mover (izquierdo) o redimensionar (derecho) la ventana bajo el
		# puntero, sin reenviar el clic a la app. Sirve también para CSD.
		if (event.button_index == BUTTON_LEFT or event.button_index == BUTTON_RIGHT):
			if event.pressed:
				if _super_held(event) and chrome_drag == null and not expose:
					if _begin_super_drag(event.position, event.button_index):
						return
			elif chrome_drag != null and bool(chrome_drag.get("super", false)):
				# Commit aunque Super ya se haya soltado: si no, el drag quedaría colgado.
				_commit_chrome_drag()
				return
		# Con Super la rueda es para el shell (cambiar de workspace), no para la app.
		if (event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN) \
				and _super_held(event):
			return
		if event.pressed and event.button_index == BUTTON_LEFT:
			var h = _handle_at(event.position)
			if h != null:
				resize_handle = h
				hover_handle = h
				request_redraw()
				return
		elif not event.pressed and resize_handle != null:
			resize_handle = null
			request_redraw()
			return
		var hit = _view_hit_test(event.position)
		if hit.id < 0:
			# Soltar el botón sobre el escritorio termina/cancela el drag nativo
			# aunque no haya ventana bajo el puntero.
			if client_drag_active:
				compositor.pointer_button(event.button_index, event.pressed)
			return
		compositor.pointer_motion(hit.id, hit.pos)
		compositor.pointer_button(event.button_index, event.pressed)
		if event.pressed:
			if hit.dialog > 0:
				compositor.focus(hit.id)
				focused_dialog = hit.dialog
			else:
				focused_dialog = 0
				_focus_tile(hit.id)
	elif event is InputEventPanGesture:
		# Pan continuo (touchpad): sólo si el puntero está sobre una ventana cliente.
		# El backend FRT/SDL hoy manda BUTTON_WHEEL_LEFT/RIGHT (wheel.x) en lugar de
		# este evento, pero si el motor pasa a emitir gestures hay que reenviarlo como
		# axis (el evento queda marcado como manejado por el Viewport si no lo hacemos).
		if event.device == SCROLL_STOP_DEVICE:
			_forward_pan(event)  # el fin del scroll va aunque el puntero ya salió
			return
		if event.delta == Vector2.ZERO:
			return
		var pan_hit = _view_hit_test(event.position)
		if pan_hit.id < 0:
			return
		_forward_pan(event)
		return


# --- K13: input del chrome flotante ------------------------------------------

# Menú contextual de la ventana (clic derecho en su barra de título): cambiar entre
# Flotante/Mosaico, maximizar/restaurar y cerrar. El modo se cambia por ventana.
func _draw_window_menu():
	if wm_menu_want:
		open_popup("##wm_menu")
		wm_menu_want = false
	if wm_menu_id < 0:
		return
	MENU_STYLE.begin(self)
	if begin_popup("##wm_menu"):
		var id = wm_menu_id
		if not tiles.has(id):
			end_popup()
		else:
			MENU_STYLE.chrome(self, "Ventana")
			var fl = hybrid.is_floating(id)
			var chosen = ""
			if MENU_STYLE.item(self, "Flotante", "", fl):
				chosen = WM_HYBRID.FLOATING
			if MENU_STYLE.item(self, "Mosaico", "", not fl):
				chosen = WM_HYBRID.TILED
			separator()
			if MENU_STYLE.item(self, "Restaurar" if (wm_maximized.has(id) or maximize_state.has(id)) else "Maximizar"):
				_toggle_maximize_window(id)
			if MENU_STYLE.item(self, "Cerrar"):
				_close_window_id(id)
			end_popup()
			if chosen != "":
				set_window_mode(id, chosen)
				wm_menu_id = -1
	MENU_STYLE.end(self)


# Resuelve la barra de título/botones/bordes de las ventanas flotantes. Devuelve
# true si el evento se consumió (no debe llegar al cliente).
func _on_chrome_input(event):
	if event is InputEventMouseMotion:
		if chrome_drag != null:
			_chrome_drag_motion(event.position)
			return true
		_update_csd_hover(event.position)
		var pick = _chrome_pick(event.position)
		if pick != null:
			_apply_cursor(_cursor_for_part(pick.part))
		# Sin chrome debajo decide _on_view_input (una sola vez por motion).
		return pick != null
	if event is InputEventMouseButton and event.button_index == BUTTON_RIGHT and event.pressed:
		# Menú contextual de la barra de título (cambio de modo, maximizar, cerrar).
		var rpick = _chrome_pick(event.position)
		if rpick != null and (String(rpick.part) == "title" or String(rpick.part) == "grip"):
			_focus_tile(int(rpick.id))
			wm_menu_id = int(rpick.id)
			wm_menu_want = true
			request_redraw()
			return true
		return false
	if not (event is InputEventMouseButton) or event.button_index != BUTTON_LEFT:
		return false
	if not event.pressed:
		var was_dragging = chrome_drag != null
		if was_dragging:
			_commit_chrome_drag()
		return was_dragging
	var pick = _chrome_pick(event.position)
	if pick == null:
		return false
	var id = int(pick.id)
	var part = String(pick.part)
	if part == "min":
		chrome_drag = {"id": id, "kind": "press"}
		_minimize_window(id)
		return true
	if part == "close":
		chrome_drag = {"id": id, "kind": "press"}
		_close_window_id(id)
		return true
	var box = wm_box if wm_box.size.x > 0.0 else _tile_rect(get_viewport_rect().size)
	if part == "title" or part == "grip":
		# Doble clic en la barra: maximizar/restaurar. Un clic simple enfoca y prepara
		# el arrastre; NO desmaximiza por sí solo (eso destrozaba la geometría y hacía
		# que el doble clic de restaurar no tuviera efecto). Desmaximizar sucede recién
		# cuando el arrastre mueve la ventana (ver _chrome_drag_motion).
		var now = OS.get_ticks_msec()
		var dbl = (part == "title" or part == "grip") and int(_wm_last_title_click.id) == id and now - int(_wm_last_title_click.at) < 350
		_wm_last_title_click = {"id": id, "at": now}
		if dbl:
			_wm_last_title_click = {"id": -1, "at": 0}
			_toggle_maximize_window(id)
			return true
		if not float_layout.has(id):
			float_layout.place_new(id, box)
		_focus_tile(id)
		var fr = window_rects.get(id, box)
		chrome_drag = {"id": id, "kind": "move", "grab": event.position - fr.position,
			"was_maximized": wm_maximized.has(id) or maximize_state.has(id)}
		window_dragging = true
		_apply_cursor(Input.CURSOR_MOVE)
		request_redraw()
		return true
	if WINDOW_CHROME.is_edge(part):
		if not float_layout.has(id):
			float_layout.place_new(id, box)
		_focus_tile(id)
		chrome_drag = {"id": id, "kind": "resize", "edge": part,
			"start": window_rects.get(id, box), "from": event.position}
		window_dragging = true
		_apply_cursor(_cursor_for_part(part))
		request_redraw()
		return true
	return false


# Forma del cursor según la zona del chrome (esquinas y bordes redimensionan).
func _cursor_for_part(part):
	match String(part):
		"left", "right":
			return Input.CURSOR_HSIZE
		"top", "bottom":
			return Input.CURSOR_VSIZE
		"tl", "br":
			return Input.CURSOR_FDIAGSIZE
		"tr", "bl":
			return Input.CURSOR_BDIAGSIZE
		"title", "grip":
			return Input.CURSOR_MOVE
		_:
			return Input.CURSOR_ARROW


# Aplica la forma del cursor. Además del default global, hay que fijarla en el
# Control que está bajo el puntero (`view`): el Viewport resuelve la forma desde el
# Control hovereado, así que `Input.set_default_cursor_shape` solo no alcanza.
func _apply_cursor(shape):
	Input.set_default_cursor_shape(shape)
	if view != null and is_instance_valid(view):
		view.mouse_default_cursor_shape = shape


# Cursor por defecto según lo que haya bajo `pos` (o flecha si no hay chrome).
# Cursor pedido por la app con foco de puntero: forma de Godot o imagen propia.
func _on_client_cursor_shape(shape):
	if int(shape) != client_cursor_shape or client_cursor_tex != null:
		if debug_input:
			print("[cursor] forma de la app: ", int(shape))
	client_cursor_shape = int(shape)
	client_cursor_tex = null
	_apply_client_cursor()


func _on_client_cursor_image(img, hotspot):
	if img == null or img.is_empty():
		return
	# Diagnóstico: una imagen totalmente transparente deja el puntero invisible sobre la app.
	var amax = 0.0
	img.lock()
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			amax = max(amax, img.get_pixel(x, y).a)
	img.unlock()
	if debug_input:
		print("[cursor] imagen de la app ", img.get_width(), "x", img.get_height(), " hotspot ", hotspot, " alfa_max ", stepify(amax, 0.01))
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	client_cursor_tex = tex
	client_cursor_hot = hotspot
	_apply_client_cursor()


# Aplica el cursor de la app sólo si cambió (crear un cursor de SDL por cada
# movimiento sería caro). La imagen va como cursor custom de la forma ARROW.
func _apply_client_cursor():
	var key = client_cursor_tex if client_cursor_tex != null else client_cursor_shape
	if key == _client_cursor_applied:
		return
	_client_cursor_applied = key
	if client_cursor_tex != null:
		Input.set_custom_mouse_cursor(client_cursor_tex, Input.CURSOR_ARROW, client_cursor_hot)
		_apply_cursor(Input.CURSOR_ARROW)
	else:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_apply_cursor(client_cursor_shape)


func _reset_cursor(pos = null):
	# Fuera del contenido de la app no debe quedar su imagen como flecha del shell.
	if _client_cursor_applied != null:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
		_client_cursor_applied = null
	if pos != null:
		var pick = _chrome_pick(pos)
		_apply_cursor(_cursor_for_part(pick.part if pick != null else ""))
	else:
		_apply_cursor(Input.CURSOR_ARROW)


# ¿Está Super (Meta) apretado? En Linux el evento llega como KEY_META, pero el
# estado físico puede reportarse como KEY_SUPER_L/R según el backend: se chequean
# los tres (frame.gd usa el mismo conjunto en SUPER_KEYS).
func _super_held(event = null):
	var event_meta = event != null and bool(event.meta)
	return WM_DRAG.super_active(event_meta, Input.is_key_pressed(KEY_META),
		Input.is_key_pressed(KEY_SUPER_L), Input.is_key_pressed(KEY_SUPER_R))


# Cierra un arrastre de chrome/cliente. El resize no tocó la ventana real durante
# el motion (sólo dibujó drag_overlay): recién ahora se aplica la geometría, un
# único set_size. El move ya fue en vivo (mover no reasigna buffer del cliente).
func _commit_chrome_drag():
	if chrome_drag == null:
		return
	var id = int(chrome_drag.id)
	if String(chrome_drag.kind) == "resize" and drag_overlay != null and tiles.has(id):
		var box = wm_box if wm_box.size.x > 0.0 else _tile_rect(get_viewport_rect().size)
		float_layout.resize_to(id, drag_overlay.rect, box)
		_pantalla_snap_aspect(id, box)
	# K13f — Snap flotante: si el drop quedó en una franja del borde, la ventana toma
	# esa mitad o se maximiza arriba. Un único set de geometría al soltar (igual que
	# el resize diferido), reusando el convenio de maximizar de flotante.
	elif String(chrome_drag.kind) == "move" and drag_overlay != null \
			and String(drag_overlay.get("kind", "")) == "snap" and tiles.has(id):
		var zone = String(drag_overlay.get("zone", ""))
		var target = String(drag_overlay.get("target", "float-half"))
		if zone == "max" or target == "maximize":
			_maximize_window(id)
		elif target == "tile-half":
			_snap_tile_to(id, zone)
		elif zone == "left" or zone == "right":
			var box = wm_box if wm_box.size.x > 0.0 else _tile_rect(get_viewport_rect().size)
			wm_maximized.erase(id)
			if not float_layout.has(id):
				float_layout.place_new(id, box)
			float_layout.resize_to(id, drag_overlay.rect, box)
			float_layout.raise(id)
			_focus_tile(id)
			_maybe_fuse_snapped_floats(id)
	chrome_drag = null
	drag_overlay = null
	window_dragging = false
	instant_switch = true
	_reset_cursor()
	request_redraw()


func _chrome_drag_motion(pos):
	if chrome_drag == null:
		return
	var id = int(chrome_drag.id)
	if not tiles.has(id):
		chrome_drag = null
		drag_overlay = null
		window_dragging = false
		return
	var box = wm_box if wm_box.size.x > 0.0 else _tile_rect(get_viewport_rect().size)
	var kind = String(chrome_drag.kind)
	if kind != "move" and kind != "resize":
		return
	if kind == "move":
		if bool(chrome_drag.get("was_maximized", false)):
			# Desmaximizar al arrastrar: la ventana vuelve a su rect flotante
			# recordado (float_layout lo conservó) y sigue al puntero con la misma
			# fracción (x e y) bajo el cursor. Se limpian ambos flags.
			wm_maximized.erase(id)
			maximize_state.erase(id)
			chrome_drag["was_maximized"] = false
			var big = Rect2(window_rects.get(id, box))
			var restored = float_layout.rect(id)
			if restored != null:
				chrome_drag["grab"] = WM_DRAG.proportional_grab(
					Vector2(chrome_drag.grab), big.size, restored.size)
		float_layout.drag_to(id, pos - chrome_drag.grab, box)
		# Reflejar el modelo en el nodo visible en este mismo evento. Si esperamos al
		# siguiente ciclo de layout, la decoración/título alcanza a viajar sola antes
		# que la textura de la ventana y el gesto se percibe como un label flotante.
		_apply_live_float_move(id, float_layout.rect(id))
		# K13f/K13i — Snap contextual con histéresis: cerca del borde del hueco se
		# ofrece una mitad (izquierda/derecha) o maximizar (franja superior). Si la
		# pantalla centrada ya tiene mosaico, la mitad inserta en mosaico; si no,
		# redimensiona la flotante. La aplicación sucede al soltar (_commit_chrome_drag).
		var thr = WM_DRAG.EDGE_SNAP * get_imgui_scale()
		var zone = WM_DRAG.zone_hold(String(chrome_drag.get("zone", "")), pos, box, thr)
		chrome_drag["zone"] = zone
		if zone == "":
			if drag_overlay != null and String(drag_overlay.get("kind", "")) == "snap":
				drag_overlay = null
		else:
			var target = "maximize" if zone == "max" else ("tile-half" if _centered_unit_has_tiled() else "float-half")
			drag_overlay = {"id": id, "kind": "snap", "zone": zone, "target": target,
				"rect": box if zone == "max" else WM_DRAG.snap_rect(zone, box)}
	else:
		# Resize diferido: NO se redimensiona la ventana real en cada motion (eso
		# dispara un set_size/buffer nuevo por frame y se siente el lag). Se guarda
		# la geometría objetivo y se dibuja un overlay; se aplica al soltar.
		var nr = WINDOW_CHROME.resized(chrome_drag.start, String(chrome_drag.edge), pos - chrome_drag.from)
		drag_overlay = {"id": id, "kind": "resize", "rect": float_layout.clamp_rect(box, nr)}
		_apply_cursor(_cursor_for_part(String(chrome_drag.edge)))
	# Durante el arrastre la ventana debe seguir al puntero 1:1, sin la animación
	# de reacomodo (que haría un efecto elástico).
	instant_switch = true
	request_redraw()


# Aplica sólo la traslación de una ventana flotante; nunca cambia el tamaño del
# surface ni solicita un buffer al cliente. El layout normal reafirma estos rects
# en el siguiente frame, pero el motion queda visualmente sincronizado 1:1.
func _apply_live_float_move(id, frame_rect):
	if frame_rect == null:
		return
	var fr = Rect2(frame_rect)
	window_rects[id] = fr
	var content = fr
	if not _is_csd(id):
		content = WINDOW_CHROME.content_rect(fr, _chrome_title_h(), _chrome_border(),
			_chrome_resize_h())
	tile_rects[id] = content
	var node = tile_nodes.get(id)
	if node != null and is_instance_valid(node):
		tile_anim.erase(id)
		node.rect_position = content.position
		node.rect_scale = Vector2.ONE
	var deco = deco_nodes.get(id)
	if deco != null and is_instance_valid(deco):
		deco.update()


# Lazy focus follows mouse: al mover el puntero sobre otra ventana (o su diálogo)
# se le da el foco; no reenfoca la misma ni restaura una minimizada. Sólo se llama
# con movimiento real del puntero (ver _on_view_input), nunca al abrir una ventana
# bajo un cursor quieto. La decisión vive en focus_follow.gd (puro, testeable).
func _focus_follow(hit):
	var d = FOCUS_FOLLOW.decide(focused_tile, focused_dialog, hit.id, hit.dialog, minimized.has(hit.id))
	if int(d.target) < 0:
		return
	if int(d.dialog) > 0:
		focused_dialog = int(d.dialog)
		_compositor_focus(int(d.dialog), false)
		request_redraw()
	else:
		focused_dialog = 0
		_focus_tile(int(d.target), false)


# --- Drag and drop nativo (wl_data_device) ---
# El icono lo compone el compositor. Se dibuja como TextureRect en una CanvasLayer
# alta (no hijo de `view`: así queda encima de tiles, decoración, exposé e ImGui y
# no lo oculta view.visible). Si el cliente no manda textura legible (p.ej. dmabuf)
# se muestra un placeholder para no perder el feedback. El cursor real lo dibuja
# el compositor anfitrión.
const DRAG_ICON_MAX = 160.0


func _on_drag_icon_changed():
	if compositor == null or not compositor.has_method("get_drag_icon_texture"):
		return
	drag_icon_tex = compositor.get_drag_icon_texture()
	if drag_icon_tex != null:
		print("[drag-icon] textura ", drag_icon_tex.get_size())
	else:
		print("[drag-icon] sin textura (placeholder)")
	_sync_drag_icon()
	request_redraw()


func _on_drag_state_changed(active):
	client_drag_active = active
	if not active:
		drag_icon_tex = null
	drag_icon_samples = 0
	print("[drag-icon] drag ", "activo" if active else "terminado")
	_sync_drag_icon()
	request_redraw()


# Placeholder opaco con borde de acento: un buffer dmabuf/GL no se puede leer
# desde CPU, así que al menos se muestra algo siguiendo al puntero.
func _drag_placeholder_texture():
	if drag_placeholder_tex != null:
		return drag_placeholder_tex
	var s = 24
	var img = Image.new()
	img.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.12, 0.16, 0.22, 0.94))
	var edge = Color(0.55, 0.80, 1.0, 0.98)
	img.lock()
	for i in range(s):
		img.set_pixel(i, 0, edge)
		img.set_pixel(i, s - 1, edge)
		img.set_pixel(0, i, edge)
		img.set_pixel(s - 1, i, edge)
	img.unlock()
	var t = ImageTexture.new()
	t.create_from_image(img, 0)
	drag_placeholder_tex = t
	return t


func _sync_drag_icon():
	if not client_drag_active:
		if drag_icon_node != null and is_instance_valid(drag_icon_node):
			drag_icon_node.visible = false
		return
	var pos = last_pointer_pos
	if pos == null:
		pos = get_viewport().get_mouse_position()
	if pos == null:
		return
	if drag_icon_node == null or not is_instance_valid(drag_icon_node):
		drag_icon_node = TextureRect.new()
		drag_icon_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		drag_icon_node.expand = true
		drag_icon_node.stretch_mode = TextureRect.STRETCH_SCALE
		_ensure_premult_material()
		drag_icon_node.material = premult_material
		drag_icon_node.visible = false
		if drag_layer == null or not is_instance_valid(drag_layer):
			drag_layer = CanvasLayer.new()
			drag_layer.layer = 100
			add_child(drag_layer)
		drag_layer.add_child(drag_icon_node)
	var tex = drag_icon_tex
	if tex == null:
		tex = _drag_placeholder_texture()
	var off = Vector2.ZERO
	if compositor != null and compositor.has_method("get_drag_icon_offset"):
		off = compositor.get_drag_icon_offset()
	var r = DRAG_ICON.icon_rect(pos, DRAG_ICON.clamp_size(tex.get_size(), DRAG_ICON_MAX), off)
	drag_icon_node.texture = tex
	drag_icon_node.rect_size = r.size
	drag_icon_node.rect_position = r.position
	drag_icon_node.visible = true
	if drag_icon_samples < 20:
		drag_icon_samples += 1
		print("[drag-icon] muestra ", drag_icon_samples, " pos=", r.position,
			" size=", r.size, " tex=", ("icono" if drag_icon_tex != null else "placeholder"),
			" view=", (view.visible if view != null else false))


# Hit-test de arriba hacia abajo: el dialogo mas reciente que contenga el puntero; si no,
# el tile bajo el puntero (cada ventana tiene su rect). En exposé, la tarjeta.
func _view_hit_test(pos):
	if expose:
		var id = _expose_hit(pos)
		if id >= 0:
			expose_sel = tiles.find(id)
			request_redraw()
			return {"id": id, "pos": Vector2.ZERO, "dialog": 0}
		return {"id": -1, "pos": Vector2.ZERO, "dialog": 0}
	var cur_root = _current_wayland_id()
	for i in range(dialogs.size() - 1, -1, -1):
		var d = dialogs[i]
		# Un diálogo de otra raíz está oculto (_update_dialogs): no captura input. Si
		# no, su rect fantasma (raíz fuera de vista, clamp) se comía clics y drops.
		if cur_root < 0 or _root_of(d) != cur_root:
			continue
		var rect = _dialog_rect(d)
		if rect.has_point(pos):
			# El compositor espera coords del buffer: la caja alinea la geometry en
			# rect.position, así que se suma geo.position.
			return {"id": d, "pos": pos - rect.position + _dialog_geo(d).position, "dialog": d}
	for id in _hit_order_ids():
		var r = tile_rects.get(id)
		if r == null:
			continue
		var fit = tile_fit.get(id)
		var geo = compositor.get_geometry(id)
		# El contenido se dibuja en coords del buffer + offset; el compositor espera
		# coords del buffer, así que alcanza con deshacer el offset (d - offset).
		var content = r
		if fit != null and fit.scale > 0.0:
			content = Rect2(r.position + geo.position * fit.scale + fit.offset, geo.size * fit.scale)
		if not content.has_point(pos) and fit != null and fit.scale > 0.0 and _popup_layer_hit(id, r, fit, pos):
			content = Rect2(pos, Vector2.ONE)  # cae en un popup que sobresale de la ventana
		if content.has_point(pos):
			if fit != null and fit.scale > 0.0:
				return {"id": id, "pos": (pos - r.position - fit.offset) / fit.scale, "dialog": 0}
			return {"id": id, "pos": pos - r.position + geo.position, "dialog": 0}
	return {"id": -1, "pos": Vector2.ZERO, "dialog": 0}


# Teclear en el Home lleva a la búsqueda de apps.
# En _input (Godot 3 lo llama también en ImGuiCanvas): con el puntero sobre el
# home ImGui marca todo como manejado y a _unhandled_input no llega nada.
func _set_capture_cursor(active):
	var entering = active and not mouse_locked
	# ImGuiCanvas encola botones directamente en su _input nativo; marcar el evento
	# como handled no los retira. Durante la captura lo apagamos por completo. El
	# hijo CaptureInput sigue recibiendo y reenviando el hardware a EIS.
	set_process_input(not active)
	# Defensa final: durante InputCapture ninguna ruta de GUI puede reenviar el
	# hardware físico a un cliente Wayland local. El módulo también limpia el foco
	# al deshabilitar; has_method conserva compatibilidad con binarios anteriores.
	if compositor != null and compositor.has_method("set_local_pointer_enabled"):
		compositor.set_local_pointer_enabled(not active)
	# MOUSE_MODE_CAPTURED oculta/centra el cursor de Godot, pero no manda
	# wl_pointer.leave al cliente Wayland que estaba debajo. Soltar ese foco al
	# cruzar evita que la app local conserve hover y reciba clics "fantasma".
	if entering and compositor != null and compositor.has_method("pointer_clear_focus"):
		compositor.pointer_clear_focus()
	# Ocultar también el fallback dibujado: los eventos consumidos no llegan a
	# _move_eis_cursor y podían dejarlo visible mientras el puntero está afuera.
	if active and eis_cursor != null and eis_cursor.visible:
		eis_cursor.visible = false
		request_redraw()
	# Leer el modo real permite recuperar el lock tras una recarga del shell.
	var mode = Input.MOUSE_MODE_CAPTURED if active else Input.MOUSE_MODE_VISIBLE
	if (active or mouse_locked or Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED) and Input.get_mouse_mode() != mode:
		Input.set_mouse_mode(mode)
	mouse_locked = active


# Teclas multimedia que llegan por el RPC `media` (sway intercepta el brillo y llama a
# session/gdtk-media): con la captura de Deskflow activa van al equipo remoto, como
# cualquier otra tecla, en vez de cambiar el brillo/volumen de este.
func _forward_media_to_capture(action):
	var keys = {"up": KEY_VOLUMEUP, "down": KEY_VOLUMEDOWN, "mute": KEY_VOLUMEMUTE,
		"brightness_up": KEY_BRIGHTNESSUP, "brightness_down": KEY_BRIGHTNESSDOWN}
	if not mouse_locked or remote_input == null or not keys.has(action):
		return false
	if remote_input.has_method("is_capturing") and not remote_input.is_capturing():
		return false
	var sc = keys[action]
	var now = OS.get_ticks_msec()
	var ok = remote_input.capture_key(sc, true, now)
	remote_input.capture_key(sc, false, now)
	return ok


func _sync_capture_cursor():
	# Release/Disable/Close y desconexiones llegan por D-Bus/EIS, aun sin mouse
	# físico. No esperar otro evento local para devolver el cursor.
	if client_pointer_locked:
		# Lock de un cliente alojado: el modo lo gobierna _set_client_pointer_lock.
		return
	if remote_input != null and remote_input.has_method("is_capturing"):
		_set_capture_cursor(remote_input.is_capturing())
	elif mouse_locked:
		# Sin módulo de captura (binario sin RemoteInput, recarga viva) y el lock
		# puesto: soltarlo ya, si no el mouse local nunca vuelve.
		_set_capture_cursor(false)
	# Si el cliente con foco pidió ocultar el cursor y no hay captura, no dejarlo
	# visible: _set_capture_cursor(false) acaba de forzar MOUSE_MODE_VISIBLE.
	if client_cursor_hidden and not mouse_locked:
		_apply_client_cursor_state()


# --- Pointer lock de un cliente alojado (SDL relativo: emuladores/juegos) ------

func _on_client_pointer_lock(id, locked):
	_set_client_pointer_lock(locked)
	if locked and id > 0 and focused_tile != id and _id_alive(id):
		_focus_tile(id)


# Cursor pedido por el cliente con foco (surface NULL). No toca el lock: sólo
# oculta/restaura el cursor dibujado por el shell.
func _on_client_cursor_hidden(hidden):
	if client_cursor_hidden == hidden:
		return
	if debug_input:
		print("[cursor] la app pide ", "ocultar" if hidden else "mostrar", " el puntero")
	client_cursor_hidden = hidden
	_apply_client_cursor_state()


func _set_client_pointer_lock(active):
	if client_pointer_locked == active:
		return
	client_pointer_locked = active
	print("[ptr-lock] lock active=%s mode=%d hidden=%s has_rel=%s has_pfocus=%s" % [
		str(active), Input.get_mouse_mode(), str(client_cursor_hidden),
		str(compositor != null and compositor.has_method("pointer_motion_relative")),
		str(compositor != null and compositor.has_method("pointer_has_focus"))])
	if active:
		# SI hay una captura remota activa, cederla: el lock local manda.
		if mouse_locked:
			_set_capture_cursor(false)
		# Mismo mecanismo que Deskflow: apagar el _input de ImGuiCanvas; el hijo
		# CaptureInput sigue recibiendo y reenvía el relativo al cliente.
		set_process_input(false)
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		set_process_input(true)
		# No forzar VISIBLE si el cliente pidió ocultar el cursor (set_cursor
		# surface NULL): _apply_client_cursor_state deja el modo que corresponda.
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_apply_client_cursor_state()


# Oculta el cursor dibujado por el shell mientras haya pointer lock o el cliente
# con foco haya pedido cursor oculto. Al soltar y no pedir oculto, lo restaura.
func _apply_client_cursor_state():
	if eis_cursor != null and (client_pointer_locked or client_cursor_hidden):
		if eis_cursor.visible:
			eis_cursor.visible = false
			request_redraw()
	# La captura remota gobierna su propio modo de cursor (MOUSE_MODE_CAPTURED).
	if mouse_locked:
		return
	# El lock del cliente ya puso MOUSE_MODE_CAPTURED (y oculta el de Godot).
	if client_pointer_locked:
		return
	if client_cursor_hidden or remote_cursor_parked:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_HIDDEN:
			if debug_input:
				print("[cursor] oculto: la app enfocada (", focused_tile, ") pidió cursor vacío")
			Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	elif Input.get_mouse_mode() == Input.MOUSE_MODE_HIDDEN:
		if debug_input:
			print("[cursor] visible otra vez")
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_reset_cursor()


# Deskflow se fue de este equipo: se oculta el puntero (queda donde lo dejó el remoto)
# hasta el próximo movimiento local, así no se ven tres punteros a la vez.
func _on_remote_left():
	remote_cursor_parked = true
	remote_parked_at = OS.get_ticks_msec()
	_apply_client_cursor_state()


# Primer movimiento local después de que el remoto se fue: el puntero vuelve a verse.
# Los 200 ms siguientes a la salida se ignoran (último motion del remoto en vuelo).
func _unpark_remote_cursor():
	if not remote_cursor_parked or OS.get_ticks_msec() - remote_parked_at < 200:
		return
	remote_cursor_parked = false
	_apply_client_cursor_state()


# Reenvía hardware al cliente con lock (lo llama CaptureInput). Sólo consume mouse:
# las teclas siguen por _unhandled_input hasta compositor.key.
func _forward_client_pointer(event):
	if not client_pointer_locked:
		return false
	last_activity = OS.get_ticks_msec()
	if event is InputEventMouseMotion:
		if compositor != null and compositor.has_method("pointer_motion_relative"):
			compositor.pointer_motion_relative(event.relative)
		_ptr_log_motion(event.relative)
		get_tree().set_input_as_handled()
		return true
	if event is InputEventMouseButton:
		if compositor != null:
			compositor.pointer_button(event.button_index, event.pressed)
		get_tree().set_input_as_handled()
		return true
	if event is InputEventPanGesture:
		# Scroll de dos dedos con el puntero capturado por un cliente: mismo axis que
		# el camino sin lock (_on_view_input), en vez de descartar el gesto.
		_forward_pan(event)
		get_tree().set_input_as_handled()
		return true
	return false


# Scroll de dos dedos hacia el cliente. Con FRT nuevo llega con la fuente real
# (device 900 = dedos, 901 = fin): se reenvía como SOURCE_FINGER continuo + axis_stop,
# como en GNOME, y así los navegadores hacen atrás/adelante con el deslizamiento
# horizontal. Sin eso (motor viejo, otra fuente) va como rueda.
func _forward_pan(event):
	if compositor == null:
		return
	if event.device == SCROLL_STOP_DEVICE:
		if compositor.has_method("pointer_axis_stop"):
			compositor.pointer_axis_stop()
		return
	if event.delta == Vector2.ZERO:
		return
	if event.device == SCROLL_FINGER_DEVICE and compositor.has_method("pointer_axis_finger"):
		compositor.pointer_axis_finger(event.delta)
		return
	var pan_axis = SCROLL_GESTURE.pan_axis(event.delta)
	if compositor.has_method("pointer_axis_h"):
		compositor.pointer_axis_h(pan_axis.x)
	compositor.pointer_axis(pan_axis.y)


# Log temporal [ptr-lock]: primeras 20 muestras y luego 1 de cada 100. Quitar
# junto con las vars _ptr_log_samples y este helper (ver cabecera de la var).
func _ptr_log_motion(rel):
	_ptr_log_samples += 1
	if _ptr_log_samples > 20 and _ptr_log_samples % 100 != 0:
		return
	var has_rel = compositor != null and compositor.has_method("pointer_motion_relative")
	var has_pf = compositor != null and compositor.has_method("pointer_has_focus")
	var pfocus = has_pf and compositor.pointer_has_focus()
	print("[ptr-lock] motion #%d rel=%s has_rel=%s has_pfocus=%s pfocus=%s mode=%d" % [
		_ptr_log_samples, rel, has_rel, has_pf, pfocus, Input.get_mouse_mode()])


var _capture_drag_held = false   # sólo para loguear una vez por arrastre


func _capture_remote_input_event(event):
	# En exposé el mouse es del shell: no reenviar a RemoteInput/Deskflow, o el
	# `set_input_as_handled` del capture mataría el arrastre entre escritorios.
	if expose:
		return false
	# InputCapture toma exclusivamente el hardware local. Los eventos EIS que entran
	# desde otro equipo tienen DEVICE_ID y nunca deben volver a Deskflow.
	if remote_input == null or event.device == RemoteInput.DEVICE_ID:
		return false
	var captured = false
	var now = OS.get_ticks_msec()
	if event is InputEventMouseMotion:
		# Arrastrando (botón sostenido, mover/redimensionar ventana, DnD) el puntero no
		# cruza a Deskflow: el soltar caería en el otro equipo y el arrastre quedaría
		# colgado acá. Ya capturado, en cambio, todo sigue yendo al otro equipo.
		if not remote_input.is_capturing() and (event.button_mask != 0 or chrome_drag != null
				or (compositor != null and compositor.is_dragging())):
			if not _capture_drag_held:
				_capture_drag_held = true
				if debug_input:
					print("deskflow: arrastre en curso, el puntero no cruza")
			return false
		_capture_drag_held = false
		captured = remote_input.capture_motion(event.position, event.relative, now)
	elif event is InputEventMouseButton:
		if event.button_index == BUTTON_WHEEL_UP and event.pressed:
			captured = remote_input.capture_scroll(0.0, -1.0, now)
		elif event.button_index == BUTTON_WHEEL_DOWN and event.pressed:
			captured = remote_input.capture_scroll(0.0, 1.0, now)
		elif event.button_index == BUTTON_WHEEL_LEFT and event.pressed:
			captured = remote_input.capture_scroll(-1.0, 0.0, now)
		elif event.button_index == BUTTON_WHEEL_RIGHT and event.pressed:
			captured = remote_input.capture_scroll(1.0, 0.0, now)
		else:
			captured = remote_input.capture_button(event.button_index, event.pressed, now)
	elif event is InputEventPanGesture:
		# Pan de dos dedos durante InputCapture: antes se descartaba y el vecino no
		# recibía scroll horizontal (ni vertical) continuo. Delta ya viene en la
		# convención positivo=derecha/abajo que espera capture_scroll.
		captured = remote_input.capture_scroll(event.delta.x, event.delta.y, now)
	elif event is InputEventKey:
		var physical = event.physical_scancode if event.physical_scancode != 0 else event.scancode
		captured = remote_input.capture_key(physical, event.pressed, now)
	# Un gesto de touchpad/touch u otro evento no reenviado no es un Release.
	# Antes `captured=false` quitaba el lock y los siguientes motions/clics volvían
	# al escritorio local mientras Deskflow seguía controlando al vecino.
	var active = captured
	if remote_input.has_method("is_capturing"):
		active = remote_input.is_capturing()
	_set_capture_cursor(active)
	if active:
		captured = true
	if captured:
		get_tree().set_input_as_handled()
		return true
	return false


func _input(event):
	last_activity = OS.get_ticks_msec()
	if _capture_remote_input_event(event):
		return
	if event is InputEventPanGesture and event.device >= SWIPE_DEVICE:
		_on_swipe(event)
		get_tree().set_input_as_handled()
		return
	# Pantallazo rápido (PrintScreen). El shell compone la pantalla completa (UI Sugar +
	# ventanas del compositor anidado), así que el viewport es el escritorio entero.
	# Se atiende acá, antes de reenviar la tecla a la app, para que funcione con cualquier
	# ventana enfocada. El guardado real corre en un Thread.
	if event is InputEventKey and event.pressed and not event.echo \
			and (int(event.scancode) == KEY_PRINT or int(event.physical_scancode) == KEY_PRINT):
		_take_screenshot()
		get_tree().set_input_as_handled()
		return
	# Teclas multimedia (volumen/brillo): el shell las consume y muestra el OSD; no
	# van a la app. En _input (no en _unhandled_input) para que también las vea con
	# el puntero sobre el Home, donde ImGui marca todo como manejado.
	if system_osd != null and system_osd.handle_input(event):
		request_redraw()
		get_tree().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		input_motion_count += 1
		_unpark_remote_cursor()
	elif event is InputEventMouseButton:
		# Cualquier suelta del botón que inició un Super+drag lo cierra. El Frame consume
		# la pulsación en su _input, así que el View no tiene mouse_focus y Godot nunca
		# le entrega la suelta: hay que cerrarlo acá, sin depender de Super ni del View.
		if not event.pressed and chrome_drag != null and bool(chrome_drag.get("super", false)) \
				and int(chrome_drag.get("button", BUTTON_LEFT)) == event.button_index:
			_commit_chrome_drag()
		input_button_count += 1
		input_last_button = {"button": event.button_index, "pressed": event.pressed, "device": event.device, "pos": [event.position.x, event.position.y]}
	elif event is InputEventScreenTouch:
		input_touch_count += 1
	if event is InputEventKey:
		input_last_key = {"scancode": event.scancode, "physical": event.physical_scancode,
			"pressed": event.pressed, "ctrl": event.control, "shift": event.shift,
			"alt": event.alt, "meta": event.meta}
	if event is InputEventMouse:
		_move_eis_cursor(event)
	if current_activity == null and not apps.search_active and not neighborhood_view and event is InputEventKey and event.pressed \
			and event.unicode >= 32 and not (event.control or event.alt or event.meta):
		apps_view = true
		apps.type(char(event.unicode))


# ¿Hay una ventana flotante enfocada, viva y a la vista? Vale como destino de
# teclado aunque la actividad del anillo no coincida (estado desincronizado).
func _float_key_focus_alive():
	return view != null and view.visible and focused_tile >= 0 \
		and hybrid.is_floating(focused_tile) and _id_alive(focused_tile) \
		and not minimized.has(focused_tile)


func _unhandled_input(event):
	if not (event is InputEventKey):
		return
	var id = _current_wayland_id()
	if id < 0:
		id = last_key_target  # última ventana que recibió teclas (exposé/Home incluidos)
	if id < 0:
		return
	if _pantalla_sender != "" and _pantalla_window_ids().has(id):
		var physical = int(event.physical_scancode if event.physical_scancode != 0 else event.scancode)
		if physical > 0:
			_window_input_enqueue({"kind": "key", "physical": physical,
				"pressed": bool(event.pressed), "echo": bool(event.echo)})
			if event.pressed:
				_window_input_keys[physical] = true
			else:
				_window_input_keys.erase(physical)
			get_tree().set_input_as_handled()
		return
	if event.pressed:
		# Las pulsaciones no van a la app con un overlay del shell delante (exposé,
		# Hogar/Apps, Vecindario). Antes se exigía además `current_activity` wayland:
		# en flotante el foco de ventana y la actividad pueden desincronizarse y la
		# app quedaba muda de teclado (mouse vivo, teclado muerto). Con foco real
		# (`_float_key_focus_alive`) se reenvía igual.
		if expose or apps_view or (neighborhood_view and current_activity == null):
			return
		if not (current_activity != null and current_activity.has("wayland")) \
				and not _float_key_focus_alive():
			_log_key_drop(event, "sin actividad wayland (focused=%d)" % focused_tile)
			return
		last_key_target = id
		if not MOD_KEYS.has(event.scancode):
			_resync_modifiers()
	if MOD_KEYS.has(event.scancode):
		if event.pressed:
			fwd_mods[event.scancode] = true
		else:
			fwd_mods.erase(event.scancode)
	# Las SUELTAS se reenvían siempre (aunque estemos en exposé o en Home): si no, un
	# modificador apretado antes de abrir exposé/Home queda pegado en la app.
	compositor.key(event)
	get_tree().set_input_as_handled()


# Antes de reenviar una tecla común: todo modificador que la app cree apretado pero
# que el teclado real ya soltó recibe su suelta (la original se perdió en el camino).
func _resync_modifiers():
	for sc in fwd_mods.keys():
		if not Input.is_key_pressed(sc):
			var ev = InputEventKey.new()
			ev.scancode = sc
			ev.physical_scancode = sc
			ev.pressed = false
			compositor.key(ev)
			fwd_mods.erase(sc)
			print("[key-sync] modificador pegado soltado: ", OS.get_scancode_string(sc))


# Diagnóstico acotado: por qué una pulsación no llegó a la app.
func _log_key_drop(event, reason):
	if key_drop_logs >= 20 or event.echo:
		return
	key_drop_logs += 1
	print("[key-drop] ", OS.get_scancode_string(event.scancode), ": ", reason)


func _run_test_logic():
	if current_activity != null and current_activity.has("wayland") and current_activity.name == open_on_start:
		if type_text != "" and not typed and tex_ready_frame >= 0 and frame_count >= tex_ready_frame + TYPE_DELAY:
			_build_type_queue()
			typed = true

	if type_queue.size() > 0:
		_send_next_key()
		if type_queue.size() == 0:
			type_done_frame = frame_count

	if screenshot_path == "":
		return

	if current_activity != null and current_activity.has("wayland"):
		if tex_ready_frame >= 0:
			var target = tex_ready_frame + SHOT_DELAY
			if type_done_frame >= 0 and type_done_frame + 30 > target:
				target = type_done_frame + 30
			if frame_count >= target:
				_capture(screenshot_path)
			elif frame_count >= SHOT_MAX_FRAMES:
				print("screenshot: sin textura")
				_capture(screenshot_path)
		elif frame_count >= SHOT_MAX_FRAMES:
			print("screenshot: sin textura")
			_capture(screenshot_path)
	elif frame_count >= 30:
		_capture(screenshot_path)


func _build_type_queue():
	var i = 0
	while i < type_text.length():
		var ch = type_text.substr(i, 1)
		var code = _char_scancode(ch)
		if ch == "\\" and i + 1 < type_text.length() and type_text.substr(i + 1, 1) == "n":
			code = KEY_ENTER
			i += 1
		i += 1
		if code != 0:
			type_queue.push_back(code)


func _send_next_key():
	var code = type_queue.pop_front()
	var press = InputEventKey.new()
	press.physical_scancode = code
	press.scancode = code
	press.pressed = true
	compositor.key(press)
	var release = InputEventKey.new()
	release.physical_scancode = code
	release.scancode = code
	release.pressed = false
	compositor.key(release)


func _char_scancode(ch):
	var c = ord(ch)
	if c >= 97 and c <= 122:
		return KEY_A + (c - 97)
	if c >= 48 and c <= 57:
		return KEY_0 + (c - 48)
	if c == 32:
		return KEY_SPACE
	if c == 10:
		return KEY_ENTER
	return 0


func _capture(path):
	var image = get_viewport().get_texture().get_data()
	image.flip_y()
	var err = image.save_png(path)
	if err != OK:
		printerr("screenshot: no se pudo guardar ", path, " (error ", err, ")")
	print("commit_count=", compositor.commit_count, " dmabuf_commits=", compositor.dmabuf_commits, " shm_commits=", compositor.shm_commits)
	print("dmabuf: ", compositor.dmabuf_state)
	get_tree().quit()


# --- Pantallazo rápido (PrintScreen) ----------------------------------------

# Directorio destino: $XDG_PICTURES_DIR/Pantallazos (según ~/.config/user-dirs.dirs),
# con respaldo a ~/Imágenes, ~/Pictures o el HOME. Sólo lectura de disco local, barata.
func _screenshot_dir():
	var home = OS.get_environment("HOME")
	if home == "":
		home = "."
	return _xdg_pictures_dir(home).plus_file("Pantallazos")


func _xdg_pictures_dir(home):
	var f = File.new()
	if f.open(home.plus_file(".config/user-dirs.dirs"), File.READ) == OK:
		while not f.eof_reached():
			var line = f.get_line().strip_edges()
			if line.begins_with("XDG_PICTURES_DIR="):
				var v = line.substr("XDG_PICTURES_DIR=".length()).strip_edges()
				v = v.trim_prefix("\"").trim_suffix("\"")
				v = v.replace("$HOME", home)
				f.close()
				if v != "":
					return v
		f.close()
	var d = Directory.new()
	if d.dir_exists(home.plus_file("Imágenes")):
		return home.plus_file("Imágenes")
	if d.dir_exists(home.plus_file("Pictures")):
		return home.plus_file("Pictures")
	return home


func _screenshot_stamp():
	var t = OS.get_datetime()
	return "%04d-%02d-%02d_%02d-%02d-%02d" % [int(t.year), int(t.month), int(t.day),
		int(t.hour), int(t.minute), int(t.second)]


# Toma el viewport y lo manda a codificar/guardar en un Thread (no bloquea el frame).
func _take_screenshot():
	# Un solo guardado en vuelo: si el anterior sigue activo, se descarta este.
	if _shot_thread != null:
		if _shot_thread.is_active():
			return
		_shot_thread.wait_to_finish()
		_shot_thread = null
	var image = get_viewport().get_texture().get_data()
	image.flip_y()
	var dir = _screenshot_dir()
	var err = Directory.new().make_dir_recursive(dir)
	if err != OK:
		printerr("pantallazo: no se pudo crear ", dir, " (error ", err, ")")
		return
	var path = dir.plus_file("Pantallazo-" + _screenshot_stamp() + ".png")
	if system_osd != null:
		system_osd.show_message("Pantallazo guardado", "")
	_shot_thread = Thread.new()
	_shot_thread.start(self, "_write_screenshot", {"image": image, "path": path})


func _write_screenshot(data):
	var err = data["image"].save_png(data["path"])
	if err != OK:
		printerr("pantallazo: no se pudo guardar ", data["path"], " (error ", err, ")")
	else:
		print("pantallazo: ", data["path"])
	return null


# --- Input remoto (libei) ---

# Permiso: sin preguntar si lo pide un servicio que el usuario prendió desde el anillo
# (Deskflow) o un hijo suyo; cualquier otro proceso, diálogo. El pid lo da el portal.
func _on_input_access(id, pid, app_id):
	var who = _proc_name(pid)
	if app_id != "":
		who = app_id + " (" + who + ")"
	if _from_service(pid):
		print("RemoteInput: control remoto permitido a ", who)
		remote_input.respond(id, true)
		return
	input_requests.append({"id": id, "who": who})
	last_activity = OS.get_ticks_msec()
	request_redraw()


func _from_service(pid):
	var guard = 0
	while pid > 1 and guard < 32:
		_svc_mutex.lock()
		var found = false
		for name in service_pids:
			if service_pids[name] == pid:
				var e = _svc_snapshot.get(name, null)
				if e != null and e.running:
					found = true
					break
		_svc_mutex.unlock()
		if found:
			return true
		pid = _ppid(pid)
		guard += 1
	return false


func _ppid(pid):
	var f = File.new()
	if f.open("/proc/%d/stat" % pid, File.READ) != OK:
		return 0
	var stat = f.get_line()
	f.close()
	# pid (comm) estado ppid ...: comm puede tener espacios, se corta tras el último ')'.
	return int(stat.substr(stat.find_last(")") + 2).split(" ")[1])


func _proc_name(pid):
	var f = File.new()
	if pid <= 0 or f.open("/proc/%d/comm" % pid, File.READ) != OK:
		return "proceso desconocido"
	var comm = f.get_line()
	f.close()
	return "%s, pid %d" % [comm, pid]


func _draw_input_requests():
	for i in range(input_requests.size() - 1, -1, -1):
		if not remote_input.is_pending(input_requests[i].id):
			input_requests.remove(i)
	if input_requests.empty():
		return
	var req = input_requests[0]
	var size = Vector2(460, 130)
	set_next_window_pos(get_viewport_rect().size * 0.5 - size * 0.5, true)
	set_next_window_size(size, true)
	set_next_window_bg_alpha(1.0)
	if begin("Control remoto##eis", WINDOW_NO_COLLAPSE | WINDOW_NO_RESIZE | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS):
		text_wrapped(req.who + " quiere controlar el mouse y el teclado.")
		spacing()
		if button("Permitir", Vector2(120, 32)):
			remote_input.respond(req.id, true)
		same_line()
		if button("Denegar", Vector2(120, 32)):
			remote_input.respond(req.id, false)
	end()


func _make_eis_cursor():
	var layer = CanvasLayer.new()
	layer.layer = 128
	add_child(layer)
	var arrow = PoolVector2Array([Vector2(0, 0), Vector2(0, 17), Vector2(4, 13), Vector2(7, 20),
		Vector2(10, 19), Vector2(7, 12), Vector2(12, 12)])
	var cursor = Polygon2D.new()
	cursor.polygon = arrow
	cursor.color = Color.white
	var outline = Line2D.new()
	arrow.append(arrow[0])
	outline.points = arrow
	outline.width = 1.0
	outline.default_color = Color.black
	cursor.add_child(outline)
	cursor.visible = false
	layer.add_child(cursor)
	return cursor


# En X11 se mueve el puntero real (warp). En Wayland/gdtk el módulo usa el cursor
# nativo del host (remote_pointer.c); no dibujar fallback para evitar un cursor
# fantasma encima del cursor real.
func _move_eis_cursor(event):
	if eis_cursor == null:
		return
	if mouse_locked:
		eis_cursor.visible = false
		return
	if event.device != RemoteInput.DEVICE_ID:
		if event is InputEventMouseMotion:
			eis_cursor.visible = false
		return
	if OS.get_environment("GDTK_SESSION") == "x11":
		Input.warp_mouse_position(event.position)
		return
	eis_cursor.visible = false
