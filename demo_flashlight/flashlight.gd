extends Spatial

# Linterna de casco (FD-298) con ImGui (Paso 13). Reusa la infraestructura del
# HoloTerminal de la Criopod (Paso 12): QuadMesh con HoloScreen.shader y cursor por
# shader, Viewport con ImGuiCanvas a update_hz = 10 y `redrawn` -> UPDATE_ONCE, fuente
# Silkscreen y paleta por luma.
#
# Dos superficies:
#   - pantalla diegetica INVENTADA 480x300 en el quad (flashlight_screen.gd) — en
#     Odisea la Linterna solo declara widget, no `view_scene()` (SPEC seccion 0);
#   - widget compacto 210x80 y su modo ampliado 1.8x (imgui_flashlight_widget.gd),
#     dibujados en el overlay de diagnostico 2D, que es como se ve hoy el "modo
#     pantalla completa" de la Linterna en Odisea (HudViewMount._open_widget).
#
# Todo se construye por codigo para correr igual como proyecto suelto
# (`demo_flashlight/`) y como sub-escena de una actividad del shell.

const SCREEN_W = 480.0
const SCREEN_H = 300.0
const QUAD_SIZE = Vector2(1.28, 0.8)

const CURSOR_MASK = [
	"X...............",
	"XX..............",
	"X.X.............",
	"X..X............",
	"X...X...........",
	"X....X..........",
	"X.....X.........",
	"X......X........",
	"X.......X.......",
	"X........X......",
	"X.....XXXXX.....",
	"X....XX...X.....",
	"X...X.X....X....",
	"XX.X..X.........",
	".XX....X........",
	"........X.......",
]

var demo_dir = ""
var camera = null
var screen_mesh = null
var material = null
var screen_viewport = null
var screen_canvas = null
var overlay_canvas = null

var fl_state = null
var screen_ui = null
var widget_ui = null

var cursor_tex = null
var cursor_size_uv = Vector2(16.0 / SCREEN_W, 16.0 / SCREEN_H)

var injected = false
var injected_pos = Vector2(-1.0, -1.0)
var injected_active = false
var _pending_release = false

var cursor_uv = Vector2(-1.0, -1.0)
var _last_cursor_uv = Vector2(-999.0, -999.0)
var _last_target_uv = Vector2(-999.0, -999.0)

# Rectangulos/posiciones (coordenadas del overlay) para el driver de verificacion.
var _widget_compact_rect := Rect2()
var _widget_zoom_rect := Rect2()
var _force_low_center := Vector2(-1.0, -1.0)

# Metricas (una linea por segundo).
var _metrics_accum = 0.0
var _renders_in_window = 0
var _cursor_changes_in_window = 0
var _frames_in_window = 0
var _frame_time_accum = 0.0
var renders_per_sec = 0.0
var cursor_changes_per_sec = 0.0
var avg_frame_ms = 0.0
var redraw_requests = 0

var screenshot_path = ""
var frame_count = 0
var _arg_on = false
var _arg_low = false


func _ready():
	demo_dir = get_script().resource_path.get_base_dir()
	_parse_flags()
	_load_scripts()
	if _arg_on and fl_state != null:
		fl_state.set_enabled(true)
	if _arg_low and fl_state != null:
		fl_state.set_enabled(true)
		fl_state.battery = fl_state.battery_low_threshold - 2.0
	_build_scene()
	_build_ui()
	_load_fonts()
	print("FLASHLIGHT_READY dir=", demo_dir)


func _parse_flags():
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--screenshot=") and demo_dir.begins_with("res://"):
			screenshot_path = arg.substr("--screenshot=".length())
		elif arg == "--flash-on":
			_arg_on = true
		elif arg == "--flash-low":
			_arg_low = true


func _load_scripts():
	var state_script = load(demo_dir.plus_file("flashlight_state.gd"))
	var screen_script = load(demo_dir.plus_file("flashlight_screen.gd"))
	var widget_script = load(demo_dir.plus_file("imgui_flashlight_widget.gd"))
	if state_script == null or screen_script == null or widget_script == null:
		printerr("Flashlight: no se pudieron cargar los scripts de ", demo_dir)
		return
	fl_state = state_script.new()
	screen_ui = screen_script.new()
	widget_ui = widget_script.new()
	fl_state.connect("battery_changed", self, "_on_state_changed")


