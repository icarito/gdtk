extends Reference

# Applet Teclado del Frame (SPEC-sugar-frame-applets.md): distribución de teclado.
# Módulo autocontenido: no usa shell, no crea providers ni abre ventanas; el Frame
# conecta su UI con choose(layout). No aplica el mapa en vivo: el keymap de los
# clientes del compositor embebido y del input remoto se compila al arrancar, así que
# la elección sólo rige la PRÓXIMA sesión.
#
# El hilo de render NUNCA consulta (SPEC-screen-share-compass §0/§14): `localectl status`
# y la lectura del archivo de config corren en un worker (Thread + Mutex, como
# neighborhood.gd) que publica un snapshot atómico {state, value, detail, version}.
# refresh() sólo copia ese snapshot; choose() encola la escritura (Thread de un solo
# uso, tmp + rename) y pide un refresco, sin bloquear.
#
# Fuentes:
#   - sesión activa: XKB_DEFAULT_LAYOUT del entorno (lo que exporta session/keyboard.sh);
#     si falta, localectl status con timeout corto (dentro del worker).
#   - próxima sesión: ${XDG_CONFIG_HOME:-$HOME/.config}/gdtk/keyboard. Se lee y se
#     escribe como texto, sin evaluarlo (nunca `.` ni eval). choose() sólo escribe
#     líneas de variables con caracteres seguros para que keyboard.sh pueda sourcearlas.

const PERIOD_MS = 5000
const SLEEP_STEP_MS = 100
const TIMEOUT_S = "2"

# Ids exactos que ofrece el selector (frame.gd) y su etiqueta corta/larga. La etiqueta
# corta es la que cabe en el bloque de 44 px; la larga va al tooltip.
const LAYOUTS = {
	"es": {"label": "ES", "name": "Español (ES)"},
	"latam": {"label": "LAT", "name": "Latinoamericano (LAT)"},
	"us": {"label": "US", "name": "Inglés (US)"},
}

# activo | cambiando | error | sin_dato; se copian del snapshot del worker.
var state = "sin_dato"
var value = "sin dato"   # texto muy corto para el bloque (ES, LAT, US)
var detail = ""          # texto para tooltip; dice si requiere reiniciar la sesión
var version = 0

# Snapshot compartido con el worker (bajo _mutex).
var _snap_state = "sin_dato"
var _snap_value = "sin dato"
var _snap_detail = ""
var _snap_version = 0

# Cache de config leída por el worker; choose() la lee bajo Mutex. `_last_value` es el
# último valor activo real, para no fingir un estado en error.
var _config_exists = false
var _config_layout = ""
var _config_variant = ""
var _config_model = ""
var _config_options = ""
var _last_value = ""

# Resolución de binarios ($PATH, sin procesos): se hace en el hilo principal antes de
# arrancar el worker y sólo se lee desde éste.
var _timeout = ""
var _localectl = ""
var _probed = false

# Worker de sonda (Thread + Mutex) y escrituras de un solo uso (tmp + rename).
var _mutex = Mutex.new()
var _thread = null
var _want_stop = false
var _want_refresh = false
var _write_threads = []
var _write_states = []


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


# Detiene el worker y espera las escrituras pendientes (llamado en frame._exit_tree).
# Idempotente; en este motor wait_to_finish() es la única forma de reapear el Thread.
func stop():
	_mutex.lock()
	_want_stop = true
	_mutex.unlock()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	for th in _write_threads:
		th.wait_to_finish()
	_write_threads = []
	_write_states = []


# --- API del Frame -----------------------------------------------------------

# Copia el snapshot del worker (bajo Mutex) y devuelve true si cambió state, value o
# detail. Arranca el worker en la primera llamada. `force` pide un refresco inmediato
# (flag que el worker atiende), nunca una consulta síncrona.
func refresh(force := false):
	if _thread == null:
		start()
	_reap_writes()
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


