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

	# GNOME (Mutter) y compositores wlroots convencionales (sway) pueden emitir.
	check("emisor local en GNOME Wayland",
		mod.local_can_emit("GNOME") and mod.local_can_emit("ubuntu:GNOME", "wayland"))
	check("GNOME elige Mutter", mod.local_emit_backend("GNOME") == "mutter")
	check("sway emite por wlroots",
		mod.local_can_emit("sway") and mod.local_emit_backend("sway") == "wlr")
	# Regresión Fase A: gdtk anida su compositor; la captura exterior de sway NO es
	# su pantalla. `desktop=gdtk` jamás equivale a sway, ni con SWAYSOCK presente.
	check("gdtk no emite sin broker embedded",
		not mod.local_can_emit("gdtk") and mod.local_emit_backend("gdtk") == "")
	check("desktop=gdtk nunca es wlr", mod.local_emit_backend("gdtk") != "wlr")
	check("gdtk + SWAYSOCK no habilita --virtual exterior",
		not mod.local_outer_virtual_allowed("gdtk", "wayland", true))
	check("sway + SWAYSOCK sí habilita --virtual exterior",
		mod.local_outer_virtual_allowed("sway", "wayland", true)
		and not mod.local_outer_virtual_allowed("sway", "wayland", false))
	check("gdtk con capacidad embedded devuelve backend estable gdtk",
		mod.local_can_emit("gdtk", "wayland", true)
		and mod.local_emit_backend("gdtk", "wayland", true) == "gdtk")
	check("x11 y escritorios sin emisor no emiten",
		not mod.local_can_emit("GNOME", "x11") and not mod.local_can_emit("XFCE")
		and not mod.local_can_emit("") and mod.local_emit_backend("gdtk", "x11", true) == "")

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

	# Receptor local en un tile: cursor embebido en el video, sin cursor sway.
	var rp = mod.local_recv_argv("/home/u/gvd/gvd.py", false)
	check("receptor local auto (gl/xv)", rp.ok and rp.cmd == "python3"
		and rp.args[1] == "recv" and rp.args[3] == "auto")
	check("receptor local desactiva cursor falso",
		rp.args.find("--cursor") >= 0 and rp.args.find("none") >= 0)
	var rps = mod.local_recv_argv("/home/u/gvd/gvd.py", true)
	check("receptor con SWAYSOCK tampoco usa cursor falso",
		rps.args.find("--cursor") >= 0 and rps.args.find("none") >= 0)
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
	check("emisor local sin captura no agrega --capture ni --virtual",
		sp.args.find("--capture") < 0 and sp.args.find("--virtual") < 0)
	var spv = mod.local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5600, "right", true)
	check("wlr_virtual conserva --virtual",
		spv.ok and spv.args.find("--virtual") >= 0 and spv.args.find("--position") >= 0)

	# Captura embebida (forward-looking): `--capture gdtk --output <id>` sólo con
	# output id validado; falla cerrada ante id/backend inválidos y nunca --virtual.
	var spc = mod.local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5600, "right",
		false, "gdtk", "remote:ab12")
	check("captura gdtk con output id validado", spc.ok and spc.args.has("--capture")
		and spc.args.has("gdtk") and spc.args.has("--output") and spc.args.has("remote:ab12"))
	check("captura gdtk no produce --virtual", spc.args.find("--virtual") < 0)
	check("output id inválido falla",
		not mod.local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 0, "",
			false, "gdtk", "bad id; rm -rf").ok)
	check("backend de captura desconocido falla",
		not mod.local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 0, "",
			false, "wlr", "remote:ab12").ok)
	var spcv = mod.local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 0, "",
		true, "gdtk", "primary")
	check("capture_backend gana a wlr_virtual (sin --virtual)",
		spcv.ok and spcv.args.find("--virtual") < 0)

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

	# Rangos del portal InputCapture: los links fijan el tramo; una dirección
	# suspendida (gvd extendiendo hacia ese borde) queda deshabilitada (0..0) y no
	# afecta a las demás. Orden [w_lo,w_hi, e_lo,e_hi, n_lo,n_hi, s_lo,s_hi].
	var lr = [{"direction": "east", "peer": "tengu", "local_range": [0.0, 67.0]},
		{"direction": "north", "peer": "cupid", "local_range": [20.0, 80.0]}]
	var full = mod.capture_ranges(lr)
	check("rangos sin suspensión", full[2] == 0.0 and full[3] == 67.0 and full[4] == 20.0 and full[5] == 80.0)
	var sus_r = mod.capture_ranges(lr, ["east"])
	check("borde extendido deshabilitado", sus_r[2] == 0.0 and sus_r[3] == 0.0)
	check("otra dirección conserva su tramo", sus_r[4] == 20.0 and sus_r[5] == 80.0)
	check("sin links queda todo abierto", mod.capture_ranges([])[1] == 100.0 and mod.capture_ranges([])[3] == 100.0)
	check("dirección inválida se ignora", mod.capture_ranges(lr, ["arriba"])[2] == 0.0)

	# Compartir una ventana (Grupo): gvd lee el archivo de window_cast.gd.
	var ws = mod.window_send_argv("/opt/gvd/gvd.py", "cupid.local", "/run/user/1000/gdtk/win-a.frames", 90)
	var wa = ws.get("args", [])
	check("ventana: argv shm", bool(ws.ok) and wa.has("send") and wa.has("--capture")
		and wa[wa.find("--capture") + 1] == "shm" and wa[wa.find("--shm") + 1] == "/run/user/1000/gdtk/win-a.frames")
	check("ventana: fps acotado", wa[wa.find("--fps") + 1] == "60")
	check("ventana: ruta relativa rechazada", not bool(mod.window_send_argv("/opt/gvd/gvd.py", "cupid", "x.frames").ok))
	check("ventana: ruta con .. rechazada", not bool(mod.window_send_argv("/opt/gvd/gvd.py", "cupid", "/run/../etc/x").ok))
	# Receptor: el contenido mide como el video (chrome aparte); si no entra, se achica.
	var rcv = mod.receiver_frame_rect(Vector2(944, 500), Rect2(0, 80, 1280, 640), Vector2(4, 30))
	check("receptor: contenido = video", rcv.size == Vector2(948, 530) and rcv.position == Vector2(166, 135))
	var rb = mod.receiver_frame_rect(Vector2(1920, 1080), Rect2(0, 0, 1280, 720), Vector2(4, 30))
	check("receptor: grande se achica sin deformar", rb.size.y <= 720 and rb.size.x <= 1280
		and abs((rb.size.x - 4) / (rb.size.y - 30) - 16.0 / 9.0) < 0.01)
	check("receptor: sin video no hay rect", mod.receiver_frame_rect(Vector2(), Rect2(0, 0, 100, 100)) == Rect2())
	var rc = mod.receiver_frame_rect(Vector2(400, 200), Rect2(0, 0, 1280, 720), Vector2(), Vector2(300, 300))
	check("receptor: reajuste conserva el centro", rc == Rect2(100, 200, 400, 200))
	var re = mod.receiver_frame_rect(Vector2(400, 200), Rect2(0, 0, 1280, 720), Vector2(), Vector2(10, 10))
	check("receptor: centro en el borde queda dentro", re.position == Vector2(0, 0))
	var sn = mod.aspect_snap_rect(Rect2(50, 60, 804, 900), Vector2(1600, 900), Rect2(0, 0, 1280, 1000), Vector2(4, 30))
	check("snap: ancho elegido, alto por proporción", sn == Rect2(50, 60, 804, 480))
	var sh = mod.aspect_snap_rect(Rect2(0, 0, 1200, 100), Vector2(400, 400), Rect2(0, 0, 1280, 600))
	check("snap: si no entra manda el alto", sh.size == Vector2(600, 600))
	var wc = load("res://window_cast.gd")
	var big = wc.out_size(Vector2(3841, 2161))
	check("cast: tamaño par y acotado", big.x <= 1920 and big.y <= 1080 and int(big.x) % 2 == 0 and int(big.y) % 2 == 0 and big.x >= 1916)
	check("cast: ventana chica conserva tamaño", wc.out_size(Vector2(801, 600)) == Vector2(800, 600))
	check("cast: tamaño nulo", wc.out_size(Vector2(1, 0)) == Vector2())
	var lr2 = wc.layer_rect(Rect2(10, 10, 100, 50), Rect2(10, 10, 100, 50), Vector2(200, 200))
	check("cast: capa raíz escalada y centrada", lr2 == Rect2(0, 50, 200, 100))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
