extends Reference

# Bus central de notificaciones del shell (SPEC-notificaciones.md).
#
# Une tres fuentes en un solo historial y lo publica como snapshot inmutable:
#   * externas: el daemon `session/gdtk-notify` posee `org.freedesktop.Notifications`
#     y es el ÚNICO escritor de `$XDG_RUNTIME_DIR/gdtk/notifications.json`.
#   * internas del shell (activación/foco, urgencia de dockapps, RPC): se encolan y
#     el worker las ejecuta con `gdtk-notify push`; si el daemon no corre, el worker
#     mantiene un historial local en memoria y el shell sigue andando.
#
# El hilo de render NUNCA hace I/O: encola comandos (`push_internal`/`dismiss`) y lee
# el snapshot que publica el worker. `poll()` copia ese snapshot, avanza los relojes
# de atención/urgencia/transitorio y devuelve true mientras haya animación pendiente.
#
# El modelo puro (orden, cap, replaces_id, expiración) vive en funciones estáticas
# testeables (`tests/notify_model_test.gd`).

const STORE_NAME = "notifications.json"
const PERIOD_MS = 1000
const SLEEP_STEP_MS = 100
const HISTORY_MAX = 100          # tope de entradas en el historial
const ATTENTION_MS = 10000       # cuánto dura el pedido de foco (pulso de borde)
const TOAST_MS = 4000            # bloque transitorio a plena opacidad
const TOAST_FADE_MS = 400        # desvanecido del bloque transitorio
const RECORD_MAX = 400           # recorte de summary/body
const URGENCY_DEFAULT_MS = 180000

# --- worker (bajo _mutex) ---
var _mutex = Mutex.new()
var _thread = null
var _want_stop = false
var _snap = {"revision": 0, "items": [], "latest": {}}
var _cmds = []                   # hilo de render -> worker: [{"op": ...}]
var _watch = null                # GdtkFileWatch opcional (si el motor lo trae)

# --- estado del hilo principal ---
var _shell = null
var revision = 0
var items = []                   # más nuevo primero
var latest = {}
var attention = {}               # id de ventana -> {"hasta_ms": int, "texto": str}
var urgency = {}                 # fuente -> {"severidad": str, "hasta_ms": int, "texto": str}
var silenced_flag = false
var enabled = true               # interruptor global de notificaciones
var atencion_enabled = true      # pedidos de foco (pulso + «ir»)
var urgencia_enabled = true      # urgencias de dockapps
var toast_enabled = true         # bloque transitorio al llegar un aviso
var panel_open = false
var panel_mode = false
var panel_scroll = 0.0
var history_max = HISTORY_MAX
var toast_id = 0
var toast_since = 0
var _seen_id = 0
var _primed = false            # el primer snapshot no dispara transitorio (recarga)
var _flash_since = 0             # último pedido de atención (para el pulso)


func setup(shell):
	_shell = shell
	_setup_watch()
	if _thread == null:
		_want_stop = false
		_thread = Thread.new()
		_thread.start(self, "_work", _paths())


func stop():
	_mutex.lock()
	_want_stop = true
	_mutex.unlock()
	if _watch != null:
		_watch.stop()
		_watch = null
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


# --- API del shell ----------------------------------------------------------

# Copia el snapshot del worker y avanza los relojes. Devuelve true mientras haya
# algo que animar (entrada nueva, transitorio, urgencia o atención vigentes).
func poll():
	var redraw = false
	var now = OS.get_ticks_msec()
	_mutex.lock()
	var snap = _snap
	_mutex.unlock()
	var rev = int(snap.get("revision", 0))
	if rev != revision:
		revision = rev
		items = snap.get("items", []).duplicate(true)
		latest = snap.get("latest", {}).duplicate(true)
		var newest_id = int(items[0].get("id", 0)) if not items.empty() else 0
		if not silenced_flag and toast_enabled and _primed and newest_id > 0 and newest_id != _seen_id:
			toast_id = newest_id
			toast_since = now
		_seen_id = max(_seen_id, newest_id)
		_primed = true
		redraw = true
	# Expiración de atención/urgencia.
	var att2 = prune_attention(attention, now)
	if att2.size() != attention.size():
		redraw = true
	attention = att2
	var urg2 = prune_urgency(urgency, now)
	if urg2.size() != urgency.size():
		redraw = true
	urgency = urg2
	# Transitorio.
	if toast_id != 0 and now - toast_since > TOAST_MS + TOAST_FADE_MS:
		toast_id = 0
	if toast_id != 0:
		redraw = true
	# Pulso de atención vigente mientras haya ids en atención.
	if not attention.empty():
		redraw = true
	return redraw


