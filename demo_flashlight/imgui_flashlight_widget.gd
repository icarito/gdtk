extends Reference

# Port a ImGui del widget compacto de la Linterna de casco de Odisea
# (`core_v2/ui/hud/FlashlightWidget.gd` + `FlashlightWidget.tscn`).
#
# Dibuja el mismo contenido a partir del mismo `widget_snapshot()`:
#   Panel 210x80 · Header [punto de estado 8x8 + "Linterna"] · MeterLabel textual
#   (_format_battery_bar) · StatusRow [estado + boton ENCENDER/APAGAR/OFFLINE].
# El mismo `draw()` sirve para el modo ampliado de `HudViewMount._open_widget`
# (zoom 1.8x) cambiando `zoom` y la fuente: en Odisea el "modo pantalla completa"
# de la Linterna es este widget reinstanciado y agrandado.

# Paleta de OdiseaOSTheme.gd (elegida por luma para HoloScreen.shader; el fondo y
# los paneles oscuros son "vidrio").
const SURFACE_PANEL := Color(0.05, 0.08, 0.1, 1.0)
const SURFACE_BORDER := Color(0.24, 0.55, 0.65, 1.0)
const STATE_ACTIVE := Color(0.18, 0.88, 0.78, 0.9)
const STATE_ALARM := Color(0.9, 0.3, 0.2, 0.9)
const STATE_OFFLINE := Color(0.5, 0.5, 0.5, 0.8)
const INK := Color(0.85, 0.95, 1.0, 1.0)

const PANEL_SIZE := Vector2(210.0, 80.0)

# Inyectados por la demo (indices de fuente del canvas del overlay).
var body_font = -1
var zoom_font = -1

# Ultimo rectangulo (en coordenadas del overlay) donde se dibujo el widget. Lo usa
# el driver de verificacion para recortar el PNG a 210x80.
var last_rect := Rect2()

var _white_tex = null


func _ensure_white():
	if _white_tex != null:
		return
	var image = Image.new()
	image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 1, 1, 1))
	_white_tex = ImageTexture.new()
	_white_tex.create_from_image(image, 0)


# ASCII: la fuente del tema no trae bloques. Puerto exacto de
# FlashlightWidget._format_battery_bar (Odisea lineas 56-68).
static func _format_battery_bar(val: float, max_val: float) -> String:
	if max_val <= 0.0:
		return "BAT: [..........]"
	var ratio := clamp(val / max_val, 0.0, 1.0)
	var total_segments := 10
	var filled_segments := int(round(ratio * total_segments))
	var bar := ""
	for i in range(total_segments):
		if i < filled_segments:
			bar += "|"
		else:
			bar += "."
	return "BAT: [%s]" % bar


func draw(ui, pos: Vector2, snapshot: Dictionary, zoom: float = 1.0, font: int = -1, id: String = "##flashlight_widget", panel_alpha: float = 1.0) -> bool:
	_ensure_white()

	var on := bool(snapshot.get("on", false))
	var low := bool(snapshot.get("low", false))
	var battery := float(snapshot.get("battery", 100.0))
	var battery_max := float(snapshot.get("battery_max", 100.0))
	var offline := String(snapshot.get("source", "online")) == "offline"
	var title := String(snapshot.get("title", "Linterna"))
	var panel_bg := SURFACE_PANEL
	panel_bg.a = min(panel_bg.a, panel_alpha)

	var dot := STATE_OFFLINE
	if not offline:
		dot = (STATE_ALARM if low else STATE_ACTIVE) if on else STATE_OFFLINE

	var status := "APAGADA"
	var button_label := "ENCENDER"
	if offline:
		status = "OFFLINE"
		button_label = "OFFLINE"
	elif on:
		status = "BAT. BAJA" if low else "ENCENDIDA"
		button_label = "APAGAR"

	var meter := "BAT: [----------]" if offline else _format_battery_bar(battery, battery_max)
	var meter_color := STATE_ALARM if (low and on and not offline) else INK

	ui.set_next_window_pos(pos, true)
	ui.set_next_window_size(PANEL_SIZE * zoom, true)
	ui.push_style_color(ui.COL_WINDOW_BG, panel_bg)
	ui.push_style_color(ui.COL_BORDER, SURFACE_BORDER)
	ui.push_style_var_vec2(ui.STYLE_VAR_WINDOW_PADDING, Vector2(6, 6) * zoom)
	ui.push_style_var_vec2(ui.STYLE_VAR_ITEM_SPACING, Vector2(6, 2) * zoom)
	if font >= 0:
		ui.push_font(font)

	var flags = ui.WINDOW_NO_DECORATION | ui.WINDOW_NO_MOVE | ui.WINDOW_NO_SAVED_SETTINGS | ui.WINDOW_NO_BRING_TO_FRONT_ON_FOCUS
	var toggled := false
	if ui.begin(id, flags):
		last_rect = Rect2(ui.get_window_pos(), ui.get_window_size())

		ui.set_cursor_pos(Vector2(0, 0))
		ui.image(_white_tex, Vector2(8, 8) * zoom, dot)
		ui.same_line(6.0 * zoom)
		ui.text_colored(INK, title)

		ui.set_cursor_pos(Vector2(0, 18.0 * zoom))
		ui.text_colored(meter_color, meter)

		ui.set_cursor_pos(Vector2(0, 34.0 * zoom))
		ui.text_colored(INK if not offline else STATE_OFFLINE, status)

		ui.set_cursor_pos(Vector2(112.0 * zoom, 32.0 * zoom))
		if offline:
			ui.push_style_color(ui.COL_BUTTON, Color(0.1, 0.1, 0.1, 1.0))
			ui.push_style_color(ui.COL_TEXT, STATE_OFFLINE)
			ui.button(button_label, Vector2(74, 20) * zoom)
			ui.pop_style_color(2)
		elif ui.button(button_label, Vector2(74, 20) * zoom):
			toggled = true
	ui.end()

	if font >= 0:
		ui.pop_font()
	ui.pop_style_var(2)
	ui.pop_style_color(2)
	return toggled
