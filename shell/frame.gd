extends Node

# El Frame (como en Sugar): franja superpuesta arriba con Inicio, todo lo que
# corre (actividades internas con instancia viva y toplevels wayland sin padre,
# los haya lanzado el shell o no) y el reloj. No ocupa espacio: la app usa toda
# la pantalla y el Frame se dibuja encima (ViewLayer va en layer -1, bajo ImGui).
#
# Se muestra con F6, tocando Super sola (como GNOME/Sugar) o dejando el mouse
# HOT_MS en la esquina superior izquierda o contra el borde superior; en el Home
# está siempre. Se oculta al elegir algo, con Esc, con F6/Super o al sacar el
# mouse (si entró en él después de mostrarse).
# Super+F6 abre y cierra el HUD de debug (ya no hay widget mini ni F1).
#
# Super: la pulsación se retiene; si se suelta sin otra tecla ni clic entre medio
# alterna el Frame y la app no ve nada. Si llega otra tecla (Super+L...), la
# pulsación retenida se reenvía antes a la app y el combo le llega entero. FRT la
# entrega como scancode KEY_META (keysym) con physical KEY_SUPER_L/R.
#
# Autohide: con la barra oculta hay que empujar el canto (arriba/abajo, HOT_EDGE px)
# durante HOT_MS para revelarla; entrar en la franja del Frame no alcanza, así no se
# dispara al interactuar con el contenido pegado al borde. Un clic mientras espera la
# desarma hasta salir de la franja.
#
# Alt+Tab / Alt+Shift+Tab ciclan entre lo abierto sin mostrar el Frame. Se eligió
# Alt+Tab (no Ctrl+Tab, que usan las apps para pestañas): bajo cage en DRM llega
# al shell; sólo en cage anidado lo roba el escritorio anfitrión (probar con el
# control remoto: `key alt+Tab`).

const HOT_MS = 250
# Entrada/salida del Frame deslizándose desde arriba (ease-out).
const SLIDE_MS = 130
const SUPER_KEYS = [KEY_META, KEY_SUPER_L, KEY_SUPER_R]
const PAD = 0.0          # sin separación entre bloques del Frame (pegados al borde)
const TILE_PAD = 4.0     # aire entre texto/ícono y el borde del bloque (escala con la UI)
const HOT_EDGE = 4.0     # con autohide sólo revela si el puntero empuja contra este canto
const DRAG_PX = 8.0
# Estilo WindowMaker/NeXT: teselas CUADRADAS de una unidad de rejilla (shell.grid_unit),
# bisel de 2px sin esquinas redondeadas, fondo gris azulado oscuro tipo NeXT. El bloque
# comunica identidad/estado aunque el nombre no quepa; el nombre largo va en el tooltip.
const NX_BG = Color(0.14, 0.16, 0.24, 0.97)
const NX_FACE = Color(0.28, 0.32, 0.42, 1.0)
const NX_FACE_SEL = Color(0.40, 0.46, 0.58, 1.0)
const NX_FACE_DIM = Color(0.19, 0.21, 0.29, 1.0)
const NX_LIGHT = Color(0.55, 0.61, 0.74, 1.0)
const NX_DARK = Color(0.07, 0.08, 0.13, 1.0)
const NX_FOCUS = Color(0.86, 0.89, 0.97, 1.0)
const NX_TEXT = Color(0.93, 0.94, 0.97, 1.0)
const NX_TEXT_DIM = Color(0.60, 0.63, 0.72, 1.0)
const NX_SEL = Color(0.98, 0.80, 0.36, 1.0)
const NX_CUR = Color(0.32, 0.60, 0.98, 1.0)
const BEVEL_BASE = 2.0    # grosor base del bisel (se escala con la UI y Apariencia)
# Sombra suave del Frame sobre el contenido, pegada al borde interior de cada barra.
const SHADOW = 3.0
const SHADOW_ALPHA = 0.18
const TITLE_H = 14.0     # alto de la línea de título dentro de la tesela
const TITLE_MAX = 10     # máximo de caracteres del título (se recorta con ...)
const ICON_MIN = 48.0    # piso del ícono de un bloque con título (Inicio/Vecindario)
const ICON_MAX = 72.0
const ICON_TILE_MIN = 64.0  # en bloques de ventana el ícono nunca baja de 64 px
const MINI = 14.0        # alto de la mini-tesela de cerrar (sólo al hover)
# Applets del borde inferior (SPEC-sugar-frame-applets.md): cada control es un bloque
# cuadrado U x U de la misma rejilla, reordenable y ocultable. Lista corta de ids
# estables; sin arquitectura genérica de providers.
const APPLETS = [
	{"id": "recursos", "name": "CPU · Memoria · Swap", "short": "SYS", "span": 1},
	{"id": "termico", "name": "Temperatura · Governor", "short": "TEMP", "span": 1},
	{"id": "reloj", "name": "Reloj", "short": "REL"},
	{"id": "teclado", "name": "Teclado", "short": "TEC"},
]
const APPLET_DEFAULT = ["recursos", "termico", "reloj", "teclado"]
# Look WindowMaker de los menús verticales (popups ImGui). Sólo estilo.
const MENU_STYLE = preload("res://menu_style.gd")
# K10b: modelo PURO de los bloques "Compartido" (sesiones activas con vecinos).
const SHARED_BLOCK = preload("res://shared_block.gd")
# Grosor de la barra de estado del bloque "Compartido".
const SHARED_W = 3.0
# Relieve (bisel) de los bloques: el ancho base ya no es fijo en píxeles. Escala
# con la UI (que sale de la unidad de rejilla y por lo tanto del tamaño de pantalla:
# en pantallas densas 2 px se veían como un hilo) y admite el factor de Apariencia
# (settings.json). Tope para que un factor alto no se coma el bloque.
const BEVEL_MAX_W = 6.0
# Etiqueta de bloque: más chica que el texto de UI para que quepa más, y hasta dos
# líneas en vez de recortar a 10 caracteres.
const LABEL_SCALE = 0.78
const LABEL_LINES = 2

onready var shell = get_parent()

var label_font = -1
var label_font_px = -1

var visible = false
var entered = false
# 0: armada; >0: ms en que el mouse llegó a la esquina; -1: desarmada hasta salir.
var corner_since = 0
var swallowed = {}
var hot_timer = false
# Pulsación de Super retenida mientras no se sepa si es un toque solo.
var super_press = null
# Pin/autohide de cada barra (K19): por defecto AMBAS con autohide (se ocultan
# solas y se muestran al acercar el mouse, superponiéndose a las ventanas sin
# redimensionarlas). Una barra fijada (pin) queda siempre visible y RESERVA su
# franja: las ventanas no se colocan debajo/encima de ella. El autohide está
# sincronizado (una sola señal `visible`), pero el pin es por barra.
var pin_top_bar = false
var pin_bottom_bar = false
var pin_saved_top = false
var pin_saved_bottom = false
# Deslizamiento por barra: último estado dibujado (mostrada u oculta) y cuándo
# cambió. Antes eran un solo `shown`/`slide_since` compartido por las dos barras.
var shown_top = false
var shown_bottom = false
var slide_since_top = 0
var slide_since_bottom = 0
# Teclado y drag: selección en el Frame, ventana "levantada" (tileo sin mouse),
# y arrastre con mouse (soltar sobre otra ventana tilea; soltar fuera deshace).
var sel = -1
var lifted = null
var dragging = null
var win_drag = null       # Super+arrastre de una ventana hacia el Frame (reordenar/tilear)
var drag_candidate = null
var drag_from = Vector2.ZERO
var mouse_down = false
var mouse_pos = Vector2.ZERO
var slide_instant = false  # aparecer sin animación (Alt+Tab)
var show_until = 0         # ms hasta el que el Frame no se auto-oculta (Alt+Tab)
# Layout del último frame dibujado (para el control remoto / tests).
var sysmon = Host.sc("res://sysmon.gd").new()
var keyboard = Host.sc("res://applet_keyboard.gd").new()
var bluetooth = Host.sc("res://applet_bluetooth.gd").new()
var items_layout = []
var drawn = false
# Applets del borde inferior: orden visible persistido (no es items_layout, que sigue
# siendo sólo de ventanas para el control remoto). `applets_future` conserva ids
# desconocidos del archivo para una versión futura.
var applets_visible = []
var applets_future = []
var applets_raw = {}
var applets_saved_bottom = []
var pinned_top = []
var pinned_dock = []
var pinned_saved_top = []
var pinned_saved_dock = []
var applets_dirty = false
var applets_layout = []    # rects del último dibujo de los applets
var applets_drawn = false
var applets_bar_rect = Rect2()  # franja inferior del último dibujo (clic derecho: controles)
var applet_picker_want = false
var applet_picker_open = false
var applet_action_want = ""
var applet_press = null    # id del applet pulsado (aún sin arrastrar)
var applet_drag = null     # id del applet que se está arrastrando (reordenar)
var applet_from = Vector2.ZERO
var app_press = null
var app_drag = null
var app_from = Vector2.ZERO
var app_grab = Vector2.ZERO    # offset del punto de agarre dentro de la tesela de app
var pinned_layout = []
var pinned_prev = []           # layout de pines del frame anterior (para el drop)
var suppress_pinned_click = ""
# Animación de las barras (reacomodo al arrastrar): id -> {from, to, x, since}.
# Mismo lenguaje de ease-out que el reacomodo del anillo (ver shell._ease_out).
var bar_anim = {}
var applet_grab = Vector2.ZERO
# K10b: bloques "Compartido" (sesiones activas). Ephemerales: no se persisten ni
# se reordenan; se dibujan a la izquierda de los applets. El estado sale de
# snapshots cacheados (host_session_state y servicios), nunca de procesos.
var shared_layout = []
var shared_drawn = false
var shared_menu_id = ""
var shared_menu_want = ""
var shared_menu_open = false
var shared_menu_block = null
var shared_press = ""
# Basurero del Frame: bloque en la esquina superior derecha, visible sólo con un
# drag activo. `trash_layout` es su rect en pantalla del último dibujo.
var trash_layout = null


func _ready():
	_load_applets()


# Los applets consultan en workers; al salir del árbol no deben quedar hilos vivos.
func _exit_tree():
	keyboard.stop()
	bluetooth.stop()


# Ruta del archivo de applets: $XDG_CONFIG_HOME/gdtk/frame-applets.json
# (~/.config/gdtk/frame-applets.json por defecto), junto a keyboard.
func _applets_path():
	var base = OS.get_environment("XDG_CONFIG_HOME")
	if base == "":
		base = OS.get_environment("HOME") + "/.config"
	return base + "/gdtk/frame-applets.json"


func _applet_def(id):
	for a in APPLETS:
		if a.id == id:
			return a
	return null


func _applet_known(id):
	return _applet_def(id) != null


func _applet_span(id):
	var a = _applet_def(id)
	return max(1, int(a.span)) if a != null and a.has("span") else 1


func _applet_width(id, side):
	var span = _applet_span(id)
	return side * float(span) + PAD * float(span - 1)


# Carga sólo el orden visible de `bottom`; archivo ausente o corrupto -> defaults.
# Ids desconocidos se guardan aparte y se reescriben intactos.
func _load_applets():
	applets_visible = APPLET_DEFAULT.duplicate()
	applets_future = []
	applets_raw = {}
	applets_saved_bottom = APPLET_DEFAULT.duplicate()
	pinned_top = []
	pinned_dock = []
	pinned_saved_top = []
	pinned_saved_dock = []
	var f = File.new()
	if f.open(_applets_path(), File.READ) == OK:
		var txt = f.get_as_text()
		f.close()
		var res = JSON.parse(txt)
		if res.error == OK and typeof(res.result) == TYPE_DICTIONARY:
			applets_raw = res.result
			for zone in ["top", "dock"]:
				var ids = applets_raw.get(zone, [])
				if typeof(ids) == TYPE_ARRAY:
					var target = pinned_top if zone == "top" else pinned_dock
					for id in ids:
						if typeof(id) == TYPE_STRING and not target.has(id):
							target.append(id)
	pinned_saved_top = pinned_top.duplicate()
	pinned_saved_dock = pinned_dock.duplicate()
	# Pin de barras (K19): default autohide (false) si el archivo no lo trae.
	var pins = applets_raw.get("pin", {})
	if typeof(pins) == TYPE_DICTIONARY:
		pin_top_bar = bool(pins.get("top", false))
		pin_bottom_bar = bool(pins.get("bottom", false))
	pin_saved_top = pin_top_bar
	pin_saved_bottom = pin_bottom_bar
	if not applets_raw.empty():
		var bottom = applets_raw.get("bottom", null)
		if typeof(bottom) == TYPE_ARRAY:
			var seen = {}
			applets_visible = []
			var saved = []
			for v in bottom:
				if typeof(v) != TYPE_STRING:
					continue
				if v in ["cpu", "memoria", "swap"]:
					v = "recursos"
				elif v in ["deskflow", "bluetooth"]:
					continue
				if _applet_known(v):
					if not seen.has(v):
						seen[v] = true
						applets_visible.append(v)
				else:
					applets_future.append(v)
				saved.append(v)
			applets_saved_bottom = saved
	applets_dirty = false


func _same_list(a, b):
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true


# Escritura atómica y sólo si el orden visible (con ids futuros) cambió. Sin cambios
# reales no toca el archivo.
func _save_applets():
	var bottom = applets_visible.duplicate()
	for id in applets_future:
		bottom.append(id)
	if _same_list(bottom, applets_saved_bottom) and _same_list(pinned_top, pinned_saved_top) and _same_list(pinned_dock, pinned_saved_dock) \
			and pin_top_bar == pin_saved_top and pin_bottom_bar == pin_saved_bottom:
		applets_dirty = false
		return
	var path = _applets_path()
	var dir = Directory.new()
	dir.make_dir_recursive(path.get_base_dir())
	applets_raw["bottom"] = bottom
	applets_raw["top"] = pinned_top
	applets_raw["dock"] = pinned_dock
	applets_raw["pin"] = {"top": pin_top_bar, "bottom": pin_bottom_bar}
	var tmp = path + ".tmp"
	var w = File.new()
	if w.open(tmp, File.WRITE) != OK:
		printerr("frame: no se pudo escribir ", tmp)
		return
	w.store_string(JSON.print(applets_raw))
	w.close()
	if dir.rename(tmp, path) != OK:
		printerr("frame: no se pudo renombrar ", tmp, " a ", path)
		return
	applets_saved_bottom = bottom
	pinned_saved_top = pinned_top.duplicate()
	pinned_saved_dock = pinned_dock.duplicate()
	pin_saved_top = pin_top_bar
	pin_saved_bottom = pin_bottom_bar
	applets_dirty = false