# --- escena 3D -------------------------------------------------------------

func _build_scene():
	camera = Camera.new()
	camera.translation = Vector3(0.0, 0.1, 1.35)
	camera.rotation_degrees = Vector3(-6.0, 0.0, 0.0)
	camera.fov = 55.0
	add_child(camera)
	camera.current = true

	var key = OmniLight.new()
	key.translation = Vector3(0.6, 0.8, 1.0)
	key.light_energy = 1.6
	key.omni_range = 12.0
	add_child(key)

	var fill = DirectionalLight.new()
	fill.rotation_degrees = Vector3(-40.0, -35.0, 0.0)
	fill.light_energy = 0.35
	add_child(fill)

	var floor_mesh = MeshInstance.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(10.0, 10.0)
	floor_mesh.mesh = plane
	floor_mesh.translation = Vector3(0.0, -0.7, 0.0)
	var floor_mat = SpatialMaterial.new()
	floor_mat.albedo_color = Color(0.04, 0.06, 0.08)
	floor_mat.roughness = 0.9
	floor_mesh.material_override = floor_mat
	add_child(floor_mesh)

	screen_mesh = MeshInstance.new()
	var quad = QuadMesh.new()
	quad.size = QUAD_SIZE
	screen_mesh.mesh = quad
	screen_mesh.translation = Vector3(0.0, 0.14, 0.0)
	screen_mesh.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	add_child(screen_mesh)

	material = ShaderMaterial.new()
	material.shader = _load_shader()
	material.set_shader_param("albedo", Color(0.64, 0.93, 1.0, 0.12))
	material.set_shader_param("hologram_alpha", 1.0)
	material.set_shader_param("emission_energy", 1.0)
	var ink = float(OS.get_environment("GDTK_FLASH_INK")) if OS.get_environment("GDTK_FLASH_INK") != "" else 0.45
	# 1.0 (no 3.0 como la Criopod): con 3.0 el rojo de STATE_ALARM se satura a blanco
	# al pasar por coverage*(1+contrast*coverage). Con 1.0 el panel sigue vidrio y el
	# rojo de alarma se lee. GDTK_FLASH_CONTRAST/GDTK_FLASH_INK son perillas de debug.
	var contrast = float(OS.get_environment("GDTK_FLASH_CONTRAST")) if OS.get_environment("GDTK_FLASH_CONTRAST") != "" else 1.0
	material.set_shader_param("ink_level", ink)
	material.set_shader_param("contrast_boost", contrast)
	# El frente del QuadMesh esta al reves que el CSGBox de Odisea: el shader cae por el
	# camino de back face, donde aligned_flip_v daria la imagen patas arriba.
	material.set_shader_param("aligned_flip_v", false)
	material.set_shader_param("cursor_uv", Vector2(-1.0, -1.0))
	material.set_shader_param("cursor_size_uv", cursor_size_uv)
	screen_mesh.material_override = material

	cursor_tex = _make_cursor_texture()
	material.set_shader_param("cursor_tex", cursor_tex)


func _load_shader():
	var path = demo_dir.plus_file("assets/HoloScreen.shader")
	var file = File.new()
	if file.open(path, File.READ) != OK:
		printerr("Flashlight: no se pudo leer ", path)
		return null
	var code = file.get_as_text()
	file.close()
	var shader = Shader.new()
	shader.code = code
	return shader


func _build_ui():
	screen_viewport = Viewport.new()
	screen_viewport.size = Vector2(SCREEN_W, SCREEN_H)
	screen_viewport.usage = Viewport.USAGE_2D
	screen_viewport.transparent_bg = true
	screen_viewport.render_target_update_mode = Viewport.UPDATE_DISABLED
	screen_viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED
	add_child(screen_viewport)

	screen_canvas = ImGuiCanvas.new()
	screen_canvas.set_update_hz(10.0)
	screen_canvas.set_input_hz(30.0)
	screen_viewport.add_child(screen_canvas)
	material.set_shader_param("texture_albedo", screen_viewport.get_texture())

	screen_canvas.connect("imgui_frame", self, "_screen_frame")
	screen_canvas.connect("redrawn", self, "_on_redrawn")
	screen_canvas.request_redraw()

	overlay_canvas = ImGuiCanvas.new()
	overlay_canvas.set_update_hz(0.0)
	var overlay_layer = CanvasLayer.new()
	add_child(overlay_layer)
	overlay_layer.add_child(overlay_canvas)
	overlay_canvas.connect("imgui_frame", self, "_overlay_frame")


