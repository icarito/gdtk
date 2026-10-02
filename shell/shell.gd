extends ImGuiCanvas

var ACTIVITIES = [
	{"name": "Terminal", "wayland": ["alacritty"]},
	{"name": "Gears", "wayland": ["es2gears_wayland"]},
	{"name": "GTK", "wayland": ["gtk4-widget-factory"]},
	# Servicio: el botón prende/apaga un proceso en segundo plano (no abre vista).
	# Deskflow: en X11 inyecta por XTest; en Wayland (cage, sway) pide el portal RemoteDesktop
	# y le llega un fd del EIS del shell (RemoteInput): se le da permiso sin preguntar.
	{"name": "Deskflow", "service": "deskflow-core client --new-instance -s ~/gdtk/deskflow-client.conf"},
	# Pantalla: receptor de gvd (monitor virtual de otro host, H.264/UDP :5600). Se abre como
	# ventana Wayland; el emisor se arranca en el otro host (gvd.py send --host <este host>).
	# La ruta se resuelve como neighborhood_actions.gvd_path_candidates: vendoreado
	# (~/gdtk/tools/gvd), dev (~/Proyectos/gvd), instalado (~/gvd) y PATH; sin
	# hardcodear una sola ubicación.
	# K18: el receptor usa un título fijo ("Pantalla compartida") y se trata como
	# una ventana normal; `match` lo asocia por ese título aunque el comando sea `python3`.
	{"name": "Pantalla", "match": ["Pantalla compartida"], "wayland": ["sh", "-c", "for c in \"$HOME/gdtk/tools/gvd/gvd.py\" \"$HOME/Proyectos/gvd/gvd.py\" \"$HOME/gvd/gvd.py\" \"$(command -v gvd 2>/dev/null)\"; do [ -n \"$c\" ] && [ -f \"$c\" ] && exec python3 \"$c\" recv --sink auto; done; echo 'vecindario: gvd no encontrado (recv)' >&2"]},
	# 'Salir' ya no es una actividad del anillo: es una acción de sesión del ícono central
	# del Hogar (ver _draw_home / popup ##home_session).
]

const TYPE_DELAY = 60
const SHOT_DELAY = 90
const SHOT_MAX_FRAMES = 900

# Modelo puro de la brújula de dirección (Kilo A): sólo normaliza/serializa y
# detecta conflictos; sin I/O. El shell lo cablea a la vista y a la persistencia.
const DIRECTIONS_MODEL = preload("res://neighborhood_directions.gd")
# Generadores puros del layout Deskflow (K5): links desde la brujula y el formato
# real de servidor; el shell sólo los consume al aplicar.
const LAYOUT_MODEL = preload("res://deskflow_layout.gd")
const CONF_MODEL = preload("res://deskflow_conf.gd")
const DESKFLOW_SETTINGS = preload("res://deskflow_settings.gd")
const SCREEN_LAYOUT = preload("res://screen_layout.gd")
const SERVICE_STATE = preload("res://service_state.gd")
# Sesión de pantalla gvd (Kilo F2): modelo puro de estados/planes/clasificación que
# usa el despacho de acciones del Vecindario (no ejecuta nada por sí mismo).
const GVD_SESSION = preload("res://gvd_session.gd")
# K17: planes puros de automatización de gvd (emisor local/receptor remoto por
# ssh, `--position` del mapa, `--cursor sway`, suspensión del vínculo Deskflow).
const GVD_LAUNCH = preload("res://gvd_launch.gd")
const MENU_STYLE = preload("res://menu_style.gd")
const HOST_DISPATCH = preload("res://host_dispatch.gd")
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

onready var compositor = Host.compositor
var view = null          # Control que dibuja las ventanas (se crea en _ready)
var view_layer = null    # CanvasLayer -1 debajo de ImGui

var current_activity = null
var activity_instance = null
# Instancias de actividades internas abiertas: se conservan al ir al Home o a otra
# ventana (el Frame las lista); sólo cerrarlas desde el Frame las descarta.
var script_instances = {}
var frame = null
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
var last_geo = {}        # id -> último tamaño observado del cliente (para reafirmar el slot)
# Los buffers wayland vienen con alfa premultiplicado.
var premult_material = null

var frame_count = 0
var screenshot_path = ""
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

# Favoritos del anillo (SPEC-sugar-home-visual): ids de app fijados por la persona,
# persistidos en $XDG_CONFIG_HOME/gdtk/ring-favorites.json. El anillo = ACTIVITIES
# (sin duplicar) + estos favoritos resueltos por `apps`.
var ring_favorites = []
var ring_saved = []
# Orden de último uso (MRU) del anillo: nombres de actividad, el más reciente al
# final. El anillo lista primero lo que está abierto/activo, ordenado por esto.
var activity_mru = []
# Layout animado del anillo: posición mostrada por nombre, animación en curso e
# instante de entrada (fade/escala breve). Se limpia cuando el ítem sale.
var ring_pos = {}
var ring_anim = {}
var ring_intro = {}
var ring_layout = []      # rects del último dibujo (para el drag con ratón)
var ring_press = null     # entrada pulsada aún sin arrastrar
var ring_drag = null      # entrada que se está arrastrando
var ring_from = Vector2.ZERO
var ring_grab = Vector2.ZERO
var ring_suppress = ""     # nombre cuya activación se ignora tras un drag
var ring_drop = null       # entrada destino resaltada mientras se arrastra

# Rotación de pantalla (menú del anillo): cache de presencia de acelerómetro.
var _rotate_sensor = null

# Vecindario: modelo de Wi-Fi y vista nativa bajo el Frame ImGui.
var neighborhood = null
var neighborhood_ui = null
var neighborhood_view = false
# Transición Hogar <-> Vecindario con metáfora de zoom del ícono central:
# 0 = Hogar, 1 = Vecindario. El Vecindario escala/aparece desde el centro.
var nb_zoom = 0.0
var nb_zoom_target = 0.0
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
# Deskflow por host: intención en memoria, nunca implícita ni automática. El
# portapapeles dejó de ser una opción (se asume compartido con "Controlar").
var host_deskflow = {}        # host_id -> bool (intención; la actividad es global)
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
var groups = []          # Array de Array de ids: pantallas partidas (2+ ventanas)
var minimized = {}       # id -> true
var unit_focus = {}      # id-líder de la pantalla -> último miembro enfocado
var focused_tile = -1
var tile_mode = false
var tile_nodes = {}      # id -> Control (contenedor de capas de la ventana)
var tile_rects = {}      # id -> Rect2 en coords de la vista
var tile_fit = {}        # id -> {"scale", "offset"}: transform del contenido (para input)
var tile_anim = {}       # id -> {"from": Vector2, "since": int}
var tile_fade = {}       # id -> ms en que apareció (fade-in)
var tile_intro = {}      # id -> true: falta su primera textura para animar la entrada
var expose = false
var expose_sel = 0
var expose_cards = {}    # id -> Rect2 de la ventana en exposé (coords de vista)
var expose_unit_cards = []  # Rect2 de cada workspace (pantalla) en exposé
var expose_hover = -1    # id de la ventana bajo el puntero en exposé (-1 = ninguna)
var ghosts = []          # cierres/minimizados animados: {"node", "from", "to", "since"}
var ghost_layer = null   # capa por encima de apps y Home para el fantasma de cierre
# Rect (coords de vista) del ícono que lanzó la próxima ventana: ancla la animación de
# entrada (escala desde el ícono). Se consume en _add_tile; expira a los pocos segundos.
var pending_origin = null
var pending_origin_since = 0
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
# Animación de transformación (entrar/salir de exposé): id -> {"from_pos", "from_scale", "since"}.
var view_anim = {}
# Pantalla completa (Alt+F11): la ventana enfocada ocupa todo y se esconde el Frame.
var fullscreen_id = -1
# Proporción de reparto de una franja partida: id -> peso (default 1). Asa de borde.
var split_weight = {}
var handles = []         # asas de la franja enfocada: {"x", "y", "h", "i", "left", "right"}
var hover_handle = null
var resize_handle = null
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
const TILE_FADE_MS = 440
const GHOST_MS = 380
const INTRO_MS = 480
const EXPOSE_MS = 430
const FOCUS_FLASH_MS = 260
const HANDLE_HIT = 7.0
const EXPOSE_PAD = 28.0
const EXPOSE_GAP = 18.0
# Zoom out: escala máxima del workspace (con uno solo, para que se note el achique).
const EXPOSE_MAX_SCALE = 0.62
# Lado del botón de cerrar de cada ventana en exposé (se ajusta al tamaño de la tarjeta).
const EXPOSE_CLOSE_MAX = 22.0
const MOD_KEYS = [KEY_CONTROL, KEY_SHIFT, KEY_ALT, KEY_META, KEY_SUPER_L, KEY_SUPER_R]

