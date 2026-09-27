extends Spatial

# Terminal de la Criopod (Paso 12). Construye todo por codigo para poder correrlo
# tanto en el proyecto `demo_holoterminal/` como instanciado dentro de una actividad
# del shell (que lo carga desde `demo_holoterminal/holoterminal.gd`, fuera de su res://).
#
# La pantalla es un QuadMesh con HoloScreen.shader; el contenido ImGui vive en un
# Viewport 2D 1024x640 que solo se re-renderiza cuando el ImGuiCanvas arma un frame de
# verdad (update_hz = 10, `redrawn` -> UPDATE_ONCE). El cursor NO va dentro de la
# textura: se dibuja en el shader con cursor_uv, actualizado cada frame desde el rayo
# de camara por el mouse, asi se mueve a la tasa del juego.

const SCREEN_W = 1024.0
const SCREEN_H = 640.0
const QUAD_SIZE = Vector2(1.6, 1.0)

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
var screen = null

var cursor_tex = null
var heart_tex = null
var cursor_size_uv = Vector2(16.0 / SCREEN_W, 16.0 / SCREEN_H)

var injected = false
var injected_pos = Vector2(-1.0, -1.0)
var injected_active = false
var _pending_release = false

var old_mode = false
var cursor_uv = Vector2(-1.0, -1.0)
var _last_cursor_uv = Vector2(-999.0, -999.0)
var _last_target_uv = Vector2(-999.0, -999.0)

# Metricas (una linea por segundo).
var _metrics_accum = 0.0
var _renders_in_window = 0
var _cursor_changes_in_window = 0
var _frames_in_window = 0
var _frame_time_accum = 0.0
var renders_per_sec = 0.0
var cursor_changes_per_sec = 0.0
var avg_frame_ms = 0.0

# Solo en el proyecto demo suelto (res://): captura y sale.
var screenshot_path = ""
var frame_count = 0


func _ready():
	demo_dir = get_script().resource_path.get_base_dir()
	_parse_flags()
	_build_scene()
	_build_ui()
	_load_fonts()
	print("HOLO_READY dir=", demo_dir, " old_mode=", old_mode)


func _parse_flags():
	if OS.get_environment("GDTK_HOLO_OLD") == "1":
		old_mode = true
	for arg in OS.get_cmdline_args():
		if arg == "--holo-old":
			old_mode = true
		elif arg.begins_with("--screenshot=") and demo_dir.begins_with("res://"):
			screenshot_path = arg.substr("--screenshot=".length())


# --- escena 3D -------------------------------------------------------------

func _build_scene():
	camera = Camera.new()
	camera.translation = Vector3(0.0, 0.12, 1.45)
	camera.rotation_degrees = Vector3(-6.0, 0.0, 0.0)
	camera.fov = 55.0
	add_child(camera)
	camera.current = true

	var key = OmniLight.new()
	key.translation = Vector3(0.7, 0.9, 1.1)
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
	# albedo.a bajo = piso de vidrio; el resto de la opacidad sale de la luma (HoloScreen).
	material.set_shader_param("albedo", Color(0.64, 0.93, 1.0, 0.12))
	material.set_shader_param("hologram_alpha", 1.0)
	material.set_shader_param("emission_energy", 1.0)
	material.set_shader_param("ink_level", 0.45)
	material.set_shader_param("contrast_boost", 3.0)
	# El QuadMesh tiene el frente al reves que el CSGBox invertido de Odisea: el shader
	# cae por el camino de "back face", donde no hay flip_v y aligned_flip_v=true daria
	# la imagen patas arriba. Se desactiva ese flip alineado para dejar uv = UV igual
	# que en el proyecto suelto.
	material.set_shader_param("aligned_flip_v", false)
	material.set_shader_param("cursor_uv", Vector2(-1.0, -1.0))
	material.set_shader_param("cursor_size_uv", cursor_size_uv)
	screen_mesh.material_override = material

	cursor_tex = _make_cursor_texture()
	heart_tex = _make_heart_texture(64)
	material.set_shader_param("cursor_tex", cursor_tex)


func _load_shader():
	var path = demo_dir.plus_file("assets/HoloScreen.shader")
	var file = File.new()
	if file.open(path, File.READ) != OK:
		printerr("HoloTerminal: no se pudo leer ", path)
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

	screen = load(demo_dir.plus_file("criopod_screen.gd")).new()
	screen.cursor_tex = cursor_tex
	screen.heart_tex = heart_tex
	screen.old_mode = old_mode
	screen.time = 0.0
	screen_canvas.connect("imgui_frame", self, "_screen_frame")
	screen_canvas.connect("redrawn", self, "_on_redrawn")

	overlay_canvas = ImGuiCanvas.new()
	overlay_canvas.set_update_hz(0.0)
	var overlay_layer = CanvasLayer.new()
	add_child(overlay_layer)
	overlay_layer.add_child(overlay_canvas)
	overlay_canvas.connect("imgui_frame", self, "_overlay_frame")

	if old_mode:
		screen_canvas.set_update_hz(0.0)
		screen_viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS
	else:
		screen_canvas.request_redraw()


func _load_fonts():
	var ttf = demo_dir.plus_file("assets/Silkscreen-Regular.ttf")
	var body = screen_canvas.add_font(ttf, 20.0)
	var big = screen_canvas.add_font(ttf, 56.0)
	if body >= 0:
		screen_canvas.set_default_font(body)
	if big < 0:
		big = body
	screen.body_font = body
	screen.big_font = big
	var overlay_font = overlay_canvas.add_font(ttf, 15.0)
	if overlay_font >= 0:
		overlay_canvas.set_default_font(overlay_font)


