extends SceneTree

# Autoprueba del modelo puro «Enviar audio» (shell/audio_send.gd).

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var A = load("res://audio_send.gd")
	check("audio_send.gd carga", A != null)
	check("RECV_PORT", A.RECV_PORT == 4714)

	# --- sink_name -----------------------------------------------------------
	check("sink_name simple", A.sink_name("aa03") == "gdtk_send_aa03")
	check("sink_name reemplaza", A.sink_name("a/b-c.d") == "gdtk_send_a_b_c_d")
	check("sink_name conserva _", A.sink_name("a_b") == "gdtk_send_a_b")
	check("sink_name vacío", A.sink_name("") == "gdtk_send_")

	# --- recv_load_argv ------------------------------------------------------
	check("recv default",
		A.recv_load_argv("192.168.1.10")
		== ["load-module", "module-native-protocol-tcp",
			"port=4714", "auth-ip-acl=192.168.1.10"])
	check("recv puerto custom",
		A.recv_load_argv("192.168.1.10", 5555)
		== ["load-module", "module-native-protocol-tcp",
			"port=5555", "auth-ip-acl=192.168.1.10"])
	check("recv IPv6",
		A.recv_load_argv("::1")
		== ["load-module", "module-native-protocol-tcp",
			"port=4714", "auth-ip-acl=::1"])
	check("recv IP inválida", A.recv_load_argv("no-es-ip") == [])
	check("recv IP vacía", A.recv_load_argv("") == [])
	check("recv puerto 0", A.recv_load_argv("10.0.0.1", 0) == [])
	check("recv puerto 70000", A.recv_load_argv("10.0.0.1", 70000) == [])

	# --- tunnel_load_argv ----------------------------------------------------
	check("tunnel IPv4",
		A.tunnel_load_argv("10.0.0.5", 4714, "aa03")
		== ["load-module", "module-tunnel-sink",
			"server=tcp:10.0.0.5:4714", "sink_name=gdtk_send_aa03"])
	check("tunnel IPv6 corchetes",
		A.tunnel_load_argv("fe80::1", 4714, "aa03")
		== ["load-module", "module-tunnel-sink",
			"server=tcp:[fe80::1]:4714", "sink_name=gdtk_send_aa03"])
	check("tunnel puerto custom",
		A.tunnel_load_argv("10.0.0.5", 6000, "x/y")
		== ["load-module", "module-tunnel-sink",
			"server=tcp:10.0.0.5:6000", "sink_name=gdtk_send_x_y"])
	check("tunnel IP inválida", A.tunnel_load_argv("nope", 4714, "a") == [])
	check("tunnel puerto inválido", A.tunnel_load_argv("10.0.0.5", -1, "a") == [])

	# --- unload_argv ---------------------------------------------------------
	check("unload int", A.unload_argv(536870916) == ["unload-module", "536870916"])
	check("unload string numérica", A.unload_argv("42") == ["unload-module", "42"])
	check("unload cero", A.unload_argv(0) == [])
	check("unload negativo", A.unload_argv(-3) == [])
	check("unload no numérico", A.unload_argv("abc") == [])
	check("unload string vacía", A.unload_argv("") == [])

	# --- parse_module_id -----------------------------------------------------
	check("module_id", A.parse_module_id("536870916\n") == 536870916)
	check("module_id con espacios", A.parse_module_id("  42  \n") == 42)
	check("module_id primer renglón", A.parse_module_id("\n\n7\n8\n") == 7)
	check("module_id vacío", A.parse_module_id("") == -1)
	check("module_id no numérico", A.parse_module_id("error\n") == -1)

	# --- parse_default_sink --------------------------------------------------
	check("default_sink",
		A.parse_default_sink("Server Name: pulse\nDefault Sink: gdtk_send_aa03\n")
		== "gdtk_send_aa03")
	check("default_sink sin marca", A.parse_default_sink("Server Name: pulse\n") == "")
	check("default_sink vacío", A.parse_default_sink("") == "")

	# --- parse_sink_inputs ---------------------------------------------------
	check("sink_inputs", A.parse_sink_inputs("12\tname\tx\n7\tother\ty\n") == [12, 7])
	check("sink_inputs ignora no numérico",
		A.parse_sink_inputs("no\tx\n\n") == [])
	check("sink_inputs vacío", A.parse_sink_inputs("") == [])

	# --- move_argvs ----------------------------------------------------------
	check("move_argvs",
		A.move_argvs([1, 2], "gdtk_send_aa03")
		== [["move-sink-input", "1", "gdtk_send_aa03"],
			["move-sink-input", "2", "gdtk_send_aa03"]])
	check("move_argvs sink vacío", A.move_argvs([1, 2], "") == [])

	OS.exit_code = 1 if failed > 0 else 0
	quit()
