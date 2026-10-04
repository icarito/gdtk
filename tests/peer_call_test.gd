extends SceneTree

# Autoprueba del cliente del canal peer (shell/peer_call.gd) contra un servidor TCP
# local mínimo, en un Thread. Cubre el bug real: `StreamPeerTCP` de este motor no
# tiene `poll()` (get_status/get_partial_data sondean solos) y llamarlo abortaba
# toda petición con un SCRIPT ERROR (el vecino nunca recibía gvd_recv).
#   ~/gdtk/bin/godot-gdtk --no-window --path shell -s $PWD/tests/peer_call_test.gd

const PC = preload("res://peer_call.gd")
const LINK = preload("res://peer_link.gd")

var failed = 0
var server_err = ""


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _serve(u):
	var srv = u.srv
	var link = load("res://peer_link.gd")
	while OS.get_ticks_msec() < int(u.deadline):
		if srv.is_connection_available():
			var c = srv.take_connection()
			if c != null:
				var buf = PoolByteArray()
				var dl = OS.get_ticks_msec() + 1000
				while OS.get_ticks_msec() < dl:
					var av = c.get_available_bytes()
					if av > 0:
						var d = c.get_partial_data(av)
						if d[0] == OK:
							buf.append_array(d[1])
						if buf.get_string_from_utf8().find("\n") >= 0:
							break
					elif c.get_status() != StreamPeerTCP.STATUS_CONNECTED:
						break
					OS.delay_msec(2)
				c.put_data(link.encode_response(true, "", {"echo": true}).to_utf8())
				c.disconnect_from_host()
				break
		OS.delay_msec(2)
	srv.stop()


func _init():
	var port = 7799
	var srv = TCP_Server.new()
	if srv.listen(port, "127.0.0.1") != OK:
		check("servidor de prueba escucha", false)
		OS.exit_code = 1
		quit()
		return
	var th = Thread.new()
	th.start(self, "_serve", {"srv": srv, "deadline": OS.get_ticks_msec() + 3000})

	var r = PC.request_status("127.0.0.1", port, "aa03", "tok", "ping", {}, 1500)
	check("request_status responde", bool(r.get("ok", false)))
	check("respuesta decodificada", bool(r.get("response", {}).get("echo", false)))
	check("sin error", String(r.get("error", "")) == "")

	th.wait_to_finish()
	# Destino inválido: no intenta red.
	var bad = PC.request_status("", 0, "aa03", "tok", "ping", {}, 200)
	check("destino inválido rechazado", not bool(bad.get("ok", false)) and String(bad.get("error", "")) == "destino inválido")
	# Puerto cerrado: falla acotado, sin colgarse.
	var t0 = OS.get_ticks_msec()
	var refused = PC.request_status("127.0.0.1", port, "aa03", "tok", "ping", {}, 400)
	check("puerto cerrado falla acotado", not bool(refused.get("ok", false)) and OS.get_ticks_msec() - t0 < 1200)

	print("PEER_CALL_TEST_" + ("OK" if failed == 0 else "FAIL"))
	OS.exit_code = 1 if failed > 0 else 0
	quit()
