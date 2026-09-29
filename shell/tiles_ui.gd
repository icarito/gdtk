extends Control

# Overlay de tiles: borde del enfocado y títulos (y, en exposé, el borde de la tarjeta
# seleccionada). Se dibuja a mano con CanvasItem._draw y mouse_filter IGNORE: no le roba
# input a las ventanas (una ventana ImGui a pantalla completa sí lo haría). El fondo
# oscuro de exposé va aparte, detrás de los tiles (expose_bg), para no taparlos.

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
	for id in shell.tiles:
		var r = shell.expose_cards.get(id) if shell.expose else shell.tile_rects.get(id)
		if r == null:
			continue
		if shell.expose:
			if shell.tiles.find(id) == shell.expose_sel:
				draw_rect(r, Color(0.26, 0.59, 0.98, 1.0), false, 3.0)
			else:
				draw_rect(r, Color(0, 0, 0, 0.45), false, 1.0)
		elif id == shell.focused_tile:
			draw_rect(r, Color(0.26, 0.59, 0.98, 0.9), false, 2.0)
		if font != null:
			var title = shell.compositor.get_title(id)
			if title == "":
				title = shell._activity_for_window(id)
			if title != "":
				draw_string(font, r.position + Vector2(9.0, 20.0), title, Color(0, 0, 0, 0.85))
				draw_string(font, r.position + Vector2(8.0, 19.0), title, Color(1, 1, 1, 0.95))