# Hogar: fila(s) de favoritos centradas (SPEC-sugar-home-visual). Pareja XO para la
# insignia de identidad del Frame; íconos de actividad con fill claro + stroke
# oscuro-medio, y estados por contorno/atenuación además del color (SPEC-resource-ring).
const XO_FILL = Color(0.78, 0.30, 0.52, 1.0)
const XO_STROKE = Color(0.34, 0.15, 0.29, 1.0)
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
const GOLDEN_ANGLE = 2.399963229728653  # PI * (3 - sqrt(5))
const RING_JITTER_A = 0.18
const RING_JITTER_R = 0.05
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
	"Pantalla": "computer-xo",
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
	if vp.y >= 3.0 * u:
		return u
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
	return CONTENT_LAYOUT.dialog_area(vp, frame_bar_h(vp))


# Ícono del equipo local: el mismo `kind` que publica el Vecindario (o "unknown",
# que cae al ícono de escritorio). Es el que va en el bloque Inicio del Frame y en
# la placa central del mapa, en lugar de una casita genérica.
func local_device_icon_tex():
	return device_icon_tex(local_device_kind())


# Ícono por kind de Vecindario (desktop/laptop/tablet/mobile/tv). Cae al ícono de
# escritorio para "unknown" y al XO de Sugar si el PNG no está.
func device_icon_tex(kind):
	var name = DEVICE_ICONS.get(String(kind), "device-desktop")
	var tex = _load_np_icon(name)
	if tex != null:
		return tex
	return _load_sugar_svg("computer-xo", SUGAR_STROKE, SUGAR_FILL)


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
	_load_ring()
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

	# Fondo de exposé: detrás de los tiles (View) para no tapar las miniaturas.
	expose_bg = ColorRect.new()
	expose_bg.color = Color(0.05, 0.06, 0.08, 0.92)
	expose_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	eis_cursor = _make_eis_cursor()

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


# Guarda el layout (orden/grupos/pesos/foco/fullscreen/minimizadas) para restaurarlo
# tras una recarga en caliente (ver main.reload_shell).
func _save_layout():
	var gs = []
	for g in groups:
		gs.append(g.duplicate())
	Host.layout = {"tiles": tiles.duplicate(), "groups": gs, "weights": split_weight.duplicate(),
		"minimized": minimized.keys(), "focused": focused_tile, "fullscreen": fullscreen_id}


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
		groups = []
		for g in lay.get("groups", []):
			var gg = []
			for id in g:
				if tiles.has(id):
					gg.append(id)
			if gg.size() >= 2:
				groups.append(gg)
		split_weight = {}
		for k in lay.get("weights", {}):
			split_weight[int(k)] = lay["weights"][k]
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
var last_activity = 0


# Un commit Wayland puede traer capas/texturas nuevas (y con dmabuf el VisualServer
# no se entera de que cambió el contenido): se rearma el frame siguiente.
func _process(_delta):
	var now = OS.get_ticks_msec()
	# Transición de zoom Hogar <-> Vecindario (metáfora del ícono central). El
	# objetivo sigue SIEMPRE a `neighborhood_view`: cualquier salida (abrir una app,
	# la grilla de Apps, _go_home) vuelve a 0 y el Vecindario se retira.
	nb_zoom_target = 1.0 if neighborhood_view else 0.0
	if abs(nb_zoom - nb_zoom_target) > 0.001:
		var step = (_delta * 1000.0) / ZOOM_MS
		if step <= 0.0:
			step = 0.15
		if nb_zoom < nb_zoom_target:
			nb_zoom = min(nb_zoom_target, nb_zoom + step)
		else:
			nb_zoom = max(nb_zoom_target, nb_zoom - step)
		request_redraw()
	elif nb_zoom != nb_zoom_target:
		nb_zoom = nb_zoom_target
		request_redraw()
	if compositor.commit_count != last_commits:
		last_commits = compositor.commit_count
		last_activity = now
		request_redraw()
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
	# Escrituras de dirección: reapea los Threads ya terminados (no bloquea).
	_dir_poll()
	# Buzón del handshake de dirección: aplica el snapshot del worker y reapea los
	# envíos ssh terminados (sin bloquear, sin I/O de disco acá).
	_inbox_poll()
	# Sesiones de pantalla gvd y escrituras de config de plan: sólo reap de Threads.
	_gvd_poll()
	_plan_poll()
	# Configuración: reapa el Thread de lectura y aplica acento/fondo del snapshot.
	settings_poll()
	if screenshot_path == "":
		var sleep = SLEEP_IDLE if now - last_activity > IDLE_MS else SLEEP_ACTIVE
		if OS.low_processor_usage_mode_sleep_usec != sleep:
			OS.low_processor_usage_mode_sleep_usec = sleep


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
	_tick_home_slide()
	# Fundido al cambiar de vista (ver frame.transition); 0 = ImGuiStyleVar_Alpha.
	# Si el Frame no cargó (p. ej. frame.gd no compila), no hay transición que
	# aplicar: se dibuja opaco en vez de reventar cada frame.
	var fade = frame.transition() if frame != null and is_instance_valid(frame) else 1.0
	if fade < 1.0:
		push_style_var_float(0, fade)
	# En exposé el ImGui no dibuja la vista de fondo (Hogar/actividad): las miniaturas
	# del escritorio van en la capa de abajo y el fondo oscuro las enmarca.
	if not expose:
		if current_activity == null:
			# Durante el zoom Hogar -> Vecindario se sigue dibujando el Hogar detrás,
			# para que el Vecindario aparezca escalando sobre él (no sobre negro).
			if neighborhood_view and nb_zoom >= 0.999:
				neighborhood_ui.refresh()
			else:
				_draw_home(_home_x(_units()))
				if neighborhood_view:
					neighborhood_ui.refresh()
		else:
			_draw_activity()
			# Paneo/animación hacia el Hogar: se dibuja deslizándose junto a las ventanas.
			if _home_anim_active() or pan_active:
				var hx = _home_x(_units())
				var vp = get_viewport_rect().size
				if hx > -vp.x and hx < vp.x:
					_draw_home(hx)
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
	# Vecindario con zoom: visible también mientras cierra/anima (nb_zoom > 0).
	var nb_vp = get_viewport_rect().size
	neighborhood_ui.visible = current_activity == null and not expose and (neighborhood_view or nb_zoom > 0.01)
	if neighborhood_ui.visible:
		var zk = lerp(0.72, 1.0, _ease_out(nb_zoom))
		neighborhood_ui.rect_pivot_offset = nb_vp * 0.5
		neighborhood_ui.rect_scale = Vector2(zk, zk)
		neighborhood_ui.modulate = Color(1, 1, 1, clamp(nb_zoom, 0.0, 1.0))
		# Al cerrar sigue visible para animar, pero no debe capturar el mouse.
		neighborhood_ui.mouse_filter = Control.MOUSE_FILTER_STOP if neighborhood_view else Control.MOUSE_FILTER_IGNORE
	if row:
		_update_tiles()
	instant_switch = false  # ya se reubicaron sin animación en este frame
	var id = _current_wayland_id()
	_update_dialogs(id)
	if tiles_ui != null:
		tiles_ui.rect_size = get_viewport_rect().size
		tiles_ui.refresh()
	if expose_bg != null:
		expose_bg.rect_size = get_viewport_rect().size
		expose_bg.visible = expose
	# En exposé no se dibujan las barras del Frame: taparían las miniaturas (el fondo
	# oscuro y los marcos las resaltan).
	if not expose:
		frame.draw(self)
	_update_ghosts(OS.get_ticks_msec())

	_draw_input_requests()
	# HUD de debug global (autoload DebugHud): Super+F6 lo abre en cualquier actividad (frame.gd).
	DebugHud.draw(self)

	frame_count += 1
	_run_test_logic()


# --- Pantallas: una fila horizontal; cada pantalla puede tener varias apps ---

# El grupo (franja con varias apps) que contiene la ventana, o null si va suelta.
func _group_of(id):
	for g in groups:
		if g.has(id):
			return g
	return null


# Miembros de la pantalla de una ventana: su grupo, o ella sola.
func _unit_members(id):
	var g = _group_of(id)
	return g if g != null else [id]