func _applet_set_visible(id, v):
	if v:
		if not applets_visible.has(id):
			applets_visible.append(id)
			if id == "teclado":
				keyboard.refresh(true)
	elif applets_visible.has(id):
		applets_visible.erase(id)
	applets_dirty = true
	_save_applets()
	shell.request_redraw()


func _applet_move(id, dir):
	var i = applets_visible.find(id)
	if i < 0:
		return
	var j = i + dir
	if j < 0 or j >= applets_visible.size():
		return
	applets_visible.remove(i)
	applets_visible.insert(j, id)
	applets_dirty = true
	_save_applets()
	shell.request_redraw()


func _pinned_app(id):
	if not shell.apps.scanned:
		shell.apps.scan()
	for app in shell.apps.apps:
		if app.id == id:
			return app
	return null


func _pin_app(app, zone, x):
	pinned_top.erase(app.id)
	pinned_dock.erase(app.id)
	var target = pinned_top if zone == "top" else pinned_dock
	var index = int(clamp(_pin_slot(zone, x), 0, target.size()))
	target.insert(index, app.id)
	_save_applets()
	shell.request_redraw()


# Índice de inserción en la zona: cuántos pines (del frame anterior, sin el arrastrado)
# tienen su centro a la izquierda de x. Es el mismo cálculo para preview y drop.
func _pin_slot(zone, x):
	var index = 0
	for tile in pinned_prev:
		if tile.zone != zone:
			continue
		if app_drag != null and tile.app.id == app_drag.id:
			continue
		if tile.rect.position.x + tile.rect.size.x * 0.5 < x:
			index += 1
	return index


func _pinned_hit(pos):
	for tile in pinned_layout:
		if tile.rect.has_point(pos):
			return tile
	return null


# Inserta `dragged` en `slot` de la lista sin él. Si no estaba, sólo se inserta.
func _order_with_gap(ids, dragged, slot):
	var rest = []
	for i in ids:
		if i != dragged:
			rest.append(i)
	slot = int(clamp(slot, 0, rest.size()))
	rest.insert(slot, dragged)
	return rest


# Posición x animada de una tesela de barra (pines/applets). Retarget con ease-out;
# pide frames mientras dura. `_bar_set` fija el punto de partida (asentado tras soltar).
func _bar_x(id, target, now):
	var a = bar_anim.get(id)
	if a == null:
		bar_anim[id] = {"from": target, "to": target, "x": target, "since": now}
		return target
	if abs(a.to - target) > 0.5:
		a["from"] = a.x
		a["to"] = target
		a["since"] = now
	var k = clamp(float(now - a.since) / float(shell.LAYOUT_MS), 0.0, 1.0)
	a["x"] = lerp(a.from, a.to, shell._ease_out(k))
	if k < 1.0:
		shell.request_redraw()
		shell.last_activity = now
	return a["x"]


func _bar_set(id, x):
	var now = OS.get_ticks_msec()
	bar_anim[id] = {"from": x, "to": x, "x": x, "since": now}
	shell.request_redraw()
	shell.last_activity = now


func _zone_at(pos):
	var bh = _vh()
	if pos.y <= bh:
		return "top"
	if pos.y >= get_viewport().size.y - bh:
		return "dock"
	return ""


func _drag_active():
	return app_drag != null or applet_drag != null or dragging != null or win_drag != null \
		or (shell != null and shell.ring_drag != null)


# Rect en pantalla del basurero (null cuando no se dibuja: sin drag activo).
func trash_rect():
	return trash_layout


func is_trash(pos):
	return trash_layout != null and trash_layout.has_point(pos)


func _draw_pinned(ui, ids, x, side, zone):
	var now = OS.get_ticks_msec()
	var step = side + PAD
	var dragged = app_drag.id if app_drag != null else null
	# Preview: con un app arrastrado en esta zona, el resto se corre dejando el hueco.
	var order = ids
	if dragged != null and _zone_at(mouse_pos) == zone:
		order = _order_with_gap(ids, dragged, _pin_slot(zone, mouse_pos.x))
	for k in range(order.size()):
		var id = order[k]
		var shown = _bar_x("pin_" + id, x + k * step, now)
		if id == dragged:
			# Hueco del destino resaltado (el fantasma va pegado al cursor).
			ui.set_cursor_pos(Vector2(shown, 0.0))
			ui.imgui_draw_rect_filled(Rect2(ui.get_cursor_screen_pos(), Vector2(side, side)), Color(1, 1, 1, 0.06), 0.0)
			ui.imgui_draw_rect_filled(Rect2(ui.get_cursor_screen_pos() + Vector2(0.0, side - 3.0), Vector2(side, 3.0)), NX_SEL, 0.0)
			continue
		var app = _pinned_app(id)
		if app == null:
			continue
		var tile = _draw_app_tile(ui, app, Vector2(shown, 0.0), side, "pin_" + zone + id, false)
		pinned_layout.append({"app": app, "rect": tile.rect, "zone": zone})
		if app_drag == null and tile.rect.has_point(mouse_pos):
			ui.set_tooltip(app.name + " · arrastrar para mover o al anillo")
		if tile.clicked and suppress_pinned_click != id:
			shell._launch_app(app)
	return x + order.size() * step


func _draw_app_tile(ui, app, pos, side, id, empty = false):
	var tile = _tile(ui, pos, side, id, NX_BG if empty else NX_FACE)
	if not empty:
		var lines = _title_lines(ui, side, app.name)
		var icon = shell._activity_icon_of(app)
		if icon != null:
			# Ícono centrado en el bloque (arriba de la línea de título) y escalado
			# con la UI: antes quedaba fijo en 56 px aun con bloques grandes.
			var ts = ui.get_imgui_scale()
			var th = _title_reserved(ui, lines)
			var pad = TILE_PAD * ts
			var icon_side = min(56.0 * ts, side - 2.0 * pad)
			# Centrado en la zona libre sobre el título, con el aire de TILE_PAD.
			var iy = pad + max(0.0, (side - th - 2.0 * pad - icon_side) * 0.5)
			ui.set_cursor_pos(pos + Vector2((side - icon_side) * 0.5, iy))
			ui.image(icon, Vector2(icon_side, icon_side))
		_tile_title(ui, pos, side, app.name, false, lines)
	return tile


# Esquina reservada: ocupa el lugar sin dibujar bloque ni relieve (queda vacía).
# Devuelve la x del siguiente bloque. El pin (si va en esa barra) se dibuja encima.
func _draw_corner_block(ui, x, y, side, id):
	return x + side + PAD


# K9 — Los menús popup (WindowMaker) se abren SÓLO con el botón derecho. El
# izquierdo queda para la acción propia del bloque (p.ej. abrir una actividad) y
# nunca abre menú. Helper puro para test; el equivalente de teclado (Enter/Espacio)
# se conserva en _frame_key.
static func menu_trigger(button_index, pressed):
	if not pressed:
		return ""
	if button_index == BUTTON_RIGHT:
		return "menu"
	if button_index == BUTTON_LEFT:
		return "primary"
	return ""


# Menú que abre el clic derecho sobre un applet: "teclado" para el applet de
# teclado; "picker" (selector de controles del Frame) para el resto. Puro para test.
static func applet_menu(id):
	return "teclado" if id == "teclado" else "picker"


# ¿Hay que muestrear los applets? Sí mientras alguna franja que los contiene esté a
# la vista: Inicio (home), el Frame abierto a pedido o una barra fijada (pin). Así los
# diales siguen vivos aunque la ventana enfocada sea otra app. Puro para test.
static func applets_live(home, frame_visible, pin_top, pin_bottom):
	return home or frame_visible or pin_top or pin_bottom


# Acción propia del bloque (clic izquierdo). Los menús van con el botón derecho
# (ver _applet_context). El applet térmico abre el menú de governor de CPU.
func _applet_primary(id):
	if id == "termico":
		applet_action_want = "gov"
		shell.request_redraw()


# Menú contextual del applet (clic derecho). Mismo destino que el equivalente de
# teclado en _frame_key (Enter/Espacio).
func _applet_context(id):
	if applet_menu(id) == "teclado":
		applet_action_want = "teclado"
	else:
		applet_picker_want = true
	shell.request_redraw()



# Estado y valor textual de cada applet. Sin medición no se estima: "sin dato".
func _applet_state(id):
	match id:
		"recursos":
			return "activo" if sysmon.has_cpu or sysmon.has_ram else "sin_dato"
		"termico":
			return "activo" if sysmon.has_temp or sysmon.has_governor else "sin_dato"
		"reloj":
			return "activo"
		"teclado":
			return keyboard.state
	return "sin_dato"


func _applet_value(id):
	match id:
		"recursos":
			return "CPU %s · MEM %s · SWP %s" % [
				("%d%%" % int(round(sysmon.cpu_now()))) if sysmon.has_cpu else "sin dato",
				("%d%%" % int(round(sysmon.ram))) if sysmon.has_ram else "sin dato",
				("%d%%" % int(round(sysmon.swap))) if sysmon.has_swap else "sin swap"]
		"termico":
			var t = ("%d°C" % int(round(sysmon.temp_c))) if sysmon.has_temp else "sin dato"
			var g = sysmon.governor if sysmon.has_governor else "sin dato"
			return t + " · " + g
		"reloj":
			var t = OS.get_time()
			return "%02d:%02d" % [t.hour, t.minute]
		"teclado":
			return keyboard.value
	return ""


func _applet_pct(id):
	# El sistema (recursos) y el térmico dibujan sus propias barras/diales: sin la
	# barra inferior genérica.
	if id == "recursos" or id == "termico":
		return -1.0
	return -1.0


# --- Bloques "Compartido" (K10b) --------------------------------------------
# Sesiones activas con vecinos: pantalla y teclado y mouse. El Frame sólo dibuja
# el snapshot que devuelve shared_block.gd; la ejecución se delega al shell. Nada
# de procesos ni disco en este hilo: se leen los mismos caches que ya usa el
# Vecindario (host_session_state, service_pids, host_deskflow). El portapapeles
# dejó de ser una opción (se asume compartido con "Controlar").


# Snapshot puro de las sesiones, a partir de los caches del shell. Sin I/O.
func _shared_snapshot():
	if shell == null or shell.neighborhood == null or not shell.has_method("_host_session_state"):
		return []
	var hosts = shell.neighborhood.get("hosts")
	if typeof(hosts) != TYPE_ARRAY:
		return []
	var host_session = {}
	var screen = {}
	var input = {}
	var labels = {}
	for h in hosts:
		if typeof(h) != TYPE_DICTIONARY:
			continue
		var hid = String(h.get("id", "")).strip_edges()
		if hid == "":
			continue
		host_session[hid] = String(shell._host_session_state(hid))
		screen[hid] = shell._gvd_has_session(hid) if shell.has_method("_gvd_has_session") else false
		input[hid] = bool(shell.host_deskflow.get(hid, false))
		labels[hid] = _shared_host_label(h, hid)
	# Sin cache de error por equipo: no se inventa uno (el modelo soporta
	# "errors" para cuando exista una fuente real).
	var running = shell._service_running("Deskflow") if shell.has_method("_service_running") else false
	return SHARED_BLOCK.from_cache(host_session, screen, input, {}, running, labels)


# Nombre visible del equipo: el que ya resuelve el Vecindario (nunca el id opaco
# ni un nombre interno). Cae al label del host y, por último, al id.
func _shared_host_label(host, hid):
	if shell.neighborhood_ui != null and shell.neighborhood_ui.has_method("host_label"):
		var name = String(shell.neighborhood_ui.host_label(host)).strip_edges()
		if name != "":
			return name
	var label = String(host.get("label", "")).strip_edges()
	return label if label != "" else String(hid)


func _shared_at(pos):
	if not shared_drawn:
		return null
	return SHARED_BLOCK.hit(pos, shared_layout)


# Acción primaria del bloque (clic izquierdo): ver el detalle en el Vecindario.
func _shared_primary(block):
	if block != null:
		_open_shared_details(block)


# Menú contextual (clic derecho): "Detener" / "Ver detalles".
func _shared_action(block, action_id):
	match String(action_id):
		"stop":
			_stop_shared(block)
		"details":
			_open_shared_details(block)


# Corta la sesión delegando en el ciclo de vida existente del shell; no crea uno
# paralelo. El bloque desaparece solo en el próximo snapshot cacheado.
func _stop_shared(block):
	if block == null:
		return
	var hid = String(block.host)
	match String(block.type):
		"screen":
			if shell.has_method("_stop_gvd_session"):
				shell._stop_gvd_session(hid)
		"input":
			shell.host_deskflow[hid] = false
			if shell.has_method("_service_running") and shell._service_running("Deskflow") \
					and shell.has_method("_toggle_service_by_name"):
				shell._toggle_service_by_name("Deskflow")
	shell.request_redraw()


# "Ver detalles": abre el Vecindario con el equipo seleccionado.
func _open_shared_details(block):
	if block == null:
		return
	set_visible(false)
	if shell.has_method("_go_neighborhood"):
		shell._go_neighborhood()
	if shell.neighborhood_ui != null:
		shell.neighborhood_ui.selected_host = String(block.host)
	shell.request_redraw()


# Dibuja los bloques a la izquierda de los applets, sin pisarlos: `start_x` es el
# fin del dock de pines y `limit_x` donde empiezan los applets. Devuelve el x final.
func _draw_shared(ui, start_x, limit_x, side, mouse):
	shared_layout = []
	shared_drawn = false
	shared_menu_open = false
	var blocks = _shared_snapshot()
	var cx = start_x
	for b in blocks:
		if cx + side > limit_x - PAD:
			break
		var id = String(b.id)
		var tile = _tile(ui, Vector2(cx, 0.0), side, "shared_" + id, NX_FACE, side)
		var rect = tile.rect
		shared_layout.append({"id": id, "x": rect.position.x, "y": rect.position.y,
			"w": rect.size.x, "h": rect.size.y, "block": b})
		_draw_shared_face(ui, Vector2(cx, 0.0), rect, b, side)
		if rect.has_point(mouse):
			ui.begin_tooltip()
			ui.text(String(b.title))
			ui.text_disabled("estado: " + String(b.state_text))
			if String(b.reason) != "":
				ui.text(String(b.reason))
			ui.end_tooltip()
		cx += side + PAD
	shared_drawn = true
	if shared_menu_want != "":
		shared_menu_id = shared_menu_want
		shared_menu_want = ""
		ui.open_popup("##shared_menu")
	if shared_menu_id != "" and SHARED_BLOCK.block_by_id(blocks, shared_menu_id) == null:
		shared_menu_id = ""
	if shared_menu_id != "":
		MENU_STYLE.begin(ui)
		if ui.begin_popup("##shared_menu"):
			shared_menu_open = true
			shared_menu_block = SHARED_BLOCK.block_by_id(blocks, shared_menu_id)
			MENU_STYLE.chrome(ui, "Compartido")
			if shared_menu_block != null:
				ui.text_disabled(String(shared_menu_block.title))
				for it in SHARED_BLOCK.menu(shared_menu_block):
					if MENU_STYLE.item(ui, String(it.label)):
						_shared_action(shared_menu_block, String(it.id))
			ui.end_popup()
		MENU_STYLE.end(ui)
	return cx