# --- frames de ImGui -------------------------------------------------------

func _screen_frame():
	screen.draw(screen_canvas)


func _on_redrawn():
	_renders_in_window += 1
	if not old_mode:
		# El contenido cambio: se re-renderiza el Viewport una sola vez.
		screen_viewport.render_target_update_mode = Viewport.UPDATE_ONCE


func _overlay_frame():
	var ui = overlay_canvas
	var vp = ui.get_viewport_rect().size
	ui.set_next_window_pos(Vector2(vp.x - 348.0, vp.y - 236.0), true)
	ui.set_next_window_size(Vector2(336.0, 224.0), true)
	if ui.begin("HoloTerminal — diagnóstico"):
		var hz = int(round(ui.slider_float("update_hz", screen_canvas.get_update_hz(), 1.0, 60.0, "%.0f")))
		if float(hz) != screen_canvas.get_update_hz() and not old_mode:
			screen_canvas.set_update_hz(float(hz))
		var ihz = int(round(ui.slider_float("input_hz", screen_canvas.get_input_hz(), 1.0, 60.0, "%.0f")))
		if float(ihz) != screen_canvas.get_input_hz():
			screen_canvas.set_input_hz(float(ihz))
		ui.separator()
		ui.text("renders Viewport/s: %.1f" % renders_per_sec)
		ui.text("cambios cursor_uv/s: %.1f" % cursor_changes_per_sec)
		ui.text("FPS juego: %.1f   frame: %.2f ms" % [Performance.get_monitor(Performance.TIME_FPS), avg_frame_ms])
		ui.text("modo: %s" % ("cursor en textura (viejo)" if old_mode else "cursor por shader"))
		var old = ui.checkbox("cursor en textura (modo viejo)", old_mode)
		if old != old_mode:
			set_old_mode(old)
	ui.end()


func set_old_mode(value):
	old_mode = value
	screen.old_mode = value
	if value:
		screen_canvas.set_update_hz(0.0)
		screen_viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS
	else:
		screen_canvas.set_update_hz(10.0)
		screen_canvas.request_redraw()
		material.set_shader_param("cursor_uv", cursor_uv)


# --- puntero / raycast -----------------------------------------------------

# La actividad del shell inyecta el puntero en coordenadas del Viewport 3D (el demo no
# es dueno del mouse real ahi). Corriendo suelto no se llama: usa el mouse de su viewport.
func set_pointer(position, active):
	injected = true
	injected_pos = position
	injected_active = active


func pointer_button(button, pressed):
	if pressed:
		_forward_button(button, true)
		_pending_release = true
	else:
		_forward_button(button, false)
		_pending_release = false


func _process(delta):
	screen.time += delta
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

	if injected and _pending_release:
		_forward_button(BUTTON_LEFT, false)
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

	if old_mode:
		material.set_shader_param("cursor_uv", Vector2(-1.0, -1.0))
		screen.cursor_px = target * Vector2(SCREEN_W, SCREEN_H)
	else:
		material.set_shader_param("cursor_uv", cursor_uv)
		screen.cursor_px = Vector2(-1.0, -1.0)

	if cursor_uv != _last_cursor_uv:
		_cursor_changes_in_window += 1
		_last_cursor_uv = cursor_uv

	if target != _last_target_uv:
		_last_target_uv = target
		_forward_motion(target)


# Mapea una UV de la textura de la terminal al plano del quad y la proyecta a
# coordenadas del Viewport que la contiene (para el driver de verificacion).
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


func _forward_button(button, pressed):
	var pos = _last_target_uv * Vector2(SCREEN_W, SCREEN_H)
	if _last_target_uv.x < 0.0:
		pos = Vector2(-1000.0, -1000.0)
	var event = InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = button
	event.pressed = pressed
	screen_canvas.call("_input", event)


func _input(event):
	if injected:
		return
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.pressed:
		_forward_button(BUTTON_LEFT, false)
	elif event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
		_forward_button(BUTTON_LEFT, true)


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
	print("HOLO_METRICS mode=%s update_hz=%.1f input_hz=%.1f viewport_renders_s=%.2f cursor_changes_s=%.2f fps=%.1f frame_ms=%.2f" % [
		"old" if old_mode else "new",
		screen_canvas.get_update_hz(),
		screen_canvas.get_input_hz(),
		renders_per_sec,
		cursor_changes_per_sec,
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


func _make_heart_texture(size):
	var image = Image.new()
	image.create(size, size, false, Image.FORMAT_RGBA8)
	image.lock()
	for y in range(size):
		for x in range(size):
			var nx = (float(x) / float(size - 1) * 2.0 - 1.0) * 1.3
			var ny = -(float(y) / float(size - 1) * 2.0 - 1.0) * 1.3
			var a = nx * nx + ny * ny - 1.0
			var inside = a * a * a - nx * nx * ny * ny * ny <= 0.0
			if inside:
				image.set_pixel(x, y, Color(1, 1, 1, 1))
			else:
				image.set_pixel(x, y, Color(0, 0, 0, 0))
	image.unlock()
	var texture = ImageTexture.new()
	texture.create_from_image(image, Texture.FLAG_FILTER)
	return texture
