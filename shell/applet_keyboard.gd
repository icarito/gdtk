extends Reference

# Applet Teclado del Frame (SPEC-sugar-frame-applets.md): distribución de teclado.
# Módulo autocontenido: no usa shell, no crea providers ni abre ventanas; el Frame
# conecta su UI con apply(layout) / next_layout() / toggle_active(layout). El módulo sólo
# lleva el estado (lista activa + distribución en uso) y lo persiste; aplicar el mapa en
# vivo (compositor.set_keymap + swaymsg + OSD) es del shell (apply_keyboard_layout). El
# keymap del input remoto (EIS) se compila al arrancar: ponytail: sigue la PRÓXIMA sesión.
#
# El hilo de render NUNCA consulta (SPEC-screen-share-compass §0/§14): `localectl status`
# y la lectura del archivo de config corren en un worker (Thread + Mutex, como
# neighborhood.gd) que publica un snapshot atómico {state, value, detail, version}.
# refresh() sólo copia ese snapshot; apply()/toggle_active() encolan la escritura (Thread
# de un solo uso, tmp + rename) y piden un refresco, sin bloquear.
#
# Fuentes:
#   - sesión activa: XKB_DEFAULT_LAYOUT del entorno (lo que exporta session/keyboard.sh);
#     si falta, localectl status con timeout corto (dentro del worker).
#   - próxima sesión: ${XDG_CONFIG_HOME:-$HOME/.config}/gdtk/keyboard. Se lee y se
#     escribe como texto, sin evaluarlo (nunca `.` ni eval). Sólo se escriben líneas de
#     variables con caracteres seguros para que keyboard.sh pueda sourcearlas.
#     GDTK_LAYOUTS=latam,es es la lista activa (Super+Espacio rota entre ellas); su
#     primera entrada es también XKB_DEFAULT_LAYOUT: la sesión siguiente arranca con ella.

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
# Lista activa (ids en orden) y distribución en uso. Sólo hilo principal; se siembran
# una vez desde el worker (entorno + archivo) en refresh().
var active = []
var current = ""

# Snapshot compartido con el worker (bajo _mutex).
var _snap_state = "sin_dato"
var _snap_value = "sin dato"
var _snap_detail = ""
var _snap_version = 0

# Cache de config leída por el worker; _persist_active() la lee bajo Mutex. `_last_value` es el
# último valor activo real, para no fingir un estado en error.
var _config_exists = false
var _config_layout = ""
var _config_variant = ""
var _config_model = ""
var _config_options = ""
var _last_value = ""
var _config_active = []      # GDTK_LAYOUTS leído por el worker
var _config_read = false     # el worker ya leyó la config al menos una vez
var _live = ""               # distribución aplicada en vivo (la que gana sobre el entorno)

# Resolución de binarios ($PATH, sin procesos): se hace en el hilo principal antes de
# arrancar el worker y sólo se lee desde éste.
var _timeout = ""
var _localectl = ""
var _probed = false

# Worker de sonda (Thread + Mutex) y UN escritor con coalescencia (tmp + rename). Un
# solo hilo escritor evita que dos tmp+rename concurrentes compartan el .tmp y se pise
# la escritura: si llegan varias, gana el último cuerpo (se descartan los intermedios).
var _mutex = Mutex.new()
var _thread = null
var _want_stop = false
var _want_refresh = false
var _writer = null
var _write_pending = false
var _write_path = ""
var _write_body = ""


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
	if _writer != null:
		_writer.wait_to_finish()
		_writer = null


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
	if current == "" and _seed_active():
		changed = true
	state = ns
	value = nv
	detail = nd
	version = nver
	return changed


# Siembra `active`/`current` cuando el worker ya leyó la config. Lista por defecto:
# [XKB_DEFAULT_LAYOUT]. Devuelve true si sembró.
func _seed_active():
	_mutex.lock()
	var ready = _config_read
	var cfg = _config_active.duplicate()
	var cfg_layout = _config_layout
	_mutex.unlock()
	if not ready:
		return false
	var env = _safe_xkb(OS.get_environment("XKB_DEFAULT_LAYOUT"))
	var list = []
	for l in cfg:
		if LAYOUTS.has(l) and not list.has(l):
			list.append(l)
	if list.empty():
		var first = env if env != "" else cfg_layout
		if LAYOUTS.has(first):
			list.append(first)
	active = list
	current = env if env != "" else (list[0] if not list.empty() else "")
	return current != ""


