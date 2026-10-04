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
	func _peer_is_confirmed(hid):
		return String(hid) == "aaaa" or String(hid) == "bbbb"
	func _peer_gvd_open(port, from):
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
	OS.exit_code = 1 if failed > 0 else 0
	quit()
