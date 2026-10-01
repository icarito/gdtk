extends "res://pages/page.gd"

# Página "Desplazamiento": dirección del scroll en el panel táctil Y en el mouse/
# TrackPoint (el scroll natural no es sólo para touch). "Natural" queda activo por
# defecto. Se guarda en settings.json al pulsar Aplicar; la sesión lo aplica en
# sway al iniciar (`session/input-settings.sh`) y el shell lo reaplica en vivo al
# detectar el cambio (sin reiniciar). Cambiar el control también lo aplica ya por
# `swaymsg` si hay compositor.


func _build():
	h_title("Desplazamiento")
	h_note("Dirección del scroll en el panel táctil y en el mouse/TrackPoint.")
	h_gap(6)
	var cb = CheckBox.new()
	cb.text = "Desplazamiento natural"
	cb.pressed = bool(settings.get("natural_scroll", model.NATURAL_SCROLL_DEFAULT))
	STYLE.apply_button(cb)
	cb.connect("toggled", self, "_on_toggle")
	box.add_child(cb)
	h_gap(4)
	box.add_child(STYLE.note("Con el desplazamiento natural el contenido sigue el movimiento de los dedos / la rueda, como en una pantalla táctil."))


func _on_toggle(on):
	host.set_field("natural_scroll", on)
	_apply(on)


# Aplica en vivo al compositor (sway) para touchpad Y pointer. Sin swaymsg o sin
# sesión sway no hace nada; el valor igual queda guardado al pulsar Aplicar y se
# aplica al reiniciar.
func _apply(on):
	var exe = "/usr/bin/swaymsg"
	if not File.new().file_exists(exe):
		return
	for cmd in model.natural_scroll_cmds(on):
		OS.execute(exe, cmd, false)