# Elige la distribución para la próxima sesión. Sólo acepta ids exactos (es, latam, us);
# la escritura del archivo se delega a un Thread de un solo uso (tmp + rename) y no
# bloquea. Conserva las opciones XKB actuales sólo si tienen caracteres seguros.
# Devuelve true si encoló la escritura.
func choose(layout):
	if not LAYOUTS.has(layout):
		_apply_error("Distribución no válida: %s (sólo es, latam, us)." % str(layout))
		return false
	var path = _config_path()
	if path == "":
		_apply_error("no se pudo ubicar la configuración: falta HOME/XDG_CONFIG_HOME")
		return false
	# Opciones y modelo actuales: primero el entorno (lo que se aplicó), luego el
	# archivo leído por el worker (bajo Mutex). Sólo pasan valores con caracteres seguros.
	var env_model = OS.get_environment("XKB_DEFAULT_MODEL").strip_edges()
	var env_options = OS.get_environment("XKB_DEFAULT_OPTIONS").strip_edges()
	_mutex.lock()
	var cfg_model = _config_model
	var cfg_options = _config_options
	_mutex.unlock()
	var model = _safe_xkb(env_model if env_model != "" else cfg_model)
	var options = _safe_xkb(env_options if env_options != "" else cfg_options)
	var body = "XKB_DEFAULT_LAYOUT=%s\nXKB_DEFAULT_VARIANT=\nXKB_DEFAULT_MODEL=%s\nXKB_DEFAULT_OPTIONS=%s\n" \
		% [layout, model, options]
	_write_config_async(path, body)
	# Refresca para mostrar el pendiente cuando el worker relea el archivo ya escrito.
	start()
	_request_refresh()
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


func _work(_userdata):
	while true:
		if _stopped():
			return
		# Consume la petición de refresco antes de sondear: si llega otra durante la
		# sonda, el bucle de espera la ve y vuelve a sondear de inmediato.
		_mutex.lock()
		_want_refresh = false
		_mutex.unlock()
		var snap = _build_snapshot()
		_mutex.lock()
		if snap.state != _snap_state or snap.value != _snap_value or snap.detail != _snap_detail:
			_snap_state = snap.state
			_snap_value = snap.value
			_snap_detail = snap.detail
			_snap_version += 1
		_mutex.unlock()
		var waited = 0
		while waited < PERIOD_MS:
			OS.delay_msec(SLEEP_STEP_MS)
			waited += SLEEP_STEP_MS
			if _stopped():
				return
			if _refresh_requested():
				break


# Sonda completa (sólo worker): entorno + config + localectl. Devuelve el snapshot.
func _build_snapshot():
	var env_layout = OS.get_environment("XKB_DEFAULT_LAYOUT").strip_edges()
	var cfg = _read_config()
	var active = env_layout
	if active == "":
		if _localectl == "":
			# Sin entorno y sin localectl no hay de dónde leer: sin_dato, no se inventa.
			if cfg.layout != "":
				return _snap("cambiando", _label(cfg.layout),
					"%s elegida para la próxima sesión. No se pudo leer la distribución actual (falta localectl). El cambio requiere reiniciar la sesión." % _name(cfg.layout))
			return _snap("sin_dato", "sin dato",
				"sin XKB_DEFAULT_LAYOUT en el entorno y localectl no está instalado")
		var read = _localectl_layout()
		if read.error != "":
			return _snap("error", _error_value(), read.error)
		active = read.layout

	if active == "":
		# X11 Layout ausente en localectl: no se inventa una distribución.
		if cfg.layout != "":
			return _snap("cambiando", _label(cfg.layout),
				"%s elegida para la próxima sesión. No se pudo leer la distribución actual. El cambio requiere reiniciar la sesión." % _name(cfg.layout))
		return _snap("sin_dato", "sin dato",
			"sin distribución X11 configurada (ni XKB_DEFAULT_LAYOUT ni localectl)")

	_last_value = _label(active)
	var pending = cfg.layout
	if pending != "" and pending != active:
		# La sesión sigue con `active`; el archivo rige la próxima. No se afirma cambio vivo.
		return _snap("cambiando", _label(pending),
			"Ahora: %s. Próxima sesión: %s. El cambio no se aplica en vivo: requiere reiniciar la sesión." % [_name(active), _name(pending)])
	return _snap("activo", _label(active),
		"Distribución %s activa en esta sesión. Cambiarla requiere reiniciar la sesión." % _name(active))


