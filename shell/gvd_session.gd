extends Reference

# Modelo PURO de una sesion de pantalla gvd del Vecindario
# (SPEC-screen-share-compass.md §5, §6, §7, §8, §13; tarea "Kilo F - sesion gvd").
#
# Una "sesion de pantalla" es una maquina de estados + planes de accion + una
# tabla que clasifica que acciones son ejecutables YA y cuales estan diferidas.
# Es puro y sin efectos: NO lanza procesos, NO toca red, NO toca filesystem y no
# guarda estado global. La orquestacion real (worker + snapshot, §14) vive en el
# shell; este modulo solo decide y describe, igual que neighborhood_actions.gd.
#
# Emisor gdtk: habilitado por `EMITTER_ENABLED` (true por pedido del usuario). Las
# acciones de emision (`gvd_send`, ids use_as_screen/share_my_screen) se planifican y
# son ejecutables ya; el shell las lanza en un Thread de un solo uso. Con
# `EMITTER_ENABLED = false` vuelve el gate de §13 y `gated_reason()` da el motivo.
# Las acciones de control/portapapeles siempre son ejecutables ya.

const ACTIONS = preload("res://neighborhood_actions.gd")
const DIRECTIONS = preload("res://neighborhood_directions.gd")

const STATES = ["idle", "preparing", "active", "stopping", "stopped", "failed"]
const EVENTS = ["start", "ready", "stop", "stopped", "fail", "reset"]

# Emisor gdtk habilitado de forma explícita por pedido del usuario ("compartir
# pantalla"): las acciones gvd_send (use_as_screen/share_my_screen) son ejecutables
# ya. Si se pone en false vuelve el gate de §13 (gdtk sólo recibe y organiza) y
# `gated_reason()` explica el motivo. El transporte sigue sin cifrar ni autenticar:
# sólo LAN de confianza o red protegida.
const EMITTER_ENABLED = true

# Estados terminales: de ellos solo se sale con `reset`.
const _TERMINAL = ["stopped", "failed"]
# Caracteres seguros para los atomos de una clave de sesion.
const _SAFE_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
# Motivo de la accion de emision diferida (§13). Sin secretos.
const _GVD_SEND_REASON = "emisor gdtk diferido (SPEC §13): gdtk hoy recibe y organiza"


# Clave determinista de sesion: "<local>-> <peer>:<direction>". Cada atomo se
# sanitiza a caracteres seguros (sin espacios/metacaracteres ni secretos) y cae a
# "none" si queda vacio. Una direccion fuera de {north,south,east,west,none} cae a
# "none". Iguales entradas -> igual clave, sin depender de hash/orden.
static func session_key(local_id, peer_id, direction):
	var l = _atom(local_id)
	var p = _atom(peer_id)
	var d = String(direction).strip_edges().to_lower()
	if not DIRECTIONS.ALL_DIRECTIONS.has(d):
		d = "none"
	return l + "-> " + p + ":" + d


# Transicion determinista de la maquina de estados. Devuelve el estado destino, o
# el mismo `state` si el par (state, event) no esta previsto (no-op).
#   idle+start -> preparing; preparing+ready -> active; preparing+fail -> failed;
#   active+stop -> stopping; stopping+stopped -> stopped; failed+reset -> idle;
#   stopped+reset -> idle; y `fail` desde cualquier estado NO terminal -> failed.
static func transition(state, event):
	var s = String(state)
	if not STATES.has(s):
		return s
	match String(event):
		"start":
			if s == "idle":
				return "preparing"
		"ready":
			if s == "preparing":
				return "active"
		"stop":
			if s == "active":
				return "stopping"
		"stopped":
			if s == "stopping":
				return "stopped"
		"reset":
			if _is_terminal(s):
				return "idle"
		"fail":
			if not _is_terminal(s):
				return "failed"
	return s


# Plan de emision (extender escritorio): deriva `--position` de la direccion del
# compas (north->above, south->below, east->right, west->left) y delega en
# neighborhood_actions.gvd_send_plan. Sin direccion valida (none/desconocida) no
# se pasa posicion. Devuelve el plan tal cual (ok/kind/cmd/args/error).
static func send_plan(gvd_path, peer_host, port, direction, opts = {}):
	var o = opts.duplicate() if typeof(opts) == TYPE_DICTIONARY else {}
	var pos = DIRECTIONS.to_gvd_position(String(direction).strip_edges())
	if pos != "":
		o["position"] = pos
	# Defaults anti-jitter (Wi-Fi); el caller puede sobreescribirlos vía opts.
	if not o.has("fps"):
		o["fps"] = ACTIONS.GVD_SEND_FPS
	if not o.has("bitrate"):
		o["bitrate"] = ACTIONS.GVD_SEND_BITRATE
	return ACTIONS.gvd_send_plan(gvd_path, peer_host, port, o)


# Plan del receptor local: `gvd recv --sink <sink>` (default auto; waylandsink
# aborta en el compositor embebido, así que se prefiere gl/xv) con buffer RTP
# holgado para Wi-Fi.
static func recv_plan(gvd_path, sink = "auto"):
	return ACTIONS.gvd_recv_plan(gvd_path, {"sink": sink,
		"jitter_ms": ACTIONS.GVD_JITTER_MS})


