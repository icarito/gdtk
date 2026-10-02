extends Control

# Overlay de pantallas: en exposé, el marco de cada workspace (pantalla), la ventana
# seleccionada y el botón de cerrar. Se dibuja a mano con CanvasItem._draw y
# mouse_filter IGNORE: no le roba input a las ventanas (una ventana ImGui a pantalla
# completa sí lo haría). El fondo oscuro de exposé va aparte, detrás de los tiles
# (expose_bg), para no taparlos.

var shell

# Chrome WindowMaker (K13b): geometría/hit-test puros; acá sólo se dibuja.
const WINDOW_CHROME = preload("res://window_chrome.gd")


func _ready():
	mouse_filter = MOUSE_FILTER_IGNORE
	rect_position = Vector2.ZERO
	rect_clip_content = false


func refresh():
	update()


func _draw():
	if shell == null:
		return
	var font = get_font("font", "Label")
	if shell.expose and shell.fullscreen_id < 0:
		_draw_expose(font)
		return
	# Asas de redimensión de la franja enfocada: línea tenue en el borde y asa al pasar.
	for h in (shell.handles if shell.view.visible else []):
		draw_line(Vector2(h.x, h.y), Vector2(h.x, h.y + h.h), Color(1, 1, 1, 0.05), 1.0)
	if shell.hover_handle != null and shell.view.visible:
		var h = shell.hover_handle
		var cy = h.y + h.h * 0.5
		draw_line(Vector2(h.x, h.y + h.h * 0.2), Vector2(h.x, h.y + h.h * 0.8), Color(0.26, 0.59, 0.98, 0.85), 2.0)
		draw_rect(Rect2(h.x - 4.0, cy - 16.0, 8.0, 32.0), Color(0.26, 0.59, 0.98, 0.9))
		for k in range(3):
			draw_circle(Vector2(h.x, cy - 7.0 + float(k) * 7.0), 1.3, Color(1, 1, 1, 0.95))
	# K13: barra de título y botones de las ventanas flotantes (WindowMaker). Se
	# dibuja encima del contenido del cliente en el marco exterior.
	if shell.is_floating() and shell.view.visible and shell.fullscreen_id < 0:
		_draw_chrome(font)
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
		draw_polyline(pts, Color(0.4, 0.7, 1.0, 0.95), 2.0)
		if font != null:
			var title = shell.compositor.get_title(id)
			if title == "":
				title = shell._activity_for_window(id)
			if title != "":
				var w = font.get_string_size(title).x
				draw_string(font, c + Vector2(-w * 0.5, rad + 20.0), title, Color(1, 1, 1, 0.85))


# Exposé como "zoom out": un marco por workspace con su número (índice/total), el
# borde tenue de cada ventana no seleccionada y el botón de cerrar sobre la ventana
# bajo el puntero. La selección no usa borde azul: la marca el propio shell escalando
# y aclarando un poco la ventana (ver _update_tile). Todos los workspaces están en
# pantalla a la vez.
func _draw_expose(font):
	var units = shell._units()
	var n = units.size()
	var sel_id = -1
	if shell.expose_sel >= 0 and shell.expose_sel < shell.tiles.size():
		sel_id = shell.tiles[shell.expose_sel]
	for i in range(n):
		if i >= shell.expose_unit_cards.size():
			break
		var frame = shell.expose_unit_cards[i]
		var on = units[i].has(sel_id)
		draw_rect(frame, Color(1, 1, 1, 0.22 if on else 0.12), false, 1.5 if on else 1.0)
		for id in units[i]:
			var r = shell.expose_cards.get(id)
			if r == null:
				continue
			if id != sel_id:
				draw_rect(r, Color(0, 0, 0, 0.45), false, 1.0)
		if font != null:
			var label = "%d/%d" % [i + 1, n]
			var col = Color(1, 1, 1, 0.55) if on else Color(1, 1, 1, 0.30)
			var lw = font.get_string_size(label).x
			draw_string(font, Vector2(frame.position.x + frame.size.x * 0.5 - lw * 0.5,
				frame.position.y + frame.size.y + 16.0), label, col)
	# Botón de cerrar: en la ventana seleccionada y en la que está bajo el puntero.
	for id in [sel_id, shell.expose_hover]:
		if id < 0:
			continue
		var cr = shell._expose_close_rect(id)
		if cr != null:
			_draw_close_glyph(cr)


