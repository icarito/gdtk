extends SceneTree

# Autoprueba PURA del despacho de acciones del Vecindario (host_dispatch.dispatch_of).
# No hace I/O, no arranca procesos ni Threads: sólo clasifica planes.
#   godot --no-window --path shell -s $PWD/tests/host_dispatch_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var S = load("res://host_dispatch.gd")

	# Plan inválido -> "none" (nada ejecutable).
	check("plan null -> none", S.dispatch_of(null).mechanism == "none")
	check("plan fallido -> none",
		S.dispatch_of({"ok": false, "kind": "process"}).mechanism == "none")
	check("kind desconocido -> none",
		S.dispatch_of({"ok": true, "kind": "otro"}).mechanism == "none")

	# Deskflow: kind "service_toggle" -> "deskflow" con argv [cmd] + args.
	var df = {"ok": true, "kind": "service_toggle", "activity": "Deskflow",
		"config": "/home/u/gdtk/deskflow-client.conf", "cmd": "deskflow-core",
		"args": ["deskflow-core", "client", "--new-instance", "-s", "/home/u/gdtk/deskflow-client.conf"]}
	var d = S.dispatch_of(df, "use_remote_input")
	check("service_toggle -> deskflow", d.mechanism == "deskflow")
	check("deskflow argv cmd+args", d.argv.size() == 6 and d.argv[0] == "deskflow-core"
		and d.argv[1] == "deskflow-core" and d.argv[2] == "client")

	# gvd: kind "process"; el id de acción decide, sin id se infiere del argv.
	var send_plan = {"ok": true, "kind": "process", "cmd": "python3",
		"args": ["/home/u/Proyectos/gvd/gvd.py", "send", "--host", "tengu.local", "--position", "right"]}
	check("use_as_screen -> gvd_recv",
		S.dispatch_of(send_plan, "use_as_screen").mechanism == "gvd_recv")
	check("share_my_screen -> gvd_send",
		S.dispatch_of(send_plan, "share_my_screen").mechanism == "gvd_send")
	check("sin id, argv send -> gvd_send", S.dispatch_of(send_plan).mechanism == "gvd_send")
	var send_argv = S.dispatch_of(send_plan, "share_my_screen").argv
	check("argv de gvd send completo", send_argv.size() == 7
		and send_argv[0] == "python3" and send_argv[1] == "/home/u/Proyectos/gvd/gvd.py"
		and send_argv[2] == "send")

	var recv_plan = {"ok": true, "kind": "process", "cmd": "python3",
		"args": ["/home/u/gvd/gvd.py", "recv", "--sink", "wayland"]}
	check("sin id, argv recv -> gvd_recv", S.dispatch_of(recv_plan).mechanism == "gvd_recv")

	# Portapapeles: por kind o por id; nunca lleva argv (sin proceso).
	check("deskflow_clipboard -> clipboard",
		S.dispatch_of({"ok": true, "kind": "deskflow_clipboard", "auto": false}).mechanism == "clipboard")
	check("id share_clipboard gana aunque el plan sea process",
		S.dispatch_of(send_plan, "share_clipboard").mechanism == "clipboard")
	check("clipboard sin argv",
		S.dispatch_of({"ok": true, "kind": "deskflow_clipboard"}).argv.empty())

	# Integración con los generadores reales (puros) de neighborhood_actions.gd.
	var A = load("res://neighborhood_actions.gd")
	var real_send = A.gvd_send_plan("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5600,
		{"position": "right"})
	check("plan real de gvd send clasifica",
		S.dispatch_of(real_send, "share_my_screen").mechanism == "gvd_send")
	var real_df = A.deskflow_plan("client", "/home/u/gdtk/deskflow-client.conf")
	check("plan real de deskflow clasifica",
		S.dispatch_of(real_df, "use_remote_input").mechanism == "deskflow")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