# Unidades en orden de `tiles`: cada grupo una vez (en la posición de su primer miembro).
func _units():
	var out = []
	var seen = {}
	for id in tiles:
		if seen.has(id):
			continue
		var g = _group_of(id)
		if g != null:
			out.append(g)
			for m in g:
				seen[m] = true
		else:
			out.append([id])
			seen[id] = true
	return out


func _focused_unit_index(units):
	for u in range(units.size()):
		if units[u].has(focused_tile):
			return u
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
	return a + pan / max(vp.x, 1.0)


# Ranura de la última pantalla que tuvo el foco (para volver desde el Hogar).
func _last_focus_unit(units):
	var ui = _focused_unit_index_of(units, focused_tile)
	if ui < 0:
		ui = units.size() - 1
	return ui


# x del Hogar dentro de la fila: 0 = centrado en pantalla, ±ancho = fuera de vista.
func _home_x(units):
	var vp = get_viewport_rect().size
	return (float(units.size()) - _row_s(units)) * vp.x


# Toda la fila a tamaño completo: la pantalla enfocada (o el Hogar) en (0,0) y el resto
# a ±ancho, para que cambiar de pantalla deslice de costado. La fila incluye el Hogar
# como ranura extra al final (índice units.size()).
func _compute_slide_layout():
	tile_rects.clear()
	var units = _units()
	var vp = get_viewport_rect().size
	# Pantalla completa: la ventana ocupa todo; el resto queda fuera de pantalla.
	if fullscreen_id >= 0 and tiles.has(fullscreen_id):
		for id in tiles:
			tile_rects[id] = Rect2(0.0, 0.0, vp.x, vp.y) if id == fullscreen_id else Rect2(vp.x * 2.0, 0.0, vp.x, vp.y)
		return
	var s = _row_s(units)
	# Cada pantalla (top-level) vive bajo la barra superior con alto completo; la
	# fila desliza con el ancho del viewport (consistente con pan/_home_x), así los
	# vecinos quedan a ±ancho. Sólo los diálogos se limitan al hueco de dos barras.
	var cr = _tile_rect(vp)
	for u in range(units.size()):
		var area = Rect2(cr.position.x + (float(u) - s) * vp.x, cr.position.y, cr.size.x, cr.size.y)
		var members = units[u]
		if members.size() == 1:
			tile_rects[members[0]] = area
		else:
			_split_rects(members, area)


# Peso de reparto de una ventana dentro de su franja (default 1: partes iguales).
func _weight(id):
	return float(split_weight.get(id, 1.0))


# Las apps de una franja van en UNA fila, sin tope; el ancho se reparte por pesos
# (el asa de borde ajusta los pesos de las dos ventanas vecinas).
func _split_rects(members, area):
	var n = members.size()
	if n == 0:
		return
	var gap = TILE_GAP
	var total = 0.0
	for m in members:
		total += max(_weight(m), 0.001)
	var avail = area.size.x - gap * float(n + 1)
	var x = area.position.x + gap
	for i in range(n):
		var w = avail * max(_weight(members[i]), 0.001) / total
		tile_rects[members[i]] = Rect2(x, area.position.y, w, area.size.y)
		x += w + gap


# Asas de la franja enfocada (sólo si tiene varias apps): coordenada x del borde
# entre cada par, para dibujar/arrastrar la redimensión.
func _compute_handles():
	handles = []
	if expose or fullscreen_id >= 0 or _at_home() or _home_anim_active():
		hover_handle = null
		resize_handle = null
		return
	var units = _units()
	if units.empty():
		return
	var u = units[_focused_unit_index(units)]
	if u.size() < 2:
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
	var left = rl.position.x
	var right = rr.position.x + rr.size.x
	var frac = clamp((mouse_x - left) / max(right - left, 1.0), 0.12, 0.88)
	var wsum = _weight(h.left) + _weight(h.right)
	split_weight[h.left] = wsum * frac
	split_weight[h.right] = wsum * (1.0 - frac)


# Rects de las ventanas de UNA pantalla en coordenadas locales del workspace (origen
# (0,0), tamaño del viewport), sin depender del estado de paneo. Misma partición que
# _split_rects: una ventana ocupa el área de contenido; una franja partida reparte por
# pesos con TILE_GAP. Lo usa el exposé para escalar cada ventana a su lugar real.
func _unit_local_layout(members):
	var out = {}
	var vp = get_viewport_rect().size
	var area = _tile_rect(vp)
	if members.size() == 1:
		out[members[0]] = area
		return out
	if members.empty():
		return out
	var gap = TILE_GAP
	var total = 0.0
	for m in members:
		total += max(_weight(m), 0.001)
	var avail = area.size.x - gap * float(members.size() + 1)
	var x = area.position.x + gap
	for i in range(members.size()):
		var w = avail * max(_weight(members[i]), 0.001) / total
		out[members[i]] = Rect2(x, area.position.y, w, area.size.y)
		x += w + gap
	return out


# Exposé = "zoom out" del escritorio: cada workspace (pantalla) se dibuja como una
# miniatura completa del viewport, con sus ventanas en la posición y proporción reales,
# y TODOS los workspaces van en una fila en su orden espacial (el mismo del paneo),
# escalados para entrar a la vista. La lógica de escalado/proporción vive en
# expose_layout.gd (pura y testeable).
func _compute_expose_layout():
	expose_cards.clear()
	expose_unit_cards = []
	var units = _units()
	var n = units.size()
	if n == 0:
		expose_sel = 0
		return
	expose_sel = int(clamp(expose_sel, 0, max(tiles.size() - 1, 0)))
	var vp = get_viewport_rect().size
	var local = []
	for u in units:
		local.append(_unit_local_layout(u))
	var plan = EXPOSE_LAYOUT.plan(vp, local, EXPOSE_PAD, EXPOSE_GAP, EXPOSE_MAX_SCALE)
	expose_unit_cards = plan["units"]
	expose_cards = plan["cards"]
	# tile_rects queda con la geometría REAL local de cada ventana: la necesita
	# _update_tile para reescalar la miniatura sin distorsionar el contenido.
	for u in range(units.size()):
		for id in local[u].keys():
			tile_rects[id] = local[u][id]


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
		node.rect_clip_content = true
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
	for id in tiles:
		if _id_alive(id):
			_update_tile(id, now)
			if expose:
				compositor.get_layers(id)  # cuenta como dibujado: la miniatura sigue viva