# Clasifica una accion por su tipo de ejecucion.
static func action_kind(action_id):
	match String(action_id):
		"use_remote_input":
			return "deskflow_service"
		"serve_input_here":
			return "deskflow_service"
		"share_clipboard":
			return "clipboard_flag"
		"use_as_screen":
			return "gvd_send"
		"share_my_screen":
			return "gvd_send"
	return ""


# true si la accion se puede ejecutar YA. Control Deskflow y portapapeles si;
# emision gvd (`gvd_send`) segun `EMITTER_ENABLED` (true por pedido del usuario).
# Un id desconocido no es ejecutable.
static func executable_now(action_id):
	var k = action_kind(action_id)
	if k == "gvd_send":
		return EMITTER_ENABLED
	return k == "deskflow_service" or k == "clipboard_flag"


# Motivo por el que una accion esta diferida; "" si no lo esta. La emision gvd se
# pospone solo cuando `EMITTER_ENABLED` es false; el resto no tiene bloqueo de esta capa.
static func gated_reason(action_id):
	if action_kind(action_id) == "gvd_send" and not EMITTER_ENABLED:
		return _GVD_SEND_REASON
	return ""


static func _atom(v):
	var raw = String(v).strip_edges()
	var out = ""
	for i in range(raw.length()):
		var ch = raw.substr(i, 1)
		if _SAFE_CHARS.find(ch) >= 0:
			out += ch
	out = out.lstrip(".-").rstrip(".-")
	return out if out != "" else "none"


static func _is_terminal(state):
	return _TERMINAL.has(String(state))


static func selftest():
	var ok = true

	# Clave determinista y direccion invalida -> none.
	var k1 = session_key("local-a", "peer.b", "east")
	var k2 = session_key("local-a", "peer.b", "east")
	ok = ok and k1 == k2 and k1.find("east") >= 0 and k1.find("local-a") >= 0
	ok = ok and session_key("a", "b", "up").find("none") >= 0
	ok = ok and session_key("a", "b", "none").find("none") >= 0
	ok = ok and session_key("bad id!", "b", "east").find("badid") >= 0
	ok = ok and session_key("", "", "") == "none-> none:none"

	# Transiciones validas.
	ok = ok and transition("idle", "start") == "preparing"
	ok = ok and transition("preparing", "ready") == "active"
	ok = ok and transition("preparing", "fail") == "failed"
	ok = ok and transition("active", "stop") == "stopping"
	ok = ok and transition("stopping", "stopped") == "stopped"
	ok = ok and transition("failed", "reset") == "idle"
	ok = ok and transition("stopped", "reset") == "idle"
	ok = ok and transition("idle", "fail") == "failed"
	ok = ok and transition("active", "fail") == "failed"
	ok = ok and transition("stopping", "fail") == "failed"
	# Terminales no cambian con fail.
	ok = ok and transition("failed", "fail") == "failed"
	ok = ok and transition("stopped", "fail") == "stopped"
	# Combinaciones no previstas: no-op.
	ok = ok and transition("idle", "stop") == "idle"
	ok = ok and transition("active", "ready") == "active"
	ok = ok and transition("stopped", "start") == "stopped"

	# Planes (delegados): direccion -> --position; sin direccion, sin --position.
	var sp = send_plan("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5600, "east")
	ok = ok and sp.ok and sp.args.find("--position") >= 0 and sp.args.find("right") >= 0
	var sp_none = send_plan("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5600, "")
	ok = ok and sp_none.ok and sp_none.args.find("--position") < 0
	ok = ok and send_plan("~/gvd/gvd.py", "tengu.local", 5600, "east").ok == false
	var rp = recv_plan("/home/u/Proyectos/gvd/gvd.py")
	ok = ok and rp.ok and rp.args[2] == "--sink" and rp.args[3] == "auto"

	# Clasificacion y disponibilidad.
	ok = ok and action_kind("use_remote_input") == "deskflow_service"
	ok = ok and action_kind("serve_input_here") == "deskflow_service"
	ok = ok and action_kind("share_clipboard") == "clipboard_flag"
	ok = ok and action_kind("use_as_screen") == "gvd_send"
	ok = ok and action_kind("share_my_screen") == "gvd_send"
	ok = ok and action_kind("nope") == "" and action_kind("") == ""
	ok = ok and executable_now("use_remote_input") and executable_now("serve_input_here")
	ok = ok and executable_now("share_clipboard")
	ok = ok and executable_now("use_as_screen") == EMITTER_ENABLED
	ok = ok and executable_now("share_my_screen") == EMITTER_ENABLED
	ok = ok and not executable_now("nope") and not executable_now("")
	ok = ok and (gated_reason("use_as_screen") != "") == (not EMITTER_ENABLED)
	ok = ok and (gated_reason("share_my_screen") != "") == (not EMITTER_ENABLED)
	ok = ok and gated_reason("use_remote_input") == "" and gated_reason("nope") == ""

	assert(ok, "selftest de gvd_session")
	return ok


func run_selftest():
	return selftest()