# Cara del bloque: ícono del equipo arriba, insignia del tipo abajo-izquierda,
# estado textual + barra. El estado se distingue por contorno/relleno/color y
# texto, nunca sólo por color.
func _draw_shared_face(ui, pos, rect, b, side):
	var type = String(b.type)
	var state = String(b.state)
	var line = Color(0.45, 0.80, 1.0, 1.0)
	if state == "starting":
		line = NX_SEL
	elif state == "error":
		line = Color(0.95, 0.55, 0.30, 1.0)
	var icon = shell._sugar_icon_for("Pantalla") if shell != null else null
	var s = min(side - 30.0, 40.0)
	var bw = _bevel_w(ui)
	if icon != null:
		ui.set_cursor_pos(pos + Vector2((side - s) * 0.5, bw + 3.0))
		ui.image(icon, Vector2(s, s))
	var badge = Vector2(max(14.0, side * 0.24), max(14.0, side * 0.24))
	var badge_pos = pos + Vector2(bw + 3.0, side - badge.size.y - 6.0)
	ui.imgui_draw_rect_filled(Rect2(badge_pos, badge), Color(0.10, 0.11, 0.14, 1.0), 0.0)
	_draw_shared_glyph(ui, Rect2(badge_pos + Vector2(2.0, 2.0), badge - Vector2(4.0, 4.0)), type, line)
	# Texto de estado corto (el completo va en el tooltip): nunca pisa al vecino.
	var tag = String(b.state_text)
	if tag.length() > 6:
		tag = tag.substr(0, 6)
	ui.set_cursor_pos(pos + Vector2(badge_pos.x + badge.size.x + 4.0, side - badge.size.y - 3.0))
	ui.text_colored(line, tag)
	ui.imgui_draw_rect_filled(Rect2(rect.position + Vector2(4.0, side - SHARED_W - 1.0),
		Vector2(side - 8.0, SHARED_W)), line, 0.0)


# Insignia dibujada a mano del tipo de sesión (monitor / teclado / portapapeles),
# para no depender de SVG del tema ni de texto diminuto.
func _draw_shared_glyph(ui, r, type, col):
	var x = r.position.x
	var y = r.position.y
	var w = r.size.x
	var h = r.size.y
	match String(type):
		"screen":
			ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * 0.10, y + h * 0.18), Vector2(w * 0.80, h * 0.50)), col, 0.0)
			ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * 0.17, y + h * 0.25), Vector2(w * 0.66, h * 0.36)), NX_BG, 0.0)
			ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * 0.46, y + h * 0.68), Vector2(w * 0.08, h * 0.14)), col, 0.0)
			ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * 0.30, y + h * 0.82), Vector2(w * 0.40, h * 0.07)), col, 0.0)
		"input":
			ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * 0.08, y + h * 0.34), Vector2(w * 0.84, h * 0.42)), col, 0.0)
			ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * 0.15, y + h * 0.42), Vector2(w * 0.70, h * 0.26)), NX_BG, 0.0)
			for i in range(3):
				ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * (0.22 + 0.22 * i), y + h * 0.48), Vector2(w * 0.10, h * 0.13)), col, 0.0)
		"clipboard":
			ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * 0.20, y + h * 0.26), Vector2(w * 0.60, h * 0.60)), col, 0.0)
			ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * 0.29, y + h * 0.36), Vector2(w * 0.42, h * 0.42)), NX_BG, 0.0)
			ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * 0.36, y + h * 0.15), Vector2(w * 0.28, h * 0.16)), col, 0.0)


# --- Bloques WindowMaker/NeXT -----------------------------------------------
# Alto de las barras y lado de las teselas: la MISMA unidad de rejilla del Hogar.
func _vh():
	return shell.frame_bar_h(get_viewport().size)


# Ancho del bisel: base escalada con la UI y con el factor de Apariencia. Antes era
# 2 px fijos y en pantallas densas (HiDPI) quedaba como un hilo.
func _bevel_w(ui):
	var ts = ui.get_imgui_scale()
	var factor = 1.0
	if shell != null and shell.appearance != null:
		factor = float(shell.appearance.get("bevel", 1.0))
	return clamp(round(BEVEL_BASE * ts * factor), 1.0, BEVEL_MAX_W)


# Modo plano (Apariencia): el relieve 3D sólo aparece al pasar el mouse o hundir.
func _flat_blocks():
	return shell != null and shell.appearance != null and bool(shell.appearance.get("flat", false))


# Relieve grabado de los íconos del sistema y de las etiquetas (Apariencia).
func _emboss():
	return shell == null or shell.appearance == null or bool(shell.appearance.get("emboss", true))


# Bisel clásico: claro arriba/izquierda, oscuro abajo/derecha. `pressed` lo invierte
# (estado hundido). Sin redondeo; las teselas del Frame nunca son redondas. `hover`
# activa el relieve en modo plano.
func _bevel(ui, r, face, pressed, hover = false):
	ui.imgui_draw_rect_filled(r, face, 0.0)
	var w = _bevel_w(ui)
	if _flat_blocks() and not (hover or pressed):
		# Plano: sólo una línea inferior tenue separa la tesela del fondo.
		var edge_w = max(1.0, round(w * 0.5))
		ui.imgui_draw_rect_filled(Rect2(Vector2(r.position.x, r.end.y - edge_w),
			Vector2(r.size.x, edge_w)), NX_DARK.linear_interpolate(face, 0.45), 0.0)
		return
	var light = NX_DARK if pressed else NX_LIGHT
	var dark = NX_LIGHT if pressed else NX_DARK
	ui.imgui_draw_rect_filled(Rect2(r.position, Vector2(r.size.x, w)), light, 0.0)
	ui.imgui_draw_rect_filled(Rect2(r.position, Vector2(w, r.size.y)), light, 0.0)
	ui.imgui_draw_rect_filled(Rect2(Vector2(r.position.x, r.end.y - w), Vector2(r.size.x, w)), dark, 0.0)
	ui.imgui_draw_rect_filled(Rect2(Vector2(r.end.x - w, r.position.y), Vector2(w, r.size.y)), dark, 0.0)


# Ícono grabado en el bloque: el INTERIOR queda del mismo color que la cara (no una
# placa ni un sticker) y sólo los bordes definen el relieve: sombra arriba-izquierda,
# luz abajo-derecha. Se dibuja la copia de la cara encima para "borrar" el interior.
func _emboss_image(ui, tex, pos, size, face):
	var d = max(1.0, round(1.25 * ui.get_imgui_scale()))
	var rim_dark = Color(NX_DARK.r, NX_DARK.g, NX_DARK.b, 0.55)
	var rim_light = Color(NX_FOCUS.r, NX_FOCUS.g, NX_FOCUS.b, 0.50)
	ui.set_cursor_pos(pos - Vector2(d, d))
	ui.image(tex, size, rim_dark)
	ui.set_cursor_pos(pos + Vector2(d, d))
	ui.image(tex, size, rim_light)
	ui.set_cursor_pos(pos)
	ui.image(tex, size, face)


# Ícono de un ítem del Frame: el de su actividad si está cargado, si no el XDG del
# programa de la ventana y, en última instancia, un ícono genérico de ventana Sugar.
# Fuerza la carga perezosa de a dos íconos por frame como en el Hogar.
func _item_icon(item):
	if item.id >= 0:
		for a in shell.ACTIVITIES:
			if a.name == item.name:
				var tex = shell._activity_tex(a)
				if tex != null:
					return tex
				break
		var win_tex = shell._window_icon(item.id, item.name)
		if win_tex != null:
			return win_tex
	return shell._sugar_icon_for(item.name)


# Botón-tesela: la interacción la maneja ImGui (colores transparentes) y el bisel se
# dibuja a mano encima. Devuelve el click y el rect en pantalla. `held` es el hundido.
func _tile(ui, pos, side, id, face = NX_FACE, h = -1.0):
	if h < 0.0:
		h = side
	ui.set_cursor_pos(pos)
	var r = Rect2(ui.get_cursor_screen_pos(), Vector2(side, h))
	ui.push_style_color(ui.COL_BUTTON, Color(0, 0, 0, 0))
	ui.push_style_color(ui.COL_BUTTON_HOVERED, Color(0, 0, 0, 0))
	ui.push_style_color(ui.COL_BUTTON_ACTIVE, Color(0, 0, 0, 0))
	ui.push_style_var_float(ui.STYLE_VAR_FRAME_ROUNDING, 0.0)
	var clicked = ui.button("##" + id, Vector2(side, h))
	var held = ui.is_item_active()
	var hover = ui.is_item_hovered()
	ui.pop_style_var()
	ui.pop_style_color(3)
	if hover and not held:
		face = face.linear_interpolate(Color(1.0, 1.0, 1.0, face.a), 0.08)
	_bevel(ui, r, face, held, hover)
	return {"clicked": clicked, "rect": r, "face": face}


# Mini-tesela de control (minimizar/cerrar) dentro del bloque de ventana. Se dibuja
# a mano y el hit se resuelve por rect: dos botones ImGui solapados dejarían que el
# cuadrado principal (más temprano) se quede con el hover. `pos` local.
func _draw_mini(ui, pos, side, glyph, pressed):
	ui.set_cursor_pos(pos)
	var r = Rect2(ui.get_cursor_screen_pos(), Vector2(side, side))
	_bevel(ui, r, Color(0.23, 0.26, 0.35, 1.0), pressed)
	var cw = 7.0 * ui.get_imgui_scale()
	ui.set_cursor_pos(pos + Vector2((side - cw) * 0.5, (side - 13.0 * ui.get_imgui_scale()) * 0.5))
	ui.text_colored(NX_TEXT, glyph)


func _in_rect(p, pos, side):
	return p.x >= pos.x and p.x < pos.x + side and p.y >= pos.y and p.y < pos.y + side


# Alto reservado por la etiqueta. Ahora la etiqueta es más chica y puede ocupar
# hasta LABEL_LINES líneas; el alto sale de las líneas reales (ver _title_lines).
func _title_h(ui):
	return TITLE_H * ui.get_imgui_scale()


func _label_px(ui):
	return max(9.0, round(shell.UI_FONT_PX * ui.get_imgui_scale() * LABEL_SCALE))


func _label_line_h(ui):
	return _label_px(ui) + max(1.0, 2.0 * ui.get_imgui_scale())


# Fuente más chica para la etiqueta de bloque (se hornea al tamaño exacto, igual que
# la fuente de UI). Devuelve true si quedó apilada para hacer pop_font.
func _push_label_font(ui):
	var px = _label_px(ui)
	if label_font < 0 or label_font_px != px:
		if not File.new().file_exists(shell.UI_FONT_FILE):
			return false
		var idx = ui.add_font(shell.UI_FONT_FILE, px, "default")
		if idx < 0:
			return false
		label_font = idx
		label_font_px = px
	ui.push_font(label_font)
	return true


# Ancho real del texto con la fuente activa (proporcional): centrar estimando
# chars*7 desalineaba con el TTF. Fallback si el binario no trae calc_text_size.
func _text_w(ui, s):
	if ui.has_method("calc_text_size"):
		return ui.calc_text_size(s).x
	return s.length() * 7.0 * ui.get_imgui_scale()


# Recorta `s` a lo sumo `max_w` px agregando "…" si hace falta.
func _truncate_w(ui, s, max_w):
	if _text_w(ui, s) <= max_w:
		return s
	var t = s
	while t.length() > 1 and _text_w(ui, t) > max_w:
		t = t.substr(0, t.length() - 1)
	return t


# Parte la etiqueta en hasta LABEL_LINES líneas de ancho `max_w`, con "…" si sobra
# texto. Usa la fuente de etiqueta para medir (la apila y la saca).
func _wrap_label(ui, label, max_w):
	var pushed = _push_label_font(ui)
	var words = label.split(" ", false)
	var lines = []
	var i = 0
	while i < words.size() and lines.size() < LABEL_LINES:
		var cur = String(words[i])
		if _text_w(ui, cur) > max_w:
			lines.append(_truncate_w(ui, cur, max_w))
			i += 1
			continue
		var j = i + 1
		while j < words.size():
			var cand = cur + " " + String(words[j])
			if _text_w(ui, cand) > max_w:
				break
			cur = cand
			j += 1
		lines.append(cur)
		i = j
	if i < words.size() and lines.size() > 0:
		lines[lines.size() - 1] = _truncate_w(ui, String(lines[lines.size() - 1]) + " …", max_w)
	if pushed:
		ui.pop_font()
	if lines.empty():
		lines = [label]
	return lines


# Líneas reales de la etiqueta de un bloque de lado `side`.
func _title_lines(ui, side, label):
	var pad = TILE_PAD * ui.get_imgui_scale()
	return _wrap_label(ui, label, max(8.0, side - 2.0 * pad))


# Alto reservado desde el borde inferior para las líneas dadas.
func _title_reserved(ui, lines):
	return _label_line_h(ui) * float(lines.size()) + TILE_PAD * ui.get_imgui_scale()


# Etiqueta corta centrada en la parte baja de la tesela, hasta dos líneas y con
# fuente más chica. Si `lines` viene null se calcula; los llamadores que ubican el
# ícono pasan las mismas líneas para que el alto reservado coincida.
func _tile_title(ui, pos, side, label, dim, lines = null):
	if lines == null:
		lines = _title_lines(ui, side, label)
	var pad = TILE_PAD * ui.get_imgui_scale()
	var lh = _label_line_h(ui)
	var total = lh * float(lines.size())
	var col = NX_TEXT_DIM if dim else NX_TEXT
	var pushed = _push_label_font(ui)
	for i in range(lines.size()):
		var lw = _text_w(ui, String(lines[i]))
		ui.set_cursor_pos(pos + Vector2(max(pad, (side - lw) * 0.5), side - total - pad + lh * float(i)))
		ui.text_colored(col, String(lines[i]))
	if pushed:
		ui.pop_font()


func set_visible(v):
	visible = v
	entered = false
	corner_since = -1
	if v:
		show_until = 0  # mostrado a mano: sin auto-ocultado de Alt+Tab
	else:
		sel = -1
		lifted = null
		applet_press = null
		applet_drag = null
		shared_press = ""
	# Desde _input (tecla tragada, ImGui no la ve) nadie más pide el frame que lo muestra.
	shell.request_redraw()
	shell.last_activity = OS.get_ticks_msec()


