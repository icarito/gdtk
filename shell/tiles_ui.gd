extends Control

# Overlay de pantallas: en exposé, el marco de cada workspace (pantalla), la ventana
# seleccionada y el botón de cerrar. Se dibuja a mano con CanvasItem._draw y
# mouse_filter IGNORE: no le roba input a las ventanas (una ventana ImGui a pantalla
# completa sí lo haría). El fondo oscuro de exposé va aparte, detrás de los tiles
# (expose_bg), para no taparlos.
#
# La decoración (barra de título OpenStep) de las ventanas flotantes NO vive acá:
# cada ventana tiene su propio nodo window_deco.gd intercalado en `view`, para que
# el z-order de las decoraciones siga al de las ventanas.

var shell

# Sombra "drop" del fantasma de arrastre (la de las miniaturas vive en expose_bg): misma receta que window_deco._draw_shadow
# (StyleBoxFlat con sombra nativa, barato en GLES2). Se arma acá porque
# draw_style_box sólo dibuja en la fase _draw() del propio nodo.
var _thumb_shadow_sb = null

const EXPOSE_FRAME_INSET = 3.0


func _ready():
	mouse_filter = MOUSE_FILTER_IGNORE
	rect_position = Vector2.ZERO
	rect_clip_content = false


func refresh():
	update()


# Acento del shell con alfa a (settings_bridge → shell.accent).
func _acc(a):
	var c = shell.accent if shell != null and shell.accent != null else Color(0.55, 0.80, 1.0)
	return Color(c.r, c.g, c.b, a)


func _draw():
	if shell == null:
		return
	var font = get_font("font", "Label")
	if shell.expose and shell.fullscreen_id < 0:
		_draw_expose(font)
		return
	# Asas de redimensión de la franja enfocada: línea tenue del acento en el borde y
	# asa resaltada al pasar (todo con el accent del shell).
	var fr = shell.float_frames()
	for h in (shell.handles if shell.view.visible else []):
		# La línea se corta donde una flotante la tapa (tiles_ui dibuja sobre `view`).
		var segs = [[h.y, h.y + h.h]]
		for r in fr:
			if h.x < r.position.x or h.x > r.position.x + r.size.x:
				continue
			var nxt = []
			for sg in segs:
				if r.position.y > sg[0]:
					nxt.append([sg[0], min(sg[1], r.position.y)])
				if r.position.y + r.size.y < sg[1]:
					nxt.append([max(sg[0], r.position.y + r.size.y), sg[1]])
			segs = nxt
		for sg in segs:
			if sg[1] > sg[0]:
				draw_line(Vector2(h.x, sg[0]), Vector2(h.x, sg[1]), _acc(0.12), 1.0)
	if shell.hover_handle != null and shell.view.visible:
		var h = shell.hover_handle
		var cy = h.y + h.h * 0.5
		draw_line(Vector2(h.x, h.y + h.h * 0.2), Vector2(h.x, h.y + h.h * 0.8), _acc(0.85), 2.0)
		draw_rect(Rect2(h.x - 4.0, cy - 16.0, 8.0, 32.0), _acc(0.9))
		for k in range(3):
			draw_circle(Vector2(h.x, cy - 7.0 + float(k) * 7.0), 1.3, Color(1, 1, 1, 0.95))
	# Pedido de atención (xdg-activation): contorno pulsante sobre cada tesela en
	# atención, sin cambiar el foco (SPEC-notificaciones).
	if shell.notify != null and shell.view.visible:
		var pa = shell.notify.pulse_alpha()
		for id in shell.notify.attention_ids():
			var node = shell.tile_nodes.get(id)
			if node == null or not is_instance_valid(node) or not node.visible:
				continue
			var r = shell._node_footprint(node)
			var col = _acc(0.30 + 0.60 * pa)
			draw_rect(r.grow(4.0), col, false, 2.5)
	# Resize diferido: mientras se arrastra un borde sólo se ve este fantasma (la
	# ventana real no se redimensiona hasta soltar). Sin input: tiles_ui es IGNORE.
	if shell.drag_overlay != null:
		_draw_drag_overlay(shell.drag_overlay)
	# Placeholder de las ventanas que todavía no tienen textura: rect + spinner + título,
	# en el rect animado de la entrada (escala desde el ícono).
	for id in shell.tile_intro.keys():
		var info = shell.tile_intro[id]
		if info.get("ready", false):
			continue
		var r = info.get("rect")
		if r == null or r.size.x < 2.0 or r.size.y < 2.0:
			continue
		draw_rect(r, Color(0.09, 0.09, 0.11, 0.94))
		draw_rect(r, Color(1, 1, 1, 0.10), false, 1.0)
		var c = r.position + r.size * 0.5
		var rad = clamp(min(r.size.x, r.size.y) * 0.16, 6.0, 16.0)
		var a0 = -PI * 0.5 + float(OS.get_ticks_msec() % 1000) / 1000.0 * TAU
		var pts = PoolVector2Array()
		for i in range(17):
			var a = a0 + TAU * 0.72 * float(i) / 16.0
			pts.append(c + Vector2(cos(a), sin(a)) * rad)
		draw_polyline(pts, _acc(0.95), 2.0)
		if font != null:
			var title = shell.window_title(id) if shell.has_method("window_title") \
				else shell.compositor.get_title(id)
			if title == "":
				title = shell._activity_for_window(id)
			if title != "":
				var w = font.get_string_size(title).x
				draw_string(font, c + Vector2(-w * 0.5, rad + 20.0 + font.get_ascent()), title, Color(1, 1, 1, 0.85))


