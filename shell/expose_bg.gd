extends Control

# Fondo del exposé. En vez del velo oscuro, pinta el mismo fondo del Hogar
# (degradado, color sólido o imagen de escritorio) para que el "zoom out" del
# escritorio se lea sobre el fondo real. Vive en view_layer (CanvasLayer -1) en el
# índice 0, detrás de las miniaturas; el Hogar es ImGui (capa 0, encima), así que
# este nodo sólo se ve mientras el exposé está abierto.

var shell

# Sombra "drop" de las miniaturas: misma receta que window_deco._draw_shadow
# (StyleBoxFlat con sombra nativa, barato en GLES2).
var _thumb_shadow_sb = null


func _ready():
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect_position = Vector2.ZERO
	rect_clip_content = false


func refresh():
	update()


func _draw():
	if shell == null:
		return
	_draw_background()
	if shell.expose and shell.fullscreen_id < 0:
		_draw_thumb_shadows()
		_draw_unit_labels()


# Rect visible del nodo de la ventana (igual que shell._node_footprint) o null.
func _visible_rect(id):
	var node = shell.tile_nodes.get(id)
	if node == null or not is_instance_valid(node) or not node.visible:
		return null
	return shell._node_footprint(node)


# Progreso de la animación de entrada de la ventana: 1 si ya se asentó.
func _settle(id):
	var a = shell.view_anim.get(id)
	if a == null:
		return 1.0
	return clamp(float(OS.get_ticks_msec() - a.since) / shell.EXPOSE_MS, 0.0, 1.0)


# Sombra de las miniaturas TILED (las flotantes ya llevan la suya por window_deco),
# en el footprint visible y con opacidad ~ progreso^2: aparece al asentarse.
func _draw_thumb_shadows():
	var sel_id = -1
	if shell.expose_sel >= 0 and shell.expose_sel < shell.tiles.size():
		sel_id = shell.tiles[shell.expose_sel]
	for id in shell.tile_nodes.keys():
		if shell.is_floating(id):
			continue
		var r = _visible_rect(id)
		if r != null:
			var k = _settle(id)
			_draw_thumb_shadow(r, id == sel_id, k * k)


func _draw_thumb_shadow(r, focused, opacity):
	if r.size.x < 6.0 or r.size.y < 6.0 or opacity <= 0.0:
		return
	if _thumb_shadow_sb == null:
		_thumb_shadow_sb = StyleBoxFlat.new()
		_thumb_shadow_sb.draw_center = false
		_thumb_shadow_sb.bg_color = Color(0, 0, 0, 0)
	_thumb_shadow_sb.set_corner_radius_all(7)
	_thumb_shadow_sb.shadow_size = 16 if focused else 10
	_thumb_shadow_sb.shadow_color = Color(0.0, 0.0, 0.0, (0.26 if focused else 0.16) * opacity)
	_thumb_shadow_sb.shadow_offset = Vector2(0.0, 4.0 if focused else 2.5)
	draw_style_box(_thumb_shadow_sb, r)


# Etiqueta "i/n" bajo cada unidad (workspace). Alfa ~ progreso mínimo de sus ventanas;
# si cae sobre una ventana visible de la unidad, baja bajo el footprint más bajo.
func _draw_unit_labels():
	var font = get_font("font", "Label")
	var units = shell.expose_units if shell.expose_units != null else []
	var n = units.size()
	if font == null:
		return
	var sel_id = -1
	if shell.expose_sel >= 0 and shell.expose_sel < shell.tiles.size():
		sel_id = shell.tiles[shell.expose_sel]
	for i in range(min(n, shell.expose_unit_cards.size())):
		var frame = shell.expose_unit_cards[i]
		var label = "%d/%d" % [i + 1, n]
		var lw = font.get_string_size(label).x
		var lh = font.get_height()
		var x = frame.position.x + frame.size.x * 0.5 - lw * 0.5
		var y = frame.position.y + frame.size.y + 16.0
		var k = 1.0
		var rects = []
		for id in units[i]:
			k = min(k, _settle(id))
			var r = _visible_rect(id)
			if r != null:
				rects.append(r)
		for r in rects:
			if Rect2(x, y, lw, lh).intersects(r):
				y = max(y, r.end.y + 8.0)
		var base = 0.55 if units[i].has(sel_id) else 0.30
		draw_string(font, Vector2(x, y + font.get_ascent()), label, Color(1, 1, 1, base * k))


func _draw_background():
	var vp = get_viewport_rect().size
	var sb = shell.settings_bridge
	var mode = "gradient"
	if sb != null:
		mode = String(sb.settings.get("wallpaper", {}).get("mode", "gradient"))
	if mode != "gradient" and mode != "solid" and sb != null and sb.has_wallpaper_image():
		var r = sb.wallpaper_rect(vp)
		draw_texture_rect(sb.wallpaper_texture(), r, false)
		# Mismo velo tenue que el Hogar, para que las miniaturas resalten.
		draw_rect(Rect2(Vector2.ZERO, vp), Color(0.0, 0.0, 0.0, 0.30))
		return
	if mode == "solid" and sb != null and sb.model != null:
		draw_rect(Rect2(Vector2.ZERO, vp), sb.model.color_of_hex(sb.settings.get("wallpaper", {}).get("color", "")))
		return
	# Degradado vertical del Hogar: mismo par de colores que _draw_home_background.
	var pair = shell.home_bg_colors()
	var pts = PoolVector2Array([Vector2(0.0, 0.0), Vector2(vp.x, 0.0), Vector2(vp.x, vp.y), Vector2(0.0, vp.y)])
	var cols = PoolColorArray([pair[0], pair[0], pair[1], pair[1]])
	draw_polygon(pts, cols)
