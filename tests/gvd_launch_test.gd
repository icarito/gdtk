extends SceneTree

# Autoprueba PURA de los planes de automatización de gvd (K17). No hace ssh ni
# arranca procesos: sólo verifica argv/mapa/suspensión. Correr:
#   godot --no-window --path shell -s $PWD/tests/gvd_launch_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var mod = load("res://gvd_launch.gd").new()
	check("selftest() de gvd_launch", mod.run_selftest())

	# Mapa -> posición de gvd (y su inversa para el emisor remoto).
	check("posición east -> right", mod.position_for("east") == "right")
	check("posición north -> above", mod.position_for("north") == "above")
	check("posición invertida east -> left", mod.position_for("east", true) == "left")
	check("dirección sin posición -> \"\"",
		mod.position_for("none") == "" and mod.position_for("up") == "")
	check("valid_position rechaza basura",
		not mod.valid_position("diagonal") and not mod.valid_position(""))

	# Sólo GNOME Wayland puede emitir localmente.
	check("emisor local en GNOME Wayland",
		mod.local_can_emit("GNOME") and mod.local_can_emit("ubuntu:GNOME", "wayland"))
	check("sway/x11 no emiten",
		not mod.local_can_emit("sway") and not mod.local_can_emit("GNOME", "x11"))

	# Extracción del plan real de neighborhood_actions.
	var A = load("res://neighborhood_actions.gd")
	var send = A.gvd_send_plan("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5601,
		{"position": "right"})
	check("gvd_path_of del plan", mod.gvd_path_of(send) == "/home/u/Proyectos/gvd/gvd.py")
	check("port_of_plan del plan", mod.port_of_plan(send) == 5601)
	check("target_host_of del plan", mod.target_host_of(send) == "tengu.local")
	var bare = A.gvd_send_plan("gvd", "tengu.local", 0, {})
	check("plan con binario del PATH", mod.gvd_path_of(bare) == "gvd"
		and mod.port_of_plan(bare) == 5600)
	check("gvd_path_of plan inválido", mod.gvd_path_of(null) == ""
		and mod.gvd_path_of({"ok": false}) == "")

	# Receptor local en un tile: --cursor sway sólo con SWAYSOCK.
	var rp = mod.local_recv_argv("/home/u/gvd/gvd.py", false)
	check("receptor local auto (gl/xv)", rp.ok and rp.cmd == "python3"
		and rp.args[1] == "recv" and rp.args[3] == "auto")
	check("receptor sin sway no fuerza cursor", rp.args.find("--cursor") < 0)
	var rps = mod.local_recv_argv("/home/u/gvd/gvd.py", true)
	check("receptor con SWAYSOCK usa --cursor sway",
		rps.args.find("--cursor") >= 0 and rps.args.find("sway") >= 0)
	check("receptor escucha el puerto del emisor",
		mod.local_recv_argv("/home/u/gvd/gvd.py", false, 5601).args.find("5601") >= 0
		and mod.local_recv_argv("/home/u/gvd/gvd.py", false, 5600).args.find("--port") < 0)
	check("receptor con ruta inválida falla", not mod.local_recv_argv("~/gvd/gvd.py", true).ok)

	# Emisor local.
	var sp = mod.local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5600, "right")
	check("emisor local con --position", sp.ok and sp.args.find("--position") >= 0
		and sp.args.find("right") >= 0)
	check("emisor local posición inválida falla",
		not mod.local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 0, "x").ok)

	# Receptor remoto por ssh (buzón): comando remoto estable, sin inyección.
	var rr = mod.remote_recv_argv("tengu.local", false)
	check("receptor remoto por ssh", rr.ok and rr.cmd == "ssh"
		and rr.args.has("BatchMode=yes") and rr.args.has("ConnectTimeout=3"))
	check("ssh con peer como argumento", rr.args[rr.args.size() - 2] == "tengu.local")
	var rcmd = String(rr.args[rr.args.size() - 1])
	check("comando remoto resuelve gvd y abre recv",
		rcmd.find("recv --sink auto") >= 0 and rcmd.find("command -v gvd") >= 0)
	check("receptor remoto sin sway no fuerza cursor", rcmd.find("--cursor") < 0)
	var rrs = mod.remote_recv_argv("tengu.local", true)
	check("receptor remoto con SWAYSOCK usa cursor",
		String(rrs.args[rrs.args.size() - 1]).find("--cursor sway") >= 0)
	check("peer inválido rechazado", not mod.remote_recv_argv("-bad", false).ok
		and not mod.remote_recv_argv("a b", false).ok)

	# Emisor remoto: destino validado, posición y puerto.
	var rs = mod.remote_send_argv("192.168.1.20", "bastion.local", 5600, "left")
	check("emisor remoto por ssh", rs.ok and rs.cmd == "ssh")
	var scmd = String(rs.args[rs.args.size() - 1])
	check("comando remoto send --host", scmd.find("send --host bastion.local") >= 0)
	check("emisor remoto posición y puerto default omitido",
		scmd.find("--position left") >= 0 and scmd.find("--port") < 0)
	var rs2 = mod.remote_send_argv("192.168.1.20", "bastion.local", 5601, "")
	check("emisor remoto puerto alternativo",
		String(rs2.args[rs2.args.size() - 1]).find("--port 5601") >= 0)
	check("emisor remoto rechaza destino/posición inválidos",
		not mod.remote_send_argv("192.168.1.20", "", 0, "").ok
		and not mod.remote_send_argv("192.168.1.20", "bastion.local", 0, "x").ok)

	# Claves de sesión: emisor local conserva el hid.
	var keys = mod.session_keys("h1")
	check("claves de sesión distintas y estables", keys.size() == 3
		and keys[0] == "h1" and keys[1] == "gvdrecv:h1" and keys[2] == "gvdsend:h1")

	# Suspensión/restauración del vínculo Deskflow hacia la dirección extendida.
	var links = [{"direction": "east", "peer": "tengu"},
		{"direction": "north", "peer": "cupid"}]
	var sus = mod.deskflow_suspend(links, "east")
	check("suspende sólo la dirección extendida", sus.suspended
		and sus.removed.size() == 1 and sus.links.size() == 1
		and String(sus.links[0].direction) == "north")
	check("restaura sin duplicar", mod.deskflow_restore(sus.links, sus.removed).size() == 2
		and mod.deskflow_restore(mod.deskflow_restore(sus.links, sus.removed),
			sus.removed).size() == 2)
	check("dirección none no suspende",
		not mod.deskflow_suspend(links, "none").suspended)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