# Lo que corre: internas (por instancia viva) primero, con su nombre; después las
# ventanas visibles en el orden de las pantallas de shell._units() (las de una
# pantalla partida quedan juntas y comparten `screen`); al final las minimizadas y
# las que aún no entraron a la franja, atenuadas y sin número de pantalla. `title`
# y `key` no cambian: el número de pantalla es un campo aparte.
func running():
	var out = []
	for name in shell.script_instances.keys():
		out.append({"key": "s:" + name, "name": name, "title": name, "id": -1,
			"minimized": false, "screen": 0})
	var order = []
	var by_id = {}
	for id in shell.compositor.get_ids():
		if shell.compositor.get_parent_id(id) > 0:
			continue
		var name = shell._activity_for_window(id)
		var title = shell.compositor.get_title(id)
		if title == "":
			title = name if name != "" else "Ventana " + str(id)
		by_id[id] = {"key": "w:" + str(id), "name": name, "title": title, "id": id,
			"minimized": shell.minimized.has(id), "screen": 0}
		order.append(id)
	var screen = 0
	for unit in shell._units():
		screen += 1
		for id in unit:
			if by_id.has(id):
				by_id[id]["screen"] = screen
				out.append(by_id[id])
				by_id.erase(id)
	for id in order:
		if by_id.has(id):
			out.append(by_id[id])
	return out


func _is_current(item):
	if item.id >= 0:
		return item.id == shell._current_wayland_id()
	return shell.current_activity != null and shell.current_activity.name == item.name


# Rect en pantalla del ítem de una ventana (para anclar animaciones de min/cerrar).
func item_rect(id):
	for it in items_layout:
		if it.id == id:
			return Rect2(it.x, it.y, it.w, it.h)
	return null


func switch_to(item, keep_frame := false):
	if not keep_frame:
		set_visible(false)
	if item.id >= 0 and shell.minimized.has(item.id):
		# Restaurar una minimizada (el Frame la lista en gris).
		shell._restore_window(item.id)
	elif item.id < 0 or item.name != "":
		shell._open_by_name(item.name)
	else:
		# Toplevel que todavía no tiene actividad dinámica: se la crea ya.
		shell.unmanaged.erase(item.id)
		shell._open_unmanaged_window(item.id)


func close(item):
	if item.id >= 0:
		# Cierre educado (xdg_toplevel.close): la app puede preguntar antes de irse.
		shell.compositor.close(item.id)
	else:
		shell._close_script_activity(item.name)


func cycle(step):
	var items = running()
	if items.empty():
		return
	var at = -1
	for i in range(items.size()):
		if _is_current(items[i]):
			at = i
	if at < 0:
		at = 0 if step > 0 else items.size()
	else:
		at = posmod(at + step, items.size())
	# Alt+Tab: cambio casi instantáneo y con el Frame a la vista durante la transición.
	slide_instant = true
	sel = at
	shell.instant_switch = true
	switch_to(items[at], true)
	set_visible(true)
	show_until = OS.get_ticks_msec() + 1200  # se auto-oculta al terminar la gracia
	shell.last_activity = OS.get_ticks_msec()
	shell.request_redraw()


# Monitor del sistema: muestrea mientras una franja con applets esté a la vista
# (Inicio, Frame abierto a pedido o barra fijada) y pide un frame por muestra
# (>= 1 Hz) para que la gráfica y los diales avancen aunque la ventana enfocada sea
# otra app. No se gatea por `visible` sólo: una barra fijada (pin) sigue a la vista.
func _process(_delta):
	if shell.fullscreen_id >= 0:
		return
	var home = shell.current_activity == null
	if applets_live(home, visible, pin_top_bar, pin_bottom_bar):
		var changed = sysmon.tick()
		if applets_visible.has("teclado"):
			changed = keyboard.refresh() or changed
		if changed:
			shell.request_redraw()


# Super dejó de ser un toque solo: la app recibe la pulsación retenida.
func _super_used():
	if super_press != null and shell._current_wayland_id() >= 0:
		shell.compositor.key(super_press)
	super_press = null


func _input(event):
	# Mouse: además del borde/esquina, sigue el arrastre de ítems para tilear.
	if event is InputEventMouseMotion:
		mouse_pos = event.position
		if mouse_down and app_press != null and app_drag == null \
				and mouse_pos.distance_to(app_from) > DRAG_PX:
			app_drag = app_press
		if app_drag != null:
			shell.request_redraw()
		# Arrastre de un applet del borde inferior: reordena, nunca mueve ventanas.
		if mouse_down and applet_press != null and applet_drag == null \
				and mouse_pos.distance_to(applet_from) > DRAG_PX:
			applet_drag = applet_press
		if applet_drag != null:
			shell.request_redraw()
		if mouse_down and dragging == null and drag_candidate != null \
				and mouse_pos.distance_to(drag_from) > DRAG_PX:
			dragging = drag_candidate
		if dragging != null:
			shell.request_redraw()
		if win_drag != null:
			shell.request_redraw()
		return
	if event is InputEventMouseButton:
		mouse_pos = event.position
		# Rueda: con Super, o sobre la barra del Frame visible, avanza entre workspaces
		# de la franja. La SUELTA de la rueda se ignora (si cayera al final del bloque
		# llamaría a _super_used y limpiaría super_press, cortando el paneo).
		if event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN:
			if not event.pressed:
				return
			# En exposé la rueda desplaza la tira (no cambia la selección).
			if shell.expose:
				shell._expose_scroll_by((240.0 if event.button_index == BUTTON_WHEEL_DOWN else -240.0))
				get_tree().set_input_as_handled()
				return
			if super_press != null:
				shell._pan_by((-1.0 if event.button_index == BUTTON_WHEEL_UP else 1.0))
				shell.request_redraw()
				get_tree().set_input_as_handled()
				return
			if (visible or shell.current_activity == null) and mouse_pos.y <= _vh():
				shell._focus_dir(-1 if event.button_index == BUTTON_WHEEL_UP else 1)
				shell.request_redraw()
				get_tree().set_input_as_handled()
				return
			return
		if event.button_index == BUTTON_RIGHT:
			# K9: el botón derecho abre el menú contextual del bloque (nunca el
			# izquierdo). En un applet abre su menú; en un bloque "Compartido",
			# Detener / Ver detalles; sobre el resto de la franja, el selector de
			# controles.
			if menu_trigger(event.button_index, event.pressed) == "menu" and not applet_picker_open:
				var right_applet = _applet_at(mouse_pos)
				if right_applet != null:
					_applet_context(right_applet)
					get_tree().set_input_as_handled()
					return
				var right_shared = _shared_at(mouse_pos)
				if right_shared != null:
					shared_menu_want = String(right_shared.id)
					shell.request_redraw()
					get_tree().set_input_as_handled()
					return
				if _applet_bar_at(mouse_pos):
					applet_picker_want = true
					shell.request_redraw()
					get_tree().set_input_as_handled()
					return
		if event.button_index == BUTTON_LEFT:
			mouse_down = event.pressed
			if event.pressed:
				var hit_tile = _pinned_hit(mouse_pos)
				if hit_tile == null and shell.apps_view:
					hit_tile = shell.apps.at_tile(mouse_pos)
				if hit_tile != null:
					app_press = hit_tile.app
					app_grab = mouse_pos - hit_tile.rect.position
					app_from = mouse_pos
					app_drag = null
				# Super+arrastre sobre una ventana: la mueve al Frame (reordenar/tilear).
				if super_press != null and mouse_pos.y > _vh() and shell.focused_tile >= 0:
					win_drag = {"id": shell.focused_tile}
					shell.window_dragging = true
					set_visible(true)
					get_tree().set_input_as_handled()
					return
				# Clic en un applet: selecciona y arma el posible arrastre de orden.
				var hit_applet = _applet_at(mouse_pos)
				if hit_applet != null and not applet_picker_open:
					applet_press = hit_applet
					var ah = _applet_hit(mouse_pos)
					applet_grab = mouse_pos - Vector2(ah.x, ah.y) if ah != null else Vector2(_vh() * 0.5, _vh() * 0.5)
					applet_from = mouse_pos
					applet_drag = null
					var at = applets_visible.find(hit_applet)
					if at >= 0:
						sel = running().size() + at
					shell.request_redraw()
					get_tree().set_input_as_handled()
					return
				# Bloque "Compartido": la primaria (detalle) se resuelve al soltar.
				var hit_shared = _shared_at(mouse_pos)
				if hit_shared != null and not shared_menu_open:
					shared_press = String(hit_shared.id)
					shell.request_redraw()
					get_tree().set_input_as_handled()
					return
				drag_candidate = _item_at(mouse_pos)
				drag_from = mouse_pos
				dragging = null
			else:
				# Soltar un bloque "Compartido": primaria (ver detalle) si sigue bajo
				# el puntero; nunca inicia arrastre (los bloques no se reordenan).
				if shared_press != "":
					var cur_shared = _shared_at(mouse_pos)
					var pressed = shared_press
					shared_press = ""
					if cur_shared != null and String(cur_shared.id) == pressed:
						_shared_primary(cur_shared.block)
				if app_drag != null:
					if is_trash(mouse_pos):
						# Basurero: desfija la app (no la desinstala).
						pinned_top.erase(app_drag.id)
						pinned_dock.erase(app_drag.id)
						_save_applets()
					elif shell.is_ring_drop(mouse_pos):
						# Frame -> Anillo: crea un favorito.
						shell.add_ring_favorite(app_drag.id)
					else:
						var zone = "top" if mouse_pos.y <= _vh() else "dock" if mouse_pos.y >= get_viewport().size.y - _vh() else ""
						if zone != "":
							_pin_app(app_drag, zone, mouse_pos.x)
						elif pinned_top.has(app_drag.id) or pinned_dock.has(app_drag.id):
							pinned_top.erase(app_drag.id)
							pinned_dock.erase(app_drag.id)
							_save_applets()
						# El bloque se asienta: parte de la posición del cursor.
						if zone != "":
							_bar_set("pin_" + app_drag.id, mouse_pos.x)
					shell.apps.suppress_click = app_drag.id
					suppress_pinned_click = app_drag.id
				app_drag = null
				app_press = null
				if applet_drag != null:
					_finish_applet_drag()
				elif applet_press != null:
					_applet_primary(applet_press)
				applet_press = null
				applet_drag = null
				if win_drag != null:
					_finish_win_drag()
				elif dragging != null:
					_finish_drag()
				dragging = null
				drag_candidate = null
		_super_used()
		if corner_since > 0:
			corner_since = -1
		return
	if not (event is InputEventKey):
		return
	var code = event.scancode
	# Esc cancela el arrastre de un applet (conserva el orden) antes de ocultar el Frame.
	if event.pressed and code == KEY_ESCAPE and applet_drag != null:
		applet_drag = null
		applet_press = null
		shell.request_redraw()
		_gulp(code)
		return
	# Exposé abierto: navegar y elegir (Esc cierra). Un toque de Super también cierra.
	if shell.expose:
		if SUPER_KEYS.has(code) or SUPER_KEYS.has(event.physical_scancode):
			if not event.pressed:
				shell._toggle_expose(false)
			get_tree().set_input_as_handled()
			return
		if not event.pressed:
			return
		if code == KEY_ESCAPE:
			shell._toggle_expose(false)
		elif code == KEY_LEFT:
			shell._expose_move(-1)
		elif code == KEY_RIGHT:
			shell._expose_move(1)
		elif code == KEY_ENTER or code == KEY_KP_ENTER or code == KEY_SPACE:
			shell._expose_commit()
		elif code == KEY_DELETE:
			# Delete cierra la ventana seleccionada sin salir del exposé.
			if shell.expose_sel >= 0 and shell.expose_sel < shell.tiles.size():
				shell._close_window_id(shell.tiles[shell.expose_sel])
		else:
			return
		_gulp(code)
		return
	# Vecindario abierto: Esc vuelve al Hogar (aunque el Frame esté a la vista).
	if event.pressed and code == KEY_ESCAPE and shell.neighborhood_view and not event.echo:
		shell._close_neighborhood()
		_gulp(code)
		return
	if SUPER_KEYS.has(code) or SUPER_KEYS.has(event.physical_scancode):
		if event.pressed:
			super_press = event
		elif super_press != null:
			super_press = null
			if shell.pan_active:
				shell._snap_pan()  # cae a la pantalla más cercana
			elif win_drag == null:
				# Toque de Super (sin combo): entra/sale del exposé (zoom out del
				# escritorio). Super+W cierra la ventana enfocada.
				shell._toggle_expose(not shell.expose)
		else:
			return  # Suelta tras un combo: va a la app.
		get_tree().set_input_as_handled()
		return
	if event.pressed and super_press != null:
		# Super+tecla: atajos del shell (no llegan a la app).
		if code == KEY_F6:
			super_press = null
			DebugHud.toggle()
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_W:
			super_press = null
			shell._close_focused()
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_M:
			super_press = null
			shell._toggle_minimize_focused()
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_LEFT or code == KEY_RIGHT:
			# Super+←/→: tiling a la mitad izquierda/derecha. En el Hogar, ← vuelve
			# a la última pantalla con foco y → no hace nada (Home es la ranura final).
			super_press = null
			if shell.current_activity == null:
				shell._focus_dir(-1 if code == KEY_LEFT else 1)
			else:
				shell._snap_tile(-1 if code == KEY_LEFT else 1)
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_T:
			super_press = null
			if event.shift:
				shell._untile_window(shell.focused_tile)
			else:
				shell._tile_with_next()
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_P:
			# Super+P fija/auto-oculta la barra superior; Super+Shift+P, la inferior.
			super_press = null
			toggle_pin("bottom" if event.shift else "top")
			_gulp(code)
			return
	if event.pressed:
		_super_used()
	if not event.pressed:
		# La suelta de una tecla que nos comimos tampoco va a la app.
		if swallowed.has(code):
			swallowed.erase(code)
			get_tree().set_input_as_handled()
		return
	# Alt+M: minimizar/restaurar la ventana enfocada, sin depender de que el Frame esté
	# a la vista (el botón "-" del bloque hace lo mismo cuando el Frame se muestra).
	if event.alt and not event.control and not event.echo and code == KEY_M:
		shell._toggle_minimize_focused()
		_gulp(code)
		return
	# Alt+F4: cierra la ventana enfocada (Super+W hace lo mismo; ver arriba).
	if event.alt and not event.control and not event.echo and code == KEY_F4:
		shell._close_focused()
		_gulp(code)
		return
	# Frame a la vista: flechas mueven la selección y Enter/Espacio/m/Delete operan.
	if visible and _frame_key(code, event):
		return
	var home = shell.current_activity == null
	if code == KEY_F6:
		if not event.echo:
			set_visible(not visible)
	elif code == KEY_ESCAPE and visible and not home:
		set_visible(false)
	elif code == KEY_TAB and event.alt:
		cycle(-1 if event.shift else 1)
	elif event.control and event.alt and not event.shift and _arrow_dir(code) != 0:
		# Ctrl+Alt+flecha: cambiar de pantalla (desliza; arriba/abajo mueve la franja).
		shell._focus_dir(_arrow_dir(code))
	elif event.control and event.alt and event.shift and _arrow_dir(code) != 0:
		# Ctrl+Alt+Shift+flecha: intercambiar la pantalla enfocada con la vecina.
		shell._swap_dir(_arrow_dir(code))
	elif event.alt and not event.control and code == KEY_F11:
		# Alt+F11: pantalla completa de la ventana enfocada.
		shell._toggle_fullscreen()
	elif event.alt and not event.control and code == KEY_F10:
		# Alt+F10: maximizar (ocupar todo el workspace).
		shell._maximize_window(shell.focused_tile)
	else:
		return
	_gulp(code)


