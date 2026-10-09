extends SceneTree

var failed = 0


func check(name, cond):
	if cond:
		print("ok   " + name)
	else:
		failed += 1
		print("FAIL " + name)


func _init():
	var W = load("res://deskflow_watch.gd")
	var base = "[t] INFO: switch from \"bastion\" to \"cupid\" at 1,2\n[t] INFO: leaving screen\n"
	check("en cupid y vivo: nada", W.stuck_on(base, "bastion") == "")
	check("cupid se desconectó estando activo", W.stuck_on(base + "[t] NOTE: client \"cupid\" has disconnected\n", "bastion") == "cupid")
	check("cupid venció", W.stuck_on(base + "[t] WARNING: client \"cupid\" timed out\n", "bastion") == "cupid")
	check("volvió a bastion antes: nada",
		W.stuck_on(base + "[t] INFO: switch from \"cupid\" to \"bastion\" at 3,4\n[t] NOTE: client \"cupid\" has disconnected\n", "bastion") == "")
	check("se cae otro equipo (tengu): nada", W.stuck_on(base + "[t] NOTE: client \"tengu\" has disconnected\n", "bastion") == "")
	check("caída vieja y nuevo switch: nada",
		W.stuck_on("[t] NOTE: client \"cupid\" has disconnected\n" + base, "bastion") == "")
	check("log vacío", W.stuck_on("", "bastion") == "")
	check("server cree local tras volver", W.server_local(base + "[t] INFO: switch from \"cupid\" to \"bastion\" at 3,4\n", "bastion"))
	check("server cree remoto", not W.server_local(base, "bastion"))
	check("sin switches: no concluye local", not W.server_local("[t] NOTE: started server\n", "bastion"))
	var jump = base + "[t] IPC: client \"cupid\" is dead\n[t] INFO: jump from \"cupid\" to \"bastion\" at 960,540\n"
	check("jump por caída devuelve el destino local", W.server_local(jump, "bastion"))
	check("jump invalida la caída del destino anterior", W.stuck_on(jump, "bastion") == "")
	check("reconexión invalida caída vieja", W.stuck_on(base + "[t] IPC: client \"cupid\" has disconnected\n[t] IPC: client \"cupid\" has connected\n", "bastion") == "")
	var local_event = W.observe(jump, "bastion").event
	check("warnings no crean evidencia nueva", W.observe(jump + "[t] WARNING: failed to open x11 default display\n", "bastion").event == local_event)
	check("cliente conectado", W.observe("[t] IPC: connected to server\n", "tengu").connection == "connected")
	check("cliente en reconexión", W.observe("[t] IPC: connected to server\n[t] IPC: connecting to 'bastion': 10.42.0.1:24800\n", "tengu").connection == "disconnected")
	check("reconexión completa gana al error anterior", W.observe("[t] WARNING: failed to connect\n[t] IPC: connected to server\n", "tengu").connection == "connected")
	check("mDNS no corta conexión viva", not W.should_retarget("10.42.0.1", "bastion.local", "connected"))
	check("falta de log no autoriza reinicio", not W.should_retarget("10.42.0.1", "bastion.local", "unknown"))
	check("caída confirmada permite corregir endpoint", W.should_retarget("10.42.0.1", "10.42.0.2", "disconnected"))
	check("endpoint igual no reinicia al reconectar", not W.should_retarget("10.42.0.1", "10.42.0.1", "disconnected"))
	OS.exit_code = 1 if failed > 0 else 0
	quit()