func _update_tile(id, now):
	var node = _tile_node(id)
	var geo = compositor.get_geometry(id)
	var layers = compositor.get_layers(id)
	var rect = tile_rects.get(id, Rect2(Vector2.ZERO, view.rect_size))
	# El cliente puede no ocupar el slot (elige tamaño propio, o se achica al cambiar
	# de fuente): se centra 1:1 y, si es más grande que el slot, se reduce para que entre.
	var fit = _content_fit(geo.size, rect.size, geo.position)
	_fill_nodes(node, layers, fit.scale, fit.offset)
	tile_fit[id] = fit

	if expose:
		# Miniatura: se escala el nodo entero (la app conserva su tamaño de tile) y se
		# centra, animando desde su transform de pantalla (ver _toggle_expose). El
		# tamaño real por ventana está en tile_rects (lo dejó _compute_expose_layout).
		var card = expose_cards.get(id, Rect2(Vector2.ZERO, view.rect_size))
		node.rect_size = rect.size
		var s = min(min(card.size.x / max(rect.size.x, 1.0), card.size.y / max(rect.size.y, 1.0)), 1.0)
		var tpos = card.position + (card.size - rect.size * s) * 0.5
		var a = view_anim.get(id)
		if a != null:
			var e = _ease(float(now - a.since) / EXPOSE_MS)
			node.rect_position = a.from_pos.linear_interpolate(tpos, e)
			var sc = lerp(float(a.from_scale), s, e)
			node.rect_scale = Vector2(sc, sc)
			if float(now - a.since) >= EXPOSE_MS:
				view_anim.erase(id)
			else:
				request_redraw()
		else:
			node.rect_scale = Vector2(s, s)
			node.rect_position = tpos
		node.modulate = Color(1, 1, 1, 1)
		node.visible = true
		return

	# Vuelta de exposé: se interpola desde la tarjeta hasta su rect de pantalla.
	if view_anim.has(id):
		var a = view_anim[id]
		var e = _ease(float(now - a.since) / EXPOSE_MS)
		node.rect_position = a.from_pos.linear_interpolate(rect.position, e)
		var sc = lerp(float(a.from_scale), 1.0, e)
		node.rect_scale = Vector2(sc, sc)
		node.rect_size = rect.size
		node.visible = true
		node.modulate = Color(1, 1, 1, 1)
		if geo.size != Vector2.ZERO and requested_sizes.get(id) != rect.size:
			requested_sizes[id] = rect.size
			compositor.set_size(id, rect.size)
		if float(now - a.since) >= EXPOSE_MS:
			view_anim.erase(id)
		else:
			request_redraw()
		return

	# Entrada: escala y se traslada desde el ícono que la lanzó (o desde el borde
	# derecho, mismo tamaño). El placeholder con spinner lo dibuja tiles_ui hasta que
	# llega la primera textura. El tamaño del cliente queda en el destino (1:1).
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
				from = Rect2(Vector2(view.rect_size.x, rect.position.y), rect.size)
		var s = lerp(_intro_scale(from, rect), 1.0, e)
		var center = (from.position + from.size * 0.5).linear_interpolate(rect.position + rect.size * 0.5, e)
		var pos = center - rect.size * s * 0.5
		node.rect_scale = Vector2(s, s)
		node.rect_position = pos
		node.rect_size = rect.size
		node.visible = true
		node.modulate = Color(1, 1, 1, min(e, 1.0))
		info["rect"] = Rect2(pos, rect.size * s)
		if geo.size != Vector2.ZERO and requested_sizes.get(id) != rect.size:
			requested_sizes[id] = rect.size
			compositor.set_size(id, rect.size)
		if k >= 1.0:
			tile_intro.erase(id)
			node.rect_scale = Vector2.ONE
			node.rect_position = rect.position
		else:
			request_redraw()
		return

	# Desliza desde donde estaba a su celda nueva (reacomodar, cambiar de pantalla).
	# Durante el paneo (Super+rueda) se posiciona directo, sin animación, para que el
	# movimiento continuo no pelee con el easing.
	var pos = rect.position
	if pan_active or instant_switch or home_slide_since >= 0:
		tile_anim.erase(id)
	elif tile_anim.has(id):
		var a = tile_anim[id]
		var k = clamp(float(now - a.since) / TILE_ANIM_MS, 0.0, 1.0)
		pos = a.from.linear_interpolate(rect.position, _ease(k))
		if k >= 1.0:
			tile_anim.erase(id)
		else:
			request_redraw()
	elif node.rect_position.distance_to(rect.position) > 0.5:
		tile_anim[id] = {"from": node.rect_position, "since": now}
		request_redraw()
	node.rect_scale = Vector2.ONE
	node.rect_position = pos
	node.rect_size = rect.size
	# Sólo se dibuja la pantalla que asoma: las demás quedan fuera (±ancho/±alto).
	var vp = view.rect_size
	node.visible = pos.x + rect.size.x > 0.0 and pos.x < vp.x and pos.y + rect.size.y > 0.0 and pos.y < vp.y
	node.modulate = Color(1, 1, 1, 1)

	# Ajuste 1:1: se le pide al cliente el tamaño del slot (texto nítido). Se reafirma
	# cuando el cliente se achica solo (p. ej. al cambiar la fuente) y no molesta si el
	# cliente no acepta (sólo se reintenta cuando su tamaño cambia).
	if rect.size.x > 0.0 and rect.size.y > 0.0:
		var drifted = geo.size != Vector2.ZERO and geo.size != rect.size and last_geo.get(id) != geo.size
		if requested_sizes.get(id) != rect.size or drifted:
			requested_sizes[id] = rect.size
			compositor.set_size(id, rect.size)
		last_geo[id] = geo.size
	if tex_ready_frame < 0 and id == focused_tile and layers.size() > 0 and layers[0].texture != null:
		tex_ready_frame = frame_count


# Easing con rebote leve (ease-out-back): arranca rápido, se pasa un poco del destino
# y vuelve. k normalizado 0..1 (puede devolver >1 por el overshoot).
func _ease(k):
	k = clamp(k, 0.0, 1.0)
	var c1 = 1.20158
	var c3 = c1 + 1.0
	return 1.0 + c3 * pow(k - 1.0, 3.0) + c1 * pow(k - 1.0, 2.0)


# Escala inicial para la entrada: la ventana nace del tamaño del ícono (nunca > 1).
func _intro_scale(from, target):
	if target.size.x <= 0.0 or target.size.y <= 0.0:
		return 1.0
	return min(min(from.size.x / target.size.x, from.size.y / target.size.y), 1.0)


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


func _focus_tile(id):
	if id < 0 or not _id_alive(id):
		return
	# Enfocar a mano cancela cualquier deslizamiento/hogar en curso y cierra la
	# grilla de Apps: el flag no debe sobrevivir al volver de la grilla a una app.
	pan = 0.0
	pan_active = false
	home_slide_since = -1
	apps_view = false
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
	compositor.focus(id)
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
	var units = _units()
	var n = units.size()
	if int(round(to)) >= n:
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
	pan = clamp(pan + amount * vp.x * 0.18, -a * vp.x, (float(n) - a) * vp.x)
	request_redraw()


# Al soltar Super: cae a la pantalla más cercana según el paneo acumulado (incluido el
# Hogar, si el paneo lo alcanzó).
func _snap_pan():
	if not pan_active:
		return
	var units = _units()
	var n = units.size()
	var vp = get_viewport_rect().size
	var a = float(n) if _at_home() else float(_focused_unit_index(units))
	var delta = int(round(pan / max(vp.x, 1.0)))
	pan_active = false
	pan = 0.0
	var target = int(clamp(a + float(delta), 0.0, float(n)))
	if target >= n:
		if not _at_home():
			_go_home()
	elif (target != int(a) or _at_home()) and n > 0:
		_focus_unit(units, target)
	request_redraw()


# Super+←/→: deja la ventana enfocada en modo tiled ocupando la mitad izquierda/derecha
# (junto a otra). Maximizar (Alt+F10) es lo mismo pero ocupando todo el workspace.
func _snap_tile(dir):
	if not tile_mode or focused_tile < 0:
		return
	var units = _units()
	var ui = _focused_unit_index(units)
	var members = units[ui]
	if members.size() >= 2:
		# Ya está en una franja: la reordena para quedar a la izquierda/derecha.
		var i = members.find(focused_tile)
		if i < 0:
			return
		var j = 0 if dir < 0 else members.size() - 1
		if i != j:
			members.remove(i)
			members.insert(j, focused_tile)
			_rebuild_tiles(units)
		for m in members:
			split_weight[m] = 1.0
		_focus_tile(focused_tile)
		return
	# Suelta: la tilea con otra pantalla vecina.
	var other = -1
	for k in range(units.size()):
		if k == ui:
			continue
		other = units[k][0]
		break
	if other < 0:
		return
	if dir < 0:
		_tile_drop(other, focused_tile)  # enfocada primero = izquierda
	else:
		_tile_drop(focused_tile, other)  # enfocada segunda = derecha
	split_weight[other] = 1.0
	split_weight[focused_tile] = 1.0


# Reordena la franja moviendo la pantalla de `dragged` al lugar de la de `anchor`.
func _move_window_to(dragged, anchor, before):
	if dragged < 0 or anchor < 0 or dragged == anchor:
		return
	if not tiles.has(dragged) or not tiles.has(anchor):
		return
	var units = _units()
	var du = _focused_unit_index_of(units, dragged)
	var au = _focused_unit_index_of(units, anchor)
	if du < 0 or au < 0 or du == au:
		return
	var moved = units[du]
	units.remove(du)
	var target = _focused_unit_index_of(units, anchor)
	if target < 0:
		target = units.size() - 1
	if not before:
		target += 1
	units.insert(int(clamp(target, 0, units.size())), moved)
	_rebuild_tiles(units)
	_focus_tile(dragged)


func _focused_unit_index_of(units, id):
	for i in range(units.size()):
		if units[i].has(id):
			return i
	return -1


# Enfoca la pantalla u (recordando su último miembro enfocado).
func _focus_unit(units, u):
	if u < 0 or u >= units.size():
		return
	var members = units[u]
	var want = unit_focus.get(members[0], members[0])
	if not members.has(want):
		want = members[0]
	_focus_tile(want)