func latest():
	return latest


func items():
	return items


# Registro de notificación como nuevo evento interno (encolado; nunca I/O acá).
func push_internal(record):
	_mutex.lock()
	_cmds.append({"op": "push", "record": record.duplicate(true)})
	_mutex.unlock()
	return true


func dismiss(id):
	_mutex.lock()
	_cmds.append({"op": "dismiss", "id": int(id)})
	_mutex.unlock()


func dismiss_all():
	_mutex.lock()
	_cmds.append({"op": "clear"})
	_mutex.unlock()


# Acción de una notificación (p. ej. "default"): la ejecuta el worker vía el daemon.
func invoke(id, key):
	_mutex.lock()
	_cmds.append({"op": "invoke", "id": int(id), "key": String(key)})
	_mutex.unlock()


# Pide atención sobre una ventana: destaca su tesela/borde y deja una notificación
# con acción «ir». NO roba el foco (SPEC-notificaciones: regla dura).
func request_attention(window_id, texto):
	var id = int(window_id)
	if id < 0:
		return false
	if not enabled or not atencion_enabled:
		return false
	var now = OS.get_ticks_msec()
	attention[id] = {"hasta_ms": now + ATTENTION_MS, "texto": String(texto)}
	_flash_since = now
	push_internal({
		"source": "activacion",
		"app": String(texto),
		"summary": String(texto),
		"target_window": id,
		"urgency": "normal",
		"expires_ms": 0,
	})
	if _shell != null:
		_shell.request_redraw()
	return true


func clear_attention(id):
	if attention.erase(int(id)):
		if _shell != null:
			_shell.request_redraw()
		return true
	return false


func attention_ids():
	var out = []
	var now = OS.get_ticks_msec()
	for id in prune_attention(attention, now).keys():
		out.append(int(id))
	out.sort()
	return out


func has_attention(id):
	return int(id) in attention_ids()


# Eleva (o renueva) una urgencia con TTL. Devuelve true si cambió el estado visible.
# Sólo encola una notificación en el primer episodio, no en cada renovación.
func raise_urgency(fuente, severidad, ttl_ms, texto):
	var src = String(fuente)
	if src == "":
		return false
	if not enabled or not urgencia_enabled:
		return false
	var now = OS.get_ticks_msec()
	var ttl = int(ttl_ms)
	if ttl <= 0:
		ttl = URGENCY_DEFAULT_MS
	var prev = urgency_for(src)
	urgency[src] = {"severidad": String(severidad), "hasta_ms": now + ttl, "texto": String(texto)}
	var new_episode = prev.empty()
	if new_episode:
		push_internal({
			"source": "urgencia",
			"app": src,
			"summary": String(texto),
			"body": "Urgencia: " + String(severidad),
			"urgency": "critical",
			"expires_ms": now + ttl,
		})
	if _shell != null:
		_shell.request_redraw()
	return true


func urgency_for(fuente):
	var u = urgency_for_(urgency, String(fuente), OS.get_ticks_msec())
	return u


func set_silenced(v):
	silenced_flag = bool(v)
	if _shell != null:
		_shell.request_redraw()


func silenced():
	return silenced_flag


func any_urgency():
	return not urgency.empty()


# Alpha del pulso de atención (0..1): usado por deco/tiles para el contorno.
func pulse_alpha():
	return 0.5 + 0.5 * sin(float(OS.get_ticks_msec()) * 0.006)


func toast_alpha():
	if toast_id == 0:
		return 0.0
	var age = OS.get_ticks_msec() - toast_since
	if age <= TOAST_MS:
		return 1.0
	return clamp(1.0 - float(age - TOAST_MS) / float(TOAST_FADE_MS), 0.0, 1.0)


func toast_item():
	for it in items:
		if int(it.get("id", 0)) == toast_id:
			return it
	return {}


