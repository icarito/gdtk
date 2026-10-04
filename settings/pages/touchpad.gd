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


# Aplicación en vivo con el mismo patrón del shell: Thread one-shot con
# OS.execute bloqueante y reap en la siguiente aplicación (Godot no reaparea los
# hijos del execute no-bloqueante: quedaban [swaymsg] <defunct>).
var _sway_threads = []
var _sway_states = []    # {"done": bool}
var _sway_mutex = Mutex.new()


# Aplica en vivo al compositor (sway) para touchpad Y pointer. Sin swaymsg o sin
# sesión sway no hace nada; el valor igual queda guardado al pulsar Aplicar y se
# aplica al reiniciar.
func _apply(on):
	var exe = "/usr/bin/swaymsg"
	if not File.new().file_exists(exe):
		return
	_reap_done()
	for cmd in model.natural_scroll_cmds(on):
		var state = {"done": false}
		var th = Thread.new()
		_sway_threads.append(th)
		_sway_states.append(state)
		th.start(self, "_sway_run", {"exe": exe, "argv": cmd, "state": state})


func _sway_run(userdata):
	OS.execute(String(userdata.get("exe", "")), userdata.get("argv", []), true)
	_sway_mutex.lock()
	userdata.get("state", {}).done = true
	_sway_mutex.unlock()


func _reap_done():
	for i in range(_sway_threads.size() - 1, -1, -1):
		_sway_mutex.lock()
		var done = _sway_states[i].get("done", false)
		_sway_mutex.unlock()
		if done:
			_sway_threads[i].wait_to_finish()
			_sway_threads.remove(i)
			_sway_states.remove(i)
