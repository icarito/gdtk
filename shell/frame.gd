extends Node

# El Frame (como en Sugar): franja superpuesta arriba con Hogar, todo lo que
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
# Mínimo de celdas de la grilla regular de barra: 4 fijas (esquina/Vecindario/Grupo/Hogar),
# la celda del pin a la derecha y al menos cuatro de contenido.
const MIN_CELLS = 9
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
const NX_CUR = Color(0.32, 0.60, 0.98, 1.0)  # fallback; ver _cur()
const BEVEL_BASE = 2.0    # grosor base del bisel (se escala con la UI y Apariencia)
# Sombra suave del Frame sobre el contenido, pegada al borde interior de cada barra.
const SHADOW = 3.0
const SHADOW_ALPHA = 0.18
const TITLE_H = 14.0     # alto de la línea de título dentro de la tesela
const TITLE_MAX = 10     # máximo de caracteres del título (se recorta con ...)
const ICON_MIN = 48.0    # piso del ícono de un bloque con título (Hogar/Grupo/Vecindario)
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
	{"id": "portapapeles", "name": "Portapapeles", "short": "CLIP"},
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
# Rects en pantalla de los bloques fijos Vecindario/Grupo/Hogar del último dibujo de la
# barra superior: la rueda sobre ellos recorre la cadena vertical (shell._wheel_vchain).
var place_rects = []
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
var drag_grab = Vector2.ZERO
var mouse_down = false
var mouse_pos = Vector2.ZERO
var slide_instant = false  # aparecer sin animación (Alt+Tab)
var show_until = 0         # ms hasta el que el Frame no se auto-oculta (Alt+Tab)
# Layout del último frame dibujado (para el control remoto / tests).
var sysmon = Host.sc("res://sysmon.gd").new()
var keyboard = Host.sc("res://applet_keyboard.gd").new()
var bluetooth = Host.sc("res://applet_bluetooth.gd").new()
var clipboard = Host.sc("res://applet_clipboard.gd").new()
# Applets con módulo propio (contrato en .operator-shared/guides/dockapp.md): el Frame
# les pide state/value/detail, los refresca mientras están a la vista y los para al
# salir. Sumar una dockapp = un archivo + su entrada en APPLETS + una línea acá.
var applet_mods = {"teclado": keyboard, "portapapeles": clipboard}
var items_layout = []
var drawn = false
# Applets del borde inferior: orden visible persistido (no es items_layout, que sigue
# siendo sólo de ventanas para el control remoto). `applets_future` conserva ids
# desconocidos del archivo para una versión futura.
var applets_visible = []
var applets_future = []
var applets_raw = {}
var applets_saved_bottom = []
# Orden UNIFICADO de bloques por barra (applets y pines comparten los slots):
# tokens "p:<app-id>" (pin) y "a:<applet-id>" (applet). Los pines (`pinned_top`/
# `pinned_dock`) se derivan de `bar_order` con `_sync_pins()`.
#
# La lista de ventanas abiertas es además un DockApp más (el "Clip" de WindowMaker):
# token "w:windows". Ocupa un slot por ventana (span dinámico) y, sin ventanas, un
# solo bloque con el ícono de clip. Al estar en `bar_order` se puede colocar en
# cualquier slot, entre los pines/applets, y su posición persiste con el resto.
const WINDOW_TOKEN = "w:windows"
# DockApp "Compartiendo": token condicional "s:sharing". Entra al orden (por
# `_place_new_token`) sólo mientras haya una relación activa y sale al terminar; en
# medio se arrastra y persiste como cualquier otro token.
const SHARED_TOKEN = "s:sharing"
var bar_order = {"top": [], "dock": []}
var bar_order_saved = {"top": [], "dock": []}
var pinned_top = []
var pinned_dock = []
var pinned_saved_top = []
var pinned_saved_dock = []
var applets_dirty = false
var applets_layout = []    # rects del último dibujo de los applets
var bar_layout = {"top": [], "dock": []}  # rects+tokens del último dibujo por barra
var bar_cell = {"top": 0.0, "dock": 0.0}  # ancho de un slot vacío (hueco) del último dibujo
var bar_origin = {"top": 0.0, "dock": 0.0}  # x de la celda 0 de cada barra (último dibujo)
var bar_side = {"top": 0.0, "dock": 0.0}  # lado del bloque (alto de barra) del último dibujo
var window_block_x = {"top": 0.0, "dock": 0.0}  # x donde se dibujan las ventanas (token w:)
# Grilla regular vigente por barra (n/pitch/side/margin) y tramo del DockApp de
# ventanas: celdas libres contiguas (span), rect en pantalla, y scroll horizontal.
var bar_grid_state = {"top": null, "dock": null}
var window_span = {"top": 0, "dock": 0}
var window_region = {"top": Rect2(), "dock": Rect2()}
var window_scroll = {"top": 0.0, "dock": 0.0}
var win_scroll_press = false
var win_scroll_from = 0.0
var win_scroll_start = 0.0
var _win_pick = null
var _win_close = null
var _win_min = null
var win_dock_press = false   # pulsado el bloque-clip de ventanas (aún sin arrastrar)
var win_dock_drag = false    # arrastrando el DockApp de ventanas (recolocar slot)
var win_dock_from = Vector2.ZERO
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
var suppress_pinned_click = ""
# Explosiones (drop en el centro del escritorio): bloques que se quitan con una
# animación breve, como el WindowMaker clásico. Cada una: {pos, size, since, tex}.
var explosions = []
# Animación de las barras (reacomodo al arrastrar): id -> {from, to, x, since}.
# Mismo lenguaje de ease-out que el reacomodo del anillo (ver shell._ease_out).
var bar_anim = {}
var applet_grab = Vector2.ZERO
# K10b: DockApp "Compartiendo" (sesiones activas), token SHARED_TOKEN del orden de
# barra. El estado sale de snapshots cacheados (host_session_state y servicios),
# nunca de procesos. `shared_diagram` es el snapshot del frame; `shared_pref` recuerda
# dónde estaba (zona/celda) al terminar la relación para volver ahí.
var shared_diagram = {}
var shared_pref = {}
var shared_drag = false
var shared_from = Vector2.ZERO
var shared_grab = Vector2.ZERO
var shared_layout = []
var shared_drawn = false
var shared_menu_id = ""
var shared_menu_want = ""
var shared_menu_open = false
var shared_menu_block = null
var shared_press = ""
func _ready():
	_load_applets()
	# Host (autoload), no shell.compositor: el onready del padre aún no corrió.
	if Host.compositor != null:
		clipboard.wayland_display = Host.compositor.start()


# Los applets consultan en workers; al salir del árbol no deben quedar hilos vivos.
func _exit_tree():
	for m in applet_mods.values():
		m.stop()
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


# --- Orden unificado de bloques de barra (pines + applets) -----------------------
# Token: "p:<app-id>" (pin) o "a:<applet-id>" (applet). El orden vive en
# `bar_order[zone]`; `pinned_top`/`pinned_dock` se derivan con `_sync_pins()`.

func _tok_pin(id):
	return "p:" + String(id)


func _tok_applet(id):
	return "a:" + String(id)


func _tok_kind(t):
	return String(t).substr(0, 1)


func _tok_id(t):
	return String(t).substr(2)


func _maybe_order_token(tok):
	if typeof(tok) != TYPE_STRING:
		return false
	if tok == "":
		return true  # slot vacío (hueco persistido entre bloques)
	if String(tok).length() < 3 or String(tok)[1] != ":":
		return false
	var kind = _tok_kind(tok)
	if kind == "p":
		return _tok_id(tok) != ""
	if kind == "w":
		return _tok_id(tok) == "windows"
	if kind == "s":
		return _tok_id(tok) == "sharing"
	return kind == "a" and _applet_known(_tok_id(tok))


# Rehace `pinned_top`/`pinned_dock` a partir de `bar_order`.
func _sync_pins():
	pinned_top = []
	pinned_dock = []
	for zone in ["top", "dock"]:
		for tok in bar_order[zone]:
			if _tok_kind(tok) == "p":
				if zone == "top":
					pinned_top.append(_tok_id(tok))
				else:
					pinned_dock.append(_tok_id(tok))


func _order_remove(tok):
	# La celda que deja queda VACÍA: los bloques de su derecha no se mueven.
	for zone in ["top", "dock"]:
		if bar_order[zone].has(tok):
			var span = _token_cells(tok, bar_layout.get(zone, []), bar_cell.get(zone, 0.0))
			bar_order[zone] = seq_vacate(bar_order[zone], tok, span)


func _order_insert(zone, tok, index):
	bar_order[zone] = seq_place(bar_order[zone], tok, index)


# Coloca `tok` (con `span` celdas, o el declarado si span<0) en la celda libre más
# cercana a `target` dentro del tope útil de la barra. `target`<0 = al final del
# orden. NO mueve otros bloques; si no hay lugar, no toca nada y devuelve false.
func _place_token_cell(zone, tok, target, span = -1):
	if span < 0:
		span = token_span(tok)
	span = max(1, int(span))
	var g = _grid_for(zone)
	var max_cells = int(g.n) - 1 - bar_fixed_cells(zone)
	# Snapshot: si no hay lugar, se restaura todo tal cual estaba (una barra llena no
	# se lleva puesto el bloque que se intentaba mover).
	var saved = {"top": bar_order["top"].duplicate(), "dock": bar_order["dock"].duplicate()}
	# Un token vive una sola vez: si ya estaba (en esta barra o en la otra), su
	# celda vieja queda vacía y los demás no se mueven.
	_order_remove(tok)
	var spans = {}
	for t in bar_order[zone]:
		if t != "":
			spans[t] = token_span(t)
	var cells = seq_to_cells(bar_order[zone], spans)
	var tgt = int(target)
	if tgt < 0:
		tgt = cells.size()
	var placed = place_cells(cells, tok, tgt, span, max_cells)
	if placed == null:
		bar_order = saved
		return false
	bar_order[zone] = cells_to_seq(placed)
	_sync_pins()
	applets_dirty = true
	_save_applets()
	var cell = bar_cell.get(zone, 0.0)
	var origin = bar_origin.get(zone, 0.0)
	if cell <= 0.0:
		cell = float(g.pitch)
	if origin <= 0.0:
		origin = bar_base_origin(zone, g)
	_bar_set(tok, slot_x(origin, placed.find(tok), cell))
	shell.request_redraw()
	return true


# Primera celda donde cabe un bloque nuevo de `span` celdas: justo después del último
# bloque ocupado. Si ese último es el tramo de ventanas (`strip_tok`), que se estira
# sobre las celdas libres a su derecha, va al extremo de la barra para no recortarlo.
# Si no entra ahí, la primera celda libre de la barra. -1 = barra llena. Pura.
static func next_free_slot(cells, span, max_cells, strip_tok = ""):
	span = max(1, int(span))
	var last = -1
	for i in range(cells.size()):
		if String(cells[i]) != "":
			last = i
	var start = last + 1
	if last >= 0 and strip_tok != "" and String(cells[last]) == strip_tok:
		start = int(max_cells) - span
	if start >= 0 and nearest_free(cells, start, span, max_cells) == start:
		return start
	return nearest_free(cells, 0, span, max_cells)


func _next_free_slot(zone, span):
	var max_cells = int(_grid_for(zone).n) - 1 - bar_fixed_cells(zone)
	var spans = {}
	for t in bar_order[zone]:
		if t != "":
			spans[t] = token_span(t)
	return next_free_slot(seq_to_cells(bar_order[zone], spans), span, max_cells, WINDOW_TOKEN)


# ÚNICO camino de alta de un bloque nuevo (applet agregado, DockApp condicional):
# celda `cell` de `zone` si se pide (y está libre), si no `_next_free_slot`; probando
# `zone`, luego la barra superior, luego el dock. false = no hubo lugar en ninguna.
func _place_new_token(tok, span = -1, zone = "", cell = -1):
	if span < 0:
		span = token_span(tok)
	var zones = [zone] if zone != "" else []
	for z in ["top", "dock"]:
		if not zones.has(z):
			zones.append(z)
	for z in zones:
		var target = int(cell) if z == zone and int(cell) >= 0 else _next_free_slot(z, span)
		if target >= 0 and _place_token_cell(z, tok, target, span):
			return true
	return false


# Mantiene SHARED_TOKEN en el orden sólo mientras haya relación activa. Al aparecer
# vuelve donde estaba (`shared_pref`) o, la primera vez, a la barra superior; al
# terminar se retira (como un pin que se estalla: su celda queda libre, sin hueco
# fantasma) recordando su lugar.
func _sync_shared_token():
	shared_diagram = _shared_snapshot()
	var zone = ""
	for z in ["top", "dock"]:
		if bar_order[z].has(SHARED_TOKEN):
			zone = z
	if shared_diagram.empty():
		shared_menu_id = ""
		shared_drag = false
		shared_press = ""
		if zone != "":
			var spans = {}
			for t in bar_order[zone]:
				if t != "":
					spans[t] = token_span(t)
			shared_pref = {"zone": zone, "cell": seq_to_cells(bar_order[zone], spans).find(SHARED_TOKEN)}
			_order_remove(SHARED_TOKEN)
			applets_dirty = true
			_save_applets()
			shell.request_redraw()
	elif zone == "":
		_place_new_token(SHARED_TOKEN, 1, String(shared_pref.get("zone", "top")), int(shared_pref.get("cell", -1)))