func _load_fonts():
	var ttf = demo_dir.plus_file("assets/Silkscreen-Regular.ttf")
	var body = screen_canvas.add_font(ttf, 16.0)
	var mid = screen_canvas.add_font(ttf, 28.0)
	var big = screen_canvas.add_font(ttf, 40.0)
	if body >= 0:
		screen_canvas.set_default_font(body)
	screen_ui.body_font = body
	screen_ui.mid_font = mid
	screen_ui.big_font = big

	var overlay_font = overlay_canvas.add_font(ttf, 14.0)
	var overlay_zoom_font = overlay_canvas.add_font(ttf, 25.0)
	if overlay_font >= 0:
		overlay_canvas.set_default_font(overlay_font)
	widget_ui.body_font = overlay_font
	widget_ui.zoom_font = overlay_zoom_font


# --- frames de ImGui -------------------------------------------------------

func _screen_frame():
	if screen_ui == null or fl_state == null:
		return
	if screen_ui.draw(screen_canvas, fl_state.widget_snapshot()):
		fl_state.toggle()
		_request_redraw()


func _on_state_changed(_value = null, _max_value = null):
	_request_redraw()


func _on_redrawn():
	_renders_in_window += 1
	screen_viewport.render_target_update_mode = Viewport.UPDATE_ONCE


func _request_redraw():
	redraw_requests += 1
	screen_canvas.request_redraw()


func _overlay_frame():
	if widget_ui == null or fl_state == null:
		return
	var ui = overlay_canvas
	var snapshot = fl_state.widget_snapshot()
	var vp = ui.get_viewport_rect().size

	# Widget compacto (210x80) y su modo ampliado 1.8x, como el "modo pantalla
	# completa" de HudViewMount._open_widget en Odisea. Van abajo a la izquierda para
	# no tapar el encabezado ni el indicador de la pantalla 3D.
	var compact_pos = Vector2(12, vp.y - 92.0)
	var zoom_pos = Vector2(12 + 216, vp.y - 156.0)
	widget_ui.draw(ui, compact_pos, snapshot, 1.0, widget_ui.body_font, "##flashlight_widget")
	_widget_compact_rect = widget_ui.last_rect
	# El ampliado va con el panel semi-transparente (como apply_widget_panel_alpha de
	# HudViewMount, 0.7; en tier LOW Odisea lo deja opaco).
	var t2 = widget_ui.draw(ui, zoom_pos, snapshot, 1.8, widget_ui.zoom_font, "##flashlight_widget_zoom", 0.7)
	_widget_zoom_rect = widget_ui.last_rect
	if t2:
		fl_state.toggle()
		_request_redraw()

	_diagnostics(ui)


func _diagnostics(ui):
	var vp = ui.get_viewport_rect().size
	var win = Vector2(360, 258)
	ui.set_next_window_pos(Vector2(vp.x - win.x - 12, vp.y - win.y - 12), true)
	ui.set_next_window_size(win, true)
	if ui.begin("Linterna — diagnóstico"):
		var hz = int(round(ui.slider_float("update_hz", screen_canvas.get_update_hz(), 1.0, 60.0, "%.0f")))
		if float(hz) != screen_canvas.get_update_hz():
			screen_canvas.set_update_hz(float(hz))
			_request_redraw()
		var drain = ui.slider_float("drenaje/s (debug)", fl_state.battery_drain_per_second, 0.0, 60.0, "%.2f")
		fl_state.battery_drain_per_second = drain
		ui.separator()
		ui.text("renders Viewport/s: %.1f" % renders_per_sec)
		ui.text("pulsos request_redraw: %d" % redraw_requests)
		ui.text("FPS juego: %.1f   frame: %.2f ms" % [Performance.get_monitor(Performance.TIME_FPS), avg_frame_ms])
		ui.text("on=%s  bat=%.1f/%.0f  low=%s  %s" % [
			str(fl_state.enabled), fl_state.battery, fl_state.battery_max,
			str(fl_state.is_battery_low()), "OFFLINE" if fl_state.offline else "online"])
		_force_low_center = ui.get_cursor_screen_pos() + Vector2(110, 15)
		if ui.button("FORZAR BATERÍA BAJA (debug)", Vector2(220, 30)):
			fl_state.force_low()
			_request_redraw()
		var off = ui.checkbox("simular OFFLINE", fl_state.offline)
		if off != fl_state.offline:
			fl_state.offline = off
			_request_redraw()
	ui.end()


