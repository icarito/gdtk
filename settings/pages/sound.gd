extends "res://pages/page.gd"

# Página "Sonido" (controles de audio universales, SPEC-notificaciones-2 §6):
# a qué equipos se aplican las teclas de volumen/silencio del shell. El shell lo
# relee en vivo por settings_bridge (`_apply_audio_settings`).


func _build():
	h_title("Sonido")
	h_note("Volumen, silencio y a qué equipos se aplican los cambios. Se aplica en vivo.")
	h_gap(6)
	var a = _cur()
	_check("Aplicar el volumen y el silencio a todo el Grupo", a.universal, "_on_universal", true)
	h_gap(8)
	h_note("Sólo viaja la acción: cada equipo conserva su propio nivel de volumen.")
	h_note("El brillo de pantalla es siempre de este equipo.")


func _cur():
	return model.audio(settings.get("audio", {}))


func _store(a):
	settings["audio"] = a
	host.set_field("audio", a)


func _check(text, value, method, enabled = true):
	var cb = CheckBox.new()
	cb.text = text
	cb.pressed = value
	STYLE.apply_button(cb)
	cb.disabled = not enabled
	cb.connect("toggled", self, method)
	box.add_child(cb)
	return cb


func _on_universal(on):
	var a = _cur()
	a.universal = on
	_store(a)
