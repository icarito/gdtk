extends Control

# Base de una página de Configuración: arma un VBox y ofrece helpers de fila.
# Las páginas mutan `settings` a través de `host` (main.gd), que marca cambios.

const STYLE = preload("res://ui/style.gd")

var model = null
var settings = {}
var host = null
var box = null


func setup(p_model, p_settings, p_host):
	model = p_model
	settings = p_settings
	host = p_host
	set_anchors_and_margins_preset(Control.PRESET_WIDE)
	box = VBoxContainer.new()
	box.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	box.add_constant_override("separation", 10)
	add_child(box)
	_build()


func _build():
	pass


func h_title(text):
	box.add_child(STYLE.title(text))


func h_note(text):
	box.add_child(STYLE.note(text))


func h_row():
	var h = HBoxContainer.new()
	h.add_constant_override("separation", 12)
	box.add_child(h)
	return h


func h_label(text, row, width = 200):
	var l = Label.new()
	l.text = text
	l.rect_min_size.x = width
	l.add_color_override("font_color", STYLE.TEXT)
	l.valign = Label.VALIGN_CENTER
	row.add_child(l)
	return l


func h_gap(height = 8):
	var c = Control.new()
	c.rect_min_size.y = height
	box.add_child(c)
