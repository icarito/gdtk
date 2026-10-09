extends "res://pages/page.gd"

# Página "Notificaciones" (SPEC-notificaciones): interruptores del bus, tope del
# historial y modo de la columna. El shell lo relee en vivo (`settings_bridge`).


func _build():
	h_title("Notificaciones")
	h_note("Avisos de las apps y del propio shell. Se aplica en vivo.")
	h_gap(6)
	var nf = _cur()
	_check("Activar notificaciones", nf.enabled, "_on_enabled", true)
	_check("Mostrar el bloque transitorio al llegar un aviso", nf.toast_transitorio, "_on_toast", true)
	_check("Destacar (sin robar el foco) cuando una ventana pide atención", nf.atencion_foco, "_on_atencion", true)
	_check("Urgencia de los controles (p. ej. temperatura alta)", nf.urgencia, "_on_urgencia", true)
	h_gap(8)
	var row = h_row()
	h_label("Tope del historial", row)
	var spin = SpinBox.new()
	spin.min_value = model.NOTIF_HISTORY_MIN
	spin.max_value = model.NOTIF_HISTORY_MAX
	spin.step = 10
	spin.value = nf.history_max
	spin.rect_min_size = Vector2(120, 0)
	row.add_child(spin)
	spin.connect("value_changed", self, "_on_history")
	h_gap(8)
	_check("Dejar la columna abierta con pendientes", nf.columna_modo, "_on_columna", false)
	_check("Silenciar (no molestar)", nf.silencio, "_on_silencio", false)
	h_gap(8)
	h_note("El historial vive en $XDG_RUNTIME_DIR y se borra al cerrar la sesión.")


func _cur():
	return model.notifications(settings.get("notifications", {}))


func _store(nf):
	settings["notifications"] = nf
	host.set_field("notifications", nf)


func _check(text, value, method, enabled = true):
	var cb = CheckBox.new()
	cb.text = text
	cb.pressed = value
	STYLE.apply_button(cb)
	cb.disabled = not enabled
	cb.connect("toggled", self, method)
	box.add_child(cb)
	return cb


func _on_enabled(on):
	var nf = _cur()
	nf.enabled = on
	_store(nf)


func _on_toast(on):
	var nf = _cur()
	nf.toast_transitorio = on
	_store(nf)


func _on_atencion(on):
	var nf = _cur()
	nf.atencion_foco = on
	_store(nf)


func _on_urgencia(on):
	var nf = _cur()
	nf.urgencia = on
	_store(nf)


func _on_history(v):
	var nf = _cur()
	nf.history_max = model.notif_history(v)
	_store(nf)


func _on_columna(on):
	var nf = _cur()
	nf.columna_modo = on
	_store(nf)


func _on_silencio(on):
	var nf = _cur()
	nf.silencio = on
	_store(nf)