func _gulp(code):
	swallowed[code] = true
	get_tree().set_input_as_handled()


# Teclado con el Frame a la vista: flechas eligen ítem (ventanas y después applets),
# Enter cambia/restaura o dispara la primaria del applet, Espacio levanta y suelta
# (tilear), Ctrl+←/→ reordena el applet elegido, Delete lo quita y Esc cancela.
# Devuelve true si lo consumió.
func _frame_key(code, event):
	if shell.apps_view:
		return false  # buscando apps en el Home: el teclado es del buscador
	var items = running()
	var n_app = applets_visible.size()
	var total = items.size() + n_app  # ventanas + applets
	if total <= 0:
		return false
	var over_app = shell.current_activity != null
	if code == KEY_ESCAPE:
		if lifted != null:
			lifted = null
		else:
			set_visible(false)
		shell.request_redraw()
		_gulp(code)
		return true
	if sel < 0 or sel >= total:
		sel = -1
		for i in range(items.size()):
			if _is_current(items[i]):
				sel = i
		if sel < 0:
			sel = 0
	if not event.control and not event.alt and code == KEY_LEFT:
		sel = posmod(sel - 1, total)
	elif not event.control and not event.alt and code == KEY_RIGHT:
		sel = posmod(sel + 1, total)
	elif sel < items.size():
		# Ventana: comportamiento de siempre (cambiar, tilear, minimizar, cerrar).
		if code == KEY_ENTER or code == KEY_KP_ENTER:
			var it = items[sel]
			lifted = null
			switch_to(it)
		elif code == KEY_SPACE and over_app:
			var it = items[sel]
			if lifted == null:
				if it.id >= 0 and not it.minimized:
					lifted = it
			elif lifted.id == it.id:
				lifted = null
			else:
				if it.id >= 0:
					shell._tile_drop(lifted.id, it.id)
				lifted = null
		elif code == KEY_M and over_app:
			if items[sel].id >= 0:
				if shell.minimized.has(items[sel].id):
					shell._restore_window(items[sel].id)
				else:
					shell._minimize_window(items[sel].id)
		elif code == KEY_DELETE:
			close(items[sel])
		else:
			return false
	elif sel < items.size() + n_app:
		# Applet: Ctrl+←/→ lo mueve en el orden; Delete lo quita; Enter lo acciona.
		var id = applets_visible[sel - items.size()]
		if event.control and code == KEY_LEFT:
			_applet_move(id, -1)
		elif event.control and code == KEY_RIGHT:
			_applet_move(id, 1)
		elif code == KEY_ENTER or code == KEY_KP_ENTER or code == KEY_SPACE:
			_applet_context(id)
		elif code == KEY_DELETE:
			_applet_set_visible(id, false)
		else:
			return false
	shell.request_redraw()
	_gulp(code)
	return true


# Ítem cuyo bloque cuadrado contiene el punto (las mini-teselas de control van dentro).
func _item_at(pos):
	for it in items_layout:
		if pos.x >= it.x and pos.x < it.x + it.w and pos.y >= it.y and pos.y < it.y + it.h:
			return it
	return null


# Id del applet bajo el punto (rects cuadrados del último dibujo del borde inferior).
func _applet_at(pos):
	if not applets_drawn:
		return null
	var it = _applet_hit(pos)
	return it.id if it != null else null


func _applet_hit(pos):
	if not applets_drawn:
		return null
	for it in applets_layout:
		if pos.x >= it.x and pos.x < it.x + it.w and pos.y >= it.y and pos.y < it.y + it.h:
			return it
	return null


# Franja inferior del último dibujo (clic derecho: abre el selector de controles).
func _applet_bar_at(pos):
	return applets_drawn and applets_bar_rect.size.x > 0.0 and applets_bar_rect.has_point(pos)


# Índice de inserción entre applets: cuántos (del dibujo anterior, sin el arrastrado)
# tienen su centro a la izquierda de x. Mismo cálculo para el preview y para soltar.
func _applet_slot(x, layout = null):
	var L = layout if layout != null else applets_layout
	var idx = 0
	for it in L:
		if applet_drag != null and it.id == applet_drag:
			continue
		if it.x + it.w * 0.5 < x:
			idx += 1
	return idx


func _finish_applet_drag():
	var id = applet_drag
	if id == null:
		return
	# El slot se calcula con applet_drag aún puesto (así _applet_slot salta su tesela).
	var slot = _applet_slot(mouse_pos.x)
	applet_drag = null
	applet_press = null
	# Basurero: quitar el control (equivale a Delete en el Frame).
	if is_trash(mouse_pos):
		_applet_set_visible(id, false)
		_bar_set("app_" + id, mouse_pos.x)
		shell.request_redraw()
		return
	# Fuera de la franja inferior, cancelar sin alterar la composición.
	var h = _vh()
	var bottom = get_viewport().size.y - h
	if mouse_pos.y < bottom or mouse_pos.y >= bottom + h:
		shell.request_redraw()
		return
	# El bloque se asienta en su lugar: parte de la posición del cursor y anima al slot.
	_bar_set("app_" + id, mouse_pos.x)
	applets_visible = _order_with_gap(applets_visible, id, slot)
	applets_dirty = true
	_save_applets()
	shell.request_redraw()


# Suelta del arrastre: sobre otra ventana tilea; fuera, la vuelve a pantalla completa.
# Sobre el basurero, cierra la ventana (equivale a la X del bloque).
func _finish_drag():
	if is_trash(mouse_pos):
		close(dragging)
		shell.request_redraw()
		return
	var target = _item_at(mouse_pos)
	if target != null and target.id >= 0 and not target.minimized and target.id != dragging.id:
		shell._tile_drop(dragging.id, target.id)
	else:
		shell._untile_window(dragging.id)
	shell.request_redraw()


# Super+arrastre: si se suelta sobre la barra del Frame, mueve la ventana a ese lugar
# (reordena la franja); sobre el basurero la cierra; si no, cancela.
func _finish_win_drag():
	var dragged = win_drag.id
	win_drag = null
	shell.window_dragging = false
	if is_trash(mouse_pos):
		var item = _item_by_id(dragged)
		if item != null:
			close(item)
	elif mouse_pos.y <= _vh():
		var t = _frame_insert_target(mouse_pos.x)
		if t != null:
			shell._move_window_to(dragged, t.id, t.before)
	shell.request_redraw()


func _item_by_id(id):
	for it in running():
		if it.id == id:
			return it
	return null


# Ítem del Frame bajo una x (coords de pantalla): dónde insertar al soltar, y si va
# antes o después de ese ítem. Ignora actividades de script (id < 0).
func _frame_insert_target(x):
	var last = null
	for it in items_layout:
		if it.id < 0:
			continue
		last = it
		if x >= it.x and x <= it.x + it.hit_w:
			return {"id": it.id, "before": x < it.x + it.w * 0.5}
	if last != null:
		return {"id": last.id, "before": false}
	return null


func _arrow_dir(code):
	if code == KEY_LEFT:
		return -1
	if code == KEY_RIGHT:
		return 1
	if code == KEY_UP:
		return -2
	if code == KEY_DOWN:
		return 2
	return 0