# --- puntero / raycast -----------------------------------------------------

# La actividad del shell inyecta el puntero en coordenadas del Viewport 3D (el demo
# no es dueno del mouse real ahi). Corriendo suelto no se llama: usa el mouse propio.
func set_pointer(position, active):
	injected = true
	injected_pos = position
	injected_active = active


func pointer_button(button, pressed):
	if pressed:
		_forward_screen_button(button, true)
		_forward_overlay_button(button, true, injected_pos)
		_pending_release = true
	else:
		_forward_screen_button(button, false)
		_forward_overlay_button(button, false, injected_pos)
		_pending_release = false


func _process(delta):
	if fl_state != null:
		fl_state.tick(delta)
	_update_metrics(delta)

	var pointer = Vector2(-1.0, -1.0)
	var active = false
	if injected:
		pointer = injected_pos
		active = injected_active
	else:
		pointer = get_viewport().get_mouse_position()
		active = get_viewport().get_visible_rect().has_point(pointer)

	_update_cursor(pointer, active, delta)

	if injected:
		# El overlay 2D no recibe el mouse del shell: se le reenvia cada frame.
		_forward_overlay_motion(pointer)
		if _pending_release:
			_forward_screen_button(BUTTON_LEFT, false)
			_forward_overlay_button(BUTTON_LEFT, false, injected_pos)
			_pending_release = false

	frame_count += 1
	if screenshot_path != "" and frame_count >= 60:
		var image = get_viewport().get_texture().get_data()
		image.flip_y()
		image.save_png(screenshot_path)
		get_tree().quit()


func _update_cursor(pointer, active, delta):
	var target = Vector2(-1.0, -1.0)
	if active:
		var hit = _raycast(pointer)
		if hit != null:
			target = hit

	# Suavizado: el cursor se mueve a la tasa del juego aunque el contenido vaya a 10 Hz.
	if target.x < 0.0 or cursor_uv.x < 0.0:
		cursor_uv = target
	else:
		cursor_uv = cursor_uv.linear_interpolate(target, clamp(delta * 25.0, 0.0, 1.0))

	material.set_shader_param("cursor_uv", cursor_uv)
	if cursor_uv != _last_cursor_uv:
		_cursor_changes_in_window += 1
		_last_cursor_uv = cursor_uv

	if target != _last_target_uv:
		_last_target_uv = target
		_forward_motion(target)


# Mapea una UV de la textura de la pantalla al plano del quad y la proyecta a
# coordenadas del Viewport que la contiene.
func uv_to_viewport(uv):
	var local = Vector3((uv.x - 0.5) * QUAD_SIZE.x, (0.5 - uv.y) * QUAD_SIZE.y, 0.0)
	return camera.unproject_position(screen_mesh.global_transform.xform(local))


func _raycast(pointer):
	if camera == null or screen_mesh == null:
		return null
	var origin = camera.project_ray_origin(pointer)
	var dir = camera.project_ray_normal(pointer)
	var xf = screen_mesh.global_transform
	var normal = xf.basis.z
	var denom = dir.dot(normal)
	if abs(denom) < 0.00001:
		return null
	var t = (xf.origin - origin).dot(normal) / denom
	if t < 0.0:
		return null
	var local = xf.affine_inverse().xform(origin + dir * t)
	var u = local.x / QUAD_SIZE.x + 0.5
	var v = 0.5 - local.y / QUAD_SIZE.y
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return null
	return Vector2(u, v)