# Exposé como "zoom out": un marco por workspace con su número (índice/total), el
# borde tenue de cada ventana no seleccionada y el botón de cerrar sobre la ventana
# bajo el puntero. La selección no usa borde azul: la marca el propio shell escalando
# y aclarando un poco la ventana (ver _update_tile). Todos los workspaces están en
# pantalla a la vez.
func _draw_expose(font):
	var units = shell.expose_units if shell.expose_units != null else []
	var n = units.size()
	var sel_id = -1
	if shell.expose_sel >= 0 and shell.expose_sel < shell.tiles.size():
		sel_id = shell.tiles[shell.expose_sel]
	# Ranura destino del arrastre entre escritorios: relleno y borde con el acento
	# (no se marca el escritorio de origen).
	if shell.expose_drag != null and shell.expose_drag_target >= 0 \
			and shell.expose_drag_target < shell.expose_unit_cards.size() \
			and shell.expose_drag_target != shell._expose_index_of_window(shell.expose_drag.id):
		var tf = shell.expose_unit_cards[shell.expose_drag_target].grow(-EXPOSE_FRAME_INSET)
		draw_rect(tf, _acc(0.16))
		draw_rect(tf, _acc(0.92), false, 2.0)
	# Hueco de inserción bajo el cursor: barra vertical con el acento. Al soltar se crea
	# un escritorio NUEVO en esa posición con la miniatura arrastrada.
	if shell.expose_drag != null and shell.expose_drag_gap >= 0:
		var bar = shell._expose_gap_bar_rect(shell.expose_drag_gap)
		if bar != null:
			draw_rect(bar.grow(2.0), _acc(0.35))
			draw_rect(bar, _acc(0.95))
	# Todas las unidades visibles tienen contenido (no hay ranura vacía): numerado 1..n.
	for i in range(n):
		if i >= shell.expose_unit_cards.size():
			break
		for id in units[i]:
			var r = shell.expose_cards.get(id)
			if r == null:
				continue
			# Borde en lo que se ve (sigue a la ventana en vuelo, no la espera).
			var node = shell.tile_nodes.get(id)
			if node != null and is_instance_valid(node) and node.visible:
				r = shell._node_footprint(node)
			if id != sel_id:
				draw_rect(r, Color(0, 0, 0, 0.45), false, 1.0)
	# Miniatura arrastrada: sigue al puntero con su forma actual y sombra propia.
	if shell.expose_drag != null and sel_id >= 0:
		var card = shell.expose_cards.get(sel_id)
		# Con el tamaño que tendrá al soltar (ver shell._expose_drag_card).
		var dc = shell._expose_drag_card(sel_id)
		if card != null:
			var gr = dc.card if dc != null else Rect2(shell.expose_drag.pos - shell.expose_drag.grab, card.size)
			_draw_thumb_shadow(gr, true)
			draw_rect(gr, Color(1, 1, 1, 0.10))
			draw_rect(gr, _acc(0.95), false, 2.0)
	# Botón de cerrar: en la ventana seleccionada y en la que está bajo el puntero.
	for id in [sel_id, shell.expose_hover]:
		if id < 0:
			continue
		var cr = shell._expose_close_rect(id)
		if cr != null:
			_draw_close_glyph(cr)


