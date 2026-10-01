extends "res://pages/page.gd"

# Página Color de acento (K11a): paleta de 8 + hex personalizado. El shell lo usa
# en resaltados/selección en vivo.

var swatches = []
var preview = null


func _build():
	h_title("Color de acento")
	h_note("Se usa para resaltar lo seleccionado.")
	h_gap(6)
	var row = h_row()
	for i in range(model.ACCENT_PALETTE.size()):
		var hex = model.ACCENT_PALETTE[i]
		var b = STYLE.swatch(model.color_of_hex(hex), hex == settings.get("accent", ""))
		b.connect("pressed", self, "_on_swatch", [hex])
		swatches.append({"hex": hex, "button": b})
		row.add_child(b)
	preview = ColorRect.new()
	preview.rect_min_size = Vector2(60, 30)
	preview.color = model.color_of_hex(settings.get("accent", ""))
	row.add_child(preview)
	h_gap(8)
	var grow = h_row()
	var edit = LineEdit.new()
	edit.text = settings.get("accent", "")
	edit.rect_min_size.x = 160
	edit.connect("text_changed", self, "_on_hex")
	h_label("Color personalizado", grow)
	grow.add_child(edit)
	var hint = STYLE.note("Formato #RRGGBB")
	grow.add_child(hint)


func _on_swatch(hex):
	settings["accent"] = hex
	host.set_field("accent", hex)
	_refresh(hex)


func _on_hex(text):
	if model.valid_hex(text) == "":
		return
	settings["accent"] = model.valid_hex(text)
	host.set_field("accent", settings["accent"])
	_refresh(settings["accent"])


func _refresh(selected):
	for s in swatches:
		s.button.add_stylebox_override("normal", STYLE.bevel(model.color_of_hex(s.hex), 2.0, 3 if s.hex == selected else 1))
	preview.color = model.color_of_hex(selected)
