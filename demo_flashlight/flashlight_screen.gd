extends Reference

# Pantalla diegetica de la Linterna de casco (INVENTADA, no existe en Odisea: ver
# SPEC-flashlight.md seccion 0). Se dibuja en la senal `imgui_frame` de un
# ImGuiCanvas montado en un Viewport 480x300 sobre el QuadMesh con HoloScreen.shader.
#
# Solo usa los campos reales de `widget_snapshot()` (on / battery / battery_max /
# low / source): nada de modos ni intensidad, que HelmetFlashlight tiene pero el
# snapshot de Odisea no expone. Paleta de OdiseaOSTheme (no la de CryoPodUI).

const DESIGN := Vector2(480.0, 300.0)

# Paleta de OdiseaOSTheme.gd.
const SUIT_ACCENT := Color(0.0, 0.835, 1.0, 1.0)
const SURFACE_PANEL := Color(0.05, 0.08, 0.1, 1.0)
const SURFACE_DIM := Color(0.42, 0.68, 0.76, 1.0)
const STATE_ACTIVE := Color(0.18, 0.88, 0.78, 0.9)
const STATE_ALARM := Color(0.9, 0.3, 0.2, 0.9)
const STATE_OFFLINE := Color(0.5, 0.5, 0.5, 0.8)
const INK := Color(0.85, 0.95, 1.0, 1.0)

# Boton principal (en pixeles de diseno; el driver apunta a su centro).
const BUTTON_POS := Vector2(22.0, 216.0)
const BUTTON_SIZE := Vector2(220.0, 46.0)

# Inyectados por flashlight.gd (indices de fuente del canvas de la pantalla).
var body_font = -1
var big_font = -1
var mid_font = -1

var _white_tex = null


func button_center_uv() -> Vector2:
	var c: Vector2 = BUTTON_POS + BUTTON_SIZE * 0.5
	return Vector2(c.x / DESIGN.x, c.y / DESIGN.y)


func _ensure_white():
	if _white_tex != null:
		return
	var image = Image.new()
	image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 1, 1, 1))
	_white_tex = ImageTexture.new()
	_white_tex.create_from_image(image, 0)


func draw(ui, snapshot: Dictionary) -> bool:
	_ensure_white()

	var on := bool(snapshot.get("on", false))
	var low := bool(snapshot.get("low", false))
	var battery := float(snapshot.get("battery", 100.0))
	var battery_max := float(snapshot.get("battery_max", 100.0))
	var offline := String(snapshot.get("source", "online")) == "offline"
	var title := String(snapshot.get("title", "Linterna"))

	var ratio := 0.0
	if battery_max > 0.0:
		ratio = clamp(battery / battery_max, 0.0, 1.0)

	var dot := STATE_OFFLINE
	var state_text := "APAGADA"
	var state_color := STATE_OFFLINE
	var button_label := "ENCENDER"
	if offline:
		state_text = "OFFLINE"
		button_label = "OFFLINE"
	elif on:
		dot = STATE_ALARM if low else STATE_ACTIVE
		state_text = "BAT. BAJA" if low else "ENCENDIDA"
		state_color = STATE_ALARM if low else STATE_ACTIVE
		button_label = "APAGAR"
	if offline:
		dot = STATE_OFFLINE

	var flags = ui.WINDOW_NO_DECORATION | ui.WINDOW_NO_MOVE | ui.WINDOW_NO_SAVED_SETTINGS | ui.WINDOW_NO_BRING_TO_FRONT_ON_FOCUS
	ui.set_next_window_pos(Vector2.ZERO, true)
	ui.set_next_window_size(DESIGN, true)
	ui.push_style_var_vec2(ui.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	ui.push_style_color(ui.COL_WINDOW_BG, SURFACE_PANEL)
	ui.push_style_color(ui.COL_TEXT, SUIT_ACCENT)
	ui.push_style_color(ui.COL_BORDER, SURFACE_DIM)
	ui.push_style_color(ui.COL_BUTTON, Color(0.06, 0.20, 0.26, 1.0))
	ui.push_style_color(ui.COL_BUTTON_HOVERED, Color(0.10, 0.42, 0.52, 1.0))
	ui.push_style_color(ui.COL_BUTTON_ACTIVE, Color(0.16, 0.56, 0.66, 1.0))
	ui.push_style_color(ui.COL_PLOT_HISTOGRAM, state_color)
	ui.push_style_color(ui.COL_SEPARATOR, SURFACE_DIM)

	var toggled := false
	if ui.begin("##flashlight_screen", flags):
		# Encabezado: punto grande + "LINTERNA · CASCO".
		ui.set_cursor_pos(Vector2(18, 16))
		ui.image(_white_tex, Vector2(12, 12), dot)
		ui.same_line(8.0)
		if body_font >= 0:
			ui.push_font(body_font)
		ui.text_colored(SUIT_ACCENT, "LINTERNA · CASCO")
		if body_font >= 0:
			ui.pop_font()
		ui.set_cursor_pos(Vector2(18, 40))
		ui.separator()

		# Indicador grande ENCENDIDA / APAGADA / BAT. BAJA.
		ui.set_cursor_pos(Vector2(22, 56))
		if big_font >= 0:
			ui.push_font(big_font)
		ui.text_colored(state_color, state_text)
		if big_font >= 0:
			ui.pop_font()

		# Medidor de bateria: numero grande + barra.
		ui.set_cursor_pos(Vector2(22, 140))
		if body_font >= 0:
			ui.push_font(body_font)
		ui.text_colored(SUIT_ACCENT, "BATERÍA")
		if body_font >= 0:
			ui.pop_font()
		var meter_color := STATE_ALARM if (low and on and not offline) else INK
		ui.set_cursor_pos(Vector2(22, 160))
		if mid_font >= 0:
			ui.push_font(mid_font)
		var meter_text := "--" if offline else "%d%%  (%.0f/%.0f)" % [int(round(ratio * 100.0)), battery, battery_max]
		ui.text_colored(meter_color, meter_text)
		if mid_font >= 0:
			ui.pop_font()
		ui.set_cursor_pos(Vector2(150, 168))
		ui.progress_bar(0.0 if offline else ratio, Vector2(306, 22), "")

		# Boton grande ENCENDER / APAGAR (o deshabilitado si OFFLINE).
		ui.set_cursor_pos(BUTTON_POS)
		if offline:
			ui.push_style_color(ui.COL_BUTTON, Color(0.07, 0.07, 0.07, 1.0))
			ui.push_style_color(ui.COL_TEXT, STATE_OFFLINE)
			ui.button(button_label, BUTTON_SIZE)
			ui.pop_style_color(2)
		else:
			if body_font >= 0:
				ui.push_font(body_font)
			if ui.button(button_label, BUTTON_SIZE):
				toggled = true
			if body_font >= 0:
				ui.pop_font()

		ui.set_cursor_pos(Vector2(22, 274))
		if body_font >= 0:
			ui.push_font(body_font)
		ui.text_colored(SURFACE_DIM, "FD-298 · VISOR DE CASCO")
		if body_font >= 0:
			ui.pop_font()
	ui.end()

	ui.pop_style_color(8)
	ui.pop_style_var(1)
	return toggled
