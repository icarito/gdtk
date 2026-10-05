extends Control

# K13e — Capa de decoración OpenStep/WindowMaker de UNA ventana flotante.
#
# Un nodo por ventana, intercalado en `view` justo ENCIMA del contenido de esa
# ventana (ver shell._compute_float_layout). Así el z-order de las decoraciones
# sigue al de las ventanas: la decoración de una ventana inferior queda debajo del
# contenido de la de arriba, en vez de taparlo (el bug de antes, cuando todas las
# decoraciones vivían en un único overlay por encima de todo).
#
# Dibuja: borde de 1 px, barra de título alta con título centrado, botones
# cuadrados full-height (minimizar/cerrar) y barra inferior con asa diagonal.
# El modelo de geometría/hit-test vive en window_chrome.gd (puro y testeable).

const WINDOW_CHROME = preload("res://window_chrome.gd")

# Paleta OpenStep/WindowMaker: marco gris, título oscuro activo / gris claro
# inactivo, texto blanco u oscuro, botones grises con bisel y asa diagonal.
var _shadow_layers = []   # StyleBoxFlat cacheados: sombra suave por capas

const BORDER_COL = Color(0.07, 0.07, 0.09)
const FACE = Color(0.72, 0.72, 0.75)
const LIGHT = Color(0.94, 0.94, 0.96)
const DARK = Color(0.24, 0.24, 0.27)
const TITLE_ACTIVE = Color(0.19, 0.21, 0.27)
const TITLE_INACTIVE = Color(0.62, 0.62, 0.66)
const TITLE_EDGE_ACTIVE = Color(0.42, 0.46, 0.58)
const TITLE_EDGE_INACTIVE = Color(0.80, 0.80, 0.83)
const TEXT_ACTIVE = Color(0.98, 0.98, 1.0)
const TEXT_INACTIVE = Color(0.10, 0.10, 0.12)
const BTN_FACE = Color(0.74, 0.74, 0.77)
const BTN_HOVER = Color(0.84, 0.84, 0.88)
const BTN_LIGHT = Color(0.97, 0.97, 0.99)
const BTN_DARK = Color(0.30, 0.30, 0.33)
const GLYPH = Color(0.06, 0.06, 0.08)

var shell = null
var id = -1


func _ready():
	mouse_filter = MOUSE_FILTER_IGNORE
	rect_clip_content = false
	rect_position = Vector2.ZERO


func refresh(view_size):
	rect_size = view_size
	update()


