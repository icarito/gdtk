extends Reference

# Applet Bluetooth del Frame (SPEC-sugar-frame-applets.md): radio (bluetoothctl) y
# apertura de blueman-manager como toplevel. Módulo autocontenido: no usa shell, no
# acepta argumentos de usuario y no crea providers.
#
# El hilo de render NUNCA consulta (SPEC-screen-share-compass §0/§14): `bluetoothctl
# show` y `bluetoothctl power` corren en un worker (Thread + Mutex, como neighborhood.gd)
# que publica un snapshot atómico {state, value, detail, version}. refresh() sólo copia
# ese snapshot; toggle_power() encola la orden y el worker la ejecuta con timeout corto.
# Sin binario o sin adaptador -> no_disponible; orden fallida o timeout -> error, sin
# inventar un valor.

const PERIOD_MS = 5000
const SLEEP_STEP_MS = 100
const TIMEOUT_S = "2"

# activo | apagado | no_disponible | sin_dato | error; se copian del snapshot del worker.
var state = "sin_dato"
var value = "sin dato"   # texto muy corto para el bloque de 44 px
var detail = ""          # texto para tooltip
var version = 0

# Snapshot compartido con el worker (bajo _mutex).
var _snap_state = "sin_dato"
var _snap_value = "sin dato"
var _snap_detail = ""
var _snap_version = 0

# Estado visto por el worker (para decidir el target de la orden) y último valor real.
var _cur_state = "sin_dato"
var _last_value = ""

# Resolución de binarios ($PATH, sin procesos): hilo principal antes de arrancar el worker.
var _bluetoothctl = ""
var _timeout = ""
var _blueman = ""
var _probed = false

# Worker de sonda (Thread + Mutex) y orden de encendido/apagado pendiente.
var _mutex = Mutex.new()
var _thread = null
var _want_stop = false
var _want_refresh = false
var _toggle_pending = false


# --- ciclo de vida -----------------------------------------------------------

# Arranca el worker de sonda (idempotente). Resuelve los binarios antes de arrancar.
func start():
	if _thread != null:
		return
	_probe()
	_mutex.lock()
	_want_stop = false
	_want_refresh = false
	_mutex.unlock()
	_thread = Thread.new()
	_thread.start(self, "_work")


func running():
	return _thread != null


# Detiene el worker (llamado en frame._exit_tree). Idempotente; en este motor
# wait_to_finish() es la única forma de reapear el Thread.
func stop():
	_mutex.lock()
	_want_stop = true
	_mutex.unlock()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


# --- API del Frame -----------------------------------------------------------

# Copia el snapshot del worker (bajo Mutex) y devuelve true si cambió state, value o
# detail. Arranca el worker en la primera llamada. `force` pide un refresco inmediato
# (flag que el worker atiende), nunca una consulta síncrona.
func refresh(force := false):
	if _thread == null:
		start()
	if force:
		_request_refresh()
	_mutex.lock()
	var ns = _snap_state
	var nv = _snap_value
	var nd = _snap_detail
	var nver = _snap_version
	_mutex.unlock()
	var changed = state != ns or value != nv or detail != nd
	state = ns
	value = nv
	detail = nd
	version = nver
	return changed


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


# Cambia la radio: encola la orden al worker (que ejecuta bluetoothctl power con timeout
# corto y actualiza el snapshot). Nunca bloquea la UI. Si no hay lectura fiable devuelve
# false sin adivinar; si no hay bluetoothctl/timeout tampoco.
func toggle_power():
	start()
	if state == "no_disponible":
		return false
	if state != "activo" and state != "apagado":
		# Sin estado fiable: pide una sonda y no ordena nada.
		_request_refresh()
		return false
	if _bluetoothctl == "" or _timeout == "":
		return false
	_mutex.lock()
	_toggle_pending = true
	_mutex.unlock()
	return true


# --- hilo de sonda -----------------------------------------------------------

func _stopped():
	_mutex.lock()
	var s = _want_stop
	_mutex.unlock()
	return s


func _refresh_requested():
	_mutex.lock()
	var r = _want_refresh
	_mutex.unlock()
	return r


func _request_refresh():
	_mutex.lock()
	_want_refresh = true
	_mutex.unlock()


func _take_toggle():
	_mutex.lock()
	var p = _toggle_pending
	_toggle_pending = false
	_mutex.unlock()
	return p


