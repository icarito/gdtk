extends Reference

# Applet Volumen del Frame (contrato: .operator-shared/guides/dockapp.md): muestra el
# volumen de la salida de audio actual (o "mute") y permite elegir otra salida.
#
# El hilo de render NUNCA lanza procesos (SPEC-screen-share-compass §0/§14): todo
# `OS.execute` (wpctl/pactl) corre en un worker (Thread + Mutex) que publica un
# snapshot atómico {state, value, detail, sinks, sink}. refresh() sólo copia ese
# snapshot; choose() sólo encola la salida elegida y no arranca el worker (el Frame ya
# llama refresh() cada frame, que es quien lo arranca).
#
# El worker, cada PERIOD_MS, corre en este orden:
#   - `wpctl get-volume @DEFAULT_AUDIO_SINK@` → volumen/mute (parse_wpctl de system_osd).
#   - `pactl info` → nombre de la salida por defecto (audio_send.parse_default_sink).
#   - `pactl list short sinks` → salidas disponibles (audio_send.parse_sinks).
# Al aplicar un pedido de choose(): `pactl set-default-sink <sink>` y luego mueve los
# streams vivos con audio_send.move_argvs() (requiere parse_sink_inputs de
# `pactl list short sink-inputs`), para que el audio no quede en la salida anterior.
#
# Al usuario se le muestran nombres en español; nunca se nombran las herramientas
# (wpctl/pactl) ni sus errores crudos.

const PERIOD_MS = 3000
const SLEEP_STEP_MS = 100
const TIMEOUT_S = "2"

# activo | cambiando | sin_dato | no_disponible | error.
var state = "sin_dato"
var value = "sin dato"   # texto muy corto para el bloque ("78%" / "mute")
var detail = ""          # tooltip: nombre de la salida actual
# Salidas de audio disponibles y la actual; se copian del snapshot en refresh().
var sinks = []
var current_sink = ""

# Snapshot compartido con el worker (bajo _mutex). `sink` = salida por defecto.
var _snap = {"state": "sin_dato", "value": "sin dato", "detail": "", "sinks": [], "sink": ""}

# Worker (Thread + Mutex) y pedido pendiente de choose().
var _mutex = Mutex.new()
var _thread = null
var _want_stop = false
var _want_refresh = false
var _want_sink = ""

# Resolución de binarios y carga de parsers: en el hilo principal, antes de arrancar
# el worker (que sólo los lee). `load()` no se hace desde el hilo de fondo.
var _probed = false
var _timeout = ""
var _wpctl = ""
var _pactl = ""
var _osd = null
var _send = null


# --- ciclo de vida -----------------------------------------------------------

# Arranca el worker de sonda (idempotente). Resuelve binarios y parsers primero.
func start():
	if _thread != null:
		return
	_probe()
	_mutex.lock()
	_want_stop = false
	_mutex.unlock()
	_thread = Thread.new()
	_thread.start(self, "_work")


func running():
	return _thread != null


# Detiene el worker (llamado en frame._exit_tree). Idempotente.
func stop():
	_mutex.lock()
	_want_stop = true
	_mutex.unlock()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


# --- API del Frame -----------------------------------------------------------

# Copia el snapshot del worker (bajo Mutex) y devuelve true si cambió algo. Arranca el
# worker en la primera llamada. Mientras haya un pedido de salida pendiente, muestra
# "cambiando" sin esperar al worker.
func refresh(force := false):
	if _thread == null:
		start()
	if force:
		_request_refresh()
	_mutex.lock()
	var s = _snap
	var pending = _want_sink
	_mutex.unlock()
	var nsink = String(s.sink)
	var nsinks = s.sinks
	var nstate = "cambiando" if pending != "" else String(s.state)
	var ndetail = "Cambiando la salida de audio…" if pending != "" else String(s.detail)
	var changed = state != nstate or value != s.value or detail != ndetail \
		or current_sink != nsink or str(sinks) != str(nsinks)
	state = nstate
	value = s.value
	detail = ndetail
	current_sink = nsink
	sinks = nsinks
	return changed