func _draw():
	if shell == null or id < 0 or not shell.tiles.has(id):
		return
	if not shell.is_floating(id) or not shell.view.visible or shell.fullscreen_id == id:
		# Excepción: durante la transición de modo el chrome sigue dibujándose (con
		# fade vía modulate) aunque el destino sea el mosaico, para que no salte.
		if not shell.wm_anim.has(id):
			return
		if not shell.view.visible or shell.fullscreen_id == id:
			return
	# El cliente dibuja su propia decoración (GTK4/CSD): sólo pill de mover y asas.
	var csd = shell._is_csd(id)
	# En exposé la miniatura basta: el chrome del shell (no CSD) no se dibuja.
	if shell.expose and not csd:
		return
	# Con la entrada/zoom (escala) el marco se desalinearía; se dibuja al asentar.
	if shell.tile_intro.has(id) or shell.view_anim.has(id):
		return
	var node = shell.tile_nodes.get(id)
	if node == null or not is_instance_valid(node) or not node.visible:
		return
	# Rect visual del contenido: durante la transición de modo el nodo lleva
	# rect_scale != 1, y el chrome debe seguir esa escala para no desalinearse ni
	# tapar el contenido (se dibuja sólo el marco/barra, nunca el área del cliente).
	var content = Rect2(node.rect_position, node.rect_size * node.rect_scale)
	if content.size.x < 6.0 or content.size.y < 6.0:
		return
	# En exposé el nodo va escalado a su miniatura: el chrome (barras, botones y
	# sombra) acompaña esa escala para no dibujarse gigante sobre la tarjeta.
	var node_scale = max(node.rect_scale.x, 0.01)
	var scale = shell.get_imgui_scale() * node_scale
	var maximized = shell.wm_maximized.has(id) or shell.maximize_state.has(id)
	if csd:
		# La sombra va antes de los early return del CSD (allí no hay chrome):
		# una ventana CSD sigue flotando y también lleva su sombra de compositor.
		if not maximized:
			_draw_shadow(content, scale, id == shell.focused_tile, true)
		_draw_peer_outline(content, scale)
		# El asa de mover se dibuja con el puntero encima y también mientras se
		# repliega (animación de salida). En maximizadas queda DENTRO del borde
		# superior, sin animación de subida (arriba no hay hueco): el cliente CSD
		# que no arrastra su barra (Electron) necesita el asa del shell para salir.
		var reveal = 0.0
		if shell.csd_grip_show_id == id:
			reveal = shell.csd_grip_reveal
		if maximized:
			if shell.csd_hover_id != id:
				return
			_draw_csd(content, scale, id == shell.focused_tile, 1.0, false, true)
			return
		if shell.csd_hover_id != id and reveal <= 0.001:
			return
		_draw_csd(content, scale, id == shell.focused_tile, reveal, shell.csd_hover_id == id)
		return
	var th = shell._chrome_title_h() * node_scale
	var bd = shell._chrome_border() * node_scale
	var rh = shell._chrome_resize_h() * node_scale
	# El marco exterior va del contenido real hacia afuera: borde arriba/abajo e
	# izquierda/derecha + barra de título + barra inferior de redimensión.
	var fr = Rect2(content.position - Vector2(bd, th + bd),
		content.size + Vector2(2.0 * bd, th + rh + 2.0 * bd))
	# Sombra del compositor detrás del marco completo (no en maximizadas: la
	# ventana ocupa todo el hueco y el halo sangraría sobre las barras del Frame).
	if not maximized:
		_draw_shadow(fr, scale, id == shell.focused_tile)
	var p = WINDOW_CHROME.parts(fr, th, bd, WINDOW_CHROME.BTN * scale, WINDOW_CHROME.BTN_MARGIN, rh)
	var active = id == shell.focused_tile
	_draw_frame(p, active, bd)
	_draw_peer_outline(fr, scale)
	_draw_buttons(p)
	_draw_grip(p.resize, scale)
	var font = get_font("font", "Label")
	if font != null:
		var label = shell.window_title(id) if shell.has_method("window_title") \
			else shell.compositor.get_title(id)
		if label == "":
			label = shell._activity_for_window(id)
		_draw_title(font, p, String(label), active, scale)


# CSD: asa de mover (pastilla del acento con puntos de agarre, como el asa de
# fronteras tiled) que se desliza desde detrás de la ventana, y franja inferior de
# redimensión. El asa se dibuja con el puntero encima o mientras se repliega; la
# franja inferior sólo con el puntero encima (shell.csd_hover_id). Con `inside`
# (maximizada) el asa queda dentro del borde superior y no se recorta.
# Ventana que llega de otro equipo (gvd): marco con el acento de ese equipo, para
# que se distinga de un vistazo de las ventanas locales.
func _draw_peer_outline(rect, scale):
	var acc = shell.window_peer_accent(id) if shell.has_method("window_peer_accent") else null
	if acc == null:
		return
	var w = max(2.0, 3.0 * scale)
	draw_rect(rect.grow(w * 0.5), acc, false, w)


