extends "res://pages/page.gd"

# Página Idioma (K11a): LANG para la sesión. Se escribe en ~/.config/gdtk/locale;
# aplica al reiniciar la sesión.


func _build():
	h_title("Idioma")
	h_note("Idioma de los textos y del sistema.")
	h_gap(6)
	var row = h_row()
	var opt = OptionButton.new()
	for i in range(model.LOCALES.size()):
		var loc = model.LOCALES[i]
		opt.add_item(loc.label, i)
		if loc.id == settings.get("locale", ""):
			opt.select(i)
	opt.connect("item_selected", self, "_on_selected")
	STYLE.apply_option(opt)
	h_label("Idioma", row)
	row.add_child(opt)
	h_gap(4)
	var warn = STYLE.note(model.restart_notice("locale"))
	warn.add_color_override("font_color", STYLE.WARN)
	box.add_child(warn)


func _on_selected(index):
	host.set_field("locale", model.LOCALES[index].id)
