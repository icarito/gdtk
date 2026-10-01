extends "res://pages/page.gd"

# Página Teclado (K11a): distribución XKB. Se escribe en ~/.config/gdtk/keyboard,
# que sourcea session/keyboard.sh; aplica al reiniciar la sesión.


func _build():
	h_title("Teclado")
	h_note("Distribución para escribir en el sistema.")
	h_gap(6)
	var row = h_row()
	var opt = OptionButton.new()
	for i in range(model.KEYBOARDS.size()):
		var kb = model.KEYBOARDS[i]
		opt.add_item(kb.label, i)
		if kb.id == settings.get("keyboard", ""):
			opt.select(i)
	opt.connect("item_selected", self, "_on_selected")
	STYLE.apply_option(opt)
	h_label("Distribución", row)
	row.add_child(opt)
	h_gap(4)
	var warn = STYLE.note(model.restart_notice("keyboard"))
	warn.add_color_override("font_color", STYLE.WARN)
	box.add_child(warn)


func _on_selected(index):
	host.set_field("keyboard", model.KEYBOARDS[index].id)