func _draw_csd(rect, scale, active, reveal = 1.0, hovered = true, inside = false):
	var base = shell.accent if shell.accent != null else Color(0.55, 0.80, 1.0)
	var peer = shell.window_peer_accent(id) if shell.has_method("window_peer_accent") else null
	if peer != null:
		base = peer
	var col = Color(base.r, base.g, base.b, 0.94 if active else 0.55)
	var g = WINDOW_CHROME.move_grip_rect(rect, scale, reveal, shell.grid_unit(shell.get_viewport_rect().size), inside)
	var v = g if inside else WINDOW_CHROME.reveal_clip(g, rect.position.y)
	if v.size.x > 0.0 and v.size.y > 0.0:
		draw_rect(v.grow(max(1.0, scale)), Color(0.05, 0.06, 0.10, 0.55))
		draw_rect(v, col)
		# Puntos de agarre centrados en la parte ya emergida: suben con el asa.
		var cy = v.position.y + v.size.y * 0.5
		var step = g.size.x / float(WINDOW_CHROME.MOVE_GRIP_DOTS + 1)
		var dot = max(1.0, 1.4 * scale)
		for k in range(WINDOW_CHROME.MOVE_GRIP_DOTS):
			draw_circle(Vector2(g.position.x + step * float(k + 1), cy), dot, Color(1, 1, 1, 0.95))
	if hovered:
		var h = 3.0 * scale
		draw_rect(Rect2(Vector2(rect.position.x, rect.end.y - h), Vector2(rect.size.x, h)), col)


# Sombra "drop" de compositor detrás de la ventana: capas de StyleBoxFlat con
# esquinas redondeadas, alpha bajo y un desplazamiento vertical leve. Varias capas
# con blur creciente y alpha decreciente dan un degradado más suave que una sola
# sombra dura; el centro no se dibuja para no tapar el contenido.
func _draw_shadow(rect, scale, focused, csd = false):
	var base = 0.11 if focused else 0.075
	var radii = [8.0, 10.0, 12.0]
	var blurs = [7.0, 11.0, 15.0]
	var fades = [1.0, 0.55, 0.28]
	var drop = [2.0, 2.6, 3.2]
	if csd:
		# La sombra de StyleBoxFlat rellena también bajo la ventana: con esquinas CSD
		# redondeadas (GTK/libadwaita ~12 px) asomaba una cuña cuadrada. Radio mayor
		# que el del cliente y casi sin corrimiento en la capa nítida.
		radii = [14.0, 15.0, 16.0]
		drop = [0.0, 1.0, 1.8]
	for i in range(3):
		var sb = _shadow_layer(i)
		sb.set_corner_radius_all(int(radii[i] * scale))
		sb.shadow_size = int(blurs[i] * scale)
		sb.shadow_color = Color(0.0, 0.0, 0.0, base * fades[i])
		sb.shadow_offset = Vector2(0.0, drop[i] * scale)
		draw_style_box(sb, rect)


func _shadow_layer(i):
	while _shadow_layers.size() <= i:
		var sb = StyleBoxFlat.new()
		sb.draw_center = false
		sb.bg_color = Color(0, 0, 0, 0)
		_shadow_layers.append(sb)
	return _shadow_layers[i]


# Marco: borde de 1 px + barra de título con borde/relieve plano + barra inferior.
# Nunca pinta el área del cliente (queda libre para la textura de la app).
func _draw_frame(p, active, bd):
	var fr = p.frame
	# Borde exterior.
	draw_rect(Rect2(fr.position, Vector2(fr.size.x, bd)), BORDER_COL)
	draw_rect(Rect2(Vector2(fr.position.x, fr.end.y - bd), Vector2(fr.size.x, bd)), BORDER_COL)
	draw_rect(Rect2(fr.position, Vector2(bd, fr.size.y)), BORDER_COL)
	draw_rect(Rect2(Vector2(fr.end.x - bd, fr.position.y), Vector2(bd, fr.size.y)), BORDER_COL)
	# Barra de título.
	if p.title.size.x > 0.0 and p.title.size.y > 0.0:
		draw_rect(p.title, TITLE_ACTIVE if active else TITLE_INACTIVE)
		draw_rect(Rect2(p.title.position, Vector2(p.title.size.x, bd)),
			TITLE_EDGE_ACTIVE if active else TITLE_EDGE_INACTIVE)
		draw_rect(Rect2(Vector2(p.title.position.x, p.title.end.y - bd), Vector2(p.title.size.x, bd)), DARK)
	# Barra inferior de redimensión.
	if p.resize.size.x > 0.0 and p.resize.size.y > 0.0:
		draw_rect(p.resize, FACE)
		draw_rect(Rect2(p.resize.position, Vector2(p.resize.size.x, bd)), LIGHT)
		draw_rect(Rect2(Vector2(p.resize.position.x, p.resize.end.y - bd), Vector2(p.resize.size.x, bd)), DARK)
	else:
		# Sin barra inferior (por si el alto es mínimo): al menos el borde de cierre.
		draw_rect(Rect2(Vector2(fr.position.x, p.content.end.y), Vector2(fr.size.x, bd)), LIGHT)