# Consulta localectl status una vez (sólo worker). Devuelve {"layout": "...", "error": "..."}
# con error vacío si pudo leer; layout vacío es válido (X11 Layout ausente). Nunca lanza
# procesos si falta localectl.
func _localectl_layout():
	if _localectl == "":
		return {"layout": "", "error": "no se pudo leer el teclado: falta localectl y XKB_DEFAULT_LAYOUT"}
	var out = []
	var code = 0
	if _timeout != "":
		code = OS.execute(_timeout, [TIMEOUT_S, _localectl, "status"], true, out, true)
	else:
		code = OS.execute(_localectl, ["status"], true, out, true)
	if code == 124:
		return {"layout": "", "error": "localectl no respondió (timeout)"}
	if code != 0:
		return {"layout": "", "error": "localectl falló (código %d)" % code}
	var text = ""
	for line in out:
		text += String(line) + "\n"
	return {"layout": parse_localectl_layout(text), "error": ""}


# Parser puro del `localectl status`: extrae el X11 Layout. Testeable sin I/O.
static func parse_localectl_layout(text):
	var layout = ""
	for raw in String(text).split("\n", false):
		var l = raw.strip_edges()
		if l.begins_with("X11 Layout:"):
			layout = l.substr("X11 Layout:".length()).strip_edges()
	return layout


# --- config (lectura en el worker, escritura en Thread de un solo uso) --------

# Lee ~/.config/gdtk/keyboard como texto (sin evaluar) y publica en la cache compartida
# sólo los valores con caracteres seguros. Un valor inseguro o ausente queda vacío.
# Sólo lo llama el worker; choose() lee la cache bajo Mutex.
func _read_config():
	var res = {"exists": false, "layout": "", "variant": "", "model": "", "options": ""}
	var path = _config_path()
	if path != "":
		var f = File.new()
		if f.file_exists(path) and f.open(path, File.READ) == OK:
			var text = f.get_as_text()
			f.close()
			res.exists = true
			for raw in text.split("\n", false):
				var l = raw.strip_edges()
				if l == "" or l.begins_with("#"):
					continue
				var eq = l.find("=")
				if eq < 0:
					continue
				var key = l.substr(0, eq).strip_edges()
				var val = _safe_xkb(l.substr(eq + 1))
				match key:
					"XKB_DEFAULT_LAYOUT":
						res.layout = val
					"XKB_DEFAULT_VARIANT":
						res.variant = val
					"XKB_DEFAULT_MODEL":
						res.model = val
					"XKB_DEFAULT_OPTIONS":
						res.options = val
	_mutex.lock()
	_config_exists = res.exists
	_config_layout = res.layout
	_config_variant = res.variant
	_config_model = res.model
	_config_options = res.options
	_mutex.unlock()
	return res


# Escribe el archivo de config en un Thread de un solo uso (tmp + rename atómico).
func _write_config_async(path, body):
	var state = {"done": false}
	var th = Thread.new()
	_write_threads.append(th)
	_write_states.append(state)
	th.start(self, "_write_config_work", {"path": path, "body": body, "state": state})


