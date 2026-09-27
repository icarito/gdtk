extends Reference

# Actividad "Panel": muestra la API curada de ImGui, ImPlot, ImPlot3D y el menú
# radial con datos vivos. El viewport 3D se crea como hijo del ImGuiCanvas y se
# libera en cleanup() (el shell lo llama al salir de la actividad).

const SHAPE_CUBE = 0
const SHAPE_SPHERE = 1
const SHAPE_TORUS = 2

const HISTORY = 300
const SURFACE_N = 25

var viewport = null
var viewport_texture = null
var camera = null
var light = null
var mesh_instance = null
var material = null

var shape = SHAPE_CUBE
var color = Color(0.85, 0.55, 0.2)
var speed = 0.8
var wireframe = false
var animate = true
var light_pos = Vector3(2.0, 2.0, 2.0)

var fps_history = []
var frame_history = []
var last_ticks = 0
var time = 0.0

var show_demo = false
var show_implot_demo = false
var show_implot3d_demo = false
var show_metrics = false

# El modulo imgui puede compilarse sin ImPlot/ImPlot3D/demos (SPEC-hud B):
# se detecta en runtime para que el Panel tolere la ausencia.
var has_implot = false
var has_implot3d = false
var has_demos = false


func cleanup():
	if viewport != null and is_instance_valid(viewport):
		viewport.queue_free()
	viewport = null
	viewport_texture = null


func _setup_3d(ui):
	viewport = Viewport.new()
	viewport.size = Vector2(560, 300)
	viewport.usage = Viewport.USAGE_3D
	viewport.own_world = true
	viewport.render_target_update_mode = Viewport.UPDATE_ALWAYS
	viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED
	ui.add_child(viewport)

	camera = Camera.new()
	camera.translation = Vector3(0, 0.6, 3.6)
	camera.rotation_degrees = Vector3(-8, 0, 0)
	camera.current = true
	viewport.add_child(camera)

	light = OmniLight.new()
	light.translation = light_pos
	light.light_energy = 3.0
	light.omni_range = 20.0
	viewport.add_child(light)

	material = SpatialMaterial.new()
	material.albedo_color = color
	material.roughness = 0.4
	material.metallic = 0.2

	mesh_instance = MeshInstance.new()
	mesh_instance.material_override = material
	viewport.add_child(mesh_instance)

	_update_mesh()
	viewport_texture = viewport.get_texture()


func _update_mesh():
	if mesh_instance == null:
		return
	match shape:
		SHAPE_CUBE:
			var cube = CubeMesh.new()
			cube.size = Vector3(1.4, 1.4, 1.4)
			cube.subdivide_width = 1
			cube.subdivide_height = 1
			mesh_instance.mesh = cube
		SHAPE_SPHERE:
			var sphere = SphereMesh.new()
			sphere.radius = 0.9
			sphere.height = 1.8
			sphere.radial_segments = 48
			sphere.rings = 24
			mesh_instance.mesh = sphere
		SHAPE_TORUS:
			var torus = TorusMesh.new()
			torus.inner_radius = 0.55
			torus.outer_radius = 1.0
			torus.rings = 48
			torus.ring_segments = 24
			mesh_instance.mesh = torus


func _process_3d():
	var now = OS.get_ticks_msec()
	var dt = 0.016
	if last_ticks > 0:
		dt = min(float(now - last_ticks) / 1000.0, 0.1)
	last_ticks = now
	time += dt

	if viewport == null or not is_instance_valid(viewport):
		return
	viewport.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if wireframe else Viewport.DEBUG_DRAW_DISABLED
	if material != null:
		material.albedo_color = color
	if light != null:
		light.translation = light_pos
	if mesh_instance != null and animate:
		mesh_instance.rotation.y += speed * dt
		mesh_instance.rotation.x += speed * 0.4 * dt


func _sample_history():
	fps_history.append(Performance.get_monitor(Performance.TIME_FPS))
	frame_history.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	while fps_history.size() > HISTORY:
		fps_history.pop_front()
	while frame_history.size() > HISTORY:
		frame_history.pop_front()