func _forward_motion(uv):
	var pos = uv * Vector2(SCREEN_W, SCREEN_H)
	if uv.x < 0.0:
		pos = Vector2(-1000.0, -1000.0)
	var event = InputEventMouseMotion.new()
	event.position = pos
	event.global_position = pos
	screen_canvas.call("_input", event)


func _forward_overlay_motion(pos):
	if not injected:
		return
	var event = InputEventMouseMotion.new()
	event.position = pos
	event.global_position = pos
	overlay_canvas.call("_input", event)


func _forward_screen_button(button, pressed):
	if pressed and _last_target_uv.x < 0.0:
		return
	var pos = _last_target_uv * Vector2(SCREEN_W, SCREEN_H)
	if _last_target_uv.x < 0.0:
		pos = Vector2(-1000.0, -1000.0)
	var event = InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = button
	event.pressed = pressed
	screen_canvas.call("_input", event)


func _forward_overlay_button(button, pressed, pos):
	if not injected:
		return
	if pos.x < 0.0:
		pos = Vector2(-1000.0, -1000.0)
	var event = InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = button
	event.pressed = pressed
	overlay_canvas.call("_input", event)


func _input(event):
	# Solo la pantalla 3D necesita reenvio en el proyecto suelto: su Viewport hijo no
	# recibe el mouse del OS. El overlay 2D si lo recibe directo (no duplicar).
	if injected:
		return
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		_forward_screen_button(BUTTON_LEFT, event.pressed)


# --- puntos para el driver de verificacion ---------------------------------

func screen_button_uv() -> Vector2:
	if screen_ui == null:
		return Vector2(-1.0, -1.0)
	return screen_ui.button_center_uv()


func widget_compact_rect() -> Rect2:
	return _widget_compact_rect


func widget_zoom_rect() -> Rect2:
	return _widget_zoom_rect


func force_low_center() -> Vector2:
	return _force_low_center


func screen_rect_in_viewport():
	if camera == null or screen_mesh == null:
		return null
	var a = uv_to_viewport(Vector2(0.0, 0.0))
	var b = uv_to_viewport(Vector2(1.0, 1.0))
	var mn = Vector2(min(a.x, b.x), min(a.y, b.y))
	var mx = Vector2(max(a.x, b.x), max(a.y, b.y))
	return Rect2(mn, mx - mn)


# --- metricas --------------------------------------------------------------

func _update_metrics(delta):
	_metrics_accum += delta
	_frames_in_window += 1
	_frame_time_accum += delta
	if _metrics_accum < 1.0:
		return
	renders_per_sec = float(_renders_in_window) / _metrics_accum
	cursor_changes_per_sec = float(_cursor_changes_in_window) / _metrics_accum
	avg_frame_ms = (_frame_time_accum / float(max(_frames_in_window, 1))) * 1000.0
	print("FLASHLIGHT_METRICS update_hz=%.1f viewport_renders_s=%.2f cursor_changes_s=%.2f redraw_requests=%d fps=%.1f frame_ms=%.2f" % [
		screen_canvas.get_update_hz(),
		renders_per_sec,
		cursor_changes_per_sec,
		redraw_requests,
		Performance.get_monitor(Performance.TIME_FPS),
		avg_frame_ms,
	])
	_metrics_accum = 0.0
	_renders_in_window = 0
	_cursor_changes_in_window = 0
	_frames_in_window = 0
	_frame_time_accum = 0.0


# --- texturas procedurales -------------------------------------------------

func _make_cursor_texture():
	var size = CURSOR_MASK.size()
	var image = Image.new()
	image.create(size, size, false, Image.FORMAT_RGBA8)
	image.lock()
	for y in range(size):
		for x in range(size):
			if CURSOR_MASK[y][x] == "X":
				image.set_pixel(x, y, Color(1, 1, 1, 1))
			else:
				image.set_pixel(x, y, Color(0, 0, 0, 0))
	image.unlock()
	var texture = ImageTexture.new()
	texture.create_from_image(image, Texture.FLAG_FILTER)
	return texture