# Igual que `_place_token_cell`, con la x de pantalla del drop.
func _place_token(zone, tok, x, span = -1):
	var g = _grid_for(zone)
	var cell = bar_cell.get(zone, 0.0)
	var origin = bar_origin.get(zone, 0.0)
	if cell <= 0.0:
		cell = float(g.pitch)
	if origin <= 0.0:
		origin = bar_base_origin(zone, g)
	return _place_token_cell(zone, tok, cell_from_x(x, origin, cell), span)


# --- Slots fijos (puros, ver tests/frame_slots_test.gd) ---------------------------
# Saca `tok` dejando `span` celdas vacías en su lugar (nadie se corre). Los huecos
# finales sobran: se recortan.
static func seq_vacate(seq, tok, span = 1):
	var out = []
	for t in seq:
		if t == tok:
			for _i in range(max(1, span)):
				out.append("")
		else:
			out.append(t)
	while out.size() > 0 and out[out.size() - 1] == "":
		out.remove(out.size() - 1)
	return out


# Pone `tok` en el índice `index`. Hueco => lo ocupa sin tocar a nadie. Ocupado =>
# sólo el grupo de bloques contiguos desde `index` se corre UN lugar a la derecha,
# consumiendo el primer hueco que encuentre (los que están más allá no se mueven).
static func seq_place(seq, tok, index):
	var out = seq.duplicate()
	index = int(max(0, index))
	while out.size() < index:
		out.append("")
	if index < out.size() and out[index] == "":
		out[index] = tok
		return out
	var hole = -1
	for j in range(index, out.size()):
		if out[j] == "":
			hole = j
			break
	if hole >= 0:
		out.remove(hole)
	out.insert(min(index, out.size()), tok)
	return out


# --- Celdas de ocupación (puros, ver tests/frame_slots_test.gd) --------------------
# Convierte una secuencia de tokens (con huecos "") a celdas: cada token escribe su
# string en TODAS las celdas de su span; "" es una celda libre. `spans` es un dict
# token -> celdas (>=1); lo que no figure vale 1.
static func seq_to_cells(seq, spans):
	var cells = []
	for tok in seq:
		var t = String(tok)
		var sp = 1
		if t != "" and typeof(spans) == TYPE_DICTIONARY and spans.has(t):
			sp = max(1, int(spans[t]))
		for _i in range(sp):
			cells.append(t)
	return cells


# Inversa de `seq_to_cells`: colapsa las celdas contiguas de un mismo token en un
# token (su span) y deja una "" por celda libre. Conserva huecos intermedios y finales.
static func cells_to_seq(cells):
	var seq = []
	for c in cells:
		var t = String(c)
		if t != "" and seq.size() > 0 and seq[seq.size() - 1] == t:
			continue
		seq.append(t)
	return seq


# Primera celda de un tramo de `span` celdas contiguas libres más cercano a `target`,
# dentro de [0, max_cells - span]. Empate de distancia -> el de la DERECHA. -1 si no
# hay ningún tramo libre (barra llena). Las celdas fuera del arreglo cuentan como libres.
static func nearest_free(cells, target, span, max_cells):
	span = max(1, int(span))
	max_cells = max(0, int(max_cells))
	var last = max_cells - span
	if last < 0:
		return -1
	target = int(clamp(int(target), 0, last))
	for d in range(max_cells + 1):
		for s in [target + d, target - d]:
			if s < 0 or s > last:
				continue
			var ok = true
			for i in range(span):
				var idx = s + i
				if idx < cells.size() and String(cells[idx]) != "":
					ok = false
					break
			if ok:
				return s
	return -1


# Saca `tok` de las celdas (si estaba), lo coloca en el tramo libre de `span` celdas
# más cercano a `target` y devuelve las celdas resultantes. Los demás tokens NO se
# mueven. `null` si no hay lugar (barra llena): el llamador deja todo como estaba.
static func place_cells(cells, tok, target, span, max_cells):
	var out = []
	for c in cells:
		out.append("" if String(c) == String(tok) else String(c))
	var start = nearest_free(out, target, span, max_cells)
	if start < 0:
		return null
	while out.size() < start + span:
		out.append("")
	for i in range(span):
		out[start + i] = String(tok)
	return out


# Celdas que ocupa un token según su tipo, sin depender del layout: un hueco y el
# DockApp de ventanas valen 1; un applet, su `span` declarado. Pura y testeable.
static func token_span(tok):
	if typeof(tok) != TYPE_STRING:
		return 1
	var t = String(tok)
	if t.begins_with("a:"):
		var id = t.substr(2)
		for a in APPLETS:
			if a.id == id:
				return max(1, int(a.get("span", 1)))
	return 1


# Ids de todos los pines fijados (los lee el Anillo de Inicio).
func pinned_ids():
	var out = []
	for zone in ["top", "dock"]:
		for tok in bar_order[zone]:
			if _tok_kind(tok) == "p":
				out.append(_tok_id(tok))
	return out


# Carga sólo el orden visible; ids desconocidos se guardan aparte e intactos.
func _load_applets():
	applets_visible = APPLET_DEFAULT.duplicate()
	applets_future = []
	applets_raw = {}
	applets_saved_bottom = APPLET_DEFAULT.duplicate()
	bar_order = {"top": [], "dock": []}
	var legacy_pins = {"top": [], "dock": []}
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
					for id in ids:
						if typeof(id) == TYPE_STRING and not legacy_pins[zone].has(id):
							legacy_pins[zone].append(id)
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
	# Orden unificado: se prefiere "order" si está; si no, se migra de los arrays
	# legacy (pines por zona + applets en la barra inferior).
	var have_order = false
	var order = applets_raw.get("order", null)
	if typeof(order) == TYPE_DICTIONARY:
		for zone in ["top", "dock"]:
			var toks = order.get(zone, [])
			if typeof(toks) == TYPE_ARRAY and not toks.empty():
				have_order = true
				for tok in toks:
					if _maybe_order_token(tok):
						bar_order[zone].append(String(tok))
					elif typeof(tok) == TYPE_STRING and String(tok) == "":
						# Slot vacío persistido: conserva la posición/hueco elegidos.
						bar_order[zone].append("")
	if not have_order:
		for id in legacy_pins["top"]:
			bar_order["top"].append(_tok_pin(id))
		for id in legacy_pins["dock"]:
			bar_order["dock"].append(_tok_pin(id))
		for id in applets_visible:
			bar_order["dock"].append(_tok_applet(id))
	# Sanidad: sin duplicados; se reponen pines/applets visibles que falten y se
	# descartan applets ocultos que hayan quedado en el orden.
	var present = {}
	for zone in ["top", "dock"]:
		var seen = {}
		var clean = []
		for tok in bar_order[zone]:
			if tok != "" and seen.has(tok):
				continue
			seen[tok] = true
			clean.append(tok)
		bar_order[zone] = clean
		for tok in clean:
			present[tok] = true
	for zone in ["top", "dock"]:
		for id in legacy_pins[zone]:
			var tok = _tok_pin(id)
			if not present.has(tok):
				bar_order[zone].append(tok)
				present[tok] = true
	for id in applets_visible:
		var tok = _tok_applet(id)
		if not present.has(tok):
			bar_order["dock"].append(tok)
			present[tok] = true
	for zone in ["top", "dock"]:
		var kept = []
		for tok in bar_order[zone]:
			if _tok_kind(tok) == "a" and not applets_visible.has(_tok_id(tok)):
				continue
			kept.append(tok)
		bar_order[zone] = kept
	# El DockApp de ventanas existe exactamente una vez, en la barra que el usuario
	# eligió (cualquier celda). Si el archivo previo no lo traía, va al final de la
	# barra superior. Sus teselas se dibujan en la barra donde esté el token.
	var have_window = bar_order["top"].has(WINDOW_TOKEN) or bar_order["dock"].has(WINDOW_TOKEN)
	if not have_window:
		bar_order["top"].append(WINDOW_TOKEN)
	else:
		var kept_window = false
		for zone in ["top", "dock"]:
			var kept = []
			for tok in bar_order[zone]:
				if tok == WINDOW_TOKEN:
					if kept_window:
						continue
					kept_window = true
				kept.append(tok)
			bar_order[zone] = kept
	# Normaliza a celdas sin superposición: datos viejos fuera de rango se reubican en
	# la celda libre más cercana (o se descartan si no caben).
	for zone in ["top", "dock"]:
		_normalize_order(zone)
	bar_order_saved = {"top": bar_order["top"].duplicate(), "dock": bar_order["dock"].duplicate()}
	_sync_pins()
	pinned_saved_top = pinned_top.duplicate()
	pinned_saved_dock = pinned_dock.duplicate()
	# K13a: la clave "window_mode" de versiones anteriores se ignora.
	applets_dirty = false


# Normaliza el orden de una barra a celdas sin superposición: cada token se reubica
# en la celda libre más cercana a su posición natural (o se descarta si no cabe en el
# tope útil). Idempotente sobre datos ya sanos. `bar_grid_state` sin grilla => sin tope.
func _normalize_order(zone):
	var g = bar_grid_state.get(zone, null)
	var max_cells = 1000000
	if g != null and int(g.get("n", 0)) > 0:
		max_cells = int(g.n) - 1 - bar_fixed_cells(zone)
	var spans = {}
	for t in bar_order[zone]:
		if t != "":
			spans[t] = token_span(t)
	var cells = seq_to_cells(bar_order[zone], spans)
	var out = []
	for c in cells:
		var t = String(c)
		if t == "":
			out.append("")
			continue
		if out.size() > 0 and String(out[out.size() - 1]) == t:
			continue  # continuación del span ya colocado
		var span = int(spans.get(t, 1))
		var placed = nearest_free(out, out.size(), span, max_cells)
		if placed < 0:
			continue
		while out.size() < placed + span:
			out.append("")
		for i in range(span):
			out[placed + i] = t
	bar_order[zone] = cells_to_seq(out)


func _same_list(a, b):
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true


# Escritura atómica y sólo si el orden visible (con ids futuros) cambió. Escribe el
# orden unificado y, además, los arrays legacy para poder volver a una versión previa.
func _save_applets():
	var bottom = applets_visible.duplicate()
	for id in applets_future:
		bottom.append(id)
	var pins_changed = not (_same_list(pinned_top, pinned_saved_top) and _same_list(pinned_dock, pinned_saved_dock))
	var order_changed = not (_same_list(bar_order["top"], bar_order_saved["top"]) and _same_list(bar_order["dock"], bar_order_saved["dock"]))
	if _same_list(bottom, applets_saved_bottom) and not pins_changed and not order_changed \
			and pin_top_bar == pin_saved_top and pin_bottom_bar == pin_saved_bottom:
		applets_dirty = false
		return
	var path = _applets_path()
	var dir = Directory.new()
	dir.make_dir_recursive(path.get_base_dir())
	applets_raw["order"] = {"top": bar_order["top"], "dock": bar_order["dock"]}
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
	bar_order_saved = {"top": bar_order["top"].duplicate(), "dock": bar_order["dock"].duplicate()}
	pinned_saved_top = pinned_top.duplicate()
	pinned_saved_dock = pinned_dock.duplicate()
	pin_saved_top = pin_top_bar
	pin_saved_bottom = pin_bottom_bar
	applets_dirty = false


func _applet_set_visible(id, v):
	if v:
		if not applets_visible.has(id):
			# Primero se intenta colocar (primera celda libre, ver `_next_free_slot`); sólo si
			# entra se marca visible. Barra llena: no se añade y el estado no cambia.
			if not _place_new_token(_tok_applet(id), _applet_span(id), "dock"):
				return
			applets_visible.append(id)
			if applet_mods.has(id):
				applet_mods[id].refresh(true)
			applets_dirty = true
			_save_applets()
			shell.request_redraw()
	elif applets_visible.has(id):
		applets_visible.erase(id)
		_order_remove(_tok_applet(id))
		applets_dirty = true
		_save_applets()
		shell.request_redraw()


# Ctrl+←/→: mueve el applet un lugar en el orden unificado de su barra.
func _applet_move(id, dir):
	var tok = _tok_applet(id)
	for zone in ["top", "dock"]:
		var seq = bar_order[zone]
		var i = seq.find(tok)
		if i < 0:
			continue
		var j = i + dir
		if j < 0 or j >= seq.size():
			return
		seq.remove(i)
		seq.insert(j, tok)
		applets_dirty = true
		_save_applets()
		shell.request_redraw()
		return


func _pinned_app(id):
	if not shell.apps.scanned:
		shell.apps.scan()
	for app in shell.apps.apps:
		if app.id == id:
			return app
	return null


# Fija/mueve un pin a la barra `zone`: va a la celda libre más cercana a x.
func _place_pin(app, zone, x):
	var tok = _tok_pin(app.id)
	if not _place_token(zone, tok, x):
		shell.request_redraw()


