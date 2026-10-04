extends Reference

# Applet Portapapeles del Frame: historial de lo copiado en las apps embebidas y el
# último ítem a la vista. Es la dockapp de ejemplo de `.operator-shared/guides/dockapp.md`
# (contrato: state/value/detail, refresh(force) -> bool, stop(), draw opcional).
#
# Captura: `session/gdtk-clipboard watch <socket>` deja un `wl-paste --watch` vivo
# contra el compositor embebido (ext-data-control-v1) que guarda cada copia como un
# archivo en $XDG_RUNTIME_DIR/gdtk/clipboard. Este módulo sólo LEE ese directorio.
#
# El hilo de render NUNCA consulta (SPEC-screen-share-compass §14): el worker lista el
# directorio, lee la entrada nueva y (re)lanza el vigía; refresh() copia el snapshot.

const PERIOD_MS = 1000
const SLEEP_STEP_MS = 100
const RELAUNCH_MS = 10000   # cada cuánto se reintenta el vigía si murió
const MAX_FAILS = 3         # vigía que no arranca N veces -> no_disponible, sin bucle
const READ_MAX = 4096       # bytes leídos de la entrada (sólo para resumir)
const SYNC_MAX = 65536      # tope de lo que se comparte con el Grupo (= tope de `store`)

var state = "sin_dato"
var value = ""     # resumen corto del último ítem (una línea)
var detail = ""    # tooltip: más texto + tamaño del historial

# Lo fija el Frame antes del primer refresh(): socket del compositor embebido.
var wayland_display = ""

var _mutex = Mutex.new()
var _thread = null
var _want_stop = false
var _snap = {"state": "sin_dato", "value": "", "detail": ""}
# Portapapeles compartido con el Grupo (SPEC-sugar-group «Portapapeles»): el worker
# deja cada copia local nueva en `_outbox`; el shell la reparte por el canal peer.
var _outbox = []
var _last_received = ""


# --- API del Frame -----------------------------------------------------------

func refresh(_force := false):
	if _thread == null:
		_want_stop = false
		_thread = Thread.new()
		_thread.start(self, "_work", _paths())
	_mutex.lock()
	var s = _snap
	_mutex.unlock()
	var changed = state != s.state or value != s.value or detail != s.detail
	state = s.state
	value = s.value
	detail = s.detail
	return changed


# Copias locales nuevas desde la última llamada (texto completo, hasta SYNC_MAX).
func take_outbox():
	_mutex.lock()
	var out = _outbox
	_outbox = []
	_mutex.unlock()
	return out


# Texto que llegó de otro equipo: pasa a ser la selección local. No se reenvía
# (el vigía lo guarda como entrada nueva y el worker lo reconoce por `_last_received`).
func receive(text):
	var t = String(text)
	var d = String(wayland_display)
	if t == "" or d == "" or not d.is_valid_filename():
		return false
	var p = _paths()
	Directory.new().make_dir_recursive(p.dir.get_base_dir())
	var tmp = p.dir.get_base_dir().plus_file("clip-in.%d" % OS.get_ticks_usec())
	var f = File.new()
	if f.open(tmp, File.WRITE) != OK:
		return false
	f.store_string(t)
	f.close()
	_mutex.lock()
	_last_received = t
	_mutex.unlock()
	# El texto viaja por archivo (XDG_RUNTIME_DIR, 0700), nunca por argumentos.
	OS.execute("sh", ["-c", "'%s' set '%s' '%s' </dev/null >>'%s' 2>&1 &" % [p.script, d, tmp, p.log]], true)
	return true


func stop():
	_mutex.lock()
	_want_stop = true
	_mutex.unlock()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


# Dibujo propio dentro de la placa (scr: coords de pantalla, loc: locales a la ventana).
# `frame` presta sus helpers de fuente/glifo para que la tesela combine con el resto.
func draw(frame, ui, scr, loc, w, h):
	var g = min(w, h) * 0.46
	var col = frame.NX_TEXT if state == "activo" else frame.NX_TEXT_DIM
	frame._draw_shared_glyph(ui, Rect2(scr + Vector2((w - g) * 0.5, h * 0.06), Vector2(g, g)), "clipboard", col)
	var text = value
	if state != "activo":
		text = "no disp." if state == "no_disponible" else "vacío"
	var small = frame._push_label_font(ui)
	text = frame._truncate_w(ui, text, w - 6.0)
	ui.set_cursor_pos(loc + Vector2(max(3.0, (w - frame._text_w(ui, text)) * 0.5), h * 0.64))
	ui.text_colored(col, text)
	if small:
		ui.pop_font()


