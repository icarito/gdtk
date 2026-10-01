extends Reference

# Estilo de la app Configuración, coherente con la paleta del shell
# (shell/menu_style.gd): gris azulado biselado sobre fondo oscuro. La app es un
# proyecto Godot aparte, así que estos valores se replican acá a propósito.

const BG = Color(0.06, 0.07, 0.09, 1.0)
const PANEL = Color(0.13, 0.15, 0.20, 1.0)
const SIDEBAR = Color(0.10, 0.11, 0.15, 1.0)
const FACE = Color(0.22, 0.25, 0.33, 1.0)
const LIGHT = Color(0.40, 0.45, 0.58, 1.0)
const DARK = Color(0.05, 0.06, 0.09, 1.0)
const TEXT = Color(0.92, 0.93, 0.97, 1.0)
const DIM = Color(0.62, 0.65, 0.72, 1.0)
const SELECT = Color(0.24, 0.32, 0.62, 1.0)
const WARN = Color(0.98, 0.72, 0.30, 1.0)

const PAD = 12


static func flat(color, radius = 2.0):
	var b = StyleBoxFlat.new()
	b.bg_color = color
	b.corner_radius_top_left = radius
	b.corner_radius_top_right = radius
	b.corner_radius_bottom_left = radius
	b.corner_radius_bottom_right = radius
	b.content_margin_left = PAD
	b.content_margin_right = PAD
	b.content_margin_top = 6
	b.content_margin_bottom = 6
	return b


# Panel con bisel claro arriba/izquierda y oscuro abajo/derecha (lenguaje WindowMaker).
static func bevel(color, radius = 2.0, width = 1):
	var b = flat(color, radius)
	b.border_width_left = width
	b.border_width_top = width
	b.border_width_right = width
	b.border_width_bottom = width
	b.border_color = LIGHT
	return b


static func apply_panel(control, color = PANEL):
	control.add_stylebox_override("panel", bevel(color))


static func apply_button(button, face = FACE):
	button.add_stylebox_override("normal", bevel(face))
	button.add_stylebox_override("hover", bevel(face.lightened(0.10)))
	button.add_stylebox_override("pressed", bevel(face.darkened(0.15)))
	button.add_stylebox_override("disabled", bevel(face.darkened(0.25)))
	button.add_stylebox_override("focus", bevel(face, 2.0, 0))
	button.add_color_override("font_color", TEXT)
	button.add_color_override("font_color_hover", TEXT)
	button.add_color_override("font_color_pressed", TEXT)
	button.add_color_override("font_color_disabled", DIM)


# Botón de la barra lateral: se resalta el seleccionado.
static func apply_nav(button, selected):
	apply_button(button, SELECT if selected else SIDEBAR)


static func apply_option(option):
	apply_button(option)
	option.add_stylebox_override("focus", bevel(FACE, 2.0, 0))
	var popup = option.get_popup()
	if popup != null:
		popup.add_stylebox_override("panel", bevel(PANEL))
		popup.add_color_override("font_color", TEXT)
		popup.add_color_override("font_color_hover", TEXT)


static func title(text, size = 20):
	var l = Label.new()
	l.text = text
	l.add_color_override("font_color", TEXT)
	l.add_constant_override("font_size", size)
	return l


static func note(text):
	var l = Label.new()
	l.text = text
	l.add_color_override("font_color", DIM)
	l.autowrap = true
	return l


static func swatch(color, selected, size = Vector2(44, 30)):
	var b = Button.new()
	b.rect_min_size = size
	var box = bevel(color, 2.0, 3 if selected else 1)
	b.add_stylebox_override("normal", box)
	b.add_stylebox_override("hover", box)
	b.add_stylebox_override("pressed", box)
	b.add_stylebox_override("focus", box)
	return b
