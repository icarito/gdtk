extends Reference

# Pantalla de la Criopod dibujada en la senal `imgui_frame` de un ImGuiCanvas (Viewport
# 1024x640). Es un port del layout de Odisea `CryoPodUI.gd` (solo lectura) al toolkit
# ImGui de gdtk, con el ECG hecho con ImPlot. Los oscuros (PANEL) se ven a traves del
# HoloScreen.shader como vidrio; el texto claro es tinta.

const DESIGN := Vector2(1024.0, 640.0)

# Paleta de CryoPodUI.gd (elegida por luma para HoloScreen.shader).
const CYAN := Color(0.42, 0.93, 1.0)
const DIM := Color(0.42, 0.72, 0.80)
const GRID := Color(0.18, 0.36, 0.42)
const PANEL := Color(0.05, 0.12, 0.15)
const OK := Color(0.42, 1.0, 0.65)
const WARN := Color(1.0, 0.76, 0.32)

# Ficha del ocupante (como los exports de CryoPodUI).
var pod_number = 7
var occupant_name = "ELÍAS VEGA"
var occupant_role = "PILOTO"
var occupant_status = "ESTABLE"
var alarm = false
var bpm = 12.0
var body_temp_c = 4.2
var integrity = 0.96
var coolant = 0.71
var oxygen = 0.88
var hibernation_days = 4212

# Inyectados por holoterminal.gd.
var body_font = 0
var big_font = 0
var cursor_tex = null
var heart_tex = null
var old_mode = false
# Posicion del cursor en pixeles de ImGui cuando se dibuja el cursor viejo (en la textura).
var cursor_px = Vector2(-1.0, -1.0)

var time = 0.0
var hatch_open = false
var debug_open = false


# p in [0,1) = un ciclo cardiaco. PQRST portado tal cual de CryoPodUI.gd.
static func _ecg(p):
	if p < 0.10:
		return 0.12 * sin(p / 0.10 * PI)
	if p < 0.16:
		return 0.0
	if p < 0.20:
		return -0.15 * sin((p - 0.16) / 0.04 * PI)
	if p < 0.24:
		return (p - 0.20) / 0.04
	if p < 0.28:
		return 1.0 - (p - 0.24) / 0.04 * 1.35
	if p < 0.33:
		return -0.35 + (p - 0.28) / 0.05 * 0.35
	if p < 0.45:
		return 0.0
	if p < 0.70:
		return 0.22 * sin((p - 0.45) / 0.25 * PI)
	return 0.0


func _accent():
	return WARN if alarm else OK


func _beat():
	return wrapf(time * max(bpm, 1.0) / 60.0, 0.0, 1.0)