# --- API RPC (hilo de render) ------------------------------------------------

# Ejecuta un comando del control remoto sobre el bus. `params` lleva action +
# campos (summary/body/icon/urgency/id) como en `remote.gd`.
func rpc_action(params):
	var action = String(params.get("action", ""))
	match action:
		"push":
			push_internal({
				"source": "rpc",
				"app": String(params.get("app", "gdtk")),
				"icon": String(params.get("icon", "")),
				"summary": String(params.get("summary", "")),
				"body": String(params.get("body", "")),
				"urgency": String(params.get("urgency", "normal")),
				"expires_ms": int(params.get("expires_ms", 0)),
			})
			return true
		"list":
			return items
		"dismiss":
			if params.has("id"):
				dismiss(int(params.get("id", 0)))
			return true
		"clear":
			dismiss_all()
			return true
		"silence":
			set_silenced(bool(params.get("on", not silenced_flag)))
			return true
		"attention":
			return request_attention(int(params.get("window", -1)), String(params.get("text", "")))
		"panel":
			panel_open = bool(params.get("open", not panel_open))
			if _shell != null:
				_shell.request_redraw()
			return true
		"urgency":
			return raise_urgency(String(params.get("source", "")),
				String(params.get("severity", "critical")),
				int(params.get("ttl_ms", URGENCY_DEFAULT_MS)),
				String(params.get("text", "")))
	return false


# --- modelo puro (testeable) -------------------------------------------------

static func normalize_record(rec):
	var r = rec if typeof(rec) == TYPE_DICTIONARY else {}
	var actions = []
	var raw_actions = r.get("actions", [])
	if typeof(raw_actions) == TYPE_ARRAY:
		for a in raw_actions:
			if typeof(a) == TYPE_DICTIONARY:
				actions.append({"key": String(a.get("key", "default")), "label": String(a.get("label", ""))})
	var urg = String(r.get("urgency", "normal")).to_lower()
	if not urg in ["low", "normal", "critical"]:
		urg = "normal"
	return {
		"id": int(r.get("id", 0)),
		"source": String(r.get("source", "")),
		"app": String(r.get("app", "")),
		"app_id": String(r.get("app_id", "")),
		"icon": String(r.get("icon", "")),
		"summary": String(r.get("summary", "")).substr(0, RECORD_MAX),
		"body": String(r.get("body", "")).substr(0, RECORD_MAX),
		"urgency": urg,
		"actions": actions,
		"target_window": int(r.get("target_window", 0)),
		"created_ms": int(r.get("created_ms", 0)),
		"expires_ms": int(r.get("expires_ms", 0)),
		"read": bool(r.get("read", false)),
	}


static func next_id(list):
	var mx = 0
	for it in list:
		mx = max(mx, int(it.get("id", 0)))
	return mx + 1


# Inserta/renueva un registro: si trae `replaces_id` (o un id existente) reemplaza
# esa entrada; si no, asigna el próximo id. Queda primero (más nuevo) y recorta al cap.
static func apply_push(list, record, cap = HISTORY_MAX):
	var rec = normalize_record(record)
	var out = []
	for it in list:
		if typeof(it) == TYPE_DICTIONARY:
			out.append(it)
	var rid = int(record.get("replaces_id", 0)) if typeof(record) == TYPE_DICTIONARY else 0
	if rid <= 0:
		rid = int(rec.get("id", 0))
	if rid > 0:
		for i in range(out.size()):
			if int(out[i].get("id", 0)) == rid:
				out.remove(i)
				break
	if int(rec.get("id", 0)) <= 0:
		rec["id"] = rid if rid > 0 else next_id(out)
	out.insert(0, rec)
	while out.size() > int(cap):
		out.pop_back()
	return out


static func apply_dismiss(list, id):
	var out = []
	for it in list:
		if typeof(it) == TYPE_DICTIONARY and int(it.get("id", 0)) != int(id):
			out.append(it)
	return out


# Fuera las entradas con `expires_ms` vencido. `expires_ms == 0` no expira nunca.
static func prune_expired(list, now_ms):
	var out = []
	for it in list:
		if typeof(it) != TYPE_DICTIONARY:
			continue
		var exp_ms = int(it.get("expires_ms", 0))
		if exp_ms > 0 and int(now_ms) >= exp_ms:
			continue
		out.append(it)
	return out