func _pin_in_order(id):
	return bar_order["top"].has(_tok_pin(id)) or bar_order["dock"].has(_tok_pin(id))


# --- Grilla pura de slots de barra ----------------------------------------------
# Cada barra es una grilla de celdas fijas de ancho `cell`, contadas desde `origin`
# (el borde izquierdo de la primera celda). El índice de slot NO depende de cuántos
# bloques haya ni de sus anchos: soltar en la celda N deja el bloque en la celda N,
# con celdas vacías (`""`) a su izquierda. Ver tests/frame_slots_test.gd.
static func cell_from_x(x, origin, cell):
	if cell <= 0.0:
		return 0
	return int(max(0.0, floor((x - origin) / cell)))


# x del borde izquierdo de la celda `index`.
static func slot_x(origin, index, cell):
	return origin + float(index) * cell


# --- Grilla regular del ancho de pantalla ----------------------------------------
# Divide el ancho en `n` celdas de paso entero `pitch`; el bloque cuadrado mide
# `side = pitch - pad`. Los pocos píxeles sobrantes (< n) van a un margen simétrico,
# así la última celda queda alineada con el borde derecho. `target_side` es el lado
# deseado (shell.frame_bar_h: ya depende del DPI/escala). Pura: tests/frame_grid_test.
static func bar_grid(vp_w, target_side, pad):
	var w = max(1.0, float(vp_w))
	var span = max(1.0, float(target_side) + float(pad))
	var n = int(max(MIN_CELLS, round(w / span)))
	# Resto par: repartir el sobrante mitad y mitad sin dejar 1 px sin asignar. Se
	# prefiere subir una celda (bloques algo menores, sin desbordar el alto de barra).
	for d in [0, 1, -1, 2, -2]:
		var c = n + d
		if c >= MIN_CELLS and int(w) % c % 2 == 0:
			n = c
			break
	var pitch = int(max(1.0, floor(w / float(n))))
	var side = max(1.0, float(pitch) - float(pad))
	var margin = int(floor((w - float(n) * float(pitch)) * 0.5))
	return {"n": n, "pitch": pitch, "side": side, "margin": margin}


# Celdas fijas antes del contenido de una barra: la superior reserva 4 (esquina,
# Vecindario, Grupo, Hogar); la inferior, 1 (esquina). La última celda es el pin.
static func bar_fixed_cells(zone):
	return 4 if zone == "top" else 1


# x de la celda 0 del contenido (tras las celdas fijas) para la grilla dada.
static func bar_base_origin(zone, grid):
	return float(grid.margin) + float(bar_fixed_cells(zone)) * float(grid.pitch)


# Plan del DockApp de ventanas dentro de su tramo de `free_cells` celdas libres:
# normal (una tesela por celda), mini (hasta 4 por celda, mitad de tamaño) o scroll
# (mismas mini con desplazamiento). La ventana enfocada siempre queda visible.
# Pura: tests/frame_grid_test.gd.
static func window_plan(n, free_cells, focused_index, scroll):
	var F = int(max(1, free_cells))
	var cap = 4 * F
	var mode = "normal"
	var per_cell = 1
	if n > F:
		mode = "mini"
		per_cell = 4
	if n > cap:
		mode = "scroll"
		per_cell = 4
	var scroll_max = int(max(0, n - cap))
	var sc = int(clamp(scroll, 0, scroll_max))
	if mode == "scroll" and focused_index >= 0:
		if focused_index < sc:
			sc = focused_index
		elif focused_index >= sc + cap:
			sc = focused_index - cap + 1
		sc = int(clamp(sc, 0, scroll_max))
	var start = sc
	var end = int(min(n, sc + cap))
	return {"mode": mode, "per_cell": per_cell, "visible_range": [start, end], "scroll_max": scroll_max}


# --- Tira de ventanas: destino del drop por escritorio/unidad ------------------
# Zona de borde (px) centrada en el canto entre dos teselas: dentro de ella el drop
# es "entre" dos escritorios (nuevo escritorio) o, si comparten unidad, sobre la más
# cercana. Las teselas del strip son las ventanas agrupadas por escritorio/unidad.
const STRIP_GAP_HIT = 14.0


# Escritorios (unidades) presentes en la tira, en orden y sin repetir consecutivos.
static func strip_groups(tile_units):
	var out = []
	var prev = null
	for i in range(tile_units.size()):
		if i == 0 or tile_units[i] != prev:
			out.append(tile_units[i])
		prev = tile_units[i]
	return out


# Cantidad de grupos (escritorios) entre las teselas 0..upto-1.
static func strip_groups_before(tile_units, upto):
	var g = 0
	for i in range(int(min(int(upto), tile_units.size()))):
		if i == 0 or tile_units[i] != tile_units[i - 1]:
			g += 1
	return g


# Escritorio (unidad) que debe quedar a la DERECHA del nuevo escritorio insertado en
# el índice de grupo `index`, o null si va al final. `index` va de 0 (antes del primer
# grupo) a strip_groups(...).size() (después del último).
static func strip_unit_at(tile_units, index):
	var g = -1
	var prev = null
	for i in range(tile_units.size()):
		if i == 0 or tile_units[i] != prev:
			g += 1
		prev = tile_units[i]
		if g == index:
			return tile_units[i]
	return null


# Destino del drop de una tesela de ventana dentro del strip del Frame. `tiles_rects`
# son los rects de las teselas (izq->der) y `tile_units[i]` el escritorio/unidad de
# cada una. Devuelve:
#   {"kind":"new", "index":k, "x":bar_x}  -> nuevo escritorio en esa posición
#   {"kind":"onto", "tile":i, "side":"left"|"right"} -> al escritorio de la tesela i
#   null si no hay teselas.
static func strip_drop_target(tiles_rects, tile_units, x):
	var n = tiles_rects.size()
	if n <= 0:
		return null
	var first = tiles_rects[0]
	var last = tiles_rects[n - 1]
	if x < first.position.x:
		return {"kind": "new", "index": 0, "x": first.position.x}
	if x > last.position.x + last.size.x:
		return {"kind": "new", "index": strip_groups_before(tile_units, n),
			"x": last.position.x + last.size.x}
	var half_hit = STRIP_GAP_HIT * 0.5
	for i in range(n - 1):
		var a = tiles_rects[i]
		var b = tiles_rects[i + 1]
		var edge = (a.position.x + a.size.x + b.position.x) * 0.5
		if abs(x - edge) > half_hit:
			continue
		if tile_units[i] != tile_units[i + 1]:
			return {"kind": "new", "index": strip_groups_before(tile_units, i + 1), "x": edge}
		var ca = a.position.x + a.size.x * 0.5
		var cb = b.position.x + b.size.x * 0.5
		if abs(x - ca) <= abs(x - cb):
			return {"kind": "onto", "tile": i, "side": "right"}
		return {"kind": "onto", "tile": i + 1, "side": "left"}
	for i in range(n):
		var r = tiles_rects[i]
		if x >= r.position.x and x <= r.position.x + r.size.x:
			var side = "left" if x < r.position.x + r.size.x * 0.5 else "right"
			return {"kind": "onto", "tile": i, "side": side}
	return null


# Celdas que ocupa un token en el dibujo de referencia (`layout`): un hueco ocupa
# una; un bloque ancho (DockApp de ventanas, applet con span) ocupa tantas como su
# ancho real. Sin dato en el layout vale una celda.
func _token_cells(tok, layout, cell):
	# Un hueco y el DockApp de ventanas valen UNA celda: el tramo de ventanas se
	# dibuja encima de los huecos siguientes sin consumirlos (si no, los bloques de
	# su derecha se corrían según cuántas ventanas/huecos hubiera).
	if tok == "" or tok == WINDOW_TOKEN:
		return 1
	for it in layout:
		if it.tok == tok:
			if cell > 0.0:
				return max(1, int(round(float(it.w) / cell)))
			break
	return 1


# Índice de secuencia en `bar_order[zone]` para soltar en la celda que contiene `x`.
# `layout` es el dibujo de referencia (el actual, o el previo durante el preview).
# `skip_tok` es el token arrastrado: no cuenta ni ocupa celdas (se reinserta).
func _slot_index(zone, x, skip_tok, layout):
	var cell = bar_cell.get(zone, 0.0)
	var origin = bar_origin.get(zone, 0.0)
	if cell <= 0.0:
		# La barra aún no se dibujó (autohide y drop antes de revelarla): reconstruir
		# la grilla desde la geometría para no colapsar todo al slot 0 (izquierda).
		var g = _grid_for(zone)
		cell = float(g.pitch)
		origin = bar_base_origin(zone, g)
	if cell <= 0.0:
		return 0
	var target = cell_from_x(x, origin, cell)
	var cells = 0
	var index = 0
	# El arrastrado deja su celda vacía (igual que al soltar): no corre a nadie.
	var seq = bar_order.get(zone, [])
	if skip_tok != "" and seq.has(skip_tok):
		seq = seq_vacate(seq, skip_tok, _token_cells(skip_tok, layout, cell))
	for tok in seq:
		var span = _token_cells(tok, layout, cell)
		if cells + span > target:
			return index
		cells += span
		index += 1
	# Más allá del último bloque: se abren huecos hasta la celda elegida.
	return index + (target - cells)


# Grilla vigente de una barra: la del último dibujo; si no, reconstruida desde el
# viewport. Nunca nil (fallback mínimo) para no romper cálculo de slots en tests.
func _grid_for(zone):
	var g = bar_grid_state.get(zone, null)
	if g != null and int(g.get("n", 0)) > 0:
		return g
	if get_viewport() != null and shell != null and shell.has_method("frame_bar_h"):
		return bar_grid(get_viewport().size.x, shell.frame_bar_h(get_viewport().size), PAD)
	return {"n": MIN_CELLS, "pitch": 1, "side": 1.0, "margin": 0}


# Índice de inserción en la barra para el drop real (orden actual).
func _zone_slot(zone, x, skip_tok = ""):
	return _slot_index(zone, x, skip_tok, bar_layout.get(zone, []))


# Token que se está arrastrando (pin, applet o DockApp de ventanas), o "".
func _drag_token():
	if app_drag != null:
		return _tok_pin(app_drag.id)
	if applet_drag != null:
		return _tok_applet(applet_drag)
	if win_dock_drag:
		return WINDOW_TOKEN
	if shared_drag:
		return SHARED_TOKEN
	return ""


func _pinned_hit(pos):
	for zone in ["top", "dock"]:
		for it in bar_layout.get(zone, []):
			if it.kind == "p" and it.rect.has_point(pos):
				var app = _pinned_app(it.id)
				if app != null:
					return {"app": app, "rect": it.rect, "zone": zone}
	return null


# Bloque del DockApp de ventanas bajo el punto (sólo cuando NO hay ventanas: con
# ventanas, el área la cubren sus teselas y se arrastran individualmente).
func _window_dock_hit(pos):
	for zone in ["top", "dock"]:
		for it in bar_layout.get(zone, []):
			if it.kind == "w" and it.rect.has_point(pos):
				return it
	return null


# Rect en pantalla del bloque (para anclar la explosión). Fallback: bajo el cursor.
func _block_rect(kind, id):
	for zone in ["top", "dock"]:
		for it in bar_layout.get(zone, []):
			if it.kind == kind and it.id == id:
				return it.rect
	var s = _vh()
	return Rect2(mouse_pos - Vector2(s, s) * 0.5, Vector2(s, s))


# ¿La app está abierta (actividad viva)? Un pin de una app activa no se estalla:
# vuelve a su lugar, para no matar una ventana por error.
func _app_active(app):
	if app == null:
		return false
	var i = shell._activity_named(String(app.name))
	if i >= 0 and shell._activity_state(shell.ACTIVITIES[i]) != "closed":
		return true
	var want = String(app.name).to_lower()
	if want == "":
		return false
	for it in running():
		if String(it.name).to_lower() == want:
			return true
	return false


# Quita un bloque del Frame con la animación de estallido (drop en el centro).
func _explode_block(kind, id):
	var rect = _block_rect(kind, id)
	var tex = null
	if kind == "p":
		var app = _pinned_app(id)
		if app != null:
			tex = shell._activity_icon_of(app)
		_order_remove(_tok_pin(id))
		_sync_pins()
	else:
		_order_remove(_tok_applet(id))
		applets_visible.erase(id)
	explosions.append({"pos": rect.position, "size": rect.size, "since": OS.get_ticks_msec(), "tex": tex})
	applets_dirty = true
	_save_applets()
	shell.request_redraw()


# Inserta `dragged` en `slot` de la lista sin él. Si no estaba, sólo se inserta.
func _order_with_gap(ids, dragged, slot):
	var rest = []
	for i in ids:
		if i != dragged:
			rest.append(i)
	slot = int(clamp(slot, 0, rest.size()))
	rest.insert(slot, dragged)
	return rest


# Igual que `_order_with_gap` pero respeta huecos: un `slot` más allá del final deja
# slots vacíos (`""`) intermedios. El preview de arrastre usa esto para coincidir con
# el drop (que también puede abrir huecos, ver `_order_insert`).
func _order_with_slots(ids, dragged, slot, span = 1):
	return seq_place(seq_vacate(ids, dragged, span), dragged, slot)


