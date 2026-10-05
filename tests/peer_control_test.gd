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
	func _peer_window_input(hid, events):
		input_events.append([String(hid), events.duplicate(true)])
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

	# token incorrecto: unauthorized
	r = _resp(pc, peer, LINK.encode_request("aaaa", "malo", "gvd_recv", {"port": 5602}))
	check("token incorrecto rechazado", not bool(r.get("ok", false)) and String(r.get("error", "")) == "unauthorized")

	# token correcto: ok (sin devolver token de nuevo)
	r = _resp(pc, peer, LINK.encode_request("aaaa", tok, "gvd_recv", {"port": 5603}))
	check("token correcto ok", bool(r.get("ok", false)) and not r.has("token"))
	check("abrió segundo receptor", pc.shell.opened.size() == 2)

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
	# Tokens: el canal conserva sus srv: entre reinicios y no borra los cli: del shell.
	var tp = OS.get_user_data_dir().plus_file("peer-tokens-test.json")
	var tf = File.new()
	tf.open(tp, File.WRITE)
	tf.store_string(JSON.print({"srv:h1": "S1", "cli:h2": "C2", "srv:bad hid": "X"}))
	tf.close()
	var tpc = load("res://peer_control.gd").new()
	tpc.tokens_path = tp
	tpc._load_tokens()
	check("tokens: carga srv: válidos", tpc.tokens.get("srv:h1", "") == "S1" and not tpc.tokens.has("srv:bad hid"))
	tpc.tokens["srv:h3"] = "S3"
	tpc._save_tokens()
	tf.open(tp, File.READ)
	var saved = JSON.parse(tf.get_as_text()).result
	tf.close()
	check("tokens: guardar conserva cli: del shell", saved.get("cli:h2", "") == "C2"
		and saved.get("srv:h1", "") == "S1" and saved.get("srv:h3", "") == "S3")
	Directory.new().remove(tp)
	tpc.free()

	OS.exit_code = 1 if failed > 0 else 0
	quit()
