extends SceneTree

# Prueba del servidor del canal peer (shell/peer_control.gd) sin TCP: se llama
# `_handle` con un peer falso y se verifican las respuestas y el TOFU del token.

const LINK = preload("res://peer_link.gd")

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


class FakePeer:
	extends Reference
	var lines = []
	func get_status():
		return StreamPeerTCP.STATUS_CONNECTED
	func put_data(d):
		lines.append(d.get_string_from_utf8())


class StubShell:
	extends Reference
	var opened = []
	var shares = []
	var stops = []
	var input_events = []
	var screen_res = []
	var layouts = []
	func _peer_is_confirmed(hid):
		return String(hid) == "aaaa" or String(hid) == "bbbb"
	func _peer_gvd_open(port, from, _hid = "", _video = Vector2()):
		opened.append([int(port), String(from)])
		return true
	func _peer_gvd_stop():
		return true
	func _peer_gvd_active():
		return not opened.empty()
	func _peer_gvd_send(_p, _t):
		return true
	func _peer_share_notify(hid, params):
		shares.append([String(hid), params.duplicate(true)])
		return true
	func _peer_share_stop(hid, params):
		stops.append([String(hid), params.duplicate(true)])
		return true
	var mv_slots = []
	var mv_stops = []
	func _peer_mv_slot(hid, params):
		mv_slots.append([String(hid), params.duplicate(true)])
		return true
	func _peer_mv_stop(hid):
		mv_stops.append(String(hid))
		return true
	func _peer_window_input(hid, events):
		input_events.append([String(hid), events.duplicate(true)])
		return true
	func _peer_screen_res(hid, vs):
		screen_res.append([String(hid), vs])
		return true
	func _peer_layout(hid, screens):
		layouts.append([String(hid), screens.duplicate(true)])
		return true


class StubBare:
	extends Reference
	func _peer_is_confirmed(hid):
		return String(hid) == "dddd"


func _resp(pc, peer, line):
	peer.lines.clear()
	pc._handle({"peer": peer}, line)
	return LINK.parse_response(peer.lines[0]) if not peer.lines.empty() else {}