# Intercambia pantallas en la fila (←/→). ↑/↓ sin efecto con una sola fila.
func _swap_dir(dir):
	if _at_home() or _home_anim_active():
		return
	if not tile_mode or tiles.empty():
		return
	if dir != -1 and dir != 1:
		return
	var units = _units()
	var ui = _focused_unit_index(units)
	_swap_units(units, ui, ui + dir)


func _swap_units(units, a, b):
	if a < 0 or b < 0 or a >= units.size() or b >= units.size() or a == b:
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
	if on:
		expose_sel = max(tiles.find(focused_tile), 0)
		release_modifiers()  # no dejar Ctrl/Shift pegados en la app al entrar
	# El pasaje se anima: cada ventana arranca desde su transform actual (pantalla o tarjeta).
	var now = OS.get_ticks_msec()
	for id in tiles:
		var node = tile_nodes.get(id)
		if node != null and is_instance_valid(node):
			view_anim[id] = {"from_pos": node.rect_position, "from_scale": node.rect_scale.x, "since": now}
	request_redraw()


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


# --- Grupos (pantallas partidas) y minimizar ---

func _remove_from_group(id):
	split_weight.erase(id)
	for i in range(groups.size() - 1, -1, -1):
		var g = groups[i]
		var k = g.find(id)
		if k >= 0:
			g.remove(k)
			if g.size() < 2:
				groups.remove(i)
			break
	request_redraw()


# Pantalla partida: `a` se suma a la pantalla de `b` (drag en el Frame, o teclado).
func _tile_drop(a, b):
	if a < 0 or b < 0 or a == b:
		return
	if not tiles.has(a) or not tiles.has(b):
		return
	_remove_from_group(a)
	var g = _group_of(b)
	if g == null:
		g = [b, a]
		groups.append(g)
		split_weight[b] = 1.0
		split_weight[a] = 1.0
	else:
		g.append(a)
		split_weight.erase(a)
	# Quedan contiguas (la pantalla sale en orden b, a).
	tiles.erase(a)
	var at = tiles.find(b)
	tiles.insert((at + 1) if at >= 0 else tiles.size(), a)
	unit_focus[b] = a
	_focus_tile(a)


# Saca la ventana de su grupo: vuelve a pantalla completa.
func _untile_window(id):
	if id < 0 or not tiles.has(id) or _group_of(id) == null:
		return
	_remove_from_group(id)
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
	minimized[id] = true
	tiles.erase(id)
	tile_fade.erase(id)
	tile_intro.erase(id)
	tile_anim.erase(id)
	view_anim.erase(id)
	# Se libera ya el nodo: si `tiles` queda vacío no habrá _update_tiles() que lo
	# limpie y podría quedar un cuadro fantasma de la ventana minimizada.
	var node = tile_nodes.get(id)
	if node != null and is_instance_valid(node):
		node.queue_free()
	tile_nodes.erase(id)
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


