extends Control

# Overlay de pantallas: en exposé, el borde de la tarjeta seleccionada; y en una
# pantalla partida, el borde de la mitad enfocada. Se dibuja a mano con
# CanvasItem._draw y mouse_filter IGNORE: no le roba input a las ventanas (una
# ventana ImGui a pantalla completa sí lo haría). El fondo oscuro de exposé va
# aparte, detrás de los tiles (expose_bg), para no taparlos.

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
	for id in shell.tiles:
		var r = shell.expose_cards.get(id) if shell.expose else shell.tile_rects.get(id)
		if r == null:
			continue
		if shell.expose:
			if shell.tiles.find(id) == shell.expose_sel:
				draw_rect(r, Color(0.26, 0.59, 0.98, 1.0), false, 3.0)
			else:
				draw_rect(r, Color(0, 0, 0, 0.45), false, 1.0)
		elif id == shell.focused_tile and shell._unit_members(id).size() > 1:
			# Borde sólo en pantallas partidas: indica qué mitad tiene el foco.
			draw_rect(r, Color(0.26, 0.59, 0.98, 0.9), false, 2.0)
	# Asas de redimensión de la franja enfocada: línea tenue en el borde y asa al pasar.
	for h in shell.handles:
		draw_line(Vector2(h.x, h.y), Vector2(h.x, h.y + h.h), Color(1, 1, 1, 0.05), 1.0)
	if shell.hover_handle != null and not shell.expose:
		var h = shell.hover_handle
		var cy = h.y + h.h * 0.5
		draw_line(Vector2(h.x, h.y + h.h * 0.2), Vector2(h.x, h.y + h.h * 0.8), Color(0.26, 0.59, 0.98, 0.85), 2.0)
		draw_rect(Rect2(h.x - 4.0, cy - 16.0, 8.0, 32.0), Color(0.26, 0.59, 0.98, 0.9))
		for k in range(3):
			draw_circle(Vector2(h.x, cy - 7.0 + float(k) * 7.0), 1.3, Color(1, 1, 1, 0.95))
	# Placeholder de las ventanas que todavía no tienen textura: rect + spinner + título,
	# en el rect animado de la entrada (escala desde el ícono).
	var font = get_font("font", "Label")
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
	# Indicador por pantalla: bajo las tarjetas, una barra que abarca todas las ventanas
	# de un grupo y su número (índice/total). Así una pantalla partida se lee como una
	# sola pantalla y seleccionar una ventana resalta a las demás que viven con ella.
	if shell.expose and shell.fullscreen_id < 0:
		var units = shell._units()
		var n = units.size()
		var sel_id = -1
		if shell.expose_sel >= 0 and shell.expose_sel < shell.tiles.size():
			sel_id = shell.tiles[shell.expose_sel]
		for i in range(n):
			var span = null
			for id in units[i]:
				var card = shell.expose_cards.get(id)
				if card == null:
					continue
				span = card if span == null else span.merge(card)
			if span == null:
				continue
			var on = units[i].has(sel_id)
			var col = Color(0.26, 0.59, 0.98, 0.95) if on else Color(1, 1, 1, 0.28)
			var y = span.position.y + span.size.y + 5.0
			draw_rect(Rect2(span.position.x, y, span.size.x, 3.0 if on else 2.0), col)
			if font != null:
				var label = "%d/%d" % [i + 1, n]
				var lw = font.get_string_size(label).x
				draw_string(font, Vector2(span.position.x + span.size.x * 0.5 - lw * 0.5, y + 17.0), label, col)
