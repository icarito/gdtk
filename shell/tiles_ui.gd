extends Control

# Overlay de pantallas: en exposé, el marco de cada workspace (pantalla), la ventana
# seleccionada y el botón de cerrar. Se dibuja a mano con CanvasItem._draw y
# mouse_filter IGNORE: no le roba input a las ventanas (una ventana ImGui a pantalla
# completa sí lo haría). El fondo oscuro de exposé va aparte, detrás de los tiles
# (expose_bg), para no taparlos.

var shell


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
# borde de cada ventana (resaltando la seleccionada) y el botón de cerrar sobre la
# ventana bajo el puntero. Todos los workspaces están en pantalla a la vez.
func _draw_expose(font):
	var units = shell._units()
	var n = units.size()
	var sel_id = -1
	if shell.expose_sel >= 0 and shell.expose_sel < shell.tiles.size():
		sel_id = shell.tiles[shell.expose_sel]
	var blue = Color(0.26, 0.59, 0.98, 1.0)
	for i in range(n):
		if i >= shell.expose_unit_cards.size():
			break
		var frame = shell.expose_unit_cards[i]
		var on = units[i].has(sel_id)
		draw_rect(frame, blue if on else Color(1, 1, 1, 0.16), false, 2.0 if on else 1.0)
		for id in units[i]:
			var r = shell.expose_cards.get(id)
			if r == null:
				continue
			if id == sel_id:
				draw_rect(r, blue, false, 3.0)
			else:
				draw_rect(r, Color(0, 0, 0, 0.45), false, 1.0)
		if font != null:
			var label = "%d/%d" % [i + 1, n]
			var col = blue if on else Color(1, 1, 1, 0.30)
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