func _monitors():
	return [
		["FPS", Performance.TIME_FPS],
		["Frame (ms)", Performance.TIME_PROCESS],
		["Memoria estatica (MB)", Performance.MEMORY_STATIC],
		["Objetos", Performance.OBJECT_COUNT],
		["Nodos", Performance.OBJECT_NODE_COUNT],
		["Draw calls", Performance.RENDER_DRAW_CALLS_IN_FRAME],
		["Objetos en frame", Performance.RENDER_OBJECTS_IN_FRAME],
		["Vertices en frame", Performance.RENDER_VERTICES_IN_FRAME],
	]


func _menu_bar(ui, vp):
	ui.set_next_window_pos(Vector2(0, 48), true)
	ui.set_next_window_size(Vector2(vp.x, 26), true)
	var flags = ui.WINDOW_NO_TITLE_BAR | ui.WINDOW_NO_RESIZE | ui.WINDOW_NO_MOVE | ui.WINDOW_NO_SCROLLBAR | ui.WINDOW_NO_SAVED_SETTINGS | ui.WINDOW_MENU_BAR
	if ui.begin("##panel_menu", flags):
		if ui.begin_menu_bar():
			if ui.begin_menu("Ver"):
				if has_demos:
					if ui.menu_item("Demo ImGui"):
						show_demo = not show_demo
					if has_implot and ui.menu_item("Demo ImPlot"):
						show_implot_demo = not show_implot_demo
					if has_implot3d and ui.menu_item("Demo ImPlot3D"):
						show_implot3d_demo = not show_implot3d_demo
				if ui.menu_item("Metricas"):
					show_metrics = not show_metrics
				ui.separator()
				if ui.menu_item("Acerca de"):
					ui.open_popup("acerca")
				ui.end_menu()
			ui.separator()
			ui.text("Panel gdtk")
			ui.end_menu_bar()
	ui.end()

	if ui.begin_popup_modal("Acerca de"):
		ui.text("Panel gdtk")
		ui.separator()
		ui.text_wrapped("Ejemplo complejo del toolkit ImGui: ventana 3D a textura, ImPlot, ImPlot3D, tablas, menus y menu radial.")
		ui.spacing()
		if ui.button("Cerrar"):
			ui.close_current_popup()
		ui.end_popup()


func _scene_window(ui):
	ui.set_next_window_pos(Vector2(16, 80))
	ui.set_next_window_size(Vector2(600, 380))
	if ui.begin("Escena"):
		if viewport_texture != null:
			ui.image(viewport_texture, Vector2(560, 300))
		if ui.is_item_hovered():
			if ui.is_mouse_clicked(1):
				ui.open_pie_menu("scene")
			ui.set_tooltip("Clic derecho: menu radial")
		ui.text("Forma: " + ["cubo", "esfera", "toro"][shape])
	ui.end()


func _controls_window(ui):
	ui.set_next_window_pos(Vector2(628, 80))
	ui.set_next_window_size(Vector2(340, 240))
	if ui.begin("Controles"):
		var shapes = PoolStringArray(["Cubo", "Esfera", "Toro"])
		shape = ui.combo("Forma", shape, shapes)
		color = ui.color_edit3("Albedo", color)
		speed = ui.slider_float("Velocidad", speed, 0.0, 4.0)
		wireframe = ui.checkbox("Wireframe", wireframe)
		animate = ui.checkbox("Animacion", animate)
		light_pos = ui.drag_float3("Luz", light_pos, 0.05, -5.0, 5.0)
		if ui.button("Reset"):
			_reset()
	ui.end()


func _reset():
	shape = SHAPE_CUBE
	color = Color(0.85, 0.55, 0.2)
	speed = 0.8
	wireframe = false
	animate = true
	light_pos = Vector3(2.0, 2.0, 2.0)
	_update_mesh()