# Borde inferior retráctil: bloques cuadrados U x U de applets y la celda del pin.
# `off` es el mismo deslizamiento de la barra superior; el alto de la barra sale de
# la rejilla.
func _draw_applets(ui, vp, off, mouse):
	var prev = applets_layout
	applets_layout = []
	applet_picker_open = false
	var side = shell.frame_bar_h(vp)
	var by = vp.y - side - off
	applets_bar_rect = Rect2(0.0, by, vp.x, side)
	ui.push_style_var_vec2(ui.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	ui.set_next_window_pos(Vector2(0.0, by), true)
	ui.set_next_window_size(Vector2(vp.x, side), true)
	var flags = ui.WINDOW_NO_DECORATION | ui.WINDOW_NO_MOVE | ui.WINDOW_NO_SAVED_SETTINGS | ui.WINDOW_NO_SCROLLBAR | ui.WINDOW_NO_BACKGROUND
	if not ui.begin("##frame_bottom", flags):
		ui.end()
		ui.pop_style_var()
		return
	# Fondo NeXT de la franja inferior, para que los bloques floten sobre lo mismo.
	ui.imgui_draw_rect_filled(Rect2(Vector2(0.0, by), Vector2(vp.x, side)), NX_BG, 0.0)
	if app_drag != null and mouse.y >= by:
		ui.imgui_draw_rect_filled(Rect2(Vector2(0.0, by), Vector2(vp.x, 3.0)), NX_SEL, 0.0)
	# Esquina izquierda reservada (vacía); el dock arranca después.
	var dock_x = _draw_corner_block(ui, PAD, 0.0, side, "bottom_left")
	var dock_end = _draw_pinned(ui, pinned_dock, dock_x, side, "dock")
	var n = applets_visible.size()
	# La franja reserva sólo la celda del pin (extremo derecho, sin PAD de cola).
	var total_w = side
	for id in applets_visible:
		total_w += _applet_width(id, side) + PAD
	var x = max(PAD, vp.x - PAD - total_w)
	# K10b: sesiones activas a la izquierda de los applets, sin taparlos.
	_draw_shared(ui, dock_end, x, side, mouse)
	var y = 0.0
	var n_items = running().size()
	var now = OS.get_ticks_msec()
	# Preview: con un applet arrastrado, el resto se corre dejando el hueco del destino.
	var order = applets_visible
	if applet_drag != null:
		order = _order_with_gap(applets_visible, applet_drag, _applet_slot(mouse.x, prev))
	var ax = x
	for i in range(n):
		var id = order[i]
		var w = _applet_width(id, side)
		var pos = Vector2(_bar_x("app_" + id, ax, now), y)
		ui.set_cursor_pos(pos)
		var o = ui.get_cursor_screen_pos()
		applets_layout.append({"id": id, "x": o.x, "y": o.y, "w": w, "h": side})
		if id == applet_drag:
			ax += w + PAD
			continue
		_draw_applet(ui, id, pos, o, w, side, visible and (n_items + i) == sel and applet_drag == null, mouse)
		ax += w + PAD
	# El selector de controles del Frame (fijar/quitar applets y barras) se abre con
	# clic derecho sobre un applet o sobre la franja; ya no hay celda "+".
	if applet_picker_want:
		applet_picker_want = false
		ui.open_popup("##applets_add")
	# Pin de la barra inferior (K19): fija la franja o vuelve al autohide.
	if _draw_pin_toggle(ui, Vector2(ax, y), side, pin_bottom_bar, "pin_bottom"):
		toggle_pin("bottom")
		entered = true
	MENU_STYLE.begin(ui)
	if ui.begin_popup("##applets_add"):
		applet_picker_open = true
		MENU_STYLE.chrome(ui, "Controles del Frame")
		ui.text_disabled("Barras · auto-ocultar o fijar")
		if MENU_STYLE.item(ui, "Barra superior fija", "", pin_top_bar):
			toggle_pin("top")
		if MENU_STYLE.item(ui, "Barra inferior fija", "", pin_bottom_bar):
			toggle_pin("bottom")
		ui.text_disabled("Fijar / quitar")
		for a in APPLETS:
			if MENU_STYLE.item(ui, a.name, "", applets_visible.has(a.id)):
				_applet_set_visible(a.id, not applets_visible.has(a.id))
		ui.end_popup()
	MENU_STYLE.end(ui)
	if applet_action_want != "":
		ui.open_popup("##applet_" + applet_action_want)
		applet_action_want = ""
	MENU_STYLE.begin(ui)
	if ui.begin_popup("##applet_teclado"):
		MENU_STYLE.chrome(ui, "Teclado")
		ui.text_disabled("Distribución · próxima sesión")
		for layout in ["es", "latam", "us"]:
			if MENU_STYLE.item(ui, {"es":"Español (ES)", "latam":"Latinoamericano (LAT)", "us":"Inglés (US)"}[layout]):
				keyboard.choose(layout)
				shell.request_redraw()
		ui.text_disabled(keyboard.detail)
		ui.end_popup()
	MENU_STYLE.end(ui)
	# Governor de CPU: selección entre TODOS los que ofrece el kernel, más el
	# predeterminado de la sesión (no sólo alternar performance/powersave).
	MENU_STYLE.begin(ui)
	if ui.begin_popup("##applet_gov"):
		MENU_STYLE.chrome(ui, "CPU · Governor")
		var cur = sysmon.governor
		var def = sysmon.governor_default()
		if def != "":
			if MENU_STYLE.item(ui, "Predeterminado (" + def + ")", "", cur == def):
				sysmon.set_governor(def)
				shell.request_redraw()
			ui.separator()
		var govs = sysmon.governors()
		if govs.empty():
			ui.text_disabled("sin governors disponibles")
		else:
			for g in govs:
				if MENU_STYLE.item(ui, String(g), "", String(g) == cur):
					sysmon.set_governor(String(g))
					shell.request_redraw()
		ui.end_popup()
	MENU_STYLE.end(ui)
	# Hueco del applet arrastrado, resaltado (Esc cancela; el fantasma va al cursor).
	if applet_drag != null:
		var gi = order.find(applet_drag)
		if gi >= 0:
			var gx = x
			for j in range(gi):
				gx += _applet_width(order[j], side) + PAD
			var gw = _applet_width(applet_drag, side)
			ui.set_cursor_pos(Vector2(gx, y))
			var gscr = ui.get_cursor_screen_pos()
			ui.imgui_draw_rect_filled(Rect2(gscr, Vector2(gw, side)), Color(1, 1, 1, 0.06), 0.0)
			ui.imgui_draw_rect_filled(Rect2(gscr + Vector2(0.0, side - 3.0), Vector2(gw, 3.0)), NX_SEL, 0.0)
	_draw_inner_shadow(ui, Vector2(0.0, by), vp.x, 1.0)
	ui.end()
	ui.pop_style_var()
	applets_drawn = true


# Filas de sombra sin hit target: se dibujan dentro de la ventana real del Frame,
# no en una ventana ImGui aparte. `dir` +1 baja desde el borde superior de la barra,
# -1 sube desde el borde inferior.
static func shadow_rows(origin, width, dir, rows_value = SHADOW, alpha_value = SHADOW_ALPHA):
	var rows = max(1, int(rows_value))
	var out = []
	for i in range(rows):
		var t = float(i) / float(rows)
		var a = alpha_value * (1.0 - t) * (1.0 - t)
		var y = origin.y + float(i) * (1.0 if dir > 0.0 else -1.0)
		out.append({"rect": Rect2(Vector2(origin.x, y), Vector2(width, 1.0)), "alpha": a})
	return out


func _draw_inner_shadow(ui, origin, width, dir):
	for row in shadow_rows(origin, width, dir):
		ui.imgui_draw_rect_filled(row.rect, Color(0.0, 0.0, 0.0, row.alpha), 0.0)


# Un applet: bloque cuadrado U x U con bisel; el estado va por color de la barra/
# etiqueta además del valor textual (nunca sólo color). Tooltip con el nombre completo.
func _draw_applet(ui, id, pos, scr, w, side, is_sel, mouse, is_ghost = false):
	var a = _applet_def(id)
	if a == null:
		return
	var state = _applet_state(id)
	var b = _tile(ui, pos, w, "app_" + id, NX_FACE, side)
	var rect = b.rect
	if applet_drag == id and not is_ghost:
		return
	var line = NX_LIGHT
	if state == "activo":
		line = Color(0.45, 0.80, 1.0, 1.0)
	elif state == "apagado" or state == "sin_dato":
		line = NX_TEXT_DIM
	elif state == "cambiando":
		line = NX_SEL
	elif state == "error" or state == "no_disponible":
		line = Color(0.95, 0.55, 0.30, 1.0)
	# Placa común: los recursos y el reloj aprovechan toda la celda.
	var bw = _bevel_w(ui)
	var gp_w = max(24.0, w - 2.0 * bw - 6.0)
	var gp_h = max(24.0, side - 2.0 * bw - 6.0)
	var gp_scr = scr + Vector2((w - gp_w) * 0.5, bw + 3.0)
	var gp_loc = pos + Vector2((w - gp_w) * 0.5, bw + 3.0)
	if id != "recursos":
		ui.imgui_draw_rect_filled(Rect2(gp_scr, Vector2(gp_w, gp_h)), Color(0.10, 0.11, 0.14, 1.0), 0.0)
	var v = _applet_value(id)
	if id == "recursos":
		_draw_resources(ui, gp_scr, gp_loc, gp_w, gp_h)
	elif id == "termico":
		if sysmon.has_temp:
			line = _temp_color()
		_draw_thermal(ui, gp_scr, gp_loc, gp_w, gp_h)
	elif id == "reloj":
		_draw_clock(ui, gp_scr, gp_loc, gp_w, gp_h, v)
	else:
		ui.set_cursor_pos(gp_loc + Vector2(4.0, 3.0))
		ui.text_colored(NX_TEXT_DIM, a.short)
		var vw = _text_w(ui, v)
		ui.set_cursor_pos(gp_loc + Vector2(max(3.0, (gp_w - vw) * 0.5), gp_h * 0.45))
		ui.text_colored(NX_TEXT, v)
	var pct = _applet_pct(id)
	if pct >= 0.0:
		var bar_w = (w - 8.0) * clamp(pct, 0.0, 1.0)
		ui.imgui_draw_rect_filled(Rect2(rect.position + Vector2(4.0, side - 6.0), Vector2(bar_w, 3.0)), line, 0.0)
	if mouse.x >= rect.position.x and mouse.x < rect.end.x and mouse.y >= rect.position.y and mouse.y < rect.end.y:
		ui.begin_tooltip()
		ui.text(a.name)
		ui.text_disabled("estado: " + state)
		if id == "recursos":
			ui.text(v)
		if id == "termico":
			ui.text(v)
			if sysmon.has_battery:
				ui.text("Batería: %d%% (%s)" % [int(round(sysmon.battery_pct)),
					sysmon.battery_status if sysmon.battery_status != "" else "sin estado"])
			ui.text_disabled("clic: elegir governor")
		if id == "teclado":
			ui.text(keyboard.detail)
		ui.end_tooltip()


# Applet de sistema: gráfica de CPU como área desde abajo, con el fondo teñido por
# la carga, y diales circulares de MEM y SWP. Sin indicadores de texto (el detalle
# va en el tooltip); el color distingue los diales (verde RAM, ámbar swap).
func _draw_resources(ui, scr, loc, w, h):
	var load_ratio = clamp(sysmon.cpu_now() / 100.0, 0.0, 1.0) if sysmon.has_cpu else 0.0
	var col = _load_color()
	# Fondo según actividad: la placa se tiñe del color de carga.
	var bg = Color(0.10, 0.11, 0.14, 1.0).linear_interpolate(col, 0.12 + 0.40 * load_ratio)
	ui.imgui_draw_rect_filled(Rect2(scr, Vector2(w, h)), bg, 3.0)
	# CPU a TODO el ancho, como área desde abajo.
	_cpu_area(ui, scr + Vector2(3.0, 3.0), w - 6.0, h - 6.0, col)
	# Un solo dial CONCÉNTRICO y centrado: SWP exterior (ámbar), MEM interior
	# (verde). El radio sale del lado corto (no del ancho) para que la celda de 1
	# slot se vea igual de llena que la de 2.
	var c = scr + Vector2(w * 0.5, h * 0.5)
	var r_out = max(8.0, min(h, w) * 0.42)
	var r_in = max(5.0, r_out * 0.60)
	ui.imgui_draw_circle_filled(c, r_out + 2.0, Color(0.06, 0.07, 0.11, 0.72), 0)
	_dial(ui, c, r_out, sysmon.swap / 100.0, Color(0.95, 0.70, 0.30, 1.0))
	_dial(ui, c, r_in, sysmon.ram / 100.0, Color(0.50, 0.90, 0.45, 1.0))


# Área de CPU anclada abajo: columnas rellenas + línea superior. Al ser área (no una
# línea al tope) el movimiento se ve de un vistazo.
func _cpu_area(ui, o, w, h, col):
	if sysmon.cpu.size() < 2:
		return
	var n = sysmon.HISTORY
	var base = o.y + h
	var pts = PoolVector2Array()
	for i in range(sysmon.cpu.size()):
		var x = o.x + w * float(i + n - sysmon.cpu.size()) / float(n - 1)
		var v = clamp(sysmon.cpu[i], 0.0, 100.0) / 100.0
		var top = base - h * v
		ui.imgui_draw_rect_filled(Rect2(Vector2(x - 1.0, top), Vector2(2.0, max(1.0, base - top))),
			Color(col.r, col.g, col.b, 0.55), 0.0)
		pts.append(Vector2(x, top))
	ui.imgui_draw_polyline(pts, col, 1.5)


# Anillo concéntrico: traza tenue de fondo y arco proporcional al valor (0..1). Se
# usa dos veces en el mismo centro con radios distintos (MEM interior, SWP exterior).
func _dial(ui, c, r, value, col):
	var ring = PoolVector2Array()
	for i in range(37):
		var a = TAU * float(i) / 36.0
		ring.append(c + Vector2(cos(a), sin(a)) * r)
	ui.imgui_draw_polyline(ring, Color(1, 1, 1, 0.14), 2.0, true)
	var f = clamp(value, 0.0, 1.0)
	if f > 0.02:
		var seg = int(max(2.0, ceil(48.0 * f)))
		var pts = PoolVector2Array()
		for i in range(seg + 1):
			var a = -PI * 0.5 + TAU * f * float(i) / float(seg)
			pts.append(c + Vector2(cos(a), sin(a)) * r)
		ui.imgui_draw_polyline(pts, col, 2.5)


# Color por carga de CPU (verde en reposo, ámbar a media, rojo a tope).
func _load_color():
	var cpu_load = clamp(sysmon.cpu_now() / 100.0, 0.0, 1.0) if sysmon.has_cpu else 0.0
	if cpu_load >= 0.8:
		return Color(0.95, 0.42, 0.34, 1.0)
	if cpu_load >= 0.5:
		return Color(0.95, 0.72, 0.32, 1.0)
	return Color(0.38, 0.78, 0.95, 1.0)


# Color por rango de temperatura (frío/verde, tibio/ámbar, caliente/rojo).
func _temp_color():
	if not sysmon.has_temp:
		return NX_TEXT_DIM
	if sysmon.temp_c >= 85.0:
		return Color(0.95, 0.40, 0.32, 1.0)
	if sysmon.temp_c >= 70.0:
		return NX_SEL
	return Color(0.50, 0.90, 0.55, 1.0)


# Applet térmico SIMBÓLICO: termómetro (temperatura) a la izquierda, batería
# (carga, con rayo si carga) a la derecha y governor como etiqueta chica al pie. Sin
# números grandes que se encimen en la celda (el detalle va en el tooltip).
func _draw_thermal(ui, scr, loc, w, h):
	var col = _temp_color()
	var tf = clamp((sysmon.temp_c - 30.0) / 70.0, 0.0, 1.0) if sysmon.has_temp else 0.0
	_draw_thermo(ui, Vector2(scr.x + w * 0.26, scr.y + h * 0.10), h * 0.52, tf, col)
	if sysmon.has_battery:
		_draw_battery_icon(ui, Rect2(scr.x + w * 0.50, scr.y + h * 0.16, w * 0.42, h * 0.26),
			clamp(sysmon.battery_pct / 100.0, 0.0, 1.0), sysmon.battery_charging())
	# Governor (la selección se hace con clic izquierdo; ver _applet_primary). Fuente
	# de etiqueta (más chica que la de UI) para que no compita con los símbolos.
	var gov = sysmon.governor if sysmon.has_governor else "sin dato"
	var small = _push_label_font(ui)
	gov = _truncate_w(ui, gov, w - 8.0)
	ui.set_cursor_pos(loc + Vector2(4.0, h * 0.72))
	ui.text_colored(NX_TEXT_DIM, gov)
	if small:
		ui.pop_font()


# Termómetro: tubo + bulbo, con mercurio hasta `frac` (0..1) en color de rango.
# `c` es el centro del extremo superior; `hgt` el alto total.
func _draw_thermo(ui, c, hgt, frac, col):
	var stem_w = max(3.0, hgt * 0.18)
	var bulb_r = max(3.5, stem_w * 1.5)
	var stem_h = max(4.0, hgt - bulb_r)
	var top = c.y
	var bulb_c = Vector2(c.x, top + stem_h + bulb_r * 0.15)
	var dark = Color(0.0, 0.0, 0.0, 0.40)
	ui.imgui_draw_rect_filled(Rect2(Vector2(c.x - stem_w * 0.5, top), Vector2(stem_w, stem_h)), dark, stem_w * 0.5)
	ui.imgui_draw_circle_filled(bulb_c, bulb_r, dark, 0)
	var mh = stem_h * clamp(frac, 0.0, 1.0)
	ui.imgui_draw_rect_filled(Rect2(Vector2(c.x - stem_w * 0.22, top + stem_h - mh), Vector2(stem_w * 0.44, mh)), col, stem_w * 0.22)
	ui.imgui_draw_circle_filled(bulb_c, max(2.0, bulb_r * 0.62), col, 0)


# Batería simbólica: cuerpo con contorno claro e interior oscuro, relleno
# proporcional y rayo si está cargando. El contorno (y no sólo un bloque oscuro) la
# hace legible a tamaño chico y deja claro dónde está el borne.
func _draw_battery_icon(ui, r, frac, charging):
	var line = NX_TEXT_DIM
	var cap_w = max(2.0, r.size.x * 0.10)
	var body = Rect2(r.position, Vector2(max(5.0, r.size.x - cap_w - 1.0), r.size.y))
	ui.imgui_draw_rect_filled(body, Color(0.06, 0.07, 0.11, 0.92), 1.5)
	_draw_outline(ui, body, line)
	# Borne (positivo): rectángulo corto a la derecha, centrado verticalmente.
	ui.imgui_draw_rect_filled(Rect2(Vector2(body.end.x + 1.0, r.position.y + r.size.y * 0.30),
		Vector2(cap_w, r.size.y * 0.40)), line, 1.0)
	var inr = body.grow(-max(1.5, body.size.y * 0.20))
	var col = Color(0.55, 0.90, 0.55, 1.0) if charging else Color(0.60, 0.80, 0.95, 1.0)
	if not charging and frac < 0.20:
		col = Color(0.95, 0.45, 0.35, 1.0)
	var fw = inr.size.x * clamp(frac, 0.0, 1.0)
	if fw > 0.0:
		ui.imgui_draw_rect_filled(Rect2(inr.position, Vector2(fw, inr.size.y)), col, 1.0)
	if charging:
		_draw_bolt(ui, body.position + body.size * 0.5, min(body.size.x, body.size.y) * 0.46,
			Color(0.98, 0.85, 0.35, 1.0))


# Rayo (indica carga): zigzag vectorial cerrado.
func _draw_bolt(ui, c, s, col):
	var pts = PoolVector2Array([
		c + Vector2(0.18 * s, -1.0 * s), c + Vector2(-0.38 * s, 0.16 * s),
		c + Vector2(-0.06 * s, 0.16 * s), c + Vector2(-0.18 * s, 1.0 * s),
		c + Vector2(0.38 * s, -0.16 * s), c + Vector2(0.06 * s, -0.16 * s),
		c + Vector2(0.18 * s, -1.0 * s)])
	ui.imgui_draw_polyline(pts, col, max(1.5, s * 0.34), true)


func _draw_clock(ui, scr, loc, w, h, value):
	var size = min(w, h)
	var center = scr + Vector2(w * 0.5, h * 0.40)
	var radius = size * 0.32
	ui.imgui_draw_circle(center, radius, NX_TEXT_DIM, 32, 1.5)
	var t = OS.get_time()
	for hand in [
		{"angle": TAU * (float(t.hour % 12) + float(t.minute) / 60.0) / 12.0 - PI * 0.5, "length": radius * 0.53, "width": 2.5},
		{"angle": TAU * float(t.minute) / 60.0 - PI * 0.5, "length": radius * 0.79, "width": 1.5}]:
		var tip = center + Vector2(cos(hand.angle), sin(hand.angle)) * hand.length
		ui.imgui_draw_polyline(PoolVector2Array([center, tip]), NX_FOCUS, hand.width)
	ui.imgui_draw_circle_filled(center, 2.0, NX_SEL, 0)
	ui.set_cursor_pos(loc + Vector2((w - _text_w(ui, value)) * 0.5, h - 15.0 * ui.get_imgui_scale()))
	ui.text_colored(NX_TEXT, value)


func _draw_outline(ui, rect, color):
	var p = PoolVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	ui.imgui_draw_polyline(p, color, 2.0, true)


# Bloque Inicio: tesela cuadrada con el ícono Sugar de hogar y el título corto abajo.
# Resalta cuando la vista actual es el Hogar (la ranura extra al final de la fila).
func _draw_home_tile(ui, pos, side):
	var at_home = shell.current_activity == null and not shell.neighborhood_view
	var b = _tile(ui, pos, side, "go_home", NX_CUR if at_home else NX_FACE)
	var ts = ui.get_imgui_scale()
	var pad = TILE_PAD * ts
	var lines = _title_lines(ui, side, "Inicio") if side >= 76.0 * ts else []
	var title_h = _title_reserved(ui, lines) if not lines.empty() else 0.0
	var bw = _bevel_w(ui)
	var inner = side - 2.0 * bw
	var s = clamp(inner - title_h - 2.0 * pad, ICON_MIN * ts, ICON_MAX * ts)
	var iy = bw + max(pad, (inner - s - title_h) * 0.5)
	# Bloque Inicio = "Este equipo": lleva el ícono del equipo local (desktop,
	# laptop, tablet, mobile o tv), no una casita genérica.
	var icon = shell.local_device_icon_tex()
	if icon != null:
		_draw_emboss_icon(ui, pos + Vector2((side - s) * 0.5, iy), Vector2(s, s), icon, b.face)
	else:
		ui.set_cursor_pos(pos + Vector2((side - 7.0 * ui.get_imgui_scale()) * 0.5, (side - 13.0 * ui.get_imgui_scale()) * 0.5))
		ui.text_colored(NX_TEXT, "H")
	if not lines.empty():
		_tile_title(ui, pos, side, "Inicio", false, lines)
	return b.clicked


# Bloque Vecindario: tesela U x U con el ícono de red inalámbrica (The Noun
# Project, ver icons/np/CREDITS.txt). Sólo abre la vista (no escanea, no conecta);
# resalta cuando la vista actual es el Vecindario.
func _draw_neighborhood_tile(ui, pos, side):
	var active = shell.neighborhood_view
	var b = _tile(ui, pos, side, "go_neighborhood", NX_CUR if active else NX_FACE)
	var ts = ui.get_imgui_scale()
	var pad = TILE_PAD * ts
	var lines = _title_lines(ui, side, "Vecindario") if side >= 76.0 * ts else []
	var title_h = _title_reserved(ui, lines) if not lines.empty() else 0.0
	var bw = _bevel_w(ui)
	var inner = side - 2.0 * bw
	var s = clamp(inner - title_h - 2.0 * pad, ICON_MIN * ts, ICON_MAX * ts)
	var iy = bw + max(pad, (inner - s - title_h) * 0.5)
	var icon = shell.neighborhood_icon_tex()
	if icon != null:
		_draw_emboss_icon(ui, pos + Vector2((side - s) * 0.5, iy), Vector2(s, s), icon, b.face)
	else:
		var center = pos + Vector2(side * 0.5, iy + s * 0.5)
		_draw_wifi_glyph(ui, center, s * 0.5, NX_TEXT)
	if not lines.empty():
		_tile_title(ui, pos, side, "Vecindario", false, lines)
	return b.clicked


# Ícono del sistema con relieve grabado. Si el relieve está apagado, sólo el ícono.
# El ícono se dibuja con aire (inset) para no tocar el borde del bloque.
func _draw_emboss_icon(ui, loc, size, tex, face):
	var inset = size * (0.10 if _emboss() else 0.0)
	var p = loc + inset
	var sz = size - inset * 2.0
	if _emboss():
		_emboss_image(ui, tex, p, sz, face)
	else:
		ui.set_cursor_pos(p)
		ui.image(tex, sz)


# Glifo Wi-Fi dibujado con la lista de dibujo de ImGui: punto y tres arcos
# concéntricos abiertos hacia arriba (reconocible, sin depender de un SVG).
func _draw_wifi_glyph(ui, c, r, col):
	var dot = c + Vector2(0.0, r * 0.45)
	ui.imgui_draw_circle_filled(dot, max(1.5, r * 0.14), col, 0)
	var thick = max(1.5, r * 0.13)
	for band in range(3):
		var ar = r * (0.38 + 0.28 * float(band))
		var pts = PoolVector2Array()
		var seg = 18
		for i in range(seg + 1):
			var a = lerp(-0.78 * PI, -0.22 * PI, float(i) / float(seg))
			pts.append(dot + Vector2(cos(a), sin(a)) * ar)
		ui.imgui_draw_polyline(pts, col, thick, true)


# Bloque de ventana: tesela cuadrada con ícono (mínimo 64 px), título corto de una
# línea y el control de cerrar superpuesto arriba SÓLO al pasar el mouse por el bloque.
# Minimizar/restaurar es el clic izquierdo en el bloque (ver draw()): la ventana
# enfocada se minimiza y una minimizada se restaura; el teclado usa Alt+M/Delete.
# Estado por color de cara (foco/actual, destino, selección, minimizada) sin depender
# del texto. `pos` es local; el bisel/foco usan el rect en pantalla que devuelve _tile.
func _draw_window_tile(ui, pos, side, item, current, is_sel, is_drop, mouse):
	var face = NX_FACE
	if current:
		face = NX_CUR
	elif is_drop:
		face = NX_SEL
	elif is_sel:
		face = NX_FACE_SEL
	elif item.minimized:
		face = NX_FACE_DIM
	var b = _tile(ui, pos, side, "w" + item.key, face)
	# El ícono manda: mínimo 64 px. Si no caben 64 px + el título, se dibuja arriba
	# (a ras del bisel) y el título va sobre una banda inferior semitransparente.
	var ts = ui.get_imgui_scale()
	var bw = _bevel_w(ui)
	# El número de pantalla compartido va como prefijo del título corto.
	var label = item.title
	if item.screen > 0:
		label = str(item.screen) + " " + label
	var lines = _title_lines(ui, side, label)
	var title_h = _title_reserved(ui, lines)
	var inner = side - 2.0 * bw
	var stack = inner - title_h - 4.0
	var icon_tile_min = ICON_TILE_MIN * ts
	var overlap = stack < icon_tile_min
	var s = min(float(icon_tile_min), inner) if overlap else clamp(stack, icon_tile_min, ICON_MAX * ts)
	var tex = _item_icon(item)
	var iy = bw + 0.5 if overlap else bw + max(0.0, (inner - title_h - s) * 0.5)
	if tex != null:
		ui.set_cursor_pos(pos + Vector2((side - s) * 0.5, iy))
		ui.image(tex, Vector2(s, s))
	else:
		var mono = item.name.substr(0, 1).to_upper() if item.name != "" else "?"
		ui.set_cursor_pos(pos + Vector2((side - 7.0 * ui.get_imgui_scale()) * 0.5, iy + s * 0.28))
		ui.text_colored(NX_TEXT, mono)
	# Banda inferior semitransparente cuando el título pisa al ícono: garantiza
	# legibilidad sin encoger el ícono por debajo de 64 px.
	if overlap:
		ui.imgui_draw_rect_filled(Rect2(b.rect.position + Vector2(bw, side - title_h),
			Vector2(side - 2.0 * bw, title_h - bw)), Color(0.0, 0.0, 0.0, 0.5), 0.0)
	_tile_title(ui, pos, side, label, item.minimized, lines)
	# Cerrar: la esquina superior derecha entera es un botón diagonal (no una
	# mini-tesela cuadrada). Aparece al pasar el mouse por el bloque.
	var off = b.rect.position - pos
	var corner = clamp(side * 0.22, 12.0 * ts, 20.0 * ts)
	if b.rect.has_point(mouse):
		var tr = b.rect.position
		var br = b.rect.end
		var a = Vector2(br.x, tr.y)
		var bb = Vector2(br.x, tr.y + corner)
		var c = Vector2(br.x - corner, tr.y)
		var over_close = _in_tri(mouse, a, bb, c)
		var pressed = over_close and mouse_down
		_draw_corner_close(ui, b.rect, corner, over_close, pressed)
		if b.clicked and over_close:
			return {"clicked": false, "close": true}
	return {"clicked": b.clicked, "close": false}


# Punto en triángulo (signos de productos cruzados), para la esquina de cerrar.
static func _sign2(p, a, b):
	return (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)


func _in_tri(p, a, b, c):
	var d1 = _sign2(p, a, b)
	var d2 = _sign2(p, b, c)
	var d3 = _sign2(p, c, a)
	var has_neg = d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos = d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (has_neg and has_pos)


# Botón de cerrar en la esquina superior derecha: triángulo relleno por filas (el
# draw list de ImGui no tiene triángulo relleno) con un aspa centrada. Se enciende
# en rojo al pasar el mouse.
func _draw_corner_close(ui, r, corner, hot, pressed):
	var face = Color(0.30, 0.33, 0.43, 1.0)
	if hot:
		face = Color(0.64, 0.28, 0.30, 1.0)
	if pressed:
		face = face.darkened(0.25)
	var rows = int(ceil(corner))
	for i in range(rows):
		var t = float(i) / float(rows)
		var w = corner * (1.0 - t)
		if w <= 0.0:
			continue
		ui.imgui_draw_rect_filled(Rect2(Vector2(r.end.x - w, r.position.y + float(i)), Vector2(w, 1.0)), face, 0.0)
	var edge = Color(1.0, 0.85, 0.85, 0.9) if hot else NX_LIGHT
	ui.imgui_draw_polyline(PoolVector2Array([
		Vector2(r.end.x - corner, r.position.y), Vector2(r.end.x, r.position.y + corner)]), edge, 1.5, false)
	var g = corner * 0.30
	var cx = r.end.x - corner * 0.32
	var cy = r.position.y + corner * 0.32
	var gc = Color(1.0, 0.94, 0.94, 1.0) if hot else NX_TEXT
	var gw = max(1.5, 2.0 * ui.get_imgui_scale())
	ui.imgui_draw_polyline(PoolVector2Array([Vector2(cx - g, cy - g), Vector2(cx + g, cy + g)]), gc, gw, false)
	ui.imgui_draw_polyline(PoolVector2Array([Vector2(cx + g, cy - g), Vector2(cx - g, cy + g)]), gc, gw, false)


# Llamado en cada imgui_frame del shell, después de la vista.
func draw(ui):
	# Otra vez tras dibujar la vista: lo que cambió en este frame (un clic que abre
	# una app, la primera textura) arranca el fundido ya, sin un frame a opacidad plena.
	transition()
	# En pantalla completa el Frame no existe (Alt+F11 vuelve).
	if shell.fullscreen_id >= 0:
		visible = false
		drawn = false
		items_layout = []
		applets_layout = []
		applets_drawn = false
		shared_layout = []
		shared_drawn = false
		trash_layout = null
		return
	var home = shell.current_activity == null
	var mouse = ui.get_mouse_pos()
	var now = OS.get_ticks_msec()
	var vp = ui.get_viewport_rect().size
	var bh = shell.frame_bar_h(vp)
	# Los applets y las ventanas se dibujan con su ícono; permitir la carga perezosa
	# de varios por frame (antes 2): con varias ventanas/pines distintas, las de más
	# caían al monograma aunque el .desktop tuviera ícono. Cada app se carga una vez.
	shell.home_icon_loads = max(shell.home_icon_loads, 8)
	# MousePos es -FLT_MAX hasta el primer movimiento: eso no es la esquina.
	# Hover para revelar el autohide: con la barra oculta hay que EMPUJAR el borde
	# (canto de HOT_EDGE px), no basta con entrar en la franja del Frame; así no
	# aparece al interactuar con el contenido pegado al borde.
	var hot = mouse.y >= 0.0 and (mouse.y <= HOT_EDGE * ui.get_imgui_scale() \
		or mouse.y >= vp.y - HOT_EDGE * ui.get_imgui_scale())
	if hot:
		if corner_since == 0:
			corner_since = now
		if corner_since > 0:
			var left = HOT_MS - (now - corner_since)
			if left <= 0:
				if not visible:
					set_visible(true)
					entered = true
			elif not hot_timer:
				# Sin input no hay frames: un timer pide el que vuelve a mirar al cumplirse HOT_MS.
				hot_timer = true
				get_tree().create_timer(left / 1000.0).connect("timeout", self, "_hot_wake")
	else:
		corner_since = 0
	if visible and not home:
		# La barra inferior cuenta como parte del Frame: el mouse ahí no lo auto-oculta.
		if mouse.y <= bh or mouse.y >= vp.y - bh:
			entered = true
		elif entered and mouse.y > bh + 16.0 and mouse.y < vp.y - bh \
				and dragging == null and lifted == null and win_drag == null \
				and applet_drag == null and applet_press == null \
				and app_drag == null and app_press == null and now > show_until:
			set_visible(false)
		elif show_until > 0 and now > show_until:
			# Frame mostrado por Alt+Tab: se oculta solo al terminar la gracia.
			set_visible(false)
			show_until = 0

	items_layout = []
	# Guarda el layout de pines anterior para calcular el destino del arrastre
	# (el de este frame se rearma durante el dibujo).
	pinned_prev = pinned_layout.duplicate()
	pinned_layout = []
	# Autohide sincronizado (una señal `visible`), con pin por barra: una barra
	# fijada queda siempre a la vista; una con autohide sigue a `visible`/Home.
	var want_top = home or visible or pin_top_bar
	var want_bottom = home or visible or pin_bottom_bar
	var off_top = _slide(want_top, now, "top")
	var off_bottom = _slide(want_bottom, now, "bottom")
	slide_instant = false
	var top_drawn = off_top > -bh
	var bottom_drawn = off_bottom > -bh
	drawn = top_drawn or bottom_drawn
	if not drawn:
		items_layout = []
		applets_layout = []
		applets_drawn = false
		shared_layout = []
		shared_drawn = false
		trash_layout = null
		return
	if not top_drawn:
		# Barra superior fuera: no hay layout de ventanas en pantalla.
		items_layout = []
		trash_layout = null
	if not bottom_drawn:
		applets_layout = []
		applets_drawn = false
		shared_layout = []
		shared_drawn = false

	# Teselas cuadradas de lado U (alto de la barra).
	var side = bh
	var chosen = null
	var to_close = null
	var to_minimize = null
	if top_drawn:
		ui.push_style_var_vec2(ui.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
		ui.set_next_window_pos(Vector2(0.0, off_top), true)
		ui.set_next_window_size(Vector2(vp.x, bh), true)
		var flags = ui.WINDOW_NO_DECORATION | ui.WINDOW_NO_MOVE | ui.WINDOW_NO_SAVED_SETTINGS | ui.WINDOW_NO_SCROLLBAR | ui.WINDOW_NO_BACKGROUND
		if ui.begin("##frame", flags):
			# Fondo NeXT de la franja superior.
			ui.imgui_draw_rect_filled(Rect2(Vector2.ZERO, Vector2(vp.x, bh)), NX_BG, 0.0)
			if app_drag != null and mouse.y <= bh:
				ui.imgui_draw_rect_filled(Rect2(Vector2(0.0, off_top + bh - 3.0), Vector2(vp.x, 3.0)), NX_SEL, 0.0)
			var y = (bh - side) * 0.5
			var x = PAD
			# Esquina izquierda reservada: bloque vacío, no se usa para apps.
			x = _draw_corner_block(ui, x, y, side, "top_left")
			# Orden: vecindario, luego inicio, luego las apps abiertas.
			if _draw_neighborhood_tile(ui, Vector2(x, y), side):
				set_visible(false)
				shell._go_neighborhood()
			x += side + PAD
			if _draw_home_tile(ui, Vector2(x, y), side):
				set_visible(false)
				shell._go_home()
			x += side + PAD
			x = _draw_pinned(ui, pinned_top, x, side, "top")

			var items = running()
			# La selección recorre las ventanas y después los applets.
			var app_total = items.size() + applets_visible.size()
			if sel < 0 or sel >= app_total:
				sel = -1
				for i in range(items.size()):
					if _is_current(items[i]):
						sel = i
				if sel < 0:
					sel = 0
			# Objetivo del arrastre/levantado, para resaltarlo al dibujar.
			var drop_id = -1
			if dragging != null:
				var t = _item_at(mouse_pos)
				if t != null and t.id >= 0 and t.id != dragging.id:
					drop_id = t.id
			elif lifted != null:
				drop_id = lifted.id

			var index = 0
			for item in items:
				var current = _is_current(item)
				var is_sel = visible and index == sel and dragging == null
				var is_drop = (item.id >= 0 and item.id == drop_id)
				var res = _draw_window_tile(ui, Vector2(x, y), side, item, current, is_sel, is_drop, mouse)
				if res.close:
					to_close = item
				elif res.clicked:
					# Clic en el bloque: la ventana enfocada se minimiza; una
					# minimizada se restaura; cualquier otra sólo se enfoca.
					if item.id >= 0 and current and not item.minimized:
						to_minimize = item
					else:
						chosen = item
				items_layout.append({"title": item.title, "id": item.id, "current": current,
					"minimized": item.minimized, "screen": item.screen, "x": x, "y": y + off_top,
					"w": side, "h": side, "min_x": x, "close_x": x + side, "hit_w": side})
				x += side + PAD
				index += 1

			# Chip flotante mientras se arrastra, se levanta o se mueve una ventana con Super.
			var ghost = dragging if dragging != null else lifted
			var ghost_title = ghost.title if ghost != null else ""
			if win_drag != null:
				for it in items:
					if it.id == win_drag.id:
						ghost_title = it.title
						break
			if ghost_title != "":
				# Mismo anclaje que el bloque: chip de arrastre pegado al cursor.
				ui.set_next_window_pos(mouse_pos, true)
				ui.begin_tooltip()
				ui.text(ghost_title)
				ui.end_tooltip()
			# Basurero: esquina superior derecha de la barra, visible SÓLO mientras hay
			# un drag activo (app, applet, ventana o anillo). Es zona de soltado.
			trash_layout = null
			# Esquina derecha reservada: el pin chico va adentro; el basurero, al
			# arrastrar, ocupa la celda justo a su izquierda.
			var corner_x = vp.x - side - PAD
			if _drag_active():
				var trash_x = corner_x - (side + PAD)
				ui.set_cursor_pos(Vector2(trash_x, y))
				var tr = Rect2(ui.get_cursor_screen_pos(), Vector2(side, side))
				trash_layout = tr
				var hot_trash = tr.has_point(mouse_pos)
				_bevel(ui, tr, Color(0.34, 0.20, 0.22, 1.0) if hot_trash else NX_FACE, false)
				_draw_trash_glyph(ui, tr, Color(0.98, 0.52, 0.46, 1.0) if hot_trash else NX_TEXT)
			# Pin de la barra superior: fija la franja (deja de auto-ocultarse y las
			# ventanas reservan su alto) o vuelve al autohide.
			if _draw_pin_toggle(ui, Vector2(corner_x, y), side, pin_top_bar, "pin_top"):
				toggle_pin("top")
				entered = true
			_draw_inner_shadow(ui, Vector2(0.0, off_top + bh - 1.0), vp.x, -1.0)
		ui.end()
		ui.pop_style_var()

	if bottom_drawn:
		_draw_applets(ui, vp, off_bottom, mouse)
	_draw_drag_tile(ui, bh)

	# Cerrar tiene prioridad sobre alternar/minimizar y sobre cambiar: la mini-tesela
	# 'x' va encima del bloque cuadrado y puede compartir el clic en la esquina.
	if to_close != null:
		close(to_close)
	elif to_minimize != null:
		shell._minimize_window(to_minimize.id)
		shell.request_redraw()
	elif chosen != null:
		switch_to(chosen)
	suppress_pinned_click = ""


# Glifo de basurero dibujado a mano (tapa, asa, cuerpo y costillas); reconocible
# sin depender de un SVG del tema.
func _draw_trash_glyph(ui, r, col):
	var x = r.position.x
	var y = r.position.y
	var w = r.size.x
	ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * 0.22, y + w * 0.28), Vector2(w * 0.56, w * 0.06)), col, 0.0)
	ui.imgui_draw_rect_filled(Rect2(Vector2(x + w * 0.40, y + w * 0.21), Vector2(w * 0.20, w * 0.05)), col, 0.0)
	ui.imgui_draw_polyline(PoolVector2Array([
		Vector2(x + w * 0.28, y + w * 0.36),
		Vector2(x + w * 0.32, y + w * 0.76),
		Vector2(x + w * 0.68, y + w * 0.76),
		Vector2(x + w * 0.72, y + w * 0.36)]), col, 2.0, false)
	ui.imgui_draw_polyline(PoolVector2Array([Vector2(x + w * 0.42, y + w * 0.42), Vector2(x + w * 0.44, y + w * 0.70)]), col, 1.0, false)
	ui.imgui_draw_polyline(PoolVector2Array([Vector2(x + w * 0.58, y + w * 0.42), Vector2(x + w * 0.56, y + w * 0.70)]), col, 1.0, false)