func draw(ui):
	var flags = ui.WINDOW_NO_DECORATION | ui.WINDOW_NO_MOVE | ui.WINDOW_NO_RESIZE | ui.WINDOW_NO_SAVED_SETTINGS | ui.WINDOW_NO_SCROLLBAR | ui.WINDOW_NO_BRING_TO_FRONT_ON_FOCUS

	ui.set_next_window_pos(Vector2.ZERO, true)
	ui.set_next_window_size(DESIGN, true)

	ui.push_style_var_vec2(ui.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	ui.push_style_color(ui.COL_WINDOW_BG, PANEL)
	ui.push_style_color(ui.COL_CHILD_BG, Color(0.03, 0.08, 0.10, 1.0))
	ui.push_style_color(ui.COL_TEXT, CYAN)
	ui.push_style_color(ui.COL_BORDER, GRID)
	ui.push_style_color(ui.COL_FRAME_BG, Color(0.02, 0.06, 0.08, 1.0))
	ui.push_style_color(ui.COL_FRAME_BG_HOVERED, Color(0.10, 0.24, 0.30, 1.0))
	ui.push_style_color(ui.COL_FRAME_BG_ACTIVE, Color(0.14, 0.32, 0.40, 1.0))
	ui.push_style_color(ui.COL_BUTTON, Color(0.13, 0.30, 0.36, 1.0))
	ui.push_style_color(ui.COL_BUTTON_HOVERED, Color(0.20, 0.44, 0.52, 1.0))
	ui.push_style_color(ui.COL_BUTTON_ACTIVE, Color(0.26, 0.56, 0.66, 1.0))
	ui.push_style_color(ui.COL_PLOT_HISTOGRAM, _accent())
	ui.push_style_color(ui.COL_SEPARATOR, DIM)

	var open = ui.begin("##criopod", flags)
	if open:
		_header(ui)
		_occupant(ui)
		_vitals(ui)
		_ecg_monitor(ui)
		_hatch(ui)
		if old_mode:
			_old_cursor(ui)
	ui.end()

	ui.pop_style_color(12)
	ui.pop_style_var(1)


func _header(ui):
	ui.set_cursor_pos(Vector2(28, 16))
	ui.text_colored(_accent(), "CRIOCÁPSULA %02d · %s · %s · %s" % [pod_number, occupant_name, occupant_role, occupant_status])
	ui.set_cursor_pos(Vector2(28, 44))
	ui.text_colored(CYAN, "T+%d d · HIBERNACIÓN NOMINAL" % hibernation_days)
	ui.set_cursor_pos(Vector2(28, 70))
	ui.text_colored(DIM, "FD-307 · TERMINAL MÉDICO")
	ui.set_cursor_pos(Vector2(28, 92))
	ui.separator()


func _occupant(ui):
	ui.set_cursor_pos(Vector2(28, 112))
	ui.begin_child("##portrait", Vector2(116, 146))
	ui.set_cursor_pos(Vector2(18, 62))
	ui.text_colored(DIM, "SIN SEÑAL")
	ui.end_child()

	ui.set_cursor_pos(Vector2(164, 112))
	ui.text_colored(_accent(), occupant_name)
	ui.set_cursor_pos(Vector2(164, 138))
	ui.text_colored(CYAN, occupant_role)
	ui.set_cursor_pos(Vector2(164, 168))
	ui.text_colored(OK if not alarm else WARN, occupant_status)


func _vitals(ui):
	# Barras de signos vitales (progress_bar con estilo, equivalen a _draw_bar de CryoPodUI).
	var x = 28.0
	var y = 300.0
	var w = 420.0
	_bar(ui, x, y, w, "TEMP", body_temp_c / 37.0, "%.1f °C" % body_temp_c, false)
	_bar(ui, x, y + 58, w, "INTEGRIDAD", integrity, "%d%%" % int(round(integrity * 100.0)), true)
	_bar(ui, x, y + 116, w, "REFRIGERANTE", coolant, "%d%%" % int(round(coolant * 100.0)), true)
	_bar(ui, x, y + 174, w, "O₂", oxygen, "%d%%" % int(round(oxygen * 100.0)), true)


func _bar(ui, x, y, w, label, value, text, low_is_bad):
	var v = clamp(value, 0.0, 1.0)
	var col = WARN if (low_is_bad and v < 0.25) else _accent()
	ui.set_cursor_pos(Vector2(x, y))
	ui.text_colored(CYAN, label)
	ui.set_cursor_pos(Vector2(x, y + 24))
	ui.text_colored(col, text)
	ui.set_cursor_pos(Vector2(x + 150, y + 22))
	ui.push_style_color(ui.COL_PLOT_HISTOGRAM, col)
	ui.progress_bar(v, Vector2(w - 150.0, 14.0), "")
	ui.pop_style_color(1)


func _ecg_monitor(ui):
	# ECG con ImPlot: ventana deslizante de 2.5 ciclos, muestras nuevas a la derecha.
	var hz = max(bpm, 1.0) / 60.0
	ui.set_cursor_pos(Vector2(510, 112))
	var flags = ui.IMPLOT_FLAGS_NO_TITLE | ui.IMPLOT_FLAGS_NO_LEGEND | ui.IMPLOT_FLAGS_NO_MOUSE_TEXT | ui.IMPLOT_FLAGS_NO_MENUS | ui.IMPLOT_FLAGS_NO_BOX_SELECT | ui.IMPLOT_FLAGS_NO_INPUTS
	ui.implot_push_style_color(ui.IMPLOT_COL_PLOT_BG, PANEL)
	ui.implot_push_style_color(ui.IMPLOT_COL_FRAME_BG, PANEL)
	ui.implot_push_style_color(ui.IMPLOT_COL_AXIS_GRID, GRID)
	ui.implot_push_style_color(ui.IMPLOT_COL_AXIS_TEXT, DIM)
	ui.implot_push_style_color(ui.IMPLOT_COL_LINE, _accent())
	if ui.implot_begin_plot("##ecg", Vector2(486, 320), flags):
		ui.implot_setup_axes("", "", ui.IMPLOT_AXIS_NO_TICK_LABELS, ui.IMPLOT_AXIS_NO_TICK_LABELS)
		ui.implot_setup_axis_limits(ui.IMPLOT_AXIS_X1, 0.0, 1.0, true)
		ui.implot_setup_axis_limits(ui.IMPLOT_AXIS_Y1, -0.5, 1.2, true)
		var n = 256
		var xs = PoolRealArray()
		var ys = PoolRealArray()
		xs.resize(n)
		ys.resize(n)
		var span = 2.5 / hz
		for i in range(n):
			var f = float(i) / float(n - 1)
			var t = time - span * (1.0 - f)
			xs[i] = f
			ys[i] = _ecg(wrapf(t * hz, 0.0, 1.0))
		ui.implot_plot_line("ecg", xs, ys)
		# Cabeza del barrido.
		var hx = PoolRealArray()
		var hy = PoolRealArray()
		hx.push_back(1.0)
		hy.push_back(ys[n - 1])
		ui.implot_plot_scatter("head", hx, hy)
		ui.implot_end_plot()
	ui.implot_pop_style_color(5)

	# BPM grande + corazon que late (exp(-beat*9) como hoy).
	ui.set_cursor_pos(Vector2(510, 452))
	ui.push_font(big_font)
	ui.text_colored(_accent(), "%d" % int(round(bpm)))
	ui.pop_font()
	ui.same_line(10)
	ui.text_colored(CYAN, "BPM")
	ui.set_cursor_pos(Vector2(510, 520))
	ui.text_colored(CYAN, "HIBERNACIÓN NOMINAL" if not alarm else "ALERTA")

	ui.set_cursor_pos(Vector2(700, 452))
	if heart_tex != null:
		var pulse = 1.0 + 0.25 * exp(-_beat() * 9.0)
		var s = 40.0 * pulse
		ui.image(heart_tex, Vector2(s, s), _accent())


func _hatch(ui):
	ui.set_cursor_pos(Vector2(28, 570))
	var label = "CERRAR CÁPSULA" if hatch_open else "ABRIR CÁPSULA"
	if ui.button(label, Vector2(300, 50)):
		hatch_open = not hatch_open
		ui.request_redraw()
	ui.same_line(320)
	ui.set_cursor_pos(Vector2(348, 584))
	ui.text_colored(OK if hatch_open else DIM, "ESTADO: CÁPSULA %s" % ("ABIERTA" if hatch_open else "CERRADA"))

	ui.set_cursor_pos(Vector2(720, 584))
	if ui.collapsing_header("Debug"):
		bpm = ui.slider_float("bpm", bpm, 12.0, 120.0, "%.0f")


func _old_cursor(ui):
	if cursor_tex != null and cursor_px.x >= 0.0:
		ui.set_cursor_pos(cursor_px)
		ui.image(cursor_tex, Vector2(24, 24), CYAN)