func _init():
	var PeerControl = load("res://peer_control.gd")
	var pc = PeerControl.new()
	var tokens_path = "/tmp/gdtk-peer-test-tokens.json"
	var d = Directory.new()
	if d.file_exists(tokens_path):
		d.remove(tokens_path)
	pc.tokens_path = tokens_path
	pc.tokens = {}
	pc.shell = StubShell.new()
	var peer = FakePeer.new()

	# ping de un host desconocido: ok, no emparejado
	var r = _resp(pc, peer, LINK.encode_request("cccc", "", "ping"))
	check("ping desconocido ok", bool(r.get("ok", false)) and not bool(r.get("paired", true)))

	# gvd_recv de un hid NO confirmado: unpaired
	r = _resp(pc, peer, LINK.encode_request("cccc", "", "gvd_recv", {"port": 5600}))
	check("no confirmado rechazado", not bool(r.get("ok", false)) and String(r.get("error", "")) == "unpaired")

	# gvd_recv de un hid confirmado: ok, provisiona token y ejecuta
	r = _resp(pc, peer, LINK.encode_request("aaaa", "", "gvd_recv", {"port": 5601, "from": "tengu"}))
	check("confirmado empareja y ejecuta", bool(r.get("ok", false)) and String(r.get("token", "")).length() == 48)
	check("abrió receptor", pc.shell.opened.size() == 1 and pc.shell.opened[0][0] == 5601)
	check("token guardado en disco", File.new().file_exists(tokens_path))
	var tok = String(r.get("token", ""))

	# token viejo/incorrecto de un par CONFIRMADO: auto-sanación (re-empara y devuelve
	# un token nuevo); no queda en `unauthorized` para siempre.
	r = _resp(pc, peer, LINK.encode_request("aaaa", "malo", "gvd_recv", {"port": 5602}))
	check("token viejo re-empara", bool(r.get("ok", false)) and String(r.get("token", "")).length() == 48)
	tok = String(r.get("token", ""))
	check("abrió receptor tras re-emparar", pc.shell.opened.size() == 2 and pc.shell.opened[1][0] == 5602)

	# token correcto (ya el nuevo): ok (sin devolver token de nuevo)
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "gvd_recv", {"port": 5603}))
	check("token correcto ok", bool(r.get("ok", false)) and not r.has("token"))
	check("abrió tercer receptor", pc.shell.opened.size() == 3)

	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "window_input", {"events": [
		{"kind": "motion", "x": 0.5, "y": 0.25},
		{"kind": "button", "button": 1, "pressed": true}]}))
	check("window_input autenticado ejecuta", bool(r.get("ok", false))
		and pc.shell.input_events.size() == 1 and pc.shell.input_events[0][1].size() == 2)
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "window_input",
		{"events": [{"kind": "motion", "x": 9.0, "y": 0.0}]}))
	check("window_input inválido rechazado", not bool(r.get("ok", false)))

	# --- Stream persistente de input ----------------------------------------
	# Handshake `window_input_stream`: autentica, aplica el lote inicial y deja la
	# conexión marcada como stream (no la cierra).
	var sconn = {"peer": peer}
	peer.lines.clear()
	pc._handle(sconn, LINK.encode_request("aaaa", tok, "window_input_stream",
		{"events": [{"kind": "motion", "x": 0.5, "y": 0.5}]}))
	var sresp = LINK.parse_response(peer.lines[0])
	check("window_input_stream handshake ok", bool(sresp.get("ok", false)))
	check("window_input_stream queda abierto", bool(sconn.get("stream", false))
		and String(sconn.get("hid", "")) == "aaaa")
	check("window_input_stream aplica lote inicial", pc.shell.input_events.size() == 2)

	# Handshake con lote inválido: error y no queda como stream.
	var sbad = {"peer": peer}
	peer.lines.clear()
	pc._handle(sbad, LINK.encode_request("aaaa", tok, "window_input_stream",
		{"events": [{"kind": "motion", "x": 5.0, "y": 0.5}]}))
	check("window_input_stream inválido rechazado",
		not bool(LINK.parse_response(peer.lines[0]).get("ok", false))
		and not bool(sbad.get("stream", false)))

	# Líneas de stream sin handshake repetido: dos lotes en un mismo buffer.
	var batch = LINK.encode_window_stream([{"kind": "motion", "x": 0.1, "y": 0.2}]) \
		+ LINK.encode_window_stream([{"kind": "button", "button": 1, "pressed": true}])
	var pconn = {"peer": peer, "buf": batch.to_utf8(), "hid": "aaaa",
		"stream": true, "close": false, "last": 0}
	var before = pc.shell.input_events.size()
	check("window_stream poll procesa dos lotes", pc._poll_stream(pconn))
	check("window_stream aplica dos lotes", pc.shell.input_events.size() == before + 2)
	check("window_stream consume el buffer", pconn.buf.empty())

	# Línea de stream inválida: cierra la conexión sin aplicar nada.
	var bconn = {"peer": peer, "buf": "no json\n".to_utf8(), "hid": "aaaa",
		"stream": true, "close": false, "last": 0}
	check("window_stream línea inválida cierra", not pc._poll_stream(bconn)
		and bool(bconn.get("close", false)))

	# Línea parcial: se conserva hasta completar el \n.
	var part = LINK.encode_window_stream([{"kind": "reset"}])
	var qconn = {"peer": peer, "buf": part.substr(0, part.length() - 2).to_utf8(),
		"hid": "aaaa", "stream": true, "close": false, "last": 0}
	check("window_stream línea parcial espera", pc._poll_stream(qconn)
		and not qconn.buf.empty())

	# ping ya emparejado
	r = _resp(pc, peer, LINK.encode_request("aaaa", "", "ping"))
	check("ping emparejado", bool(r.get("ok", false)) and bool(r.get("paired", false)))

	# --- Avisos de lados compartidos (G5) ------------------------------------
	# share_notify válido: se valida y se delega al shell con el hid y los params.
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "share_notify",
		{"type": "screen", "side": "south", "state": "active"}))
	check("share_notify válido ok", bool(r.get("ok", false)))
	check("share_notify delegado al shell", pc.shell.shares.size() == 1
		and String(pc.shell.shares[0][0]) == "aaaa"
		and String(pc.shell.shares[0][1].side) == "south"
		and String(pc.shell.shares[0][1].type) == "screen")

	# lado inválido: error y NO delega.
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "share_notify",
		{"type": "screen", "side": "up", "state": "active"}))
	check("share_notify lado inválido rechazado",
		not bool(r.get("ok", false)) and pc.shell.shares.size() == 1)

	# estado inválido: error.
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "share_notify",
		{"type": "input", "side": "west", "state": "idle"}))
	check("share_notify estado inválido rechazado",
		not bool(r.get("ok", false)) and pc.shell.shares.size() == 1)

	# share_stop válido.
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "share_stop", {"type": "input"}))
	check("share_stop válido ok", bool(r.get("ok", false))
		and pc.shell.stops.size() == 1 and String(pc.shell.stops[0][1].type) == "input")

	# share_stop sin tipo: error.
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "share_stop", {}))
	check("share_stop sin tipo rechazado",
		not bool(r.get("ok", false)) and pc.shell.stops.size() == 1)

	# --- Resolución de pantalla del par (rotación) ---------------------------
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "screen_res", {"w": 2160, "h": 1440}))
	check("screen_res ok", bool(r.get("ok", false)) and pc.shell.screen_res.size() == 1
		and pc.shell.screen_res[0][1] == Vector2(2160, 1440))
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "screen_res", {"w": 0, "h": 0}))
	check("screen_res inválido rechazado",
		not bool(r.get("ok", false)) and pc.shell.screen_res.size() == 1)
	# Un par NO confirmado sigue rechazado (no ejecuta ni con token).
	r = _resp(pc, peer, LINK.encode_request("cccc", tok, "screen_res", {"w": 800, "h": 600}))
	check("screen_res sin token rechazado", not bool(r.get("ok", false)))

	# --- Layout del Grupo (propagación) --------------------------------------
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "layout", {"screens": [
		{"id": "61950c8964e60e15", "peer": "cupid", "label": "cupid",
			"x": 1.0, "y": 2.0, "w": 3.0, "h": 4.0, "px_w": 1440, "px_h": 2160}, {"id": ""}]}))
	check("layout ok", bool(r.get("ok", false)) and pc.shell.layouts.size() == 1
		and pc.shell.layouts[0][1].size() == 1 and String(pc.shell.layouts[0][1][0].id) == "61950c8964e60e15")
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "layout", {"screens": []}))
	check("layout vacío rechazado",
		not bool(r.get("ok", false)) and pc.shell.layouts.size() == 1)

	# --- Reparto de slots del multiview (F3) ---------------------------------
	# mv_slot válido: se valida y se delega al shell con el hid y los params.
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "mv_slot",
		{"port": 5700, "host": "bastion.local", "slot": 1}))
	check("mv_slot válido ok", bool(r.get("ok", false)))
	check("mv_slot delegado al shell", pc.shell.mv_slots.size() == 1
		and String(pc.shell.mv_slots[0][0]) == "aaaa"
		and int(pc.shell.mv_slots[0][1].port) == 5700
		and String(pc.shell.mv_slots[0][1].host) == "bastion.local"
		and int(pc.shell.mv_slots[0][1].slot) == 1)

	# puerto/slot/host inválidos: error y NO delega.
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "mv_slot",
		{"port": 80, "host": "bastion.local", "slot": 1}))
	check("mv_slot puerto inválido rechazado",
		not bool(r.get("ok", false)) and pc.shell.mv_slots.size() == 1)
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "mv_slot",
		{"port": 5700, "host": "bastion.local", "slot": 16}))
	check("mv_slot slot inválido rechazado",
		not bool(r.get("ok", false)) and pc.shell.mv_slots.size() == 1)
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "mv_slot",
		{"port": 5700, "host": "a/b", "slot": 1}))
	check("mv_slot host inválido rechazado",
		not bool(r.get("ok", false)) and pc.shell.mv_slots.size() == 1)

	# mv_stop: sin params, se delega al shell.
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "mv_stop"))
	check("mv_stop ok", bool(r.get("ok", false)) and pc.shell.mv_stops.size() == 1
		and String(pc.shell.mv_stops[0]) == "aaaa")

	# Shell sin los handlers: parámetros válidos pero error de disponibilidad.
	pc.shell = StubBare.new()
	r = _resp(pc, peer, LINK.encode_request("dddd", "", "share_notify",
		{"type": "screen", "side": "north", "state": "active"}))
	check("share_notify sin handler -> error",
		not bool(r.get("ok", false)) and String(r.get("error", "")) == "no disponible")
	pc.shell = StubShell.new()

	# método inválido: bad request
	r = _resp(pc, peer, JSON.print({"v": 1, "hid": "aaaa", "token": tok, "method": "shutdown"}) + "\n")
	check("método inválido rechazado", not bool(r.get("ok", false)))

	if d.file_exists(tokens_path):
		d.remove(tokens_path)
	# Tokens: el canal es el ÚNICO dueño del archivo (lee y escribe srv: y cli:) y expone
	# get/set/forget/hids para que el shell no haga read-modify-write por su lado.
	var tp = OS.get_user_data_dir().plus_file("peer-tokens-test.json")
	var tf = File.new()
	tf.open(tp, File.WRITE)
	tf.store_string(JSON.print({"srv:h1": "S1", "cli:h2": "C2", "srv:bad hid": "X"}))
	tf.close()
	var tpc = load("res://peer_control.gd").new()
	tpc.tokens_path = tp
	tpc._load_tokens()
	check("tokens: carga srv: y cli: válidos", tpc.tokens.get("srv:h1", "") == "S1"
		and tpc.tokens.get("cli:h2", "") == "C2" and not tpc.tokens.has("srv:bad hid"))
	check("token_for devuelve cli:", tpc.token_for("h2") == "C2" and tpc.token_for("nope") == "")
	tpc.set_client_token("h4", "C4")
	check("set_client_token persiste", tpc.token_for("h4") == "C4")
	check("token_hids ordenados y únicos", tpc.token_hids() == ["h1", "h2", "h4"])
	tpc.token_forget("h2")
	check("token_forget borra cli:", tpc.token_for("h2") == "" and not tpc.tokens.has("cli:h2"))
	tpc.tokens["srv:h3"] = "S3"
	tpc._save_tokens()
	tf.open(tp, File.READ)
	var saved = JSON.parse(tf.get_as_text()).result
	tf.close()
	check("tokens: guardar escribe srv: y cli:", saved.get("srv:h1", "") == "S1"
		and saved.get("cli:h4", "") == "C4" and saved.get("srv:h3", "") == "S3"
		and not saved.has("cli:h2"))
	Directory.new().remove(tp)
	tpc.free()

	OS.exit_code = 1 if failed > 0 else 0
	quit()