# Orden con el token arrastrado (preview) colocado en la celda libre más cercana a la
# x del puntero. Usa la MISMA regla que el drop real (`_place_token`), así el hueco
# del preview coincide exactamente con dónde caerá el bloque.
func _seq_with_drag(zone, drag_tok, mouse_x, grid, prev, x0):
	var cell = float(grid.pitch)
	var max_cells = int(grid.n) - 1 - bar_fixed_cells(zone)
	var target = cell_from_x(mouse_x, x0, cell)
	var span = token_span(drag_tok)
	var spans = {}
	for t in bar_order[zone]:
		if t != "":
			spans[t] = token_span(t)
	var cells = seq_to_cells(bar_order[zone], spans)
	var placed = place_cells(cells, drag_tok, target, span, max_cells)
	if placed == null:
		return bar_order[zone].duplicate()
	return cells_to_seq(placed)


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


# Dibuja los bloques de una barra en orden unificado (pines y applets), con preview
# de arrastre. `grid` es la grilla regular (misma para las dos barras). Devuelve la x
# local posterior al último bloque y llena `bar_layout`.
func _draw_bar_blocks(ui, zone, x0, y, grid, mouse):
	var now = OS.get_ticks_msec()
	var prev = bar_layout.get(zone, [])
	bar_layout[zone] = []
	# La grilla de la barra se fija ANTES del preview: origen (celda 0) y ancho de
	# celda no dependen de los bloques dibujados.
	var cell = float(grid.pitch)
	var side = float(grid.side)
	var fixed = bar_fixed_cells(zone)
	bar_cell[zone] = cell
	bar_origin[zone] = x0
	bar_side[zone] = side
	bar_grid_state[zone] = grid
	var drag_tok = _drag_token()
	var seq = bar_order[zone].duplicate()
	if drag_tok != "" and _zone_at(mouse) == zone:
		# Preview: el bloque va a la MISMA celda libre más cercana que el drop real
		# (nadie se corre y nunca se superpone), con la misma grilla.
		seq = _seq_with_drag(zone, drag_tok, mouse.x, grid, prev, x0)
	var cell_i = 0
	var win_items = running()
	# Celdas de contenido útiles (deja libre la celda del pin a la derecha).
	var max_cells = max(0, int(grid.n) - 1 - fixed)
	window_span[zone] = 0
	var strip_end = 0   # última celda cubierta por el tramo de ventanas (para `return`)
	for ti in range(seq.size()):
		# Cada token arranca en su celda de la grilla (`slot_x`); un bloque ancho
		# avanza tantas celdas como ocupa, así los huecos a su izquierda persisten.
		# Lo que no entra en la barra no se dibuja: nunca dos bloques en una celda.
		if cell_i >= max_cells:
			break
		var x = slot_x(x0, cell_i, cell)
		var tok = seq[ti]
		if tok == "":
			# Slot vacío persistido: reserva el ancho de una celda y sigue.
			bar_layout[zone].append({"kind": "g", "id": "", "tok": "",
				"x": x, "y": y, "w": side, "h": side, "rect": Rect2(x, y, side, side)})
			cell_i += 1
			continue
		var kind = _tok_kind(tok)
		var id = _tok_id(tok)
		if kind == "w" and tok == drag_tok:
			# Arrastrando el DockApp: reserva UN bloque en el destino (no el tramo).
			ui.set_cursor_pos(Vector2(x, y))
			var dgap = ui.get_cursor_screen_pos()
			ui.imgui_draw_rect_filled(Rect2(dgap, Vector2(side, side)), Color(1, 1, 1, 0.06), 0.0)
			ui.imgui_draw_rect_filled(Rect2(dgap + Vector2(0.0, side - 3.0), Vector2(side, 3.0)), NX_SEL, 0.0)
			cell_i += 1
			continue
		if kind == "w":
			# Tramo del DockApp de ventanas: celdas libres contiguas desde su celda
			# hasta el próximo bloque ocupado o el borde. No depende de cuántas
			# ventanas haya: los bloques a su derecha NUNCA se mueven al abrir/cerrar.
			var gaps = 0
			var k = ti + 1
			while k < seq.size() and seq[k] == "":
				gaps += 1
				k += 1
			var cap = max_cells - cell_i
			var F = cap if k >= seq.size() else min(1 + gaps, cap)
			F = int(max(1, F))
			var w = float(F) * cell - PAD
			window_block_x[zone] = x
			var scr = Vector2(x, y)
			if win_items.empty():
				scr = _draw_window_dock_empty(ui, Vector2(x, y), side, mouse).rect.position
			else:
				ui.set_cursor_pos(Vector2(x, y))
				scr = ui.get_cursor_screen_pos()
			var region = Rect2(scr, Vector2(w, side))
			window_span[zone] = F
			window_region[zone] = region
			bar_layout[zone].append({"kind": "w", "id": id, "tok": tok,
				"x": scr.x, "y": scr.y, "w": w, "h": side, "rect": region})
			# Ocupa su celda; las siguientes siguen siendo huecos (se dibujan debajo).
			strip_end = cell_i + F
			cell_i += 1
			continue
		var w = side if kind == "p" or kind == "s" else _applet_width(id, side)
		var span = max(1, int(round(w / cell))) if cell > 0.0 else 1
		if cell_i + span > max_cells:
			break
		if tok == drag_tok:
			# Hueco del destino resaltado (el fantasma va pegado al cursor).
			ui.set_cursor_pos(Vector2(x, y))
			var gap = ui.get_cursor_screen_pos()
			ui.imgui_draw_rect_filled(Rect2(gap, Vector2(w, side)), Color(1, 1, 1, 0.06), 0.0)
			ui.imgui_draw_rect_filled(Rect2(gap + Vector2(0.0, side - 3.0), Vector2(w, 3.0)), NX_SEL, 0.0)
			cell_i += span
			continue
		var pos = Vector2(_bar_x(tok, x, now), y)
		if kind == "s":
			if shared_diagram.empty():
				cell_i += span
				continue
			var srect = _draw_shared_tile(ui, pos, side, shared_diagram)
			bar_layout[zone].append({"kind": "s", "id": "sharing", "tok": tok,
				"x": srect.position.x, "y": srect.position.y, "w": side, "h": side, "rect": srect})
			shared_layout.append({"id": "sharing", "x": srect.position.x, "y": srect.position.y,
				"w": side, "h": side, "block": shared_diagram})
			shared_drawn = true
			_draw_shared_menu(ui, shared_diagram)
		elif kind == "p":
			var app = _pinned_app(id)
			if app == null:
				cell_i += span
				continue
			var tile = _draw_app_tile(ui, app, pos, side, "pin_" + id, false)
			bar_layout[zone].append({"kind": "p", "id": id, "tok": tok,
				"x": tile.rect.position.x, "y": tile.rect.position.y,
				"w": side, "h": side, "rect": tile.rect})
			if tile.clicked and suppress_pinned_click != id:
				_frame_launch(app)
		else:
			ui.set_cursor_pos(pos)
			var scr = ui.get_cursor_screen_pos()
			var ai = applets_visible.find(id)
			var is_sel = visible and ai >= 0 and win_items.size() + ai == sel and applet_drag == null
			_draw_applet(ui, id, pos, scr, w, side, is_sel, mouse)
			var rect = Rect2(scr, Vector2(w, side))
			bar_layout[zone].append({"kind": "a", "id": id, "tok": tok,
				"x": scr.x, "y": scr.y, "w": w, "h": side, "rect": rect})
			applets_layout.append({"id": id, "x": scr.x, "y": scr.y, "w": w, "h": side, "zone": zone})
		cell_i += span
	return slot_x(x0, max(cell_i, strip_end), cell)


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


# Ancho de contenido del DockApp de ventanas: un slot por ventana (las de una misma
# pantalla partida van pegadas). Sin ventanas vale un slot (el bloque-clip). Puro:
# tiene que coincidir con el avance de `draw` para que los bloques posteriores no se
# pisen. `items` es la lista de `running()`.
func _window_block_width(side, items):
	var n = items.size()
	if n <= 0:
		return side
	var content = side
	for i in range(1, n):
		var fused = items[i].screen > 0 and items[i - 1].screen == items[i].screen
		content += (0.0 if fused else PAD) + side
	return content


# Bloque-clip del DockApp de ventanas cuando no hay ninguna abierta: una tesela con
# el ícono de clip (WindowMaker).
func _draw_window_dock_empty(ui, pos, side, mouse):
	var tile = _tile(ui, pos, side, "win_clip", NX_FACE)
	var g = side * 0.5
	_draw_shared_glyph(ui, Rect2(tile.rect.position + Vector2((side - g) * 0.5, (side - g) * 0.5),
		Vector2(g, g)), "clipboard", NX_TEXT_DIM)
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
	if id == "teclado":
		return "teclado"
	return "picker"


# ¿Hay que muestrear los applets? Sí mientras alguna franja que los contiene esté a
# la vista: Hogar (home), el Frame abierto a pedido o una barra fijada (pin). Así los
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
	if applet_mods.has(id):
		return applet_mods[id].state
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
	if applet_mods.has(id):
		return applet_mods[id].value
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


# Snapshot puro del bloque "Compartiendo", a partir de los caches del shell. Sin
# I/O: las sesiones locales (con su lado), los avisos remotos y las ventanas
# extendidas van al modelo puro `shared_block.diagram(...)`. Devuelve {} si no hay
# nada que mostrar (el Frame no dibuja nada).
func _shared_snapshot():
	if shell == null or shell.neighborhood == null or not shell.has_method("_host_session_state"):
		return {}
	var hosts = shell.neighborhood.get("hosts")
	if typeof(hosts) != TYPE_ARRAY:
		hosts = []
	var host_session = {}
	var labels = {}
	for h in hosts:
		if typeof(h) != TYPE_DICTIONARY:
			continue
		var hid = String(h.get("id", "")).strip_edges()
		if hid == "":
			continue
		host_session[hid] = String(shell._host_session_state(hid))
		labels[hid] = _shared_host_label(h, hid)
	var running = shell._service_running("Deskflow") if shell.has_method("_service_running") else false
	var sessions = []
	for hid in host_session.keys():
		var hsid = String(hid)
		var dir = String(shell._direction_for(hsid)) if shell.has_method("_direction_for") else ""
		if dir == "":
			continue  # sin lado confirmado no hay dónde dibujarlo
		var agg = String(host_session[hid])
		var name = String(labels.get(hid, hid))
		var screen = shell._gvd_has_session(hsid) if shell.has_method("_gvd_has_session") else false
		var input = bool(shell.host_deskflow.get(hsid, false))
		var input_on = input and (bool(running) or agg != "idle")
		if screen:
			sessions.append({"host": hsid, "peer_name": name, "type": "screen",
				"side": dir, "state": ("starting" if agg == "starting" else "active")})
		if input_on:
			sessions.append({"host": hsid, "peer_name": name, "type": "input",
				"side": dir, "state": ("active" if bool(running) else "starting")})
		if not screen and not input_on and agg == "starting":
			sessions.append({"host": hsid, "peer_name": name, "type": "screen",
				"side": dir, "state": "starting"})
	var remote = shell.remote_shares if shell.get("remote_shares") != null else []
	# Teclado compartido por el servicio global (Pantallas): cuenta aunque el par no esté
	# descubierto, ni confirmado, ni marcado en host_deskflow. Sin esto la dockapp no
	# aparecía cuando sólo se compartía el teclado.
	if shell.has_method("deskflow_input_sessions"):
		remote = remote.duplicate()
		for d in shell.deskflow_input_sessions():
			var pname = String(d.peer_name)
			var dup = false
			for s in sessions:
				if String(s.type) == "input" and (String(s.peer_name) == pname or String(s.host) == pname):
					dup = true
			if dup:
				continue
			if String(d.direction) == "out":
				sessions.append({"host": pname, "peer_name": pname, "type": "input",
					"side": String(d.side), "state": "active"})
			else:
				remote.append({"peer_name": pname, "type": "input", "side": String(d.side), "state": "active"})
	var windows = shell._share_windows() if shell.has_method("_share_windows") else []
	# Ubicación guardada por la vista Grupo ({clave o nombre: grados}) y foco/captura:
	# ambos opcionales, con guarda (el shell puede no exponerlos todavía).
	var placements = shell.get("group_placements") if shell.get("group_placements") != null else {}
	var focus = {"capturing": false}
	if shell.get("remote_input") != null and shell.remote_input.has_method("is_capturing"):
		focus.capturing = bool(shell.remote_input.is_capturing())
	return SHARED_BLOCK.diagram(sessions, remote, windows, placements, focus)


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


# Acción primaria del bloque (clic izquierdo): abre la vista Grupo.
func _shared_primary(_block):
	if shell == null:
		return
	set_visible(false)
	if shell.has_method("_go_group"):
		shell._go_group()
	shell.request_redraw()