func _work(_userdata):
	while true:
		if _stopped():
			return
		_mutex.lock()
		_want_refresh = false
		_mutex.unlock()
		if _take_toggle():
			_do_toggle()
		var snap = _build_snapshot()
		_mutex.lock()
		if snap.state != _snap_state or snap.value != _snap_value or snap.detail != _snap_detail:
			_snap_state = snap.state
			_snap_value = snap.value
			_snap_detail = snap.detail
			_snap_version += 1
		_cur_state = _snap_state
		_mutex.unlock()
		var waited = 0
		while waited < PERIOD_MS:
			OS.delay_msec(SLEEP_STEP_MS)
			waited += SLEEP_STEP_MS
			if _stopped():
				return
			if _refresh_requested() or _toggle_requested():
				break


func _toggle_requested():
	_mutex.lock()
	var p = _toggle_pending
	_mutex.unlock()
	return p


# Sonda completa (sólo worker). Devuelve el snapshot.
func _build_snapshot():
	if _bluetoothctl == "":
		return _snap("no_disponible", "sin bt", "bluetoothctl no está instalado")
	if _timeout == "":
		return _snap("no_disponible", "sin bt", "falta coreutils timeout")
	var out = []
	var code = OS.execute(_timeout, [TIMEOUT_S, _bluetoothctl, "show"], true, out, true)
	var text = ""
	for line in out:
		text += String(line) + "\n"
	if code != 0:
		var motive = "bluetoothctl no respondió (timeout)" if code == 124 else "bluetoothctl falló (código %d)" % code
		return _snap("error", _error_value(), motive)
	var p = parse_bluetooth_show(text)
	if p.powered == "":
		if p.no_controller:
			return _snap("no_disponible", "sin bt", "no hay adaptador Bluetooth")
		return _snap("error", _error_value(), "respuesta inesperada de bluetoothctl")
	var on = p.powered == "yes"
	var who = p.name if p.name != "" else p.controller
	var d = "Bluetooth " + ("activo" if on else "apagado")
	if who != "":
		d += " — " + who
	if p.discovering == "yes":
		d += " · buscando"
	_last_value = "on" if on else "off"
	return _snap("activo" if on else "apagado", _last_value, d)


# Ejecuta `bluetoothctl power on|off` con timeout corto (sólo worker). No adivina: sin
# lectura fiable no toca la radio. Al fallar publica error; el bucle de sonda vuelve a
# leer el estado real después.
func _do_toggle():
	if _bluetoothctl == "" or _timeout == "":
		return
	if _cur_state != "activo" and _cur_state != "apagado":
		return
	var target = "off" if _cur_state == "activo" else "on"
	var out = []
	var code = OS.execute(_timeout, [TIMEOUT_S, _bluetoothctl, "power", target], true, out, true)
	if code != 0:
		var what = "apagar" if target == "off" else "encender"
		_mutex.lock()
		var lv = _last_value
		_snap_state = "error"
		_snap_value = lv if lv != "" else "error"
		_snap_detail = "no se pudo %s la radio (código %d)" % [what, code]
		_snap_version += 1
		_mutex.unlock()


# --- utilidades --------------------------------------------------------------

# Parser puro de `bluetoothctl show`: extrae Powered/Controller/Name/Discovering y
# detecta la ausencia de adaptador. Testeable sin I/O.
static func parse_bluetooth_show(text):
	var s = String(text)
	var res = {"powered": "", "controller": "", "name": "", "discovering": "", "no_controller": false}
	for raw in s.split("\n", false):
		var l = raw.strip_edges()
		if l.begins_with("Controller "):
			res.controller = l.substr("Controller ".length()).strip_edges()
		elif l.begins_with("Powered:"):
			res.powered = l.substr("Powered:".length()).strip_edges()
		elif l.begins_with("Name:"):
			res.name = l.substr("Name:".length()).strip_edges()
		elif l.begins_with("Discovering:"):
			res.discovering = l.substr("Discovering:".length()).strip_edges()
	if res.powered == "" and (s.findn("No default controller") >= 0 or s.findn("No controller") >= 0):
		res.no_controller = true
	return res


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
	_mutex.lock()
	var v = _last_value
	_mutex.unlock()
	return v if v != "" else "error"


# Snapshot inmutable de la sonda.
func _snap(s, v, d):
	return {"state": s, "value": v, "detail": d}
