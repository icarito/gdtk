extends Reference

# Actividad "Linterna" del shell: instancia la demo de la Linterna de casco
# (`demo_flashlight/`, fuera del res:// del shell) dentro de un Viewport 3D y la
# dibuja como imagen en el cuerpo de la actividad. Mismo patron que la actividad
# "Criopod" (Paso 12): el control remoto la maneja como cualquier otra actividad.

var viewport = null
var demo = null
var load_error = ""
var _image_origin = Vector2.ZERO
var _image_size = Vector2.ZERO


func cleanup():
	if viewport != null and is_instance_valid(viewport):
		viewport.queue_free()
	viewport = null
	demo = null


func _demo_dir():
	var base = ProjectSettings.globalize_path("res://")
	return base.plus_file("../demo_flashlight").simplify_path()


func _ensure(ui, size):
	if viewport == null or not is_instance_valid(viewport):
		viewport = Viewport.new()
		viewport.size = size
		viewport.usage = Viewport.USAGE_3D
		viewport.own_world = true
		viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS
		viewport.render_target_v_flip = false
		viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED
		ui.add_child(viewport)
		var script = load(_demo_dir().plus_file("flashlight.gd"))
		if script == null:
			load_error = "no se pudo cargar " + _demo_dir().plus_file("flashlight.gd")
			return
		demo = script.new()
		viewport.add_child(demo)
	else:
		viewport.size = size


func draw(ui):
	var avail = ui.get_content_region_avail()
	if avail.x < 16.0 or avail.y < 16.0:
		return
	_ensure(ui, avail)
	if demo == null or not is_instance_valid(demo):
		ui.text("Linterna: " + load_error)
		return

	ui.set_cursor_pos(Vector2.ZERO)
	var origin = ui.get_cursor_screen_pos()
	ui.image(viewport.get_texture(), avail)
	_image_origin = origin
	_image_size = avail

	var mouse = ui.get_mouse_pos()
	var inside = mouse.x >= origin.x and mouse.y >= origin.y and mouse.x < origin.x + avail.x and mouse.y < origin.y + avail.y
	demo.set_pointer(mouse - origin, inside)
	if inside and ui.is_mouse_clicked(0):
		demo.pointer_button(BUTTON_LEFT, true)


func _point(p):
	if p == null or demo == null or not is_instance_valid(demo):
		return null
	return _image_origin + p


func screen_point(uv):
	if demo == null or not is_instance_valid(demo):
		return null
	return _image_origin + demo.uv_to_viewport(uv)


func screen_rect_in_viewport():
	if demo == null or not is_instance_valid(demo):
		return null
	var a = demo.uv_to_viewport(Vector2(0.0, 0.0))
	var b = demo.uv_to_viewport(Vector2(1.0, 1.0))
	var mn = Vector2(min(a.x, b.x), min(a.y, b.y))
	var mx = Vector2(max(a.x, b.x), max(a.y, b.y))
	return Rect2(_image_origin + mn, mx - mn)


# Puntos utiles para el driver de verificacion (coordenadas del shell).
func holo_points():
	if demo == null or not is_instance_valid(demo):
		return {}
	var points = {}
	points["button"] = screen_point(demo.screen_button_uv())
	points["screen_tl"] = screen_point(Vector2(0.0, 0.0))
	points["screen_br"] = screen_point(Vector2(1.0, 1.0))
	points["force_low"] = _point(demo.force_low_center())
	var compact = demo.widget_compact_rect()
	if compact.size.x > 0.0:
		points["widget_tl"] = _point(compact.position)
		points["widget_br"] = _point(compact.end)
	var zoomed = demo.widget_zoom_rect()
	if zoomed.size.x > 0.0:
		points["widget_zoom_tl"] = _point(zoomed.position)
		points["widget_zoom_br"] = _point(zoomed.end)
	return points