# Sombra "drop" del fantasma (window_deco._draw_shadow no puede dibujar fuera de
# su propio _draw, así que se repite la receta acá). No pinta el centro.
func _draw_thumb_shadow(r, focused):
	if r.size.x < 6.0 or r.size.y < 6.0:
		return
	if _thumb_shadow_sb == null:
		_thumb_shadow_sb = StyleBoxFlat.new()
		_thumb_shadow_sb.draw_center = false
		_thumb_shadow_sb.bg_color = Color(0, 0, 0, 0)
	_thumb_shadow_sb.set_corner_radius_all(7)
	_thumb_shadow_sb.shadow_size = 16 if focused else 10
	_thumb_shadow_sb.shadow_color = Color(0.0, 0.0, 0.0, 0.26 if focused else 0.16)
	_thumb_shadow_sb.shadow_offset = Vector2(0.0, 4.0 if focused else 2.5)
	draw_style_box(_thumb_shadow_sb, r)


func _draw_close_glyph(cr):
	draw_rect(cr, Color(0.06, 0.07, 0.10, 0.94))
	draw_rect(cr, Color(1, 1, 1, 0.22), false, 1.0)
	var p = cr.position + cr.size * 0.30
	var q = cr.position + cr.size * 0.70
	var col = Color(1.0, 0.84, 0.82, 0.96)
	draw_line(p, q, col, 1.6)
	draw_line(Vector2(q.x, p.y), Vector2(p.x, q.y), col, 1.6)


# Fantasma del resize diferido: relleno tenue + borde y una franja de título, para
# ver la geometría objetivo sin que la app reasigne buffer en cada motion.
# K13f — cuando kind="snap" es la propuesta de snap flotante: la franja del hueco
# (mitad o completo) con el acento del shell y una etiqueta de destino.
func _draw_drag_overlay(info):
	var r = info.get("rect")
	if r == null:
		return
	var rr = Rect2(r)
	if rr.size.x < 2.0 or rr.size.y < 2.0:
		return
	if String(info.get("kind", "resize")) == "snap":
		var accent = shell.accent if shell.accent != null else Color(0.55, 0.80, 1.0)
		var fill = Color(accent.r, accent.g, accent.b, 0.16)
		var line = Color(accent.r, accent.g, accent.b, 0.92)
		draw_rect(rr, fill)
		draw_rect(rr, line, false, 2.0)
		var font = get_font("font", "Label")
		if font != null:
			var zone = String(info.get("zone", ""))
			var target = String(info.get("target", "float-half"))
			var label = ""
			if zone == "max" or target == "maximize":
				label = "Maximizar"
			elif target == "tile-half":
				label = "Mosaico · mitad izquierda" if zone == "left" else "Mosaico · mitad derecha"
			else:
				label = "Mitad izquierda" if zone == "left" else "Mitad derecha"
			if label != "":
				var lw = font.get_string_size(label).x
				draw_string(font, Vector2(rr.position.x + (rr.size.x - lw) * 0.5,
					rr.position.y + rr.size.y * 0.5 + font.get_ascent()),
					label, Color(0.94, 0.97, 1.0, 0.95))
		return
	draw_rect(rr, _acc(0.14))
	draw_rect(rr, _acc(0.95), false, 2.0)
	var th = shell._chrome_title_h()
	if rr.size.y > th + 4.0:
		draw_rect(Rect2(rr.position + Vector2(2, 2), Vector2(rr.size.x - 4.0, th)),
			_acc(0.22))
	var font = get_font("font", "Label")
	if font != null:
		var label = "%d × %d" % [int(round(rr.size.x)), int(round(rr.size.y))]
		var lw = font.get_string_size(label).x
		draw_string(font, Vector2(rr.position.x + (rr.size.x - lw) * 0.5,
			rr.position.y + rr.size.y * 0.5 + font.get_ascent()),
			label, Color(0.92, 0.96, 1.0, 0.95))