# Botón de pin de una barra (K19): control redondo, chico y sutil en la esquina
# derecha, no un bloque. El slot se reserva para el layout, pero sólo el círculo es
# clickeable (el resto del slot no captura el mouse). En relieve, apenas notorio en
# reposo; se aclara al pasar el mouse y toma acento ámbar cuando la barra está fija.
func _draw_pin_toggle(ui, pos, side, pinned, id):
	var ts = ui.get_imgui_scale()
	# Pin chico (~1/4 del bloque) centrado en la celda de la esquina.
	var d = max(12.0 * ts, side * 0.25)
	var r = d * 0.5
	var center = pos + Vector2(side * 0.5, side * 0.5)
	ui.set_cursor_pos(center - Vector2(r, r))
	var rect = Rect2(ui.get_cursor_screen_pos(), Vector2(d, d))
	ui.push_style_color(ui.COL_BUTTON, Color(0, 0, 0, 0))
	ui.push_style_color(ui.COL_BUTTON_HOVERED, Color(0, 0, 0, 0))
	ui.push_style_color(ui.COL_BUTTON_ACTIVE, Color(0, 0, 0, 0))
	var clicked = ui.button("##" + id, Vector2(d, d))
	var held = ui.is_item_active()
	var hover = ui.is_item_hovered()
	ui.pop_style_color(3)
	var c = rect.position + Vector2(r, r)
	var face = NX_CUR if pinned else NX_FACE.linear_interpolate(NX_LIGHT, 0.12)
	if hover and not held:
		face = face.linear_interpolate(Color(1, 1, 1, face.a), 0.10)
	# Relieve circular: sombra abajo-derecha, cara, aro claro arriba-izquierda.
	ui.imgui_draw_circle_filled(c + Vector2(0.0, 1.0), r, NX_DARK, 0)
	ui.imgui_draw_circle_filled(c, r, face, 0)
	ui.imgui_draw_circle(c, r - 0.5, NX_DARK if held else NX_LIGHT, 24, 1.0)
	var g = r * 0.72
	_draw_pin_glyph(ui, Rect2(c - Vector2(g, g), Vector2(g * 2.0, g * 2.0)),
		NX_SEL if pinned else NX_TEXT_DIM)
	return clicked