# Botones cuadrados que usan todo el alto de la barra, pegados a las esquinas.
func _draw_buttons(p):
	var mouse = get_local_mouse_position()
	_draw_button(p.min_btn, "min", mouse)
	_draw_button(p.close_btn, "close", mouse)


func _draw_button(rect, kind, mouse):
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var scale = shell.get_imgui_scale()
	var b = max(1.0, 1.0 * scale)
	draw_rect(rect, BTN_HOVER if rect.has_point(mouse) else BTN_FACE)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, b)), BTN_LIGHT)
	draw_rect(Rect2(rect.position, Vector2(b, rect.size.y)), BTN_LIGHT)
	draw_rect(Rect2(Vector2(rect.position.x, rect.end.y - b), Vector2(rect.size.x, b)), BTN_DARK)
	draw_rect(Rect2(Vector2(rect.end.x - b, rect.position.y), Vector2(b, rect.size.y)), BTN_DARK)
	var w = max(1.5, 1.5 * scale)
	if kind == "close":
		var a = rect.position + rect.size * 0.28
		var c = rect.end - rect.size * 0.28
		draw_line(a, c, GLYPH, w)
		draw_line(Vector2(c.x, a.y), Vector2(a.x, c.y), GLYPH, w)
	else:
		var y = rect.position.y + rect.size.y * 0.5
		draw_line(Vector2(rect.position.x + rect.size.x * 0.24, y),
			Vector2(rect.end.x - rect.size.x * 0.24, y), GLYPH, w)


# Asa diagonal de la esquina inferior derecha (dentro de la barra inferior).
func _draw_grip(r, scale):
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	var dark = Color(0.30, 0.30, 0.33)
	var light = Color(0.95, 0.95, 0.97)
	var step = 3.0 * scale
	var m = 2.0 * scale
	var lw = max(1.0, scale)
	for k in range(4):
		var x0 = r.end.x - m - float(k) * step
		var y0 = r.end.y - m
		var x1 = r.end.x - m
		var y1 = r.end.y - m - float(k) * step
		draw_line(Vector2(x0, y0), Vector2(x1, y1), dark, lw)
		draw_line(Vector2(x0 - lw, y0), Vector2(x1, y1 - lw), light, lw)


# Título centrado horizontal y verticalmente. `draw_string` usa la línea base:
# baseline = centro + (ascendente - descendente) / 2 (antes se trataba como
# top-left y el texto quedaba pegado arriba).
func _draw_title(font, p, label, active, scale):
	if label == "":
		return
	var bar = p.title
	var avail = max(bar.size.x - p.min_btn.size.x - p.close_btn.size.x - 12.0 * scale, 8.0)
	var text = label
	while text.length() > 1 and font.get_string_size(text).x > avail:
		text = text.substr(0, text.length() - 1)
	if text.length() < label.length() and text.length() > 1:
		text = text.substr(0, text.length() - 1) + "…"
	var tw = font.get_string_size(text).x
	var baseline = bar.position.y + (bar.size.y + font.get_ascent() - font.get_descent()) * 0.5
	draw_string(font, Vector2(bar.position.x + (bar.size.x - tw) * 0.5, baseline),
		text, TEXT_ACTIVE if active else TEXT_INACTIVE)
