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

	OS.exit_code = 1 if failed > 0 else 0
	quit()
