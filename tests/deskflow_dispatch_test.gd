extends SceneTree

# Autoprueba PURA del despacho de Deskflow servidor vs cliente (host_dispatch.gd).
# No hace I/O, no arranca procesos ni Threads: sólo clasifica modo, clave y argv.
#   godot --no-window --path shell -s $PWD/tests/deskflow_dispatch_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var S = load("res://host_dispatch.gd")
	var A = load("res://neighborhood_actions.gd")

	# deskflow_dispatch_mode: distingue client/server y rechaza basura.
	check("mode server", S.deskflow_dispatch_mode({"mode": "server"}) == "server")
	check("mode client", S.deskflow_dispatch_mode({"mode": "client"}) == "client")
	check("mode ausente -> vacio", S.deskflow_dispatch_mode({}) == "")
	check("mode invalido -> vacio", S.deskflow_dispatch_mode({"mode": "peer"}) == "")
	check("mode no dict -> vacio", S.deskflow_dispatch_mode(null) == "")

	# deskflow_session_key: determinista, distinta por host y distinta de la clave
	# gvd (que es el propio host_id).
	check("clave de servidor por host", S.deskflow_session_key("h1") == "deskflow:h1")
	check("clave distinta por host", S.deskflow_session_key("h1") != S.deskflow_session_key("h2"))
	check("clave de servidor != host_id", S.deskflow_session_key("h1") != "h1")

	# Plan real del servidor (neighborhood_actions) -> argv real sin la duplicacion
	# descriptiva del nombre del programa (plan.args[0] == plan.cmd).
	var plan = A.deskflow_plan("server", "/home/u/gdtk/deskflow-server.conf")
	check("plan server ok", plan.ok and plan.mode == "server" and plan.cmd == "deskflow-core")
	var argv = S.deskflow_server_argv(plan)
	check("argv server: cmd", argv.cmd == "deskflow-core")
	check("argv server: args sin el programa duplicado",
		argv.args == ["server", "--new-instance", "-s", "/home/u/gdtk/deskflow-server.conf"])
	check("argv server: no repite deskflow-core", argv.args.find("deskflow-core") < 0)

	# Defensivo: si un plan no repite el programa, se respeta tal cual.
	var no_dup = {"ok": true, "kind": "service_toggle", "mode": "server", "cmd": "deskflow-core",
		"args": ["server", "-s", "/tmp/x.conf"]}
	var nd = S.deskflow_server_argv(no_dup)
	check("argv sin duplicado se respeta", nd.cmd == "deskflow-core"
		and nd.args == ["server", "-s", "/tmp/x.conf"])

	# El plan cliente no entra por el camino servidor: sigue la actividad Deskflow.
	var client = A.deskflow_plan("client", "/home/u/gdtk/deskflow-client.conf")
	check("plan client no es server", S.deskflow_dispatch_mode(client) == "client")
	check("dispatch_of service_toggle -> deskflow",
		S.dispatch_of(client, "use_remote_input").mechanism == "deskflow")

	# Robustez con entradas no diccionario.
	var null_argv = S.deskflow_server_argv(null)
	check("argv null vacio", null_argv.cmd == "" and null_argv.args.empty())
	check("argv no dict vacio", S.deskflow_server_argv("x").args.empty())

	OS.exit_code = 1 if failed > 0 else 0
	quit()