# Elige la salida de audio. Sólo encola el pedido (no lanza procesos ni arranca el
# worker): el worker lo aplica en su próxima vuelta. Devuelve true si encoló.
func choose(sink):
	var s = String(sink).strip_edges()
	if s == "":
		_apply_error("no se eligió ninguna salida de audio")
		return false
	_mutex.lock()
	_want_sink = s
	_want_refresh = true
	_mutex.unlock()
	state = "cambiando"
	detail = "Cambiando la salida de audio…"
	return true


# --- dibujo en el bloque LCD (lo llama _draw_applet) -------------------------

# Indicador VERTICAL de LED verde retro: columna de segmentos que se encienden de
# abajo hacia arriba según el volumen, con el valor abajo. Mute/ sin dato: apagado.
# El volumen se cambia con la rueda (o pan de touchpad) sobre el bloque, no arrastrando.
func draw(frame, ui, scr, loc, w, h):
	var on = state == "activo"
	var led = frame.VOLUME_LED
	var dim = frame.VOLUME_LED_DIM
	var pct = 0.0
	var muted = false
	if on:
		if value == "mute":
			muted = true
		elif value.ends_with("%"):
			pct = clamp(float(value.trim_suffix("%")) / 100.0, 0.0, 1.0)
	# El texto usa la fuente chica de labels; su alto real reserva el pie del bloque
	# (con la fuente por defecto el "%" se salía por abajo del LCD).
	var txt = value if on else ("--" if state == "no_disponible" else "…")
	var small = frame._push_label_font(ui)
	var th = 12.0
	if ui.has_method("calc_text_size"):
		th = max(8.0, ui.calc_text_size("00%").y)
	var text_h = th + 1.0
	var n = 12
	var gap = 1.0
	var bar_top = loc.y + 2.0
	var bar_bot = loc.y + h - text_h
	var cell_h = max(2.0, (bar_bot - bar_top - float(n - 1) * gap) / float(n))
	var cw = max(10.0, w * 0.42)
	var cx = loc.x + (w - cw) * 0.5
	var lit = 0 if (muted or not on) else int(round(pct * float(n)))
	for i in range(n):
		var cell_y = bar_bot - float(i + 1) * cell_h - float(i) * gap
		if i < lit:
			ui.imgui_draw_rect_filled(Rect2(Vector2(cx - 1.0, cell_y - 0.5), Vector2(cw + 2.0, cell_h + 1.0)),
				Color(led.r, led.g, led.b, 0.20), 0.0)
		var c = led if i < lit else dim
		ui.imgui_draw_rect_filled(Rect2(Vector2(cx, cell_y), Vector2(cw, cell_h)), c, 0.0)
	var tw = frame._text_w(ui, txt)
	ui.set_cursor_pos(Vector2(loc.x + max(1.0, (w - tw) * 0.5), bar_bot))
	ui.text_colored(led if on else dim, txt)
	if small:
		ui.pop_font()


# --- hilo de trabajo ---------------------------------------------------------

func _stopped():
	_mutex.lock()
	var b = _want_stop
	_mutex.unlock()
	return b


func _refresh_requested():
	_mutex.lock()
	var b = _want_refresh
	_mutex.unlock()
	return b


func _request_refresh():
	_mutex.lock()
	_want_refresh = true
	_mutex.unlock()


# Toma (y limpia) el pedido de salida pendiente. "" si no hay ninguno.
func _take_pending_sink():
	_mutex.lock()
	var s = _want_sink
	if s != "":
		_want_sink = ""
	_mutex.unlock()
	return s


func _work(_userdata = null):
	while not _stopped():
		_mutex.lock()
		_want_refresh = false
		_mutex.unlock()
		var pending = _take_pending_sink()
		if pending != "":
			_apply_sink(pending)
		var snap = _build_snapshot()
		_mutex.lock()
		_snap = snap
		_mutex.unlock()
		var waited = 0
		while waited < PERIOD_MS:
			OS.delay_msec(SLEEP_STEP_MS)
			waited += SLEEP_STEP_MS
			if _stopped():
				return
			if _refresh_requested():
				break