func _write_config_work(userdata):
	var path = String(userdata.get("path", ""))
	var body = String(userdata.get("body", ""))
	if path != "":
		var dir = Directory.new()
		dir.make_dir_recursive(path.get_base_dir())
		if dir.dir_exists(path.get_base_dir()):
			var tmp = path + ".tmp"
			var w = File.new()
			if w.open(tmp, File.WRITE) != OK:
				printerr("applet_keyboard: no se pudo escribir ", tmp)
			else:
				w.store_string(body)
				w.close()
				if dir.rename(tmp, path) != OK:
					printerr("applet_keyboard: no se pudo renombrar ", tmp, " a ", path)
	# Pide al worker releer el archivo ya escrito; publica el fin sin bloquear.
	_mutex.lock()
	_want_refresh = true
	userdata.state.done = true
	_mutex.unlock()


# Reapea los Threads de escritura ya terminados. is_active() no baja hasta
# wait_to_finish(): el fin lo publica el propio Thread con el flag `done` bajo Mutex.
func _reap_writes():
	for i in range(_write_threads.size() - 1, -1, -1):
		var st = _write_states[i]
		_mutex.lock()
		var done = st.done
		_mutex.unlock()
		if done:
			_write_threads[i].wait_to_finish()
			_write_threads.remove(i)
			_write_states.remove(i)


# Ruta del archivo que lee session/keyboard.sh, o "" si no hay HOME ni XDG_CONFIG_HOME.
func _config_path():
	var base = OS.get_environment("XDG_CONFIG_HOME").strip_edges()
	if base == "":
		var home = OS.get_environment("HOME").strip_edges()
		if home == "":
			return ""
		base = home + "/.config"
	return base + "/gdtk/keyboard"


# --- utilidades --------------------------------------------------------------

# Valor XKB seguro para escribir y sourcear sin comillas: sólo letras, dígitos y los
# separadores de la sintaxis XKB (_ - , : + .). Cualquier otro carácter (espacio,
# comillas, $, `, ;, \...) invalida el valor y se devuelve "" (se deja vacío).
func _safe_xkb(text):
	var s = String(text).strip_edges()
	if s == "":
		return ""
	for i in range(s.length()):
		var c = s[i]
		if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") \
				or c == "_" or c == "-" or c == "," or c == ":" or c == "+" or c == "."):
			return ""
	return s


# Etiqueta corta de un layout (ES/LAT/US); un layout desconocido se abrevia en 4 letras.
func _label(layout):
	if LAYOUTS.has(layout):
		return LAYOUTS[layout]["label"]
	return layout.to_upper().substr(0, 4)


# Nombre largo de un layout para el tooltip.
func _name(layout):
	if LAYOUTS.has(layout):
		return LAYOUTS[layout]["name"]
	return layout


# Resuelve timeout y localectl una sola vez, buscándolos en $PATH sin lanzar procesos.
func _probe():
	if _probed:
		return
	_probed = true
	_timeout = _which("timeout")
	_localectl = _which("localectl")


# Ruta absoluta de un ejecutable en $PATH, o "" si no está. Sólo File, sin shell.
func _which(prog):
	for d in OS.get_environment("PATH").split(":", false):
		if d != "" and File.new().file_exists(d + "/" + prog):
			return d + "/" + prog
	return ""


# Valor textual a mostrar en error: el último activo real, o genérico si nunca hubo lectura.
func _error_value():
	_mutex.lock()
	var v = _last_value
	_mutex.unlock()
	return v if v != "" else "error"


# Snapshot inmutable de la sonda.
func _snap(s, v, d):
	return {"state": s, "value": v, "detail": d}


# Error de validación en el hilo principal: publica en el snapshot y en los campos
# públicos para que el tooltip/popup lo vean sin esperar al worker.
func _apply_error(msg):
	_mutex.lock()
	var v = _last_value if _last_value != "" else "error"
	_snap_state = "error"
	_snap_value = v
	_snap_detail = msg
	_snap_version += 1
	var ver = _snap_version
	_mutex.unlock()
	state = "error"
	value = v
	detail = msg
	version = ver