# Acción de una fila del menú del diagrama (clic derecho). Reusa los ciclos de vida
# existentes del shell; nunca crea uno paralelo.
func _shared_action(_diagram, action_id):
	var a = String(action_id)
	if a == "open_group":
		_shared_primary(null)
		return
	if a.begins_with("stop:"):
		var rest = a.substr(5)
		var sep = rest.find(":")
		if sep > 0:
			_stop_shared_side(rest.substr(0, sep), rest.substr(sep + 1))
		return
	if a.begins_with("win_show:"):
		if shell != null and shell.has_method("_focus_tile"):
			shell._focus_tile(int(a.substr(9)))
		return
	if a.begins_with("win_max:"):
		if shell != null and shell.has_method("_toggle_maximize_window"):
			shell._toggle_maximize_window(int(a.substr(8)))
		return
	if a.begins_with("win_close:"):
		if shell != null and shell.has_method("_close_window_id"):
			shell._close_window_id(int(a.substr(10)))


# Corta un lado compartido: si es local, detiene la sesión de este equipo; si es un
# aviso remoto, le pide al otro que detenga la suya (share_stop) y quita el aviso.
func _stop_shared_side(type, key):
	if shell == null:
		return
	var t = String(type)
	var k = String(key)
	var remote = false
	for e in shell.remote_shares:
		if typeof(e) == TYPE_DICTIONARY and String(e.get("host", "")) == k \
				and String(e.get("type", "")) == t:
			remote = true
			break
	if remote:
		if shell.has_method("_peer_endpoint_for") and shell.has_method("_peer_call"):
			var ep = shell._peer_endpoint_for(k)
			if typeof(ep) == TYPE_DICTIONARY and bool(ep.get("ok", false)):
				shell._peer_call(String(ep.get("peer", "")), k, "share_stop", {"type": t})
		if shell.has_method("_peer_share_notify"):
			shell._peer_share_notify(k, {"type": t, "state": "stopped"})
	elif t == "screen":
		if shell.has_method("_stop_gvd_screen"):
			shell._stop_gvd_screen(k)
	elif t == "input":
		# Misma salida que el interruptor del Grupo (también avisa al otro equipo).
		shell.host_deskflow[k] = false
		if shell.has_method("_group_input_set"):
			shell._group_input_set(k, false)
	shell.request_redraw()


# Tesela del DockApp "Compartiendo" en `pos` (local a la ventana ImGui de la barra).
# Devuelve su rect en pantalla; el dibujo radial usa ESE rect (el draw list es en
# coords absolutas, así que vale en cualquier barra).
func _draw_shared_tile(ui, pos, side, diagram, ghost = false):
	var tile = _tile(ui, pos, side, "drag_shared" if ghost else "shared_sharing", NX_FACE)
	var rect = tile.rect
	var hovered = ui.is_item_hovered()
	_draw_shared_face(ui, pos, rect, diagram, side)
	var tip = String(diagram.get("tooltip", ""))
	for p in diagram.get("radial", []):
		if bool(p.get("input", false)):
			tip += "\n" + SHARED_BLOCK.focus_text(diagram.radial, bool(diagram.get("local_focus", true)))
			break
	if hovered and not ghost and not shared_drag and tip != "":
		ui.set_tooltip(tip)
	return rect


# Menú contextual (clic derecho) del DockApp: se abre/dibuja en la ventana de la barra
# donde se dibujó la tesela.
func _draw_shared_menu(ui, diagram):
	if shared_menu_want != "":
		shared_menu_id = shared_menu_want
		shared_menu_want = ""
		ui.open_popup("##shared_menu")
	if shared_menu_id == "":
		return
	MENU_STYLE.begin(ui)
	if ui.begin_popup("##shared_menu"):
		shared_menu_open = true
		shared_menu_block = diagram
		MENU_STYLE.chrome(ui, "Compartiendo")
		for it in diagram.get("menu", []):
			if typeof(it) != TYPE_DICTIONARY:
				continue
			if String(it.get("kind", "")) == "separator":
				ui.separator()
				continue
			if MENU_STYLE.item(ui, String(it.get("label", ""))):
				_shared_action(diagram, String(it.get("id", "")))
		ui.end_popup()
	MENU_STYLE.end(ui)