# Siguiente distribución de la lista activa tras `current` ("" si hay menos de dos).
func next_layout():
	if active.size() < 2:
		return ""
	var i = active.find(current)
	return active[(i + 1) % active.size()]


# Marca `layout` como en uso (la aplicación en vivo la hace el shell). Si no estaba en
# la lista activa la agrega. Persiste y refresca. Devuelve true si es un id válido.
func apply(layout):
	if not LAYOUTS.has(layout):
		_apply_error("Distribución no válida: %s (sólo es, latam, us)." % str(layout))
		return false
	if not active.has(layout):
		active.append(layout)
	current = layout
	_mutex.lock()
	_live = layout
	_mutex.unlock()
	_persist_active()
	return true


# Agrega o quita `layout` de la lista activa (siempre queda al menos una). Quitar la
# que está en uso no cambia el teclado en vivo: la próxima rotación sale de la lista.
func toggle_active(layout):
	if not LAYOUTS.has(layout):
		return false
	if active.has(layout):
		if active.size() < 2:
			return false
		active.erase(layout)
	else:
		active.append(layout)
	_persist_active()
	return true


func name_of(layout):
	return _name(layout)


# Escribe el archivo de config con la lista activa (primera = XKB_DEFAULT_LAYOUT).
# Conserva modelo y opciones actuales sólo si tienen caracteres seguros. Sin bloquear.
func _persist_active():
	var path = _config_path()
	if path == "":
		_apply_error("no se pudo ubicar la configuración: falta HOME/XDG_CONFIG_HOME")
		return
	var env_model = OS.get_environment("XKB_DEFAULT_MODEL").strip_edges()
	var env_options = OS.get_environment("XKB_DEFAULT_OPTIONS").strip_edges()
	_mutex.lock()
	var cfg_model = _config_model
	var cfg_options = _config_options
	_config_active = active.duplicate()
	_mutex.unlock()
	var model = _safe_xkb(env_model if env_model != "" else cfg_model)
	var options = _safe_xkb(env_options if env_options != "" else cfg_options)
	var body = "XKB_DEFAULT_LAYOUT=%s\nXKB_DEFAULT_VARIANT=\nXKB_DEFAULT_MODEL=%s\nXKB_DEFAULT_OPTIONS=%s\nGDTK_LAYOUTS=%s\n" \
		% [active[0], model, options, PoolStringArray(active).join(",")]
	# ponytail: dos escrituras casi simultáneas comparten el .tmp; con clics humanos no ocurre.
	_write_config_async(path, body)
	start()
	_request_refresh()


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
	_mutex.lock()
	var live = _live
	_mutex.unlock()
	if live != "":
		# Aplicada en vivo desde el shell: gana sobre el entorno de arranque.
		_last_value = _label(live)
		return _snap("activo", _label(live),
			"Distribución %s activa. Super+Espacio rota entre las elegidas." % _name(live))
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
# Sólo lo llama el worker; _persist_active() lee la cache bajo Mutex.
func _read_config():
	var res = {"exists": false, "layout": "", "variant": "", "model": "", "options": "", "layouts": []}
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
					"GDTK_LAYOUTS":
						for id in val.split(",", false):
							if not res.layouts.has(id):
								res.layouts.append(id)
	_mutex.lock()
	_config_exists = res.exists
	_config_layout = res.layout
	_config_variant = res.variant
	_config_model = res.model
	_config_options = res.options
	_config_active = res.layouts
	_config_read = true
	_mutex.unlock()
	return res


# Encola la escritura (tmp + rename) con coalescencia: un único hilo escritor toma el
# último cuerpo pedido. Nunca hay dos tmp+rename a la vez, así que clics seguidos no se
# pisan (el penúltimo estado se descarta y gana el último).
func _write_config_async(path, body):
	_mutex.lock()
	_write_path = path
	_write_body = body
	_write_pending = true
	var start_writer = _writer == null
	_mutex.unlock()
	if start_writer:
		_writer = Thread.new()
		_writer.start(self, "_write_loop")


func _write_loop(_userdata):
	while true:
		_mutex.lock()
		var pending = _write_pending
		var path = _write_path
		var body = _write_body
		var stop = _want_stop
		_write_pending = false
		_mutex.unlock()
		if pending:
			_write_config_now(path, body)
			# Pide al worker releer el archivo ya escrito.
			_mutex.lock()
			_want_refresh = true
			_mutex.unlock()
		if stop:
			return
		if not pending:
			OS.delay_msec(SLEEP_STEP_MS)


func _write_config_now(path, body):
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