# Aplica la salida elegida y mueve los streams activos (sólo worker).
func _apply_sink(sink):
	if _pactl == "":
		return
	var out = []
	OS.execute(_pactl, ["set-default-sink", String(sink)], true, out, true)
	var r = _run([_pactl, "list", "short", "sink-inputs"])
	var ids = _send.parse_sink_inputs(r.text) if _send != null else []
	if _send != null:
		for argv in _send.move_argvs(ids, sink):
			OS.execute(_pactl, argv, true, out, true)


# Sonda completa (sólo worker). Devuelve el snapshot.
func _build_snapshot():
	var snap = {"state": "sin_dato", "value": "sin dato", "detail": "", "sinks": [], "sink": ""}
	if _pactl == "" and _wpctl == "":
		snap.state = "no_disponible"
		snap.detail = "No se encontró el control de audio del sistema."
		return snap

	var info = _run([_pactl, "info"]) if _pactl != "" else {"code": 1, "text": ""}
	var current = _send.parse_default_sink(info.text) if _send != null else ""
	var short = _run([_pactl, "list", "short", "sinks"]) if _pactl != "" else {"code": 1, "text": ""}
	snap.sinks = _send.parse_sinks(short.text) if _send != null else []
	snap.sink = current

	var vol = _read_volume()
	if not vol.ok:
		snap.state = "no_disponible"
		snap.value = "sin dato"
		snap.detail = "No se pudo leer el volumen de esta salida."
		return snap
	snap.state = "activo"
	snap.value = "mute" if vol.muted else ("%d%%" % int(round(vol.volume * 100.0)))
	snap.detail = current if current != "" else "Sin salida de audio detectada"
	return snap


# `wpctl get-volume @DEFAULT_AUDIO_SINK@` parseado con system_osd.parse_wpctl (sólo worker).
func _read_volume():
	var res = {"ok": false, "volume": -1.0, "muted": false}
	if _wpctl == "" or _osd == null:
		return res
	var r = _run([_wpctl, "get-volume", "@DEFAULT_AUDIO_SINK@"])
	if r.code != 0:
		return res
	var p = _osd.parse_wpctl(r.text.split("\n"))
	if float(p.volume) < 0.0:
		return res
	res.ok = true
	res.volume = float(p.volume)
	res.muted = bool(p.muted)
	return res


# Ejecuta argv = [ruta, arg...] con timeout si está disponible y devuelve
# {"code": int, "text": String}. Sólo desde el worker.
func _run(argv):
	var out = []
	var code = 0
	if _timeout != "":
		code = OS.execute(_timeout, [TIMEOUT_S] + argv, true, out, true)
	else:
		code = OS.execute(argv[0], argv.slice(1, argv.size()), true, out, true)
	var text = ""
	for line in out:
		text += String(line) + "\n"
	return {"code": code, "text": text}


# --- utilidades --------------------------------------------------------------

# Resuelve timeout, wpctl y pactl una sola vez, y carga los parsers. Sin procesos.
func _probe():
	if _probed:
		return
	_probed = true
	_timeout = _which("timeout")
	_wpctl = _which("wpctl")
	_pactl = _which("pactl")
	_osd = load("res://system_osd.gd")
	_send = load("res://audio_send.gd")


# Ruta absoluta de un ejecutable en $PATH, o "" si no está. Sólo File, sin shell.
func _which(prog):
	for d in OS.get_environment("PATH").split(":", false):
		if d != "" and File.new().file_exists(d + "/" + prog):
			return d + "/" + prog
	return ""


# Error de validación en el hilo principal: descarta el pedido y publica el estado.
func _apply_error(msg):
	_mutex.lock()
	_want_sink = ""
	_snap.state = "error"
	_snap.detail = msg
	_mutex.unlock()
	state = "error"
	detail = msg