# Alt+F10: maximizar = sacar la ventana de su franja partida para que ocupe todo el
# hueco central del Frame (K12). Ya no se esconde el Frame: la ventana no queda por
# debajo de las barras, así que ocultarlo sólo dejaría franjas vacías. Pantalla
# completa (todo el viewport, sin Frame) sigue siendo Alt+F11.
func _maximize_window(id):
	if id < 0 or not tiles.has(id):
		return
	fullscreen_id = -1
	_remove_from_group(id)
	_focus_tile(id)
	request_redraw()


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
	if is_key_pressed(KEY_TAB):
		apps_view = not apps_view
	if apps_view:
		_draw_apps(offset)
		return
	var vp = get_viewport_rect().size
	set_next_window_pos(Vector2(offset, 0.0), true)
	set_next_window_size(vp, true)
	var flags = WINDOW_NO_DECORATION | WINDOW_NO_BACKGROUND | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS | WINDOW_NO_BRING_TO_FRONT_ON_FOCUS
	# Sin padding el fondo y las posiciones absolutas coinciden con la vista.
	push_style_var_vec2(STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	if begin("##home", flags):
		# Fondo: degradado sobrio, color sólido o imagen configurada (K11a).
		_draw_home_background(vp)

		home_icon_loads = 8
		var u = grid_unit(vp)
		var pad = 0.0  # bloques pegados al borde, igual que el Frame (sin margen de 1px)
		var btn_size = Vector2(u * 1.25, u * 1.25)
		var entries = _ring_entries()
		var layout = _orbit_layout(vp, entries.size(), entries)
		_ring_prune(entries)

		# El equipo propio ocupa el centro de la órbita; las apps quedan alrededor.
		# El ícono central (figura XO/monitor) ya no es decorativo: abre el menú de
		# sesión (Salir/Recargar), porque 'Salir' dejó de ser actividad del anillo.
		var cc = vp * 0.5
		var monitor = Rect2(cc - Vector2(u * 0.45, u * 0.45), Vector2(u * 0.90, u * 0.90))
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
		imgui_draw_circle_filled(cc + Vector2(0.0, 3.0), cr, Color(0, 0, 0, 0.35), 0)
		imgui_draw_circle_filled(cc, cr, center_face, 0)
		imgui_draw_circle(cc, cr, HOME_BLOCK_DARK, 0, 2.0)
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
				recovery.restart(self)
			end_popup()
		MENU_STYLE.end(self)

		# Anillo: ACTIVITIES + favoritos, con reacomodo animado al entrar/salir ítems.
		ring_layout = []
		ring_drop = null
		var mouse = get_mouse_pos()
		var slide = Vector2(offset, 0.0)
		for i in range(entries.size()):
			var e = entries[i]
			var pos = _ring_show(e.name, layout[i], now)
			var screen = pos + slide
			var label = e.name
			if e.activity != null and e.activity.has("service") and _service_running(e.name):
				label += " *"
			var clicked = _draw_ring_item(pos, btn_size, _ring_tex(e), label,
				_ring_state(e), e.id, starting.get(e.name, -1), _ring_appear(e.name, now))
			ring_layout.append({"entry": e, "screen": screen, "size": btn_size})
			if ring_drag != null and e.kind == "favorite" and e.name != ring_drag.name:
				var d = (mouse - (screen + btn_size * 0.5)).length()
				if d < btn_size.x * 1.6 and (ring_drop == null or d < ring_drop.dist):
					ring_drop = {"screen": screen, "size": btn_size, "dist": d, "entry": e}
			if clicked and ring_suppress != e.name:
				_ring_activate(e, pos, btn_size)
		ring_suppress = ""

		# Fantasma del ítem arrastrado, anclado al punto de agarre (no centrado).
		if ring_drag != null:
			_draw_ring_ghost(ring_drag, mouse - ring_grab, btn_size)
			if ring_drop != null:
				imgui_draw_circle(ring_drop.screen + ring_drop.size * 0.5, ring_drop.size.x * 0.5 + 3.0, accent, 0, 2.5)

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
	if File.new().file_exists(exe):
		OS.execute(exe, args, false)


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


# --- Anillo: entradas, favoritos y layout animado --------------------------------

# Ruta del archivo de favoritos: $XDG_CONFIG_HOME/gdtk/ring-favorites.json
# (~/.config/gdtk/ring-favorites.json por defecto), mismo patrón que frame-applets.json.
func _ring_path():
	var base = OS.get_environment("XDG_CONFIG_HOME")
	if base == "":
		base = OS.get_environment("HOME") + "/.config"
	return base + "/gdtk/ring-favorites.json"


func _load_ring():
	ring_favorites = []
	ring_saved = []
	var f = File.new()
	if f.open(_ring_path(), File.READ) == OK:
		var txt = f.get_as_text()
		f.close()
		var res = JSON.parse(txt)
		if res.error == OK:
			var data = res.result
			var arr = data.get("favorites", []) if typeof(data) == TYPE_DICTIONARY else data
			if typeof(arr) == TYPE_ARRAY:
				for v in arr:
					if typeof(v) == TYPE_STRING and not ring_favorites.has(v):
						ring_favorites.append(v)
	ring_saved = ring_favorites.duplicate()


# Escritura atómica (tmp + rename); sin cambios reales no toca el archivo.
func _save_ring():
	if ring_saved == ring_favorites:
		return
	var path = _ring_path()
	Directory.new().make_dir_recursive(path.get_base_dir())
	var tmp = path + ".tmp"
	var w = File.new()
	if w.open(tmp, File.WRITE) != OK:
		printerr("shell: no se pudo escribir ", tmp)
		return
	w.store_string(JSON.print({"favorites": ring_favorites}))
	w.close()
	if Directory.new().rename(tmp, path) != OK:
		printerr("shell: no se pudo renombrar ", tmp, " a ", path)
		return
	ring_saved = ring_favorites.duplicate()


# Añade un favorito al anillo (Frame -> Anillo). Sin duplicar por id; el dedup por
# nombre contra ACTIVITIES se resuelve al armar las entradas.
func add_ring_favorite(app_id):
	if app_id == "" or ring_favorites.has(app_id):
		return
	ring_favorites.append(app_id)
	_save_ring()
	request_redraw()


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


# Entradas del anillo: primeras las actividades de ACTIVITIES (orden fijo), después
# los favoritos resueltos por `apps`. Sin duplicar por nombre (una app abierta ya
# figura como actividad dinámica).
# Entradas del anillo, DINÁMICAS: sólo lo que está abierto/activo (sin Launcher ni
# demos del catálogo), ordenado por último uso, más los favoritos de la persona en
# su orden guardado. "Configuración" vive en el submenú del ícono central.
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
	for id in ring_favorites:
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
		_launch_app(e.app)
		return
	var i = _activity_named(e.name)
	if i < 0:
		return
	var act = ACTIVITIES[i]
	if act.has("wayland") and _activity_state(act) == "closed":
		pending_origin = Rect2(pos, size)
		pending_origin_since = OS.get_ticks_msec()
		starting[act.name] = OS.get_ticks_msec()
	_activate(i)


# Fantasma del arrastre del anillo: placa circular con el ícono, anclado al agarre.
func _draw_ring_ghost(entry, pos, size):
	var c = pos + size * 0.5
	var radius = size.x * 0.5 - 2.0
	imgui_draw_circle_filled(c + Vector2(2.0, 3.0), radius, Color(0, 0, 0, 0.35), 0)
	imgui_draw_circle_filled(c, radius, RING_PLATE, 0)
	imgui_draw_circle(c, radius, accent, 0, 2.5)
	var tex = _ring_tex(entry)
	if tex != null:
		var side = clamp(size.x * 0.56, 64.0, 72.0)
		set_cursor_pos(c - Vector2(side, side) * 0.5)
		image(tex, Vector2(side, side))
	else:
		var cw = 7.0 * get_imgui_scale()
		set_cursor_pos(c - Vector2(cw * 0.5, 6.5 * get_imgui_scale()))
		text_colored(Color(0.95, 0.85, 0.95, 1.0), entry.name.substr(0, 1))


# ¿El punto cae en la zona del anillo (Hogar a la vista)? El Frame lo consulta al
# soltar un app arrastrado para crear un favorito (Frame -> Anillo).
func is_ring_drop(pos):
	if current_activity != null or neighborhood_view:
		return false
	var vp = get_viewport_rect().size
	var top = frame_bar_h(vp)
	return pos.y > top and pos.y < vp.y - top


# Entrada del anillo cuyo rect (en pantalla) contiene el punto.
func _ring_hit(pos):
	for it in ring_layout:
		if pos.x >= it.screen.x and pos.x < it.screen.x + it.size.x \
				and pos.y >= it.screen.y and pos.y < it.screen.y + it.size.y:
			return it
	return null


# Id del favorito mostrado más cercano al punto (dentro del radio de una tesela),
# o "" si no hay ninguno cerca. `exclude_id` es el favorito arrastrado, que se salta
# para que soltarlo sobre sí mismo no lo mande al final. Un favorito arrastrado toma
# el lugar del más cercano.
func _favorite_target_near(pos, exclude_id = ""):
	var best = ""
	var bd = 1e9
	var bs = 0.0
	for it in ring_layout:
		var e = it.entry
		if e.kind != "favorite" or e.app.id == exclude_id:
			continue
		var d = (pos - (it.screen + it.size * 0.5)).length()
		if d < bd:
			bd = d
			best = e.app.id
			bs = it.size.x
	if best != "" and bd > bs * 1.6:
		return ""
	return best


# Inicio/reanudación del drag del anillo desde _input (el clic normal lo maneja ImGui).
func _ring_mouse(pressed, pos):
	if current_activity != null or apps_view or neighborhood_view:
		ring_press = null
		ring_drag = null
		ring_drop = null
		return
	if pressed:
		var hit = _ring_hit(pos)
		if hit != null:
			ring_press = hit.entry
			ring_from = pos
			ring_grab = pos - hit.screen
			ring_drag = null
	else:
		if ring_drag != null:
			_finish_ring_drag(pos)
			ring_suppress = ring_drag.name
		ring_press = null
		ring_drag = null
		ring_drop = null
		request_redraw()


func _finish_ring_drag(pos):
	var e = ring_drag
	if e == null:
		return
	# Ring -> basurero: borra el favorito (una actividad no se borra).
	if frame != null and frame.is_trash(pos):
		if e.kind == "favorite":
			ring_favorites.erase(e.app.id)
			_save_ring()
			request_redraw()
		return
	# Reordenar favoritos: el que se suelta sobre otro toma su lugar.
	if e.kind == "favorite":
		var target = _favorite_target_near(pos, e.app.id)
		if target != "":
			ring_favorites.erase(e.app.id)
			var at = ring_favorites.find(target)
			if at < 0:
				at = ring_favorites.size()
			ring_favorites.insert(at, e.app.id)
			_save_ring()
			request_redraw()


# Posiciones de las actividades en órbitas alrededor de la computadora.
func _home_layout(vp):
	return _orbit_layout(vp, ACTIVITIES.size(), ACTIVITIES)


# Distribución del anillo: pocas → un círculo ordenado alrededor del equipo central;
# muchas → espiral de ángulo áureo con dispersión orgánica (burbujas). El orden es
# el de `entries` (ya viene por último uso). Limita cada posición al lienzo.
func _orbit_layout(vp, n, entries = []):
	var out = []
	if n <= 0:
		return out
	var u = grid_unit(vp)
	var btn = u * 1.25
	var top = frame_bar_h(vp)
	var cx = vp.x * 0.5
	var cy = vp.y * 0.5
	var avail_x = min(cx, vp.x - cx)
	var avail_y = min(cy - (top + 2.0), (vp.y - top - 18.0) - cy)
	if n <= RING_CIRCLE_MAX:
		# Círculo: orden y simetría. El radio deja libre el equipo central y el borde.
		var rad = max(btn * 1.15, min(avail_x, avail_y) - btn * 0.5)
		rad = min(rad, min(avail_x, avail_y) * 0.92)
		for i in range(n):
			var a = -PI * 0.5 + TAU * float(i) / float(n)
			var center = Vector2(cx + cos(a) * rad, cy + sin(a) * rad)
			out.append(_ring_clamp(center, btn, vp, top))
		return out
	var margin = 10.0
	var rx = max(btn * 1.4, (vp.x - btn) * 0.5 - margin)
	var ry = max(btn * 1.4, (vp.y - 2.0 * top - btn) * 0.5 - margin)
	var f_in = clamp(max(u * 0.62, btn * 0.85) / max(rx, ry), 0.12, 0.60)
	for i in range(n):
		var t = (float(i) + 0.5) / float(n)
		var f = lerp(f_in, 1.0, sqrt(t))
		var a = -PI * 0.5 + GOLDEN_ANGLE * float(i)
		var jr = 0.0
		var ja = 0.0
		if i < entries.size() and typeof(entries[i]) == TYPE_DICTIONARY:
			var h = abs(String(entries[i].get("name", "")).hash())
			ja = (float(h % 1000) / 1000.0 - 0.5) * RING_JITTER_A
			jr = (float(int(h / 1000) % 1000) / 1000.0 - 0.5) * RING_JITTER_R
		var ff = clamp(f + jr, f_in, 1.0)
		var aa = a + ja
		var center = Vector2(cx + cos(aa) * rx * ff, cy + sin(aa) * ry * ff)
		out.append(_ring_clamp(center, btn, vp, top))
	return out


# Pasa un centro de ítem (lado `btn`) a la esquina, dentro del lienzo.
func _ring_clamp(center, btn, vp, top):
	return Vector2(clamp(center.x - btn * 0.5, 2.0, vp.x - btn - 2.0),
		clamp(center.y - btn * 0.5, top + 2.0, vp.y - top - btn - 18.0))


# Insignia de identidad del Frame: figura XO + nombre de usuario, cacheada como
# cualquier ícono Sugar (el rasterizador vive acá; el Frame la consume).
func identity_tex():
	return _load_sugar_svg("computer-xo", XO_STROKE, XO_FILL)


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
	if not apps.scanned:
		apps.scan()
	var prog = ""
	if activity.has("wayland") and activity.wayland.size() > 0:
		prog = activity.wayland[0]
	# El app_id de Wayland suele traer otra capitalización que el binario del .desktop
	# (p. ej. "Alacritty" vs "alacritty"): se compara plegado o Terminal no encontraba
	# su ícono y caía al genérico.
	var want_prog = apps.fold(prog)
	if want_prog != "":
		# El app_id de Wayland puede ser reverse-DNS (org.gnome.Nautilus) o llevar
		# sufijo; el binario del .desktop suele ser el último segmento (nautilus).
		# También se compara contra StartupWMClass, que es el mapeo canónico.
		var tail = want_prog
		var dot = want_prog.find(".")
		if dot > 0:
			tail = want_prog.substr(dot + 1)
		for a in apps.apps:
			var wm = apps.fold(a.get("wm_class", ""))
			if (wm == want_prog or (wm != "" and wm == tail)) and _activity_icon_of(a) != null:
				return a.tex
		for a in apps.apps:
			var p = apps.fold(apps._program(a.exec))
			if (p == want_prog or p == tail) and _activity_icon_of(a) != null:
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
	return _load_sugar_svg("computer-xo", SUGAR_STROKE, SUGAR_FILL)


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
			_launch_app(app)
	end()


# Una app de la grilla se abre como actividad wayland dinámica: sale en el
# anillo mientras viva su ventana (ver _on_toplevel_removed).
func _launch_app(app):
	apps.query = ""
	var i = _activity_named(app.name)
	if i < 0:
		ACTIVITIES.append({"name": app.name, "wayland": ["sh", "-c", app.cmd], "dynamic": true})
		i = ACTIVITIES.size() - 1
	var act = ACTIVITIES[i]
	# Igual que el anillo: si la actividad está cerrada se registra el pulso de
	# arranque; la ventana entra animada desde el ícono de la grilla cuando llegue.
	if act.has("wayland") and _activity_state(act) == "closed":
		act["match"] = [apps._program(app.exec), app.name]
		if apps.chosen_rect != null:
			pending_origin = apps.chosen_rect
			pending_origin_since = OS.get_ticks_msec()
	_activate(i)
	# La grilla vuelve al anillo de Hogar: ahí se ve el pulso de arranque del ícono
	# hasta que llegue la ventana (la vista no salta a la actividad al lanzarla).
	apps_view = false
	apps.watch(self, app.name, last_launch_pid)
	# Si no se pudo lanzar, no queda colgada en el anillo.
	if not _pending_has(app.name) and not wayland_ids.has(app.name) and ACTIVITIES[i].get("dynamic", false):
		ACTIVITIES.remove(i)


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
	for a in ACTIVITIES:
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
func _start_publishers():
	if _publish_started:
		return
	_publish_started = true
	_publisher = PUBLISH_MODEL.new()
	var avahi = _publisher.detect_avahi()
	if not avahi.available:
		return   # degradado, sin error
	var identity = PUBLISH_PLAN.local_identity(_local_hostname(), local_device_kind())
	var caps = {"gvd": true, "gvd_port": 5600, "deskflow": true, "deskflow_port": 24800,
		"deskflow_role": _deskflow_role}
	var plan = PUBLISH_PLAN.new().build(identity, caps, avahi.path)
	for entry in plan.services:
		_publish_launch(entry)


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
	neighborhood_view = false
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
		OS.execute("swaymsg", cmd, false)


func _apply_deskflow_settings():
	if settings_bridge == null or settings_bridge.model == null:
		return
	var cfg = settings_bridge.model.deskflow(settings_bridge.settings.get("deskflow", {}))
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


func _deskflow_activity():
	for a in ACTIVITIES:
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
		imgui_draw_rect_filled(Rect2(Vector2.ZERO, vp), Color(0.0, 0.0, 0.0, 0.30))
		return
	if mode == "solid" and settings_bridge != null and settings_bridge.model != null:
		imgui_draw_rect_filled(Rect2(Vector2.ZERO, vp), settings_bridge.model.color_of_hex(settings_bridge.settings.get("wallpaper", {}).get("color", "")), 0.0)
		return
	imgui_draw_rect_filled_multicolor(Rect2(Vector2.ZERO, vp), HOME_BG_TOP, HOME_BG_TOP, HOME_BG_BOTTOM, HOME_BG_BOTTOM)


# --- Vecindario --------------------------------------------------------------

# Abrir la vista Vecindario desde el bloque del Frame (sin actividad abierta).
func _go_neighborhood():
	if current_activity != null or apps_view:
		_go_home()
	neighborhood_view = true
	nb_zoom_target = 1.0
	expose = false
	if neighborhood != null:
		neighborhood.poll()
	_refresh_direction_views()
	neighborhood_ui.refresh(true)
	request_redraw()


# Volver al Hogar desde el Vecindario (Esc, el bloque Inicio o el mismo bloque).
func _close_neighborhood():
	neighborhood_view = false
	nb_zoom_target = 0.0
	neighborhood_ui.selected = ""
	neighborhood_ui.selected_host = ""
	request_redraw()


# El hilo de refresco no debe quedar vivo al recargar/cerrar el shell.
func _exit_tree():
	if neighborhood != null:
		neighborhood.stop()
		neighborhood = null
	_stop_service_worker()
	# Anuncios mDNS: sus Threads ya terminaron con el worker; matar los pids vivos.
	_stop_publishers()
	# Buzón del handshake: detiene el worker y espera los envíos ssh en curso.
	_stop_inbox()
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


# Vuelca el estado ya disponible a la vista (nunca consulta red/procesos/disco).
func _refresh_direction_views():
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
		_write_texts_async(writes, "", then_launch)
		return
	_launch_tracked(key, String(launch.cmd), launch.args)


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
	for a in ACTIVITIES:
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
# El shell lanza/corta gvd solo: emisor local si es GNOME, receptor remoto por
# ssh (buzón), receptor local en un tile (actividad "Pantalla"), `--position` del
# mapa y `--cursor sway` si hay SWAYSOCK; además suspende y restaura el vínculo
# Deskflow de esa dirección. Nada bloquea el render: los procesos van por
# _launch_tracked (Threads) y el estado se lee de caches.

func _screen_keys(host_id):
	return GVD_LAUNCH.session_keys(host_id)


func _screen_session_active(host_id):
	for k in _screen_keys(host_id):
		if _has_tracked(k):
			return true
	return false


func _stop_gvd_screen(host_id):
	var id = String(host_id)
	for k in _screen_keys(id):
		_stop_tracked(k)
	_close_pantalla_window()
	_restore_deskflow_link(id)


func _close_pantalla_window():
	if wayland_ids.has("Pantalla") and _id_alive(wayland_ids["Pantalla"]):
		compositor.close(wayland_ids["Pantalla"])


# Abre el receptor local en un tile: reutiliza la actividad wayland "Pantalla"
# con el argv calculado (`--cursor sway` sólo si la sesión expone SWAYSOCK).
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


func _direction_for(host_id):
	var entry = host_directions.get(String(host_id), {})
	if typeof(entry) != TYPE_DICTIONARY:
		return ""
	var d = String(entry.get("direction", "none")).strip_edges()
	return d if DIRECTIONS_MODEL.valid_direction(d) else ""


func _has_sway_socket():
	return OS.get_environment("SWAYSOCK").strip_edges() != ""


# ¿Hay canal autorizado hacia este host para abrir su receptor (ssh/buzón)? Es el
# mismo canal que usa `_start_gvd_screen` para el receptor remoto; el Vecindario lo
# consulta para habilitar las acciones de pantalla cuando el peer anuncia
# state=capable (no mantiene receptor escuchando). Barato: lookup + modelo puro.
func provision_channel_for(host_id):
	return bool(_inbox_peer_for(String(host_id)).get("ok", false))


# Arranca una sesión de pantalla hacia `host_id`. `share_my_screen` emite local
# (si GNOME) y abre el receptor del peer por ssh; `use_as_screen` abre el receptor
# local en un tile y pide al peer (GNOME) que emita. Nunca bloquea.
func _start_gvd_screen(host_id, action):
	var id = String(host_id)
	var plan = action.get("plan", null) if typeof(action) == TYPE_DICTIONARY else null
	var gvd_path = GVD_LAUNCH.gvd_path_of(plan)
	if gvd_path == "":
		activity_error = "pantalla: no se encontró el programa de pantalla"
		return
	var direction = _direction_for(id)
	var target = _inbox_peer_for(id)
	var aid = String(action.get("id", "")) if typeof(action) == TYPE_DICTIONARY else ""
	if aid == "share_my_screen":
		if not GVD_LAUNCH.local_can_emit(OS.get_environment("XDG_CURRENT_DESKTOP"),
				OS.get_environment("XDG_SESSION_TYPE")):
			activity_error = "pantalla: este equipo no puede emitir su escritorio"
			return
		var peer = GVD_LAUNCH.target_host_of(plan)
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
		_launch_tracked(id, String(sp.get("cmd", "")), sp.get("args", []))
		_suspend_deskflow_link(id, direction)
		if bool(target.get("ok", false)):
			var rp = GVD_LAUNCH.remote_recv_argv(String(target.get("peer", "")), _has_sway_socket())
			if bool(rp.get("ok", false)):
				_launch_tracked(GVD_LAUNCH.remote_recv_key(id),
					String(rp.get("cmd", "")), rp.get("args", []))
	else:
		_open_pantalla_window(gvd_path, _has_sway_socket(), GVD_LAUNCH.port_of_plan(plan))
		if bool(target.get("ok", false)):
			var rp2 = GVD_LAUNCH.remote_send_argv(String(target.get("peer", "")),
				_local_hostname(), GVD_LAUNCH.port_of_plan(plan),
				GVD_LAUNCH.position_for(direction, true))
			if bool(rp2.get("ok", false)):
				_launch_tracked(GVD_LAUNCH.remote_send_key(id),
					String(rp2.get("cmd", "")), rp2.get("args", []))
	request_redraw()


# Suspende el vínculo Deskflow hacia la dirección extendida: si había una sesión
# de servidor Deskflow viva para ese host, se corta y se recuerda su argv para
# restaurarla al cortar la pantalla. La dirección queda marcada para que un
# layout posterior no la reintroduzca (ver apply_deskflow_layout).
func _suspend_deskflow_link(host_id, direction):
	var id = String(host_id)
	_gvd_link_suspended[id] = String(direction)
	var key = HOST_DISPATCH.deskflow_session_key(id)
	if _has_tracked(key):
		_stop_tracked(key)
		if _deskflow_server_launch.has(id):
			_gvd_link_restore[id] = true


func _restore_deskflow_link(host_id):
	var id = String(host_id)
	_gvd_link_suspended.erase(id)
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
	var reaped = false
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
			_add_tile(id)
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


func _add_tile(id):
	if not tiles.has(id):
		tiles.append(id)
		tile_intro[id] = _new_intro()
	request_redraw()


# Entrada animada: si hay un ícono de origen reciente, escala desde él; si no, desde el
# borde derecho (mismo tamaño). `ready` pasa a true con la primera textura.
# `scale_in`: crece en su lugar (desminimizar), sin traslación desde el borde.
func _new_intro(scale_in = false):
	var from = null
	if not scale_in and pending_origin != null and OS.get_ticks_msec() - pending_origin_since < 4000:
		from = pending_origin
	pending_origin = null
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


func _on_view_input(event):
	if window_dragging:
		return
	if expose:
		# Zoom out del escritorio: hover para mostrar el botón de cerrar, clic para
		# elegir una ventana (cambia a su pantalla y la enfoca) o cerrarla.
		if event is InputEventMouseMotion:
			var over = _expose_hit(event.position)
			if over != expose_hover:
				expose_hover = over
				request_redraw()
			return
		if event is InputEventMouseButton and event.pressed:
			var cid = _expose_close_hit(event.position)
			if cid >= 0:
				_close_window_id(cid)
				expose_hover = -1
				return
			var hit = _expose_hit(event.position)
			if hit >= 0:
				expose_sel = tiles.find(hit)
				_expose_commit()
			return
		return
	if event is InputEventMouseMotion:
		# Asa de redimensión de la franja: primero la arrastra, después sólo la insinúa.
		if resize_handle != null:
			_resize_to(resize_handle, event.position.x)
			request_redraw()
			return
		hover_handle = _handle_at(event.position)
		if hover_handle != null:
			request_redraw()
			return
		var hit = _view_hit_test(event.position)
		if hit.id < 0:
			return
		_focus_follow(hit)
		compositor.pointer_motion(hit.id, hit.pos)
	elif event is InputEventMouseButton:
		# Con Super la rueda es para el shell (cambiar de workspace), no para la app.
		if (event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN) \
				and Input.is_key_pressed(KEY_META):
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
		compositor.focus(int(d.dialog))
		request_redraw()
	else:
		focused_dialog = 0
		_focus_tile(int(d.target))


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
	for i in range(dialogs.size() - 1, -1, -1):
		var d = dialogs[i]
		var rect = _dialog_rect(d)
		if rect.has_point(pos):
			# El compositor espera coords del buffer: la caja alinea la geometry en
			# rect.position, así que se suma geo.position.
			return {"id": d, "pos": pos - rect.position + _dialog_geo(d).position, "dialog": d}
	for id in tiles:
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
		if content.has_point(pos):
			if fit != null and fit.scale > 0.0:
				return {"id": id, "pos": (pos - r.position - fit.offset) / fit.scale, "dialog": 0}
			return {"id": id, "pos": pos - r.position + geo.position, "dialog": 0}
	return {"id": -1, "pos": Vector2.ZERO, "dialog": 0}


# Teclear en el Home lleva a la búsqueda de apps.
# En _input (Godot 3 lo llama también en ImGuiCanvas): con el puntero sobre el
# home ImGui marca todo como manejado y a _unhandled_input no llega nada.
func _input(event):
	last_activity = OS.get_ticks_msec()
	# InputCapture toma exclusivamente el hardware local. Los eventos EIS que entran
	# desde otro equipo tienen DEVICE_ID y nunca deben volver a Deskflow.
	if remote_input != null and event.device != RemoteInput.DEVICE_ID:
		var captured = false
		var now = OS.get_ticks_msec()
		if event is InputEventMouseMotion:
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
		elif event is InputEventKey:
			var physical = event.physical_scancode if event.physical_scancode != 0 else event.scancode
			captured = remote_input.capture_key(physical, event.pressed, now)
		if captured:
			# Captura activa: pointer lock para recibir deltas crudos del compositor
			# (sway clava el puntero en el borde y sin esto `relative` es ~0).
			if not mouse_locked:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				mouse_locked = true
			get_tree().set_input_as_handled()
			return
		if mouse_locked:
			# Deskflow soltó el control: devolver puntero y cursor al escritorio local.
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			mouse_locked = false
	if event is InputEventMouseMotion:
		input_motion_count += 1
		# Drag del anillo (Hogar): el clic normal lo resuelve ImGui; acá sólo se
		# detecta el arrastre una vez superado el umbral.
		if ring_press != null and ring_drag == null and event.position.distance_to(ring_from) > DRAG_PX:
			ring_drag = ring_press
			request_redraw()
		elif ring_drag != null:
			request_redraw()
	elif event is InputEventMouseButton:
		input_button_count += 1
		input_last_button = {"button": event.button_index, "pressed": event.pressed, "device": event.device, "pos": [event.position.x, event.position.y]}
		if event.button_index == BUTTON_LEFT:
			_ring_mouse(event.pressed, event.position)
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


func _unhandled_input(event):
	if not (event is InputEventKey):
		return
	var id = _current_wayland_id()
	if id < 0:
		id = last_key_target  # última ventana que recibió teclas (exposé/Home incluidos)
	if id < 0:
		return
	if event.pressed:
		# Las pulsaciones sólo van a la app con una actividad wayland activa y sin exposé.
		if current_activity == null or not current_activity.has("wayland") or expose:
			return
		last_key_target = id
	# Las SUELTAS se reenvían siempre (aunque estemos en exposé o en Home): si no, un
	# modificador apretado antes de abrir exposé/Home queda pegado en la app.
	compositor.key(event)
	get_tree().set_input_as_handled()


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


# Sólo con un host que no exponga wlr_virtual_pointer: en X11 se mueve el puntero real
# (warp) y en Wayland el módulo usa el cursor nativo del host (remote_pointer.c), así que
# este cursor dibujado queda como último recurso y casi nunca se ve.
func _move_eis_cursor(event):
	if event.device != RemoteInput.DEVICE_ID:
		if event is InputEventMouseMotion:
			eis_cursor.visible = false
		return
	if OS.get_environment("GDTK_SESSION") == "x11":
		Input.warp_mouse_position(event.position)
		return
	eis_cursor.position = event.position
	eis_cursor.visible = true