static func parse_store(text):
	var doc = {"revision": 0, "items": []}
	if typeof(text) != TYPE_STRING or text.strip_edges() == "":
		return doc
	var res = JSON.parse(text)
	if res.error != OK or typeof(res.result) != TYPE_DICTIONARY:
		return doc
	doc["revision"] = int(res.result.get("revision", 0))
	var arr = res.result.get("items", [])
	if typeof(arr) == TYPE_ARRAY:
		for it in arr:
			if typeof(it) == TYPE_DICTIONARY:
				doc["items"].append(normalize_record(it))
	return doc


static func serialize_store(revision, list):
	return JSON.print({"revision": int(revision), "items": list})


static func prune_attention(att, now_ms):
	var out = {}
	if typeof(att) != TYPE_DICTIONARY:
		return out
	for id in att.keys():
		var e = att[id]
		if typeof(e) == TYPE_DICTIONARY and int(e.get("hasta_ms", 0)) > int(now_ms):
			out[id] = e
	return out


static func prune_urgency(urg, now_ms):
	var out = {}
	if typeof(urg) != TYPE_DICTIONARY:
		return out
	for src in urg.keys():
		var e = urg[src]
		if typeof(e) == TYPE_DICTIONARY and int(e.get("hasta_ms", 0)) > int(now_ms):
			out[src] = e
	return out


static func urgency_for_(urg, fuente, now_ms):
	if typeof(urg) != TYPE_DICTIONARY:
		return {}
	var e = urg.get(fuente, {})
	if typeof(e) == TYPE_DICTIONARY and int(e.get("hasta_ms", 0)) > int(now_ms):
		return e
	return {}


# --- hilo de trabajo ---------------------------------------------------------

func _paths():
	var run = OS.get_environment("XDG_RUNTIME_DIR")
	if run == "":
		run = "/tmp"
	var dir = run + "/gdtk"
	return {
		"dir": dir,
		"store": dir + "/" + STORE_NAME,
		"tmp": dir + "/notify-push.json",
		"script": ProjectSettings.globalize_path("res://").plus_file("../session/gdtk-notify").simplify_path(),
		"log": run + "/gdtk-notify.log",
	}


func _stopped():
	_mutex.lock()
	var s = _want_stop
	_mutex.unlock()
	return s


func _setup_watch():
	if _watch != null or not ClassDB.class_exists("GdtkFileWatch"):
		return
	var p = _paths()
	Directory.new().make_dir_recursive(p.dir)
	var w = ClassDB.instance("GdtkFileWatch")
	if w == null:
		return
	w.watch(p.dir)
	if w.watch_count() <= 0:
		return
	w.connect("changed", self, "_on_fs_changed")
	w.start()
	_watch = w


func _on_fs_changed():
	_mutex.lock()
	_cmds.append({"op": "fs"})
	_mutex.unlock()


func _work(p):
	var local = []            # historial en memoria si el daemon no corre
	var daemon_ok = File.new().file_exists(p.store)
	var last_sig = null
	var rev = 0
	Directory.new().make_dir_recursive(p.dir)
	while not _stopped():
		# Ojo: se leen TODOS los comandos antes de decidir la fuente, así un push
		# local reciente no se pisa con el store viejo.
		var cmds = _drain_cmds()
		for c in cmds:
			var op = String(c.get("op", ""))
			if op == "push":
				if _push_remote(p, c.get("record", {})):
					daemon_ok = true
				else:
					daemon_ok = false
					local = apply_push(local, c.get("record", {}), history_max)
			elif op == "dismiss":
				if not _run_cli(p, ["dismiss", str(c.get("id", 0))]):
					daemon_ok = false
					local = apply_dismiss(local, c.get("id", 0))
			elif op == "clear":
				if not _run_cli(p, ["clear"]):
					daemon_ok = false
					local = []
			elif op == "invoke":
				_run_cli(p, ["invoke", str(c.get("id", 0)), String(c.get("key", "default"))])
		var file_items = []
		var file_exists = File.new().file_exists(p.store)
		if file_exists:
			file_items = parse_store(_read(p.store)).get("items", [])
		# Fuente: si un comando CLI anduvo, el store manda (aunque esté vacío tras un
		# clear); si no, un store con ítems indica un daemon vivo (p. ej. notificación
		# externa) y también manda; si no, historial local.
		var source = local
		if daemon_ok or (file_exists and not file_items.empty()):
			source = file_items
		var merged = prune_expired(source, OS.get_ticks_msec())
		if merged.size() > history_max:
			merged = merged.slice(0, history_max)
		var sig = JSON.print(merged)
		if sig != last_sig:
			last_sig = sig
			rev += 1
			_publish(rev, merged)
		var waited = 0
		while waited < PERIOD_MS and not _stopped():
			OS.delay_msec(SLEEP_STEP_MS)
			waited += SLEEP_STEP_MS