# --- puro (testeable) --------------------------------------------------------

# Primera línea no vacía, con espacios colapsados. "" si no hay texto.
static func summary(text):
	for line in String(text).split("\n", false):
		var s = String(line).strip_edges().replace("\t", " ")
		while s.find("  ") >= 0:
			s = s.replace("  ", " ")
		if s != "":
			return s
	return ""


# Entrada más nueva: nombres = reloj en ns de igual largo, el mayor lexicográfico gana.
static func newest(names):
	var best = ""
	for n in names:
		if not String(n).begins_with(".") and String(n) > best:
			best = String(n)
	return best


# --- hilo de trabajo ---------------------------------------------------------

func _paths():
	var run = OS.get_environment("XDG_RUNTIME_DIR")
	if run == "":
		run = "/tmp"
	return {
		"dir": run + "/gdtk/clipboard",
		"script": ProjectSettings.globalize_path("res://").plus_file("../session/gdtk-clipboard").simplify_path(),
		"log": run + "/gdtk-clipboard.log",
		"display": wayland_display,
	}


func _stopped():
	_mutex.lock()
	var s = _want_stop
	_mutex.unlock()
	return s


func _work(p):
	var last_name = null   # null: la primera vuelta siempre publica (listo/activo)
	var fails = 0
	var launch_at = 0
	var snap = {"state": "sin_dato", "value": "", "detail": ""}
	while not _stopped():
		var now = OS.get_ticks_msec()
		if fails < MAX_FAILS and now >= launch_at:
			launch_at = now + RELAUNCH_MS
			if _watcher_alive(p.dir):
				fails = 0
			else:
				_launch(p)
				fails += 1   # se confirma vivo en la próxima vuelta (lock tomado)
		var names = _list(p.dir)
		var name = newest(names)
		if last_name == null or name != last_name:
			if last_name != null and name != "":
				_queue_sync(_read(p.dir.plus_file(name), SYNC_MAX))
			last_name = name
			var text = _read(p.dir.plus_file(name)) if name != "" else ""
			snap = {"state": "activo" if name != "" else "listo",
				"value": summary(text),
				"detail": "Portapapeles: %s\n\n%d en el historial" % [text.substr(0, 300), names.size()]}
		if fails >= MAX_FAILS and name == "":
			snap = {"state": "no_disponible", "value": "",
				"detail": "Portapapeles: no se pudo vigilar (falta wl-paste o el motor no trae ext-data-control). Ver %s" % p.log}
		_mutex.lock()
		_snap = snap
		_mutex.unlock()
		var waited = 0
		while waited < PERIOD_MS and not _stopped():
			OS.delay_msec(SLEEP_STEP_MS)
			waited += SLEEP_STEP_MS


# El vigía vivo tiene el lock: `flock -n` falla (≠ 0) si está tomado.
func _watcher_alive(dir):
	if not Directory.new().file_exists(dir.plus_file(".lock")):
		return false
	return OS.execute("flock", ["-n", dir.plus_file(".lock"), "true"], true) != 0


# `sh -c '... &'` para que el vigía quede colgado de init (sin zombies en Godot).
# El socket viene del motor; se valida igual porque va dentro de un comando de shell.
func _launch(p):
	var d = String(p.display)
	if d == "" or not d.is_valid_filename() or d.find("'") >= 0:
		return
	OS.execute("sh", ["-c", "'%s' watch '%s' </dev/null >>'%s' 2>&1 &" % [p.script, d, p.log]], true)


func _list(dir):
	var out = []
	var da = Directory.new()
	if da.open(dir) != OK:
		return out
	da.list_dir_begin(true, true)
	var n = da.get_next()
	while n != "":
		if not da.current_is_dir():
			out.append(n)
		n = da.get_next()
	da.list_dir_end()
	return out


func _queue_sync(text):
	_mutex.lock()
	if text != "" and text != _last_received:
		_outbox.append(text)
	_mutex.unlock()


func _read(path, limit = READ_MAX):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var t = f.get_buffer(min(f.get_len(), limit)).get_string_from_utf8()
	f.close()
	return t
