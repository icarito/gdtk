extends SceneTree

# Autoprueba del protocolo puro del canal peer (shell/peer_link.gd).

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var P = load("res://peer_link.gd")
	check("peer_link.gd carga", P != null)
	check("selftest interno", P.selftest())

	var req = P.encode_request("aa03", "tok", "ping", {"x": 1})
	check("request una línea", req.ends_with("\n") and req.count("\n") == 1)
	var p = P.parse_request(req)
	check("parse conserva campos", p.hid == "aa03" and p.method == "ping" and int(p.params.x) == 1)
	check("rechaza versión distinta", P.parse_request(JSON.print({"v": 9, "hid": "a", "method": "ping"}) + "\n").empty())
	check("rechaza método fuera de lista", P.parse_request(JSON.print({"v": 1, "hid": "a", "method": "shutdown"}) + "\n").empty())
	check("rechaza hid inválido", P.parse_request(JSON.print({"v": 1, "hid": "a/b", "method": "ping"}) + "\n").empty())
	check("respuesta ok parseable", bool(P.parse_response(P.encode_response(true)).ok))
	check("respuesta error parseable", String(P.parse_response(P.encode_response(false, "bad")).error) == "bad")

	# --- Avisos de lados compartidos (G5) ------------------------------------
	check("métodos share en la lista blanca",
		P.valid_method("share_notify") and P.valid_method("share_stop"))
	check("share_notify válido",
		P.valid_share_params("share_notify",
			{"type": "screen", "side": "north", "state": "active"}))
	check("share_notify acepta stopped",
		P.valid_share_params("share_notify",
			{"type": "input", "side": "west", "state": "stopped"}))
	check("share_notify rechaza tipo",
		not P.valid_share_params("share_notify",
			{"type": "clipboard", "side": "north", "state": "active"}))
	check("share_notify rechaza lado",
		not P.valid_share_params("share_notify",
			{"type": "screen", "side": "up", "state": "active"}))
	check("share_notify rechaza estado",
		not P.valid_share_params("share_notify",
			{"type": "screen", "side": "north", "state": "idle"}))
	check("share_notify rechaza params no dict",
		not P.valid_share_params("share_notify", "x"))
	check("share_stop válido", P.valid_share_params("share_stop", {"type": "input"}))
	check("share_stop exige tipo",
		not P.valid_share_params("share_stop", {})
		and not P.valid_share_params("share_stop", {"type": "nope"}))
	check("otros métodos sin restricción", P.valid_share_params("gvd_recv", {}))

	# Los métodos share pasan el parseo normal del canal.
	var sn = P.parse_request(P.encode_request("aa03", "tok", "share_notify",
		{"type": "screen", "side": "south", "state": "active"}))
	check("share_notify parseable", String(sn.method) == "share_notify"
		and String(sn.params.side) == "south")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
