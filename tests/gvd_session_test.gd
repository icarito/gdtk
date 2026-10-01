extends SceneTree

# Autoprueba del modelo puro de sesion gvd. Correr:
#   godot --no-window --path shell -s $PWD/tests/gvd_session_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var mod = load("res://gvd_session.gd").new()
	check("selftest() de gvd_session", mod.run_selftest())

	var S = mod.STATES
	var E = mod.EVENTS
	check("STATES y EVENTS declarados", S.size() == 6 and E.size() == 6
		and S.has("idle") and S.has("preparing") and S.has("active")
		and S.has("stopping") and S.has("stopped") and S.has("failed")
		and E.has("start") and E.has("ready") and E.has("stop")
		and E.has("stopped") and E.has("fail") and E.has("reset"))

	# session_key: determinista, iguales entradas -> igual clave.
	var k1 = mod.session_key("local-a", "peer.b", "east")
	var k2 = mod.session_key("local-a", "peer.b", "east")
	check("session_key determinista", k1 == k2 and k1.find("local-a") >= 0
		and k1.find("peer.b") >= 0 and k1.find("east") >= 0)
	check("session_key distingue direccion", mod.session_key("a", "b", "east")
		!= mod.session_key("a", "b", "west"))
	check("session_key direccion invalida cae a none",
		mod.session_key("a", "b", "up").find("none") >= 0
		and mod.session_key("a", "b", "diagonal").find("none") >= 0)

	# transition: todas las validas.
	check("transition idle+start", mod.transition("idle", "start") == "preparing")
	check("transition preparing+ready", mod.transition("preparing", "ready") == "active")
	check("transition preparing+fail", mod.transition("preparing", "fail") == "failed")
	check("transition active+stop", mod.transition("active", "stop") == "stopping")
	check("transition stopping+stopped", mod.transition("stopping", "stopped") == "stopped")
	check("transition failed+reset", mod.transition("failed", "reset") == "idle")
	check("transition stopped+reset", mod.transition("stopped", "reset") == "idle")
	check("transition fail no terminal -> failed",
		mod.transition("idle", "fail") == "failed"
		and mod.transition("active", "fail") == "failed"
		and mod.transition("stopping", "fail") == "failed")
	check("transition fail terminal no cambia",
		mod.transition("failed", "fail") == "failed"
		and mod.transition("stopped", "fail") == "stopped")
	# transition: invalida no cambia el estado.
	check("transition invalida no-op", mod.transition("idle", "stop") == "idle"
		and mod.transition("active", "ready") == "active"
		and mod.transition("stopped", "start") == "stopped")

	# send_plan: direccion east -> --position right; sin direccion -> sin position.
	var sp = mod.send_plan("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5600, "east")
	check("send_plan east -> --position right", sp.ok
		and sp.args.find("--position") >= 0 and sp.args.find("right") >= 0
		and sp.cmd == "python3" and sp.args[1] == "send")
	var sp_none = mod.send_plan("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5600, "")
	check("send_plan sin direccion -> sin --position", sp_none.ok
		and sp_none.args.find("--position") < 0)
	check("send_plan ruta invalida falla",
		not mod.send_plan("~/gvd/gvd.py", "tengu.local", 5600, "east").ok)

	# recv_plan.
	var rp = mod.recv_plan("/home/u/Proyectos/gvd/gvd.py")
	check("recv_plan ---sink auto", rp.ok and rp.args[2] == "--sink"
		and rp.args[3] == "auto")
	check("recv_plan sink invalido falla",
		not mod.recv_plan("/home/u/Proyectos/gvd/gvd.py", "fbdev").ok)

	# action_kind, executable_now y gated_reason.
	check("action_kind deskflow_service",
		mod.action_kind("use_remote_input") == "deskflow_service"
		and mod.action_kind("serve_input_here") == "deskflow_service")
	check("action_kind clipboard_flag",
		mod.action_kind("share_clipboard") == "clipboard_flag")
	check("action_kind gvd_send",
		mod.action_kind("use_as_screen") == "gvd_send"
		and mod.action_kind("share_my_screen") == "gvd_send")
	check("action_kind desconocido -> \"\"",
		mod.action_kind("nope") == "" and mod.action_kind("") == "")

	check("EMITTER_ENABLED declarado", typeof(mod.EMITTER_ENABLED) == TYPE_BOOL)
	check("executable_now gvd_send segun EMITTER_ENABLED",
		mod.executable_now("use_as_screen") == mod.EMITTER_ENABLED
		and mod.executable_now("share_my_screen") == mod.EMITTER_ENABLED
		and (mod.gated_reason("use_as_screen") != "") == (not mod.EMITTER_ENABLED)
		and (mod.gated_reason("share_my_screen") != "") == (not mod.EMITTER_ENABLED))
	check("action_deskflow/clipboard ejecutables ya",
		mod.executable_now("use_remote_input") and mod.executable_now("serve_input_here")
		and mod.executable_now("share_clipboard")
		and mod.gated_reason("use_remote_input") == "" and mod.gated_reason("share_clipboard") == "")
	check("id desconocido -> \"\" y false",
		mod.action_kind("nope") == "" and not mod.executable_now("nope")
		and mod.gated_reason("nope") == "")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