func _performance_window(ui):
	ui.set_next_window_pos(Vector2(16, 472))
	ui.set_next_window_size(Vector2(600, 232))
	if ui.begin("Rendimiento"):
		if ui.begin_tab_bar("##perf"):
			if ui.begin_tab_item("ImPlot"):
				var count = fps_history.size()
				if count > 0:
					var xs = PoolRealArray()
					var fps = PoolRealArray()
					xs.resize(count)
					fps.resize(count)
					for i in range(count):
						xs[i] = i
						fps[i] = fps_history[i]
					# Alto suficiente para que el area de datos no quede en cero:
					# cada plot ocupa el alto disponible (>= 160 px) y medio ancho.
					var avail = ui.get_content_region_avail()
					var plot_h = max(avail.y - 4.0, 160.0)
					var plot_w = max((avail.x - 8.0) * 0.5, 120.0)
					if has_implot:
						if ui.implot_begin_plot("FPS", Vector2(plot_w, plot_h)):
							ui.implot_setup_axes("frames", "fps", ui.IMPLOT_AXIS_AUTOFIT, ui.IMPLOT_AXIS_AUTOFIT)
							ui.implot_plot_shaded("FPS", xs, fps, 0.0)
							ui.implot_plot_line("FPS", xs, fps)
							ui.implot_end_plot()
						ui.same_line()
						if ui.implot_begin_plot("Frame time (ms)", Vector2(plot_w, plot_h)):
							ui.implot_setup_axes("frames", "ms", ui.IMPLOT_AXIS_AUTOFIT, ui.IMPLOT_AXIS_AUTOFIT)
							ui.implot_plot_shaded("ms", xs, frame_history)
							ui.implot_plot_line("ms", xs, frame_history)
							ui.implot_end_plot()
					else:
						ui.plot_lines("FPS", fps, "", 0.0, 0.0, Vector2(plot_w, plot_h))
						ui.same_line()
						ui.plot_lines("Frame time (ms)", frame_history, "", 0.0, 0.0, Vector2(plot_w, plot_h))
				ui.end_tab_item()
			if ui.begin_tab_item("Barras"):
				var mem = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
				var objects = Performance.get_monitor(Performance.OBJECT_COUNT) / 100.0
				var draws = Performance.get_monitor(Performance.RENDER_DRAW_CALLS_IN_FRAME)
				var values = PoolRealArray()
				values.push_back(mem)
				values.push_back(objects)
				values.push_back(draws)
				if has_implot:
					if ui.implot_begin_plot("Recursos", Vector2(-1, 140)):
						ui.implot_setup_axes("", "valor", ui.IMPLOT_AXIS_AUTOFIT, ui.IMPLOT_AXIS_AUTOFIT)
						ui.implot_plot_bars("recursos", values)
						ui.implot_end_plot()
				else:
					ui.plot_histogram("Recursos", values, "", 0.0, 0.0, Vector2(-1, 140))
				ui.same_line()
				ui.text("mem %.1f MB  obj/100 %.0f  draws %.0f" % [mem, objects, draws])
				ui.end_tab_item()
			if ui.begin_tab_item("Tabla"):
				if ui.begin_table("##mon", 2, ui.TABLE_BORDERS | ui.TABLE_ROW_BG | ui.TABLE_RESIZABLE):
					ui.table_setup_column("Monitor")
					ui.table_setup_column("Valor")
					ui.table_headers_row()
					for entry in _monitors():
						ui.table_next_row()
						ui.table_next_column()
						ui.text(entry[0])
						ui.table_next_column()
						ui.text("%.3f" % Performance.get_monitor(entry[1]))
					ui.end_table()
				ui.end_tab_item()
			if ui.begin_tab_item("Nativo"):
				var count2 = frame_history.size()
				if count2 > 0:
					var ys2 = PoolRealArray()
					ys2.resize(count2)
					for i in range(count2):
						ys2[i] = frame_history[i]
					ui.plot_lines("Frame (ms)", ys2, "", 0.0, 40.0, Vector2(-1, 140))
				ui.end_tab_item()
			ui.end_tab_bar()
	ui.end()