# Cara radial del bloque (`pos` local para el texto, `rect` en pantalla para las
# primitivas del draw list): este equipo al centro (borde de acento si el foco está
# acá) y cada par en su ángulo con glifo de pantalla y/o teclado e inicial. Entre
# ambos un tramo punteado con cabeza de flecha hacia quien es controlado; el par
# con el foco (puntero/teclado allá) se resalta con marco. Color por estado.
func _draw_shared_face(ui, pos, rect, diagram, side):
	var bw = _bevel_w(ui)
	var u = float(side)
	var c = rect.position + Vector2(u * 0.5, u * 0.5)
	var half = u * 0.14
	var crect = Rect2(c - Vector2(half, half), Vector2(half, half) * 2.0)
	var accent = shell.accent if shell != null else NX_CUR
	var e = max(1.0, bw * 0.5)
	if bool(diagram.get("local_focus", true)):
		ui.imgui_draw_rect_filled(crect.grow(e + 1.0), accent, 0.0)
	ui.imgui_draw_rect_filled(crect, NX_BG, 0.0)
	_draw_shared_glyph(ui, crect, "screen", NX_TEXT)
	var ns = u * 0.28
	var radius = u * 0.34
	for p in diagram.get("radial", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var col = _shared_state_color(String(p.get("state", "active")))
		var dir = Vector2(cos(deg2rad(float(p.angle))), sin(deg2rad(float(p.angle))))
		var nc = c + dir * radius
		var nrect = Rect2(nc - Vector2(ns, ns) * 0.5, Vector2(ns, ns))
		_draw_shared_link(ui, c + dir * (half * 1.3), nc - dir * (ns * 0.55), dir,
			String(p.get("direction", "none")), col)
		if bool(p.get("focused", false)):
			ui.imgui_draw_rect_filled(nrect.grow(e + 1.0), accent, 0.0)
		ui.imgui_draw_rect_filled(nrect, NX_BG, 0.0)
		var kind = String(p.get("kind", "screen"))
		if kind == "both":
			var h2 = Vector2(ns * 0.5, ns)
			_draw_shared_glyph(ui, Rect2(nrect.position, h2), "screen", col)
			_draw_shared_glyph(ui, Rect2(nrect.position + Vector2(ns * 0.5, 0.0), h2), "input", col)
		else:
			_draw_shared_glyph(ui, nrect, kind, col)
		if ns >= 16.0 and kind != "both":
			# El texto usa cursor LOCAL a la ventana: `pos` + desplazamiento dentro del rect.
			ui.set_cursor_pos(pos + (nrect.position - rect.position) + Vector2(ns * 0.5 - 3.5, ns * 0.22))
			ui.text_colored(NX_TEXT, String(p.get("initial", "")))


# Tramo entre el centro y el par: puntos y cabeza cuadrada del lado de quien es
# controlado ("out": hacia el par; "in": hacia este equipo; "both": ambas).
func _draw_shared_link(ui, a, b, dir, direction, col):
	for k in range(4):
		var q = a.linear_interpolate(b, float(k) / 3.0)
		ui.imgui_draw_rect_filled(Rect2(q - Vector2(1.0, 1.0), Vector2(2.0, 2.0)), col, 0.0)
	var hs = Vector2(3.0, 3.0)
	if direction == "out" or direction == "both":
		ui.imgui_draw_rect_filled(Rect2(b - hs, hs * 2.0), col, 0.0)
	if direction == "in" or direction == "both":
		ui.imgui_draw_rect_filled(Rect2(a - hs, hs * 2.0), col, 0.0)


# Color por estado: activo = acento, conectando = acento atenuado con pulso, error
# = rojo. El estado también se distingue por la forma (barra/flecha) y el tooltip.
func _shared_state_color(state):
	var accent = shell.accent if shell != null else NX_CUR
	match String(state):
		"error":
			return Color(0.95, 0.42, 0.34, 1.0)
		"starting":
			var pulse = 0.35 + 0.35 * (0.5 + 0.5 * sin(float(OS.get_ticks_msec()) * 0.006))
			return Color(accent.r, accent.g, accent.b, pulse)
	return accent


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
	return {"clicked": clicked, "rect": r, "face": face, "hover": hover}


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
		win_dock_press = false
		win_dock_drag = false
		win_scroll_press = false
		shared_press = ""
		shared_drag = false
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
		# La ranura Escritorio (sin miembros tiled) no cuenta como pantalla numerada.
		if unit.empty():
			continue
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


# Salir del exposé desde el Frame: API pública del shell si existe (t3), si no el
# toggle interno. Idempotente (no hace nada fuera de exposé).
func _leave_expose():
	if not shell.expose:
		return
	if shell.has_method("exit_expose"):
		shell.exit_expose()
	else:
		shell._toggle_expose(false)


# Lanzar una app desde el Frame sale de exposé: el Frame sigue visible en exposé
# (barras forzadas), pero la app debe abrirse en el escritorio, no detrás del zoom.
func _frame_launch(app):
	_leave_expose()
	shell._launch_app(app)


func switch_to(item, keep_frame := false):
	_leave_expose()
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
		shell._close_window_id(item.id)
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
# (Hogar, Frame abierto a pedido o barra fijada) y pide un frame por muestra
# (>= 1 Hz) para que la gráfica y los diales avancen aunque la ventana enfocada sea
# otra app. No se gatea por `visible` sólo: una barra fijada (pin) sigue a la vista.
func _process(_delta):
	if shell.fullscreen_id >= 0:
		return
	var home = shell.current_activity == null
	if applets_live(home, visible, pin_top_bar, pin_bottom_bar):
		var changed = sysmon.tick()
		for id in applet_mods:
			if applets_visible.has(id):
				changed = applet_mods[id].refresh() or changed
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
		if mouse_down and shared_press != "" and not shared_drag \
				and mouse_pos.distance_to(shared_from) > DRAG_PX:
			shared_drag = true
		if shared_drag:
			shell.request_redraw()
		# Arrastre horizontal sobre el tramo del DockApp de ventanas (modo scroll).
		if mouse_down and win_scroll_press:
			var szone = _zone_at(mouse_pos)
			if szone != "":
				var spitch = float(bar_cell.get(szone, 1.0))
				var splan = window_plan(running().size(), window_span.get(szone, 0), -1, window_scroll.get(szone, 0.0))
				var sdelta = (win_scroll_from - mouse_pos.x) / max(1.0, spitch) * max(1, splan.per_cell)
				window_scroll[szone] = clamp(win_scroll_start + sdelta, 0.0, float(splan.scroll_max))
			shell.request_redraw()
		# Arrastre del DockApp de ventanas vacío (bloque-clip): reordena su slot.
		if mouse_down and win_dock_press and not win_dock_drag \
				and mouse_pos.distance_to(win_dock_from) > DRAG_PX:
			win_dock_drag = true
		if win_dock_drag:
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
			# Sobre Vecindario/Grupo/Hogar o el ícono central: un paso de la misma cadena
			# vertical que el gesto de 3 dedos (rueda arriba = dedos arriba).
			if super_press == null and (_over_place(mouse_pos) or shell._over_center_icon(mouse_pos)):
				shell._wheel_vchain(1 if event.button_index == BUTTON_WHEEL_UP else -1)
				get_tree().set_input_as_handled()
				return
			# En exposé la rueda desplaza la tira (no cambia la selección).
			if shell.expose:
				shell._expose_scroll_by((240.0 if event.button_index == BUTTON_WHEEL_DOWN else -240.0))
				get_tree().set_input_as_handled()
				return
			if super_press != null:
				# En el Hogar o dentro del zoom (Grupo/Vecindario) la rueda VERTICAL
				# aleja/acerca un nivel Sugar (el ícono central se achica/agranda).
				# Fuera de ahí el paneo de la franja sigue igual.
				if shell.zoom_level > 0 or shell._at_home():
					shell._zoom_step(1 if event.button_index == BUTTON_WHEEL_UP else -1)
				else:
					shell._pan_by((-1.0 if event.button_index == BUTTON_WHEEL_UP else 1.0))
				shell.request_redraw()
				get_tree().set_input_as_handled()
				return
			# Rueda sobre el tramo del DockApp de ventanas: scroll horizontal de sus
			# teselas (modo scroll); no cambia el foco de pantalla.
			if _window_scroll_at(mouse_pos, -1 if event.button_index == BUTTON_WHEEL_UP else 1):
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
				# El Frame recibe _input antes que View._gui_input: iniciar acá evita que el
				# primer Super+clic llegue al cliente. También en mosaico el gesto mueve la
				# ventana real; _begin_super_drag la pasa antes a modo flotante.
				# En FRT/SDL el keydown de Super no siempre llega antes que el botón:
				# puede existir sólo como `event.meta`. Usar el detector del WM evita
				# dejar vivo `app_press` y que ImGui levante su label en vez de mover
				# la ventana con su tesela/wmIcon.
				if shell._super_held(event) and shell.focused_tile >= 0:
					if shell._begin_super_drag(mouse_pos, event.button_index):
						# Super manda sobre cualquier widget del Frame. En particular, un
						# appicon de la barra superior ya pudo armar `app_press` unas líneas
						# antes: descartarlo evita que el motion siguiente levante su label
						# mientras el WM mueve la ventana.
						app_press = null
						app_drag = null
						applet_press = null
						applet_drag = null
						drag_candidate = null
						dragging = null
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
					shared_from = mouse_pos
					shared_grab = mouse_pos - Vector2(hit_shared.x, hit_shared.y)
					shell.request_redraw()
					get_tree().set_input_as_handled()
					return
				# Bloque del DockApp de ventanas: arma su arrastre si no hay una tesela
				# de ventana bajo el cursor (así mover el DockApp no roba el clic de una
				# ventana). Con el clip vacío se puede soltar en cualquier barra.
				# Asa del tramo de ventanas: arrastra el DockApp aunque haya ventanas.
				if _window_grip_zone(mouse_pos) != "":
					win_dock_press = true
					win_dock_from = mouse_pos
					win_dock_drag = false
					shell.request_redraw()
					get_tree().set_input_as_handled()
					return
				var hit_win_dock = _window_dock_hit(mouse_pos)
				if hit_win_dock != null and _item_at(mouse_pos) == null:
					# En modo scroll, arrastrar el tramo lo desplaza; si no, mueve el
					# DockApp de ventanas a otro slot.
					if _window_scroll_mode(hit_win_dock, mouse_pos):
						var szone = _zone_at(mouse_pos)
						win_scroll_press = true
						win_scroll_from = mouse_pos.x
						win_scroll_start = window_scroll.get(szone, 0.0)
						shell.request_redraw()
						get_tree().set_input_as_handled()
						return
					win_dock_press = true
					win_dock_from = mouse_pos
					win_dock_drag = false
					shell.request_redraw()
					get_tree().set_input_as_handled()
					return
				drag_candidate = _item_at(mouse_pos)
				drag_from = mouse_pos
				if drag_candidate != null:
					drag_grab = mouse_pos - Vector2(drag_candidate.x, drag_candidate.y)
				dragging = null
			else:
				# Soltar el DockApp "Compartiendo": si hubo arrastre se reubica; si no,
				# primaria (ver detalle) si sigue bajo el puntero.
				if shared_press != "":
					var cur_shared = _shared_at(mouse_pos)
					var pressed = shared_press
					shared_press = ""
					if shared_drag:
						_finish_shared_drag()
					elif cur_shared != null and String(cur_shared.id) == pressed:
						_shared_primary(cur_shared.block)
				if app_drag != null:
					_finish_app_drag()
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
				if win_dock_drag:
					_finish_win_dock_drag()
				win_dock_press = false
				win_dock_drag = false
				win_scroll_press = false
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
	# Pinch del touchpad: mismo zoom que Super+rueda vertical en Hogar/vistas de zoom.
	if event is InputEventMagnifyGesture:
		if shell.zoom_level > 0 or shell._at_home():
			if event.factor > 1.0:
				shell._zoom_step(1)
			elif event.factor < 1.0:
				shell._zoom_step(-1)
			shell.request_redraw()
			get_tree().set_input_as_handled()
		return
	if not (event is InputEventKey):
		return
	var code = event.scancode
	# Esc cancela el arrastre de un applet (conserva el orden) antes de ocultar el Frame.
	if event.pressed and code == KEY_ESCAPE and (applet_drag != null or shared_drag):
		applet_drag = null
		shared_drag = false
		shared_press = ""
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
	# Zoom Sugar: F1 Vecindario, F2 Grupo, F3 Hogar y F4 vuelve a la última pantalla
	# con foco (la función que sale del Hogar hacia la pantalla enfocada). Sin
	# modificadores sólo en las vistas de zoom (en una app F2/F3 son de la app);
	# con Super funcionan siempre. Alt/Ctrl+F4 siguen siendo de la ventana.
	var zoom_keys = event.meta or super_press != null or shell.zoom_level > 0 or shell._at_home()
	if event.pressed and not event.echo and not (event.alt or event.control) and zoom_keys \
			and code in [KEY_F1, KEY_F2, KEY_F3, KEY_F4]:
		super_press = null  # Super+Fn es combo: soltar Super no abre el exposé
		if code == KEY_F1:
			shell._go_neighborhood()
			_gulp(code)
			return
		elif code == KEY_F2:
			shell._go_group()
			_gulp(code)
			return
		elif code == KEY_F3:
			shell._go_home()
			_gulp(code)
			return
		elif code == KEY_F4:
			shell._set_zoom(0)
			shell._focus_dir(-1)
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
		if code == KEY_SPACE and event.shift:
			# Super+Shift+Space: alterna flotante <-> mosaico de la ventana enfocada.
			super_press = null
			shell.toggle_window_mode(shell.focused_tile)
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_F:
			# Super+F: maximizar/restaurar (alias de Alt+F10).
			super_press = null
			shell._toggle_maximize_window(shell.focused_tile)
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_UP or code == KEY_DOWN:
			# Super+↑ maximiza; Super+↓ restaura a flotante.
			super_press = null
			if code == KEY_UP:
				shell._maximize_window(shell.focused_tile)
			else:
				shell._restore_maximized_window(shell.focused_tile)
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_H or code == KEY_J or code == KEY_K or code == KEY_L:
			# Super+H/J/K/L: foco entre pantallas; con Shift, intercambia la pantalla.
			super_press = null
			if event.shift:
				if code == KEY_H:
					shell._swap_dir(-1)
				elif code == KEY_L:
					shell._swap_dir(1)
			elif code == KEY_H:
				shell._focus_dir(-1)
			elif code == KEY_L:
				shell._focus_dir(1)
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
		# Alt+F10: maximizar/desmaximizar (workspace entero <-> franja partida).
		shell._toggle_maximize_window(shell.focused_tile)
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


# Franja del Frame (superior o inferior) del último dibujo: clic derecho abre el
# selector de controles sobre cualquiera de las dos barras.
func _applet_bar_at(pos):
	if not applets_drawn:
		return false
	var h = _vh()
	return pos.y <= h or pos.y >= get_viewport().size.y - h


# Suelta de un bloque de app (pin del Frame o icono del lanzador): a una barra se
# fija/mueve a ese slot; al centro del escritorio se estalla —salvo que sea una app o
# ventana top-level activa, que vuelve a su lugar—.
func _finish_app_drag():
	var zone = _zone_at(mouse_pos)
	if zone != "":
		_place_pin(app_drag, zone, mouse_pos.x)
	elif _pin_in_order(app_drag.id):
		if not _app_active(app_drag):
			_explode_block("p", app_drag.id)
	# Un icono del lanzador (no fijado) soltado al centro sólo se descarta.


# Suelta de un applet: a una barra se mueve al slot unificado; al centro se estalla.
func _finish_applet_drag():
	var id = applet_drag
	if id == null:
		return
	var zone = _zone_at(mouse_pos)
	applet_drag = null
	applet_press = null
	if zone == "":
		_explode_block("a", id)
		return
	_place_token(zone, _tok_applet(id), mouse_pos.x, _applet_span(id))
	if not bar_order[zone].has(_tok_applet(id)):
		shell.request_redraw()


# Suelta del DockApp "Compartiendo": se reubica en la barra donde se suelte; fuera de
# las barras conserva su lugar (no se estalla: depende de la relación, no del usuario).
func _finish_shared_drag():
	shared_drag = false
	var zone = _zone_at(mouse_pos)
	if zone == "":
		shell.request_redraw()
		return
	_move_token(zone, SHARED_TOKEN, mouse_pos.x)


# Suelta del DockApp de ventanas (bloque-clip): se reubica en el slot elegido de la
# barra donde se suelte (superior o inferior). Soltarlo fuera conserva el layout.
func _finish_win_dock_drag():
	win_dock_drag = false
	win_dock_press = false
	var zone = _zone_at(mouse_pos)
	if zone == "":
		shell.request_redraw()
		return
	_move_token(zone, WINDOW_TOKEN, mouse_pos.x)


# Reubica un token (pin, applet o el DockApp de ventanas) en la celda libre más
# cercana a `x` de la barra `zone`, persiste y anima. Helper común de los finales de
# arrastre: nadie más se mueve y nunca se superpone.
func _move_token(zone, tok, x):
	if not _place_token(zone, tok, x):
		shell.request_redraw()


# Barra cuyo tramo de ventanas contiene `pos` (o "" si ninguna), del último dibujo.
func _strip_zone(pos):
	for zone in ["top", "dock"]:
		var r = window_region.get(zone)
		if r != null and int(window_span.get(zone, 0)) > 0 and r.has_point(pos):
			return zone
	return ""


# Teselas de ventana del strip (orden de items_layout) para decidir el drop: rects,
# ids y el escritorio/unidad de cada una (lo resuelve el shell).
func _strip_arrays():
	var rects = []
	var units = []
	var ids = []
	for it in items_layout:
		if it.id < 0:
			continue
		rects.append(Rect2(it.x, it.y, it.w, it.h))
		ids.append(it.id)
		units.append(shell.frame_strip_unit(it.id))
	return {"rects": rects, "units": units, "ids": ids}


# Suelta del arrastre: dentro del strip de ventanas decide por escritorio/unidad
# (nuevo escritorio en los bordes/extremos, acople o reancla sobre otra tesela); fuera
# conserva el comportamiento clásico: sobre otra ventana tilea, si no desacopla.
func _finish_drag():
	# Vista Grupo: soltar la ventana sobre un equipo la comparte por gvd.
	if dragging != null and shell._group_drop_window(dragging.id, mouse_pos):
		shell.request_redraw()
		return
	if dragging != null and _strip_zone(mouse_pos) != "":
		var sa = _strip_arrays()
		var t = strip_drop_target(sa.rects, sa.units, mouse_pos.x)
		if t != null:
			if t.kind == "new":
				shell.frame_strip_new(dragging.id, strip_unit_at(sa.units, int(t.index)),
					int(t.index) == 0)
			elif t.kind == "onto" and int(t.tile) < sa.ids.size():
				shell.frame_strip_onto(dragging.id, int(sa.ids[int(t.tile)]), String(t.side))
			shell.request_redraw()
			return
	var target = _item_at(mouse_pos)
	if target != null and target.id >= 0 and not target.minimized and target.id != dragging.id:
		shell._tile_drop(dragging.id, target.id)
	else:
		shell._untile_window(dragging.id)
	shell.request_redraw()


# Super+arrastre: si se suelta sobre la barra del Frame, mueve la ventana a ese lugar
# (reordena la franja); si no, cancela.
func _finish_win_drag():
	var dragged = win_drag.id
	win_drag = null
	shell.window_dragging = false
	if mouse_pos.y <= _vh():
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
func _draw_applets(ui, vp, off, mouse, grid):
	applet_picker_open = false
	var side = float(grid.side)
	var by = round(vp.y - side - off)
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
	# Esquina izquierda reservada (vacía); el dock arranca después. Pines y applets
	# comparten los slots de la barra (orden unificado); la celda del pin va al final.
	var dock_x = bar_base_origin("dock", grid)
	_draw_bar_blocks(ui, "dock", dock_x, 0.0, grid, mouse)
	var pin_x = float(grid.margin) + float(grid.n - 1) * float(grid.pitch)
	var y = 0.0
	# El selector de controles del Frame (fijar/quitar applets y barras) se abre con
	# clic derecho sobre un applet o sobre la franja; ya no hay celda "+".
	if applet_picker_want:
		applet_picker_want = false
		ui.open_popup("##applets_add")
	# Pin de la barra inferior (K19): fija la franja o vuelve al autohide.
	if _draw_pin_toggle(ui, Vector2(pin_x, y), side, pin_bottom_bar, "pin_bottom"):
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
		# Autocierre: si el puntero sale del popup (con margen de media celda) hacia
		# el escritorio u otra ventana, se cierra. NO se cierra mientras está sobre
		# el popup o sobre la barra que lo abrió.
		var pop = Rect2(ui.get_window_pos(), ui.get_window_size())
		var margin = side * 0.5
		if not (pop.grow(margin).has_point(mouse) or applets_bar_rect.grow(margin).has_point(mouse)):
			ui.close_current_popup()
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
		# Estado honesto: la selección se marca recién cuando sysfs la refleja.
		if sysmon.governor_state == "applying":
			ui.text_disabled("aplicando…")
		elif sysmon.governor_state == "not_provisioned":
			ui.text_disabled("permiso no provisionado")
			ui.text_disabled("sudo ~/gdtk/session/gdtk-governor-provision install")
		elif sysmon.governor_state == "error":
			ui.text_disabled("no se pudo aplicar")
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
	# Las teselas del DockApp de ventanas se dibujan donde esté su token: también
	# en la barra inferior (antes sólo aparecían en la superior).
	if bar_order["dock"].has(WINDOW_TOKEN) and not running().empty():
		_draw_windows(ui, "dock", side, 0.0, by, mouse)
		_draw_window_grip(ui, "dock", mouse)
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
	elif applet_mods.has(id) and applet_mods[id].has_method("draw"):
		applet_mods[id].draw(self, ui, gp_scr, gp_loc, gp_w, gp_h)
	else:
		ui.set_cursor_pos(gp_loc + Vector2(4.0, 3.0))
		ui.text_colored(NX_TEXT_DIM, a.short)
		var vw = _text_w(ui, v)
		ui.set_cursor_pos(gp_loc + Vector2(max(3.0, (gp_w - vw) * 0.5), gp_h * 0.45))
		ui.text_colored(NX_TEXT, v)
	if b.hover and not is_ghost and applet_mods.has(id) and applet_mods[id].detail != "":
		ui.set_tooltip(applet_mods[id].detail)
	var pct = _applet_pct(id)
	if pct >= 0.0:
		var bar_w = (w - 8.0) * clamp(pct, 0.0, 1.0)
		ui.imgui_draw_rect_filled(Rect2(rect.position + Vector2(4.0, side - 6.0), Vector2(bar_w, 3.0)), line, 0.0)


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


# Bloque Hogar: tesela cuadrada con el ícono Sugar de hogar y el título corto abajo.
# Resalta cuando la vista actual es el Hogar (la ranura extra al final de la fila).
# Color de acento del shell para el bloque actual/fijado.
func _cur():
	if shell != null and "accent" in shell:
		return Color(shell.accent.r, shell.accent.g, shell.accent.b, 1.0)
	return NX_CUR


func _over_place(p):
	if not shown_top:
		return false
	for r in place_rects:
		if r.has_point(p):
			return true
	return false


func _draw_home_tile(ui, pos, side):
	var at_home = shell.current_activity == null and shell.zoom_level == 0 and not shell.neighborhood_view
	var b = _tile(ui, pos, side, "go_home", _cur() if at_home else NX_FACE)
	var ts = ui.get_imgui_scale()
	var pad = TILE_PAD * ts
	var lines = _title_lines(ui, side, "Hogar") if side >= 76.0 * ts else []
	var title_h = _title_reserved(ui, lines) if not lines.empty() else 0.0
	var bw = _bevel_w(ui)
	var inner = side - 2.0 * bw
	var s = clamp(inner - title_h - 2.0 * pad, ICON_MIN * ts, ICON_MAX * ts)
	var iy = bw + max(pad, (inner - s - title_h) * 0.5)
	# Bloque Hogar = "Este equipo": lleva el ícono del equipo local (desktop,
	# laptop, tablet, mobile o tv), no una casita genérica.
	var icon = shell.local_device_icon_tex()
	if icon != null:
		_draw_emboss_icon(ui, pos + Vector2((side - s) * 0.5, iy), Vector2(s, s), icon, b.face)
	else:
		ui.set_cursor_pos(pos + Vector2((side - 7.0 * ui.get_imgui_scale()) * 0.5, (side - 13.0 * ui.get_imgui_scale()) * 0.5))
		ui.text_colored(NX_TEXT, "H")
	if not lines.empty():
		_tile_title(ui, pos, side, "Hogar", false, lines)
	return b.clicked


# Bloque Vecindario: tesela U x U con el ícono de red inalámbrica (The Noun
# Project, ver icons/np/CREDITS.txt). Sólo abre la vista (no escanea, no conecta);
# resalta cuando la vista actual es el Vecindario.
func _draw_neighborhood_tile(ui, pos, side):
	var active = shell.zoom_level == 2
	var b = _tile(ui, pos, side, "go_neighborhood", _cur() if active else NX_FACE)
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


# Bloque Grupo: igual que Vecindario, con el ícono Sugar de red cableada (sin
# ícono propio en el shell); resalta sólo en la vista Grupo (zoom_level 1).
func _draw_group_tile(ui, pos, side):
	var b = _tile(ui, pos, side, "go_group", _cur() if shell.zoom_level == 1 else NX_FACE)
	var ts = ui.get_imgui_scale()
	var pad = TILE_PAD * ts
	var lines = _title_lines(ui, side, "Grupo") if side >= 76.0 * ts else []
	var title_h = _title_reserved(ui, lines) if not lines.empty() else 0.0
	var bw = _bevel_w(ui)
	var inner = side - 2.0 * bw
	var s = clamp(inner - title_h - 2.0 * pad, ICON_MIN * ts, ICON_MAX * ts)
	var iy = bw + max(pad, (inner - s - title_h) * 0.5)
	var icon = shell._load_sugar_svg("network-wired", shell.SUGAR_STROKE, shell.SUGAR_FILL)
	if icon != null:
		_draw_emboss_icon(ui, pos + Vector2((side - s) * 0.5, iy), Vector2(s, s), icon, b.face)
	else:
		ui.set_cursor_pos(pos + Vector2((side - 7.0 * ts) * 0.5, (side - 13.0 * ts) * 0.5))
		ui.text_colored(NX_TEXT, "G")
	if not lines.empty():
		_tile_title(ui, pos, side, "Grupo", false, lines)
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
		face = _cur()
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


# Mini-tesela del DockApp de ventanas (modo mini/scroll): mitad de tamaño, con el
# ícono, una barra mínima de título/estado y un cuadradito de cerrar arriba a la
# derecha. Hit-test y click/cerrar funcionan igual que en tamaño normal.
func _draw_window_mini(ui, pos, side, item, current, is_sel, is_drop, mouse):
	var face = NX_FACE
	if current:
		face = _cur()
	elif is_drop:
		face = NX_SEL
	elif is_sel:
		face = NX_FACE_SEL
	elif item.minimized:
		face = NX_FACE_DIM
	var b = _tile(ui, pos, side, "wm" + item.key, face)
	var ts = ui.get_imgui_scale()
	var bw = _bevel_w(ui)
	var inner = max(2.0, side - 2.0 * bw)
	var icon_side = max(8.0, inner - 2.0)
	var tex = _item_icon(item)
	if tex != null:
		ui.set_cursor_pos(pos + Vector2((side - icon_side) * 0.5, bw + 1.0))
		ui.image(tex, Vector2(icon_side, icon_side))
	else:
		var mono = item.name.substr(0, 1).to_upper() if item.name != "" else "?"
		ui.set_cursor_pos(pos + Vector2((side - 7.0 * ts) * 0.5, bw + 1.0))
		ui.text_colored(NX_TEXT, mono)
	# Barra mínima de título/estado: foco, minimizada o pantalla compartida.
	var bar_h = max(3.0, side * 0.16)
	var col = _cur() if current else (NX_TEXT_DIM if item.minimized else NX_LIGHT)
	ui.imgui_draw_rect_filled(Rect2(b.rect.position + Vector2(bw, side - bar_h - bw),
		Vector2(max(1.0, inner), bar_h)), col, 0.0)
	var cs = max(8.0, side * 0.30)
	var close_off = Vector2(side - cs - bw, bw)
	var over_close = _in_rect(mouse, b.rect.position + close_off, cs)
	if b.rect.has_point(mouse):
		_draw_mini(ui, pos + close_off, cs, "x", over_close and mouse_down)
		if b.clicked and over_close:
			return {"clicked": false, "close": true}
	return {"clicked": b.clicked, "close": false}


# Dibuja las teselas del DockApp de ventanas dentro de su tramo (`window_span`), en
# cualquier barra. `off` es el desplazamiento vertical en pantalla de la barra (para
# que el hit-test de `items_layout` quede en coords absolutas).
# Asa del tramo de ventanas: franja en su borde izquierdo (con ventanas, las teselas
# cubren el resto del tramo y se arrastran ellas mismas).
func _window_grip_rect(zone):
	var region = window_region.get(zone)
	if region == null or int(window_span.get(zone, 0)) <= 0:
		return null
	var gw = max(6.0, round(region.size.y * 0.14))
	return Rect2(region.position, Vector2(gw, region.size.y))


func _window_grip_zone(pos):
	if running().empty():
		return ""
	for zone in ["top", "dock"]:
		var r = _window_grip_rect(zone)
		if r != null and r.has_point(pos):
			return zone
	return ""


func _draw_window_grip(ui, zone, mouse):
	var r = _window_grip_rect(zone)
	if r == null or running().empty():
		return
	var region = window_region.get(zone)
	if not (region.has_point(mouse) or win_dock_press or win_dock_drag):
		return
	var hot = r.has_point(mouse) or win_dock_drag
	ui.imgui_draw_rect_filled(r, Color(NX_BG.r, NX_BG.g, NX_BG.b, 0.92 if hot else 0.75), 0.0)
	var dot = max(2.0, round(r.size.x * 0.28))
	var cx = r.position.x + (r.size.x - dot) * 0.5
	var col = _cur() if hot else Color(1, 1, 1, 0.55)
	for i in range(5):
		var cy = r.position.y + r.size.y * (0.3 + 0.1 * i) - dot * 0.5
		ui.imgui_draw_rect_filled(Rect2(Vector2(cx, cy), Vector2(dot, dot)), col, dot * 0.5)


func _draw_windows(ui, zone, side, y, off, mouse):
	var items = running()
	var F = int(window_span.get(zone, 0))
	if F <= 0:
		return
	var x0 = window_block_x.get(zone, 0.0)
	var pitch = float(bar_cell.get(zone, side + PAD))
	if pitch <= 0.0:
		pitch = side + PAD
	var focus_idx = -1
	for i in range(items.size()):
		if _is_current(items[i]):
			focus_idx = i
	var plan = window_plan(items.size(), F, focus_idx, window_scroll.get(zone, 0.0))
	if plan.mode == "scroll":
		window_scroll[zone] = float(plan.visible_range[0])  # auto-scroll: foco visible
	var rng = plan.visible_range
	# Objetivo del arrastre/levantado, para resaltarlo al dibujar.
	var drop_id = -1
	if dragging != null:
		var t = _item_at(mouse)
		if t != null and t.id >= 0 and t.id != dragging.id:
			drop_id = t.id
	elif lifted != null:
		drop_id = lifted.id
	var sub = side * 0.5
	var entries = []
	for vi in range(int(rng[0]), int(rng[1])):
		var local = vi - int(rng[0])
		var px = x0
		var py = y
		var sz = side
		if plan.mode == "normal":
			px = x0 + float(local) * pitch
		else:
			var celli = int(local / 4)
			var slot = local % 4
			var col = slot % 2
			var row = int(slot / 2)
			px = x0 + float(celli) * pitch + float(col) * sub
			py = y + float(row) * sub
			sz = sub
		entries.append({"i": vi, "pos": Vector2(px, py), "sz": sz})
	# Placa de fusión (sólo modo normal): grupo de ventanas de una misma pantalla.
	if plan.mode == "normal":
		var gi = 0
		while gi < entries.size():
			var it0 = items[entries[gi].i]
			if it0.screen > 0:
				var gj = gi
				while gj + 1 < entries.size() and items[entries[gj + 1].i].screen == it0.screen:
					gj += 1
				if gj > gi:
					var g0 = entries[gi].pos.x
					var g1 = entries[gj].pos.x + side
					ui.imgui_draw_rect_filled(Rect2(Vector2(g0 - 2.0, y - 2.0),
						Vector2(g1 - g0 + 4.0, side + 4.0)), Color(0.0, 0.0, 0.0, 0.35), 0.0)
					ui.imgui_draw_rect_filled(Rect2(Vector2(g0, y + side - 3.0),
						Vector2(g1 - g0, 3.0)), NX_SEL, 0.0)
				gi = gj + 1
			else:
				gi += 1
	# Drop por escritorio/unidad: destino del arrastre dentro del strip (barra de
	# inserción o media tesela). Sólo cuando el puntero está sobre el tramo.
	var strip_t = null
	if dragging != null and window_region.get(zone, Rect2()).has_point(mouse):
		var srects = []
		var sunits = []
		for e in entries:
			srects.append(Rect2(e.pos.x, e.pos.y, e.sz, e.sz))
			sunits.append(shell.frame_strip_unit(items[e.i].id))
		strip_t = strip_drop_target(srects, sunits, mouse.x)
	for e in entries:
		var item = items[e.i]
		var current = _is_current(item)
		var is_sel = visible and e.i == sel and dragging == null
		var is_drop = (item.id >= 0 and item.id == drop_id) \
			and not (strip_t != null and String(strip_t.kind) == "new")
		var is_dragged = dragging != null and item.id == dragging.id
		var res = {"clicked": false, "close": false}
		if is_dragged:
			ui.imgui_draw_rect_filled(Rect2(Vector2(e.pos.x, e.pos.y), Vector2(e.sz, e.sz)),
				Color(1, 1, 1, 0.06), 0.0)
			ui.imgui_draw_rect_filled(Rect2(Vector2(e.pos.x, e.pos.y + e.sz - 3.0),
				Vector2(e.sz, 3.0)), NX_SEL, 0.0)
		elif plan.mode == "normal":
			res = _draw_window_tile(ui, e.pos, e.sz, item, current, is_sel, is_drop, mouse)
		else:
			res = _draw_window_mini(ui, e.pos, e.sz, item, current, is_sel, is_drop, mouse)
		if res.close:
			_win_close = item
		elif res.clicked:
			# Clic: la enfocada se minimiza; una minimizada se restaura; otra se enfoca.
			if item.id >= 0 and current and not item.minimized:
				_win_min = item
			else:
				_win_pick = item
		items_layout.append({"title": item.title, "id": item.id, "current": current,
			"minimized": item.minimized, "screen": item.screen,
			"x": e.pos.x, "y": e.pos.y + off, "w": e.sz, "h": e.sz,
			"min_x": e.pos.x, "close_x": e.pos.x + e.sz, "hit_w": e.sz})
	_draw_window_scroll_hints(ui, items.size(), plan, Vector2(x0, y + off), float(F) * pitch, side)


# Indicadores de scroll en los bordes del tramo cuando hay más ventanas que
# capacidad: chevron + degradado tenue. La ventana enfocada se mantiene a la vista.
func _draw_window_scroll_hints(ui, n, plan, origin, width, side):
	if plan.mode != "scroll" or int(plan.scroll_max) <= 0:
		return
	var rng = plan.visible_range
	if int(rng[0]) > 0:
		_draw_chevron(ui, Rect2(origin, Vector2(side * 0.5, side)), -1.0)
	if int(rng[1]) < n:
		_draw_chevron(ui, Rect2(origin + Vector2(width - side * 0.5, 0.0), Vector2(side * 0.5, side)), 1.0)


func _draw_chevron(ui, r, dir):
	ui.imgui_draw_rect_filled(r, Color(0.0, 0.0, 0.0, 0.38), 0.0)
	var c = r.position + r.size * 0.5
	var h = r.size.x * 0.30
	var w = r.size.x * 0.32
	ui.imgui_draw_polyline(PoolVector2Array([
		c + Vector2(dir * w, -h), c + Vector2(-dir * w, 0.0), c + Vector2(dir * w, h)]),
		NX_TEXT, max(1.5, r.size.x * 0.12))


# ¿Un tramo con modo scroll? (rueda/arrastre sobre el tramo desplazan las ventanas).
func _window_scroll_mode(hit, pos):
	if not (visible or shell.current_activity == null or pin_top_bar or pin_bottom_bar):
		return false
	var zone = _zone_at(pos)
	if zone == "" or hit == null or not bar_order[zone].has(WINDOW_TOKEN):
		return false
	var plan = window_plan(running().size(), window_span.get(zone, 0), -1, window_scroll.get(zone, 0.0))
	return plan.mode == "scroll"


# Desplaza las ventanas del tramo con la rueda. Devuelve true si consumió el evento.
func _window_scroll_at(pos, dir):
	if not (visible or shell.current_activity == null or pin_top_bar or pin_bottom_bar):
		return false
	var zone = _zone_at(pos)
	if zone == "" or not bar_order[zone].has(WINDOW_TOKEN):
		return false
	if not window_region.get(zone, Rect2()).has_point(pos):
		return false
	var plan = window_plan(running().size(), window_span.get(zone, 0), -1, window_scroll.get(zone, 0.0))
	if plan.scroll_max <= 0:
		return false
	var step = int(max(1, plan.per_cell))
	window_scroll[zone] = clamp(window_scroll.get(zone, 0.0) + float(dir * step), 0.0, float(plan.scroll_max))
	shell.request_redraw()
	return true


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
	applets_layout = []
	applets_drawn = false
	# Autohide sincronizado (una señal `visible`), con pin por barra: una barra
	# fijada queda siempre a la vista; una con autohide sigue a `visible`/Home.
	# En exposé las barras se fuerzan visibles: son el borde del escritorio.
	var want_top = home or visible or pin_top_bar or shell.expose
	var want_bottom = home or visible or pin_bottom_bar or shell.expose
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
		_draw_explosions(ui)
		return
	if not top_drawn:
		# Barra superior fuera: no hay layout de ventanas en pantalla.
		items_layout = []
	if not bottom_drawn:
		applets_layout = []
		applets_drawn = false
		shared_layout = []
		shared_drawn = false

	shared_layout = []
	shared_drawn = false
	shared_menu_open = false

	# Grilla regular: MISMA `n`/`pitch` para las dos barras. Cada bloque es cuadrado
	# de lado `side` (≈ alto de barra) y la última celda alineada al borde derecho.
	var grid = bar_grid(vp.x, bh, PAD)
	bar_grid_state["top"] = grid
	bar_grid_state["dock"] = grid
	_sync_shared_token()
	var side = float(grid.side)
	var pitch = float(grid.pitch)
	var margin = float(grid.margin)
	var chosen = null
	var to_close = null
	var to_minimize = null
	_win_pick = null
	_win_close = null
	_win_min = null
	place_rects = []
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
			# Celdas fijas: 0 esquina (vacía), 1 Vecindario, 2 Grupo, 3 Hogar. Los
			# bloques de contenido arrancan en la celda 4 (`bar_base_origin`).
			for k in [1.0, 2.0, 3.0]:
				place_rects.append(Rect2(Vector2(margin + k * pitch, off_top + y), Vector2(side, side)))
			if _draw_neighborhood_tile(ui, Vector2(margin + pitch, y), side):
				set_visible(false)
				shell._go_neighborhood()
			if _draw_group_tile(ui, Vector2(margin + 2.0 * pitch, y), side):
				set_visible(false)
				shell._go_group()
			if _draw_home_tile(ui, Vector2(margin + 3.0 * pitch, y), side):
				set_visible(false)
				shell._go_home()
			_draw_bar_blocks(ui, "top", bar_base_origin("top", grid), y, grid, mouse)
			applets_drawn = true

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
			# Las teselas de ventana se dibujan en el tramo del DockApp "w:windows"
			# SIEMPRE que su token viva en esta barra (no sólo si está arriba).
			if bar_order["top"].has(WINDOW_TOKEN) and not items.empty():
				_draw_windows(ui, "top", side, y, off_top, mouse)
				_draw_window_grip(ui, "top", mouse)
			# Durante el drag viaja la tesela completa, no un label/tooltip separado.
			_draw_window_drag_tile(ui, items, side)
			# Esquina derecha reservada para el pin chico (última celda de la grilla).
			var corner_x = margin + float(grid.n - 1) * pitch
			# Pin de la barra superior: fija la franja (deja de auto-ocultarse y las
			# ventanas reservan su alto) o vuelve al autohide.
			if _draw_pin_toggle(ui, Vector2(corner_x, y), side, pin_top_bar, "pin_top"):
				toggle_pin("top")
				entered = true
			_draw_inner_shadow(ui, Vector2(0.0, off_top + bh - 1.0), vp.x, -1.0)
		ui.end()
		ui.pop_style_var()

	if bottom_drawn:
		_draw_applets(ui, vp, off_bottom, mouse, grid)
	# Lo elegido en cualquier barra (las teselas de ventana pueden vivir en la inferior).
	if _win_close != null:
		to_close = _win_close
	elif _win_min != null:
		to_minimize = _win_min
	elif _win_pick != null:
		chosen = _win_pick
	_draw_drag_tile(ui, bh)
	# El estallido va al final: su overlay (ventana ImGui sin mouse) queda por encima
	# de las barras, no tapado por su fondo.
	_draw_explosions(ui)

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
	var face = _cur() if pinned else NX_FACE.linear_interpolate(NX_LIGHT, 0.12)
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


# --- Estallido (drop en el centro del escritorio) --------------------------------
# Un bloque soltado en medio del Escritorio se quita con una expansión breve, como el
# WindowMaker clásico. La animación dura EXPLODE_MS y no captura mouse.
const EXPLODE_MS = 420.0
# ImGuiWindowFlags_NoMouseInputs (mismo valor que usa system_osd.gd): el overlay de
# estallido queda por encima sin robar clics.
const WINDOW_NO_MOUSE_INPUTS = 512
# ImGuiWindowFlags_Tooltip (1 << 25): la ventana va a la capa de display superior
# (como los tooltips) sin tomar foco. Sin esto el overlay de explosiones quedaba DEBAJO
# de las ventanas del Hogar (ImGui ordena por foco) y sólo se veía sobre el Vecindario.
const WINDOW_TOP_LAYER = 33554432


func _draw_explosions(ui):
	if explosions.empty():
		return
	var now = OS.get_ticks_msec()
	var keep = []
	for ex in explosions:
		var t = clamp(float(now - int(ex.since)) / EXPLODE_MS, 0.0, 1.0)
		if t < 1.0:
			keep.append(ex)
	if keep.size() != explosions.size():
		explosions = keep
	if keep.empty():
		return
	# Las primitivas `imgui_draw_*` DEBEN ir dentro de una ventana ImGui: fuera de
	# una caen en la ventana de debug del módulo y aparecen mal ubicadas. Overlay de
	# pantalla completa, sin fondo y sin mouse (NoMouseInputs), padding 0 para que
	# las coordenadas absolutas coincidan (mismo patrón que system_osd.gd).
	var vp = ui.get_viewport_rect().size
	ui.set_next_window_pos(Vector2.ZERO, true)
	ui.set_next_window_size(vp, true)
	ui.set_next_window_bg_alpha(0.0)
	ui.push_style_var_vec2(ui.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	var flags = ui.WINDOW_NO_DECORATION | ui.WINDOW_NO_BACKGROUND | ui.WINDOW_NO_MOVE \
		| ui.WINDOW_NO_RESIZE | ui.WINDOW_NO_SAVED_SETTINGS | ui.WINDOW_NO_SCROLLBAR \
		| ui.WINDOW_NO_TITLE_BAR | ui.WINDOW_NO_COLLAPSE \
		| ui.WINDOW_NO_BRING_TO_FRONT_ON_FOCUS | WINDOW_NO_MOUSE_INPUTS | WINDOW_TOP_LAYER
	if ui.begin("##frame_explosions", flags):
		for ex in keep:
			var t = clamp(float(now - int(ex.since)) / EXPLODE_MS, 0.0, 1.0)
			_draw_explosion(ui, ex, t)
	ui.end()
	ui.pop_style_var()
	shell.last_activity = now
	shell.request_redraw()


func _draw_explosion(ui, ex, t):
	var c = (ex.pos as Vector2) + (ex.size as Vector2) * 0.5
	var base = (ex.size as Vector2).x
	var alpha = 1.0 - t
	var r = base * (0.35 + 0.85 * t)
	ui.imgui_draw_circle(c, r, Color(1.0, 0.85, 0.45, 0.55 * alpha), 28, max(1.0, 2.5 * (1.0 - 0.5 * t)))
	ui.imgui_draw_circle(c, r * 0.7, Color(1.0, 1.0, 1.0, 0.35 * alpha), 24, 1.5)
	for i in range(6):
		var ang = TAU * float(i) / 6.0 + 0.4
		var d = base * (0.15 + 0.95 * t)
		var p = c + Vector2(cos(ang), sin(ang)) * d
		ui.imgui_draw_circle_filled(p, max(1.0, 3.0 * alpha), Color(1.0, 0.9, 0.6, 0.8 * alpha), 10)
	if ex.get("tex") != null:
		var side = base * (1.0 - 0.5 * t)
		ui.set_cursor_pos(c - Vector2(side, side) * 0.5)
		ui.image(ex.tex, Vector2(side, side))


func _draw_drag_tile(ui, side):
	if app_drag == null and applet_drag == null and not shared_drag:
		return
	ui.push_style_var_vec2(ui.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	# El tooltip por defecto se ancla en MousePos + (16,10) (+ padding): eso era el
	# corrimiento de ~20 px. Se fuerza al cursor MENOS el offset de agarre, para que
	# la tesela quede exactamente donde estaba respecto del punto que se tomó.
	var grab = app_grab if app_drag != null else (shared_grab if shared_drag else applet_grab)
	ui.set_next_window_pos(mouse_pos - grab, true)
	ui.begin_tooltip()
	var pos = Vector2.ZERO
	if app_drag != null:
		_draw_app_tile(ui, app_drag, pos, side, "drag_app")
	elif shared_drag:
		_draw_shared_tile(ui, pos, side, shared_diagram, true)
	else:
		ui.set_cursor_pos(pos)
		_draw_applet(ui, applet_drag, pos, ui.get_cursor_screen_pos(), _applet_width(applet_drag, side), side, false, Vector2(-1, -1), true)
	ui.end_tooltip()
	ui.pop_style_var()


# Fantasma de una ventana de la franja superior. Reutiliza exactamente el dibujo
# del bloque normal y conserva bajo el cursor el punto donde comenzó el gesto.
func _draw_window_drag_tile(ui, items, side):
	var ghost = null
	if dragging != null:
		for it in items:
			if it.id == dragging.id:
				ghost = it
				break
	elif lifted != null:
		ghost = lifted
	elif win_drag != null:
		for it in items:
			if it.id == win_drag.id:
				ghost = it
				break
	if ghost == null:
		return
	var grab = drag_grab if dragging != null else Vector2(side * 0.5, side * 0.5)
	ui.push_style_var_vec2(ui.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	ui.set_next_window_pos(mouse_pos - grab, true)
	ui.begin_tooltip()
	_draw_window_tile(ui, Vector2.ZERO, side, ghost, _is_current(ghost), false, false,
		Vector2(-100000.0, -100000.0))
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
		# Si la vista cambió al terminar un deslizamiento (paneo/gesto hacia o desde el
		# Hogar), ese movimiento ya fue la transición: re-fundir desde 0 hacía "flash".
		if now > int(shell.get("fade_skip_until") if shell.get("fade_skip_until") != null else 0):
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
