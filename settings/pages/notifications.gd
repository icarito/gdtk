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
	_check("Animar (salto) las ventanas que piden atención", nf.bounce, "_on_bounce", true)
	_check("Urgencia de los controles (p. ej. temperatura alta)", nf.urgencia, "_on_urgencia", true)
	_check("Mostrar el ícono de la aplicación", nf.iconos, "_on_iconos", true)
	_check("Mostrar el texto completo al pasar el puntero", nf.hover_card, "_on_hover", true)
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
	var row2 = h_row()
	h_label("Duración del aviso normal (s)", row2)
	var spin2 = SpinBox.new()
	spin2.min_value = model.NOTIF_TOAST_MS_MIN / 1000
	spin2.max_value = model.NOTIF_TOAST_MS_MAX / 1000
	spin2.step = 1
	spin2.value = float(nf.toast_ms_normal) / 1000.0
	spin2.rect_min_size = Vector2(120, 0)
	row2.add_child(spin2)
	spin2.connect("value_changed", self, "_on_toast_ms")
	var row3 = h_row()
	h_label("Caducar el historial tras (h, 0 = nunca)", row3)
	var spin3 = SpinBox.new()
	spin3.min_value = 0
	spin3.max_value = model.NOTIF_TTL_MS_MAX / 3600000
	spin3.step = 1
	spin3.value = float(nf.history_ttl_ms) / 3600000.0
	spin3.rect_min_size = Vector2(120, 0)
	row3.add_child(spin3)
	spin3.connect("value_changed", self, "_on_ttl")
	h_gap(8)
	_check("Dejar la columna abierta con pendientes", nf.columna_modo, "_on_columna", false)
	_check("Silenciar (no molestar)", nf.silencio, "_on_silencio", false)
	h_gap(8)
	h_note("El historial persiste en $XDG_STATE_HOME/gdtk/notifications.json.")


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


func _on_bounce(on):
	var nf = _cur()
	nf.bounce = on
	_store(nf)


func _on_iconos(on):
	var nf = _cur()
	nf.iconos = on
	_store(nf)


func _on_hover(on):
	var nf = _cur()
	nf.hover_card = on
	_store(nf)


func _on_history(v):
	var nf = _cur()
	nf.history_max = model.notif_history(v)
	_store(nf)


func _on_toast_ms(v):
	var nf = _cur()
	nf.toast_ms_normal = model.notif_ms(int(round(v)) * 1000, nf.toast_ms_normal)
	_store(nf)


func _on_ttl(v):
	var nf = _cur()
	nf.history_ttl_ms = model.notif_ttl_ms(int(round(v)) * 3600000, nf.history_ttl_ms)
	_store(nf)


func _on_columna(on):
	var nf = _cur()
	nf.columna_modo = on
	_store(nf)


func _on_silencio(on):
	var nf = _cur()
	nf.silencio = on
	_store(nf)
