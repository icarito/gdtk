extends Reference

# Applet Bluetooth del Frame (SPEC-sugar-frame-applets.md): radio (bluetoothctl) y
# apertura de blueman-manager como toplevel. Módulo autocontenido: no usa shell, no
# acepta argumentos de usuario y no crea providers. Se consulta como máximo cada
# PERIOD_MS (~5 s), nunca por frame. Sin binario o sin adaptador -> no_disponible;
# orden fallida o timeout -> error, sin inventar un valor.

const PERIOD_MS = 5000
const TIMEOUT_S = "2"

# activo | apagado | no_disponible | sin_dato | error
var state = "sin_dato"
var value = "sin dato"   # texto muy corto para el bloque de 44 px
var detail = ""          # texto para tooltip

var _bluetoothctl = ""
var _timeout = ""
var _blueman = ""
var _probed = false
var _last_ms = -PERIOD_MS
var _last_value = ""     # último valor real, para no fingir un estado en error


# Consulta la radio a lo sumo cada PERIOD_MS; `force` salta el límite. Devuelve true
# si cambió state, value o detail (hay algo que redibujar).
func refresh(force := false):
	var now = OS.get_ticks_msec()
	if not force and now - _last_ms < PERIOD_MS:
		return false
	_last_ms = now
	_probe()
	if _bluetoothctl == "":
		return _apply("no_disponible", "sin bt", "bluetoothctl no está instalado")
	if _timeout == "":
		return _apply("no_disponible", "sin bt", "falta coreutils timeout")
	var out = []
	var code = OS.execute(_timeout, [TIMEOUT_S, _bluetoothctl, "show"], true, out, true)
	var text = ""
	for line in out:
		text += String(line) + "\n"
	if code != 0:
		var motive = "bluetoothctl no respondió (timeout)" if code == 124 else "bluetoothctl falló (código %d)" % code
		return _apply("error", _error_value(), motive)
	var powered = ""
	var controller = ""
	var name = ""
	var discovering = ""
	for raw in text.split("\n", false):
		var l = raw.strip_edges()
		if l.begins_with("Controller "):
			controller = l.substr("Controller ".length()).strip_edges()
		elif l.begins_with("Powered:"):
			powered = l.substr("Powered:".length()).strip_edges()
		elif l.begins_with("Name:"):
			name = l.substr("Name:".length()).strip_edges()
		elif l.begins_with("Discovering:"):
			discovering = l.substr("Discovering:".length()).strip_edges()
	if powered == "":
		if text.findn("No default controller") >= 0 or text.findn("No controller") >= 0:
			return _apply("no_disponible", "sin bt", "no hay adaptador Bluetooth")
		return _apply("error", _error_value(), "respuesta inesperada de bluetoothctl")
	var on = powered == "yes"
	var who = name if name != "" else controller
	var d = "Bluetooth " + ("activo" if on else "apagado")
	if who != "":
		d += " — " + who
	if discovering == "yes":
		d += " · buscando"
	_last_value = "on" if on else "off"
	return _apply("activo" if on else "apagado", _last_value, d)


# Abre blueman-manager sin bloquear la UI. Devuelve true si el proceso arrancó; el
# motivo del fallo queda visible en detail. Godot 3 no trae create_process: se usa
# OS.execute(..., false) y la existencia del binario se comprueba antes (_which).
func open_manager():
	_probe()
	if _blueman == "":
		detail = "blueman-manager no está instalado"
		return false
	var pid = OS.execute(_blueman, [], false)
	if pid <= 0:
		detail = "no se pudo abrir blueman-manager"
		return false
	detail = "Gestión de Bluetooth abierta"
	return true


# Cambia la radio con bluetoothctl (timeout corto) y luego refresca el estado. Si no
# hay lectura fiable no adivina: devuelve false sin tocar la radio.
func toggle_power():
	refresh(true)
	if state == "no_disponible":
		return false
	if state != "activo" and state != "apagado":
		_apply("error", value, "no se pudo leer el estado de la radio")
		return false
	if _timeout == "":
		return false
	var target = "off" if state == "activo" else "on"
	var out = []
	var code = OS.execute(_timeout, [TIMEOUT_S, _bluetoothctl, "power", target], true, out, true)
	if code != 0:
		var what = "apagar" if target == "off" else "encender"
		return _apply("error", _error_value(), "no se pudo %s la radio (código %d)" % [what, code])
	refresh(true)
	return true


# Resuelve bluetoothctl, timeout y blueman-manager una sola vez, buscándolos en $PATH
# sin lanzar procesos.
func _probe():
	if _probed:
		return
	_probed = true
	_bluetoothctl = _which("bluetoothctl")
	_timeout = _which("timeout")
	_blueman = _which("blueman-manager")


# Ruta absoluta de un ejecutable en $PATH, o "" si no está. Sólo File, sin shell.
func _which(prog):
	for d in OS.get_environment("PATH").split(":", false):
		if d != "" and File.new().file_exists(d + "/" + prog):
			return d + "/" + prog
	return ""


# Valor textual a mostrar en error: el último real, o genérico si nunca hubo lectura.
func _error_value():
	return _last_value if _last_value != "" else "error"


# Fija los tres campos y dice si alguno cambió.
func _apply(new_state, new_value, new_detail):
	var changed = state != new_state or value != new_value or detail != new_detail
	state = new_state
	value = new_value
	detail = new_detail
	return changed