func _3d_window(ui):
	ui.set_next_window_pos(Vector2(628, 332))
	ui.set_next_window_size(Vector2(340, 372))
	if ui.begin("3D"):
		if not has_implot3d:
			ui.text_wrapped("ImPlot3D no esta compilado en este binario (imgui_implot3d=no).")
			ui.end()
			return
		var n = SURFACE_N
		var xs = PoolRealArray()
		var ys = PoolRealArray()
		var zs = PoolRealArray()
		xs.resize(n * n)
		ys.resize(n * n)
		zs.resize(n * n)
		var t = time
		for i in range(n):
			for j in range(n):
				var idx = i * n + j
				var x = -3.0 + 6.0 * float(j) / float(n - 1)
				var y = -3.0 + 6.0 * float(i) / float(n - 1)
				xs[idx] = x
				ys[idx] = y
				zs[idx] = sin(x * t) * cos(y * t)
		if ui.implot3d_begin_plot("Superficie", Vector2(-1, 170), ui.IMPLOT3D_FLAGS_NO_CLIP):
			ui.implot3d_setup_axes_flags("x", "y", "z", ui.IMPLOT3D_AXIS_AUTOFIT)
			ui.implot3d_plot_surface("superficie", xs, ys, zs, n, n)
			ui.implot3d_end_plot()

		var hn = 120
		var hx = PoolRealArray()
		var hy = PoolRealArray()
		var hz = PoolRealArray()
		hx.resize(hn)
		hy.resize(hn)
		hz.resize(hn)
		for k in range(hn):
			var a = float(k) / float(hn - 1) * 12.0
			hx[k] = cos(a) * 1.2
			hy[k] = sin(a) * 1.2
			hz[k] = -2.0 + 4.0 * float(k) / float(hn - 1)
		if ui.implot3d_begin_plot("Helice", Vector2(-1, 170)):
			ui.implot3d_setup_axes_flags("x", "y", "z", ui.IMPLOT3D_AXIS_AUTOFIT)
			ui.implot3d_plot_line("helice", hx, hy, hz)
			ui.implot3d_end_plot()
	ui.end()


func draw(ui):
	if viewport == null or not is_instance_valid(viewport):
		_setup_3d(ui)

	has_implot = ui.has_method("implot_begin_plot")
	has_implot3d = ui.has_method("implot3d_begin_plot")
	has_demos = ui.has_method("show_demo_window")

	_process_3d()
	_sample_history()

	var vp = ui.get_viewport_rect().size
	_menu_bar(ui, vp)
	_scene_window(ui)
	_controls_window(ui)
	_performance_window(ui)
	_3d_window(ui)

	var items = PoolStringArray(["Cubo", "Esfera", "Toro", "Rojo", "Verde", "Azul", "Reset"])
	var choice = ui.pie_menu("scene", items)
	if choice == 0:
		shape = SHAPE_CUBE
		_update_mesh()
	elif choice == 1:
		shape = SHAPE_SPHERE
		_update_mesh()
	elif choice == 2:
		shape = SHAPE_TORUS
		_update_mesh()
	elif choice == 3:
		color = Color(0.9, 0.2, 0.2)
	elif choice == 4:
		color = Color(0.2, 0.85, 0.3)
	elif choice == 5:
		color = Color(0.25, 0.45, 0.95)
	elif choice == 6:
		_reset()

	if show_demo and ui.has_method("show_demo_window"):
		ui.show_demo_window()
	if show_implot_demo and has_implot and ui.has_method("implot_show_demo_window"):
		ui.implot_show_demo_window()
	if show_implot3d_demo and has_implot3d and ui.has_method("implot3d_show_demo_window"):
		ui.implot3d_show_demo_window()
	if show_metrics and ui.has_method("show_metrics_window"):
		ui.show_metrics_window()