func _draw_close_glyph(cr):
	draw_rect(cr, Color(0.06, 0.07, 0.10, 0.94))
	draw_rect(cr, Color(1, 1, 1, 0.22), false, 1.0)
	var p = cr.position + cr.size * 0.30
	var q = cr.position + cr.size * 0.70
	var col = Color(1.0, 0.84, 0.82, 0.96)
	draw_line(p, q, col, 1.6)
	draw_line(Vector2(q.x, p.y), Vector2(p.x, q.y), col, 1.6)


# --- K13b: chrome WindowMaker de las ventanas flotantes ----------------------

func _draw_chrome(font):
	var ids = shell.float_layout.ids_z()
	for id in shell.tiles:
		if not ids.has(id):
			ids.append(id)
	var th = shell._chrome_title_h()
	var bd = shell._chrome_border()
	var mouse = get_local_mouse_position()
	for id in ids:
		if id == shell.fullscreen_id or not shell.tiles.has(id):
			continue
		# Con la entrada/zoom (escala) el marco se desalinearía; se dibuja al asentar.
		if shell.tile_intro.has(id) or shell.view_anim.has(id):
			continue
		var node = shell.tile_nodes.get(id)
		if node == null or not is_instance_valid(node) or not node.visible:
			continue
		var content = Rect2(node.rect_position, node.rect_size)
		if content.size.x < 6.0 or content.size.y < 6.0:
			continue
		# El marco exterior va del contenido real (en animación incluida) hacia arriba.
		var fr = Rect2(content.position - Vector2(bd, th), content.size + Vector2(2.0 * bd, th + bd))
		_draw_window_frame(font, fr, id, id == shell.focused_tile, mouse, th, bd)


func _draw_window_frame(font, fr, id, active, mouse, th, bd):
	var face = Color(0.72, 0.72, 0.75)
	var light = Color(0.96, 0.96, 0.96)
	var dark = Color(0.32, 0.32, 0.35)
	var title_col = Color(0.24, 0.32, 0.62) if active else Color(0.42, 0.42, 0.55)
	_bevel(fr, face, light, dark, bd)
	var p = WINDOW_CHROME.parts(fr, th, bd)
	_bevel(p.title, title_col, light, dark, max(1.0, bd * 0.5))
	if font != null:
		var label = shell.compositor.get_title(id)
		if label == "":
			label = shell._activity_for_window(id)
		_draw_title_text(font, p.title, String(label))
	_draw_button_glyph(p.min_btn, "min", mouse)
	_draw_button_glyph(p.close_btn, "close", mouse)
	if active:
		draw_rect(fr, Color(0.55, 0.80, 1.0, 0.9), false, 1.0)


func _draw_title_text(font, bar, label):
	if label == "":
		return
	var btn = WINDOW_CHROME.BTN * shell.get_imgui_scale()
	var avail = max(bar.size.x - 2.0 * btn - 12.0, 8.0)
	var text = label
	while text.length() > 1 and font.get_string_size(text).x > avail:
		text = text.substr(0, text.length() - 1)
	if text.length() < label.length() and text.length() > 1:
		text = text.substr(0, text.length() - 1) + "…"
	var tw = font.get_string_size(text).x
	var tp = Vector2(bar.position.x + (bar.size.x - tw) * 0.5,
		bar.position.y + (bar.size.y - font.get_height()) * 0.5)
	draw_string(font, tp, text, Color(0.97, 0.97, 1.0))


func _draw_button_glyph(rect, kind, mouse):
	var hover = rect.has_point(mouse)
	_bevel(rect, Color(0.78, 0.79, 0.84) if hover else Color(0.72, 0.72, 0.75),
		Color(0.96, 0.96, 0.96), Color(0.32, 0.32, 0.35), 1.0)
	var col = Color(0.06, 0.06, 0.08)
	if kind == "close":
		var a = rect.position + rect.size * 0.28
		var b = rect.end - rect.size * 0.28
		draw_line(a, b, col, 1.6)
		draw_line(Vector2(b.x, a.y), Vector2(a.x, b.y), col, 1.6)
	else:
		var y = rect.position.y + rect.size.y * 0.5
		draw_line(Vector2(rect.position.x + rect.size.x * 0.25, y),
			Vector2(rect.end.x - rect.size.x * 0.25, y), col, 1.6)


func _bevel(r, face, light, dark, b):
	draw_rect(r, face)
	draw_rect(Rect2(r.position, Vector2(r.size.x, b)), light)
	draw_rect(Rect2(r.position, Vector2(b, r.size.y)), light)
	draw_rect(Rect2(Vector2(r.position.x, r.end.y - b), Vector2(r.size.x, b)), dark)
	draw_rect(Rect2(Vector2(r.end.x - b, r.position.y), Vector2(b, r.size.y)), dark)

