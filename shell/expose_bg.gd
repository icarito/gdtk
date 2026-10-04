extends Control

# Fondo del exposé. En vez del velo oscuro, pinta el mismo fondo del Hogar
# (degradado, color sólido o imagen de escritorio) para que el "zoom out" del
# escritorio se lea sobre el fondo real. Vive en view_layer (CanvasLayer -1) en el
# índice 0, detrás de las miniaturas; el Hogar es ImGui (capa 0, encima), así que
# este nodo sólo se ve mientras el exposé está abierto.

var shell


func _ready():
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect_position = Vector2.ZERO
	rect_clip_content = false


func refresh():
	update()


func _draw():
	if shell == null:
		return
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
