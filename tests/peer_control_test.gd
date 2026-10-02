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

	# método inválido: bad request
	r = _resp(pc, peer, JSON.print({"v": 1, "hid": "aaaa", "token": tok, "method": "shutdown"}) + "\n")
	check("método inválido rechazado", not bool(r.get("ok", false)))

	if d.file_exists(tokens_path):
		d.remove(tokens_path)
	OS.exit_code = 1 if failed > 0 else 0
	quit()
