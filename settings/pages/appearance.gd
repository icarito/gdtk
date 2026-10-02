extends "res://pages/page.gd"

# Página "Apariencia": relieve de los bloques del Frame y del Hogar. El ancho del
# bisel ya se calcula según el tamaño de la pantalla (unidad de rejilla); acá se
# ajusta con un factor. "Bloques planos" deja el 3D sólo al pasar el mouse y el
# relieve grabado aplica a los íconos del sistema. Todo se aplica en vivo.

var bevel_label = null
var ui_scale_label = null


func _build():
	h_title("Apariencia")
	h_note("Relieve de los bloques del Frame y del Hogar. Se aplica en vivo.")
	h_gap(6)
	var ap = _cur()
	var row = h_row()
	h_label("Ancho del bisel", row)
	var slider = HSlider.new()
	slider.min_value = model.BEVEL_MIN
	slider.max_value = model.BEVEL_MAX
	slider.step = 0.25
	slider.value = ap.bevel
	slider.rect_min_size = Vector2(200, 0)
	row.add_child(slider)
	bevel_label = STYLE.note("%.2f×" % ap.bevel)
	row.add_child(bevel_label)
	slider.connect("value_changed", self, "_on_bevel")
	h_gap(4)
	box.add_child(STYLE.note("El bisel se calcula según el tamaño de la pantalla; esto lo engrosa o adelgaza."))
	h_gap(8)
	var flat = CheckBox.new()
	flat.text = "Bloques planos (el 3D sólo al pasar el mouse)"
	flat.pressed = ap.flat
	STYLE.apply_button(flat)
	flat.connect("toggled", self, "_on_flat")
	box.add_child(flat)
	h_gap(4)
	var emboss = CheckBox.new()
	emboss.text = "Íconos del sistema con relieve grabado"
	emboss.pressed = ap.emboss
	STYLE.apply_button(emboss)
	emboss.connect("toggled", self, "_on_emboss")
	box.add_child(emboss)
	h_gap(4)
	box.add_child(STYLE.note("Vecindario, Inicio y las burbujas del anillo."))
	h_gap(10)
	var srow = h_row()
	h_label("Escala de la interfaz", srow)
	var sslider = HSlider.new()
	sslider.min_value = model.UI_SCALE_MIN
	sslider.max_value = model.UI_SCALE_MAX
	sslider.step = 0.25
	sslider.value = _ui()
	sslider.rect_min_size = Vector2(200, 0)
	srow.add_child(sslider)
	ui_scale_label = STYLE.note("%.2f×" % _ui())
	srow.add_child(ui_scale_label)
	sslider.connect("value_changed", self, "_on_ui_scale")
	h_gap(4)
	box.add_child(STYLE.note("También escala las apps (Firefox, GTK). Reabrilas para que la tomen."))


func _ui():
	return model.ui_scale_value(settings.get("ui_scale", 1.0))


func _on_ui_scale(v):
	settings["ui_scale"] = model.ui_scale_value(v)
	ui_scale_label.text = "%.2f×" % settings["ui_scale"]
	host.set_field("ui_scale", settings["ui_scale"])


func _cur():
	return model.appearance(settings.get("appearance", {}))


func _store(ap):
	settings["appearance"] = ap
	host.set_field("appearance", ap)


func _on_bevel(v):
	var ap = _cur()
	ap.bevel = model.bevel_scale(v)
	bevel_label.text = "%.2f×" % ap.bevel
	_store(ap)


func _on_flat(on):
	var ap = _cur()
	ap.flat = on
	_store(ap)


func _on_emboss(on):
	var ap = _cur()
	ap.emboss = on
	_store(ap)