func _drain_cmds():
	_mutex.lock()
	var out = _cmds
	_cmds = []
	_mutex.unlock()
	return out


func _publish(rev, list):
	_mutex.lock()
	_snap = {
		"revision": rev,
		"items": list,
		"latest": (list[0] if not list.empty() else {}),
	}
	_mutex.unlock()


# Ejecuta un push interno: el cuerpo va por archivo (nunca por argv).
func _push_remote(p, record):
	var rec = normalize_record(record)
	if int(rec.get("created_ms", 0)) <= 0:
		rec["created_ms"] = OS.get_ticks_msec()
	Directory.new().make_dir_recursive(p.dir)
	var f = File.new()
	if f.open(p.tmp, File.WRITE) != OK:
		return false
	f.store_string(JSON.print(rec))
	f.close()
	var ok = _run_cli(p, ["push", p.tmp])
	Directory.new().remove(p.tmp)
	return ok


func _run_cli(p, args):
	var out = []
	var cmd = String(p.script)
	if cmd == "":
		return false
	return OS.execute(cmd, args, true, out) == 0


func _read(path):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var t = f.get_as_text()
	f.close()
	return t


# --- selftest (puro) ---------------------------------------------------------

static func selftest():
	var a = apply_push([], {"id": 1, "summary": "uno"}, 3)
	assert(a.size() == 1 and int(a[0].id) == 1)
	a = apply_push(a, {"id": 2, "summary": "dos"}, 3)
	a = apply_push(a, {"id": 3, "summary": "tres"}, 3)
	assert(int(a[0].id) == 3 and int(a[1].id) == 2 and int(a[2].id) == 1)
	a = apply_push(a, {"id": 4, "summary": "cuatro"}, 3)
	assert(a.size() == 3 and int(a[0].id) == 4 and int(a[2].id) == 2, "cap recorta el más viejo")
	# replaces_id reemplaza y sube al frente.
	var r = apply_push(a, {"replaces_id": 2, "summary": "dos nuevo"}, 3)
	assert(int(r[0].id) == 2 and r[0].summary == "dos nuevo" and r.size() == 3)
	# id autogenerado.
	var n = apply_push([], {"summary": "sin id"}, 5)
	assert(int(n[0].id) == 1, "id autogenerado")
	var m = apply_push(n, {"summary": "otro"}, 5)
	assert(int(m[0].id) == 2)
	assert(apply_dismiss(m, 1).size() == 1)
	# expiración.
	var now = 1000
	var items_e = [{"id": 1, "expires_ms": 0}, {"id": 2, "expires_ms": 1500}]
	assert(prune_expired(items_e, now).size() == 2)
	assert(prune_expired(items_e, 1600).size() == 1)
	# store round-trip.
	var doc = parse_store(serialize_store(7, items_e))
	assert(int(doc.revision) == 7 and doc.items.size() == 2)
	assert(parse_store("basura").items.empty())
	# normalización de urgencia inválida.
	assert(normalize_record({"urgency": "URGENTE"}).urgency == "normal")
	# atención/urgencia expiran.
	var att = {5: {"hasta_ms": 2000, "texto": "x"}}
	assert(prune_attention(att, 1000).size() == 1)
	assert(prune_attention(att, 3000).empty())
	var urg = {"termico": {"severidad": "critical", "hasta_ms": 2000, "texto": "t"}}
	assert(urgency_for_(urg, "termico", 1000).severidad == "critical")
	assert(urgency_for_(urg, "termico", 3000).empty())
	print("notify selftest ok")