# Chincheta: cabeza (rombo/triángulo), cuerpo y aguja, dibujados a mano.
func _draw_pin_glyph(ui, r, col):
	var x = r.position.x
	var y = r.position.y
	var w = r.size.x
	var cx = x + w * 0.5
	ui.imgui_draw_rect_filled(Rect2(Vector2(cx - w * 0.09, y + w * 0.22), Vector2(w * 0.18, w * 0.34)), col, 0.0)
	ui.imgui_draw_polyline(PoolVector2Array([
		Vector2(x + w * 0.30, y + w * 0.40),
		Vector2(x + w * 0.70, y + w * 0.40),
		Vector2(cx, y + w * 0.20),
		Vector2(x + w * 0.30, y + w * 0.40)]), col, 1.5, true)
	ui.imgui_draw_polyline(PoolVector2Array([Vector2(cx, y + w * 0.56), Vector2(cx, y + w * 0.78)]), col, 2.0, false)


func _draw_drag_tile(ui, side):
	if app_drag == null and applet_drag == null:
		return
	ui.push_style_var_vec2(ui.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	# El tooltip por defecto se ancla en MousePos + (16,10) (+ padding): eso era el
	# corrimiento de ~20 px. Se fuerza al cursor MENOS el offset de agarre, para que
	# la tesela quede exactamente donde estaba respecto del punto que se tomó.
	var grab = app_grab if app_drag != null else applet_grab
	ui.set_next_window_pos(mouse_pos - grab, true)
	ui.begin_tooltip()
	var pos = Vector2.ZERO
	if app_drag != null:
		_draw_app_tile(ui, app_drag, pos, side, "drag_app")
	else:
		ui.set_cursor_pos(pos)
		_draw_applet(ui, applet_drag, pos, ui.get_cursor_screen_pos(), _applet_width(applet_drag, side), side, false, Vector2(-1, -1), true)
	ui.end_tooltip()
	ui.pop_style_var()


func _hot_wake():
	hot_timer = false
	shell.request_redraw()


# Desplazamiento vertical de una barra: 0 quieta a la vista, -alto fuera. `key`
# ("top"/"bottom") separa el estado de cada barra. Mientras desliza pide frames y
# mantiene despierto el loop; al terminar deja de pedirlos.
func _slide(want, now, key = "top"):
	var bh = _vh()
	var is_top = key == "top"
	var shown = shown_top if is_top else shown_bottom
	var since = slide_since_top if is_top else slide_since_bottom
	if want and slide_instant:
		shown = true
		since = now - SLIDE_MS
		if is_top:
			shown_top = true
			slide_since_top = since
		else:
			shown_bottom = true
			slide_since_bottom = since
		return 0.0
	if want != shown:
		shown = want
		# Si cambia a mitad de camino, sigue desde donde está.
		var done = min(now - since, SLIDE_MS)
		since = now - (SLIDE_MS - done)
		if is_top:
			shown_top = shown
			slide_since_top = since
		else:
			shown_bottom = shown
			slide_since_bottom = since
	var k = clamp(float(now - since) / SLIDE_MS, 0.0, 1.0)
	if k < 1.0:
		shell.request_redraw()
		shell.last_activity = now
	var p = 1.0 - pow(1.0 - k, 3.0)
	if not shown:
		p = 1.0 - p
	return -bh * (1.0 - p)


# Lados que el Frame RESERVA para las ventanas: sólo las barras fijadas (pin).
# Con autohide (default) no reserva nada: la barra se superpone a la ventana sin
# redimensionarla. Lo consulta el layout de tiles/diálogos del shell.
func reserved_edges():
	return {"top": pin_top_bar, "bottom": pin_bottom_bar}


# Fija/auto-oculta una barra (pin). Al fijar aparece de inmediato (sin deslizar) y
# las ventanas se reacomodan al hueco reservado; al soltar vuelve al autohide.
func toggle_pin(key):
	if key == "bottom":
		pin_bottom_bar = not pin_bottom_bar
	else:
		pin_top_bar = not pin_top_bar
	if pin_top_bar or pin_bottom_bar:
		slide_instant = true
	applets_dirty = true
	_save_applets()
	shell.request_redraw()


# Cambio de vista (Home <-> app, anillo <-> grilla, entre apps): fundido de FADE_MS
# y, en la vista wayland, zoom leve desde el centro. Devuelve el alfa para ImGui.
# Sólo toca nodos mientras dura: en reposo no hay nada que redibujar.
const FADE_MS = 320
var view_key = ""
var fade_since = 0
var fading = false


func transition():
	var now = OS.get_ticks_msec()
	var key = "home:" + str(shell.apps_view) + ":" + str(shell.neighborhood_view)
	if shell.current_activity != null:
		if shell.current_activity.has("wayland") and shell.tile_mode:
			# En tiling todas las ventanas están a la vista: enfocar otra no re-funde todo.
			key = "tiles"
		else:
			# Una app nueva cambia de clave otra vez al llegar su primera textura.
			key = shell.current_activity.name + ":" + str(shell.tex_ready_frame >= 0)
	if key != view_key:
		view_key = key
		fade_since = now
		fading = true
	if not fading:
		return 1.0
	var k = clamp(float(now - fade_since) / FADE_MS, 0.0, 1.0)
	var a = 1.0 - pow(1.0 - k, 3.0)
	if k < 1.0:
		shell.request_redraw()
		shell.last_activity = now
	else:
		fading = false
	var v = shell.view
	v.rect_pivot_offset = v.rect_size * 0.5
	var z = lerp(0.94, 1.0, a)
	v.rect_scale = Vector2(z, z)
	# Las capas usan alfa premultiplicado: se escala también el color.
	v.modulate = Color(a, a, a, a)
	return a
