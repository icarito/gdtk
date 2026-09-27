extends ImGuiCanvas

# Controles ImGui equivalentes a godot_ui.tscn: N filas de text + progress_bar
# + button y una polilínea de 300 puntos (implot_plot_line o plot_lines).

const POLY_POINTS = 300

var count = 20
var mode = "static"
var values = []
var configured = false
var tick = 0


func _ready():
	connect("imgui_frame", self, "_draw_frame")


func configure(p_count, p_mode):
	count = p_count
	mode = p_mode
	values = []
	for i in range(count):
		values.append(0)
	configured = true


func set_frame_values(p_frame):
	tick = p_frame
	for i in range(count):
		values[i] = int(50.0 + 49.0 * sin(float(p_frame) * 0.05 + float(i)))


func _poly_x():
	var xs = PoolRealArray()
	xs.resize(POLY_POINTS)
	for i in range(POLY_POINTS):
		xs[i] = i
	return xs


func _poly_y():
	var ys = PoolRealArray()
	ys.resize(POLY_POINTS)
	for i in range(POLY_POINTS):
		ys[i] = sin(float(i) * 0.1 + float(tick) * 0.1) * 40.0
	return ys


func _draw_frame():
	if not configured:
		return
	var vp = get_viewport_rect().size
	set_next_window_pos(Vector2.ZERO, true)
	set_next_window_size(vp, true)
	var flags = WINDOW_NO_DECORATION | WINDOW_NO_MOVE | WINDOW_NO_RESIZE | WINDOW_NO_TITLE_BAR | WINDOW_NO_BACKGROUND | WINDOW_NO_SAVED_SETTINGS
	if begin("##bench", flags):
		for i in range(count):
			text("Fila %d: %d" % [i, values[i]])
			same_line()
			progress_bar(float(values[i]) / 100.0, Vector2(180, 0), "%d" % values[i])
			same_line()
			button("Boton %d##b%d" % [i, i])

		if has_feature("implot"):
			if implot_begin_plot("##poly", Vector2(-1, 200)):
				implot_setup_axes("", "", IMPLOT_AXIS_AUTOFIT, IMPLOT_AXIS_AUTOFIT)
				implot_plot_line("poly", _poly_x(), _poly_y())
				implot_end_plot()
		else:
			plot_lines("##poly", _poly_y(), "", 0.0, 0.0, Vector2(-1, 200))
	end()
