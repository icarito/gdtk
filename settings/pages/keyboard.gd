extends "res://pages/page.gd"

# Página Teclado (K11a): distribución XKB y lista activa de Super+Espacio. Escribe
# en ~/.config/gdtk/keyboard, que sourcea session/keyboard.sh: la primera elegida es
# XKB_DEFAULT_LAYOUT de la próxima sesión; entre las elegidas rota Super+Espacio.

var _checks = {}   # id -> CheckBox, para revertir el último que no puede quedarse


func _build():
	h_title("Teclado")
	h_note("Distribución para escribir en el sistema.")
	h_gap(6)
	var chosen = model.keyboard_layouts_list(settings.get("keyboard_layouts", null), model.KEYBOARD_LAYOUTS_DEFAULT.duplicate(true))
	if chosen.empty():
		chosen = [model.keyboard_id(settings.get("keyboard", ""))]
	var picked = {}
	for id in chosen:
		picked[id] = true
	for kb in model.KEYBOARDS:
		var row = h_row()
		var cb = CheckBox.new()
		cb.text = kb.label + (" (por defecto)" if kb.id == chosen[0] else "")
		cb.pressed = picked.has(kb.id)
		STYLE.apply_button(cb)
		cb.connect("toggled", self, "_on_toggled", [kb.id])
		_checks[kb.id] = cb
		row.add_child(cb)
		box.add_child(row)
	h_gap(4)
	box.add_child(STYLE.note("Super+Espacio rota entre las elegidas; el applet Teclado del Frame también deja elegir la lista."))
	h_gap(2)
	var warn = STYLE.note(model.restart_notice("keyboard"))
	warn.add_color_override("font_color", STYLE.WARN)
	box.add_child(warn)


func _on_toggled(on, id):
	var chosen = model.keyboard_layouts_list(settings.get("keyboard_layouts", null), model.KEYBOARD_LAYOUTS_DEFAULT.duplicate(true))
	if on:
		if not chosen.has(id):
			chosen.append(id)
	else:
		if chosen.size() < 2:
			# Siempre queda por lo menos una elegida: no se desmarca la última.
			_revert_check(id)
			return
		chosen.erase(id)
	host.set_field("keyboard_layouts", chosen)
	host.set_field("keyboard", chosen[0])


func _revert_check(id):
	var cb = _checks.get(id, null)
	if cb != null:
		cb.set_pressed_no_signal(true)
