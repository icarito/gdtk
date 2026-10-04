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
	check("sin switches: local", W.server_local("[t] NOTE: started server\n", "bastion"))
	OS.exit_code = 1 if failed > 0 else 0
	quit()
