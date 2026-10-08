extends SceneTree

# Autoprueba de las acciones de host del Vecindario. Correr:
#   godot --no-window --path shell -s $PWD/tests/neighborhood_actions_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var acts = load("res://neighborhood_actions.gd").new()
	acts.run_selftest()
	check("selftest() de acciones", true)

	# Integración con el modelo de hosts (Kilo A): servicios reales -> acciones.
	var hosts_model = load("res://neighborhood_hosts.gd").new()
	var text = PoolStringArray([
		"=;eth0;IPv4;Tengu GVD;_gdtk-gvd._udp;local;tengu.local;192.168.1.20;5600;\"v=1\";\"hid=h1\";\"role=recv\";\"state=ready\"",
		"=;eth0;IPv4;Tengu Deskflow;_gdtk-deskflow._tcp;local;tengu.local;192.168.1.20;24800;v=1;hid=h1;role=server;clip=1",
	]).join("\n")
	var hosts = hosts_model.build_hosts(hosts_model.parse_services(text, 10), {}, 10, 60)
	var local = {"gvd_path": "/home/u/Proyectos/gvd/gvd.py", "home": "/home/u"}
	var actions = acts.host_actions(hosts[0], local)
	var ids = []
	for a in actions:
		ids.append(a.id)
	check("dos capacidades -> dos acciones (sin portapapeles)", ids.has("use_as_screen")
		and ids.has("use_remote_input") and not ids.has("share_clipboard") and ids.size() == 2)
	var screen = _by_id(actions, "use_as_screen")
	check("pantalla con argv seguro", screen.enabled and screen.plan.cmd == "python3"
		and screen.plan.args[2] == "--host" and screen.plan.args[3] == "192.168.1.20"
		and screen.plan.args.find("--port") < 0)
	check("verbos K16 en las acciones", screen.label == "Ver su escritorio aquí"
		and _by_id(actions, "use_remote_input").label == "Usar su teclado y mouse aquí")
	var df = _by_id(actions, "use_remote_input")
	check("deskflow cliente con config por defecto", df.enabled
		and df.plan.config == "/home/u/gdtk/deskflow-client.conf"
		and df.plan.args[1] == "client"
		and df.plan.args[df.plan.args.size() - 1] == df.plan.config)
	check("deskflow cliente con remoteHost del peer", df.plan.settings_text.find("coreMode=1") >= 0
		and df.plan.settings_text.find("remoteHost=tengu.local") >= 0)

	# El portapapeles no aparece como acción, ni siquiera si el peer anuncia clip=1.
	check("sin acción de portapapeles aunque clip=1",
		_by_id(actions, "share_clipboard") == null)

	# state=capable sin canal autorizado: deshabilitada y con razón.
	var capable = acts.host_actions(_hosts_from(hosts_model, text.replace("state=ready", "state=capable"))[0], local)
	var c = _by_id(capable, "use_as_screen")
	check("capable sin canal queda deshabilitada", not c.enabled and c.reason != "")

	# Host sin hid (degradado): acciones presentes pero no confiables.
	var loose_text = "=;eth0;IPv4;Suelto;_gdtk-gvd._udp;local;x.local;10.0.0.9;5600;\"role=recv\";\"state=ready\""
	var loose_hosts = hosts_model.build_hosts(hosts_model.parse_services(loose_text, 10), {}, 10, 60)
	var loose = acts.host_actions(loose_hosts[0], local)
	check("host degradado no confiable", loose.size() == 1 and not loose[0].enabled
		and loose[0].state == "no confiable")

	# Sin ruta gvd resuelta localmente: la pantalla se deshabilita, Deskflow sigue.
	var sin_gvd = acts.host_actions(hosts[0], {"home": "/home/u"})
	check("sin gvd_path la pantalla se deshabilita", not _by_id(sin_gvd, "use_as_screen").enabled
		and _by_id(sin_gvd, "use_as_screen").reason != ""
		and _by_id(sin_gvd, "use_remote_input").enabled)

	# --- Direccion (SPEC-screen-share-compass, Kilo C) ---
	var gvd_svc = {"txt": {"role": "recv", "state": "ready"}, "address": "192.168.1.20", "port": 5600}
	var df_client = {"txt": {"role": "client"}, "address": "192.168.1.20", "port": 24800}
	var dir_local = {"gvd_path": "/home/u/Proyectos/gvd/gvd.py", "home": "/home/u"}
	var dir_host = {"id": "h1", "label": "tengu", "capabilities": {"gvd": gvd_svc, "deskflow": df_client}}

	# Direccion -> --position en la accion de pantalla (north->above, east->right).
	var east = _by_id(acts.host_actions({"id": "h1", "label": "tengu",
		"capabilities": {"gvd": gvd_svc}}, _merge(dir_local, {"direction": "east"})), "use_as_screen")
	check("direccion east -> --position right", east.enabled
		and east.plan.args.find("--position") >= 0 and east.plan.args.find("right") >= 0)
	var north = _by_id(acts.host_actions({"id": "h1", "label": "tengu",
		"capabilities": {"gvd": gvd_svc}}, _merge(dir_local, {"direction": "north"})), "use_as_screen")
	check("direccion north -> --position above", north.plan.args.find("--position") >= 0
		and north.plan.args.find("above") >= 0)
	var no_dir = _by_id(acts.host_actions({"id": "h1", "label": "tengu",
		"capabilities": {"gvd": gvd_svc}}, dir_local), "use_as_screen")
	check("sin direccion -> sin --position", no_dir.enabled
		and no_dir.plan.args.find("--position") < 0)

	# Conflicto de borde: pantalla y serve_input_here deshabilitadas con state "conflicto".
	var conflict_local = _merge(dir_local,
		{"direction": "east", "direction_conflict": true, "deskflow_server": true})
	var conflict = _by_id(acts.host_actions(dir_host, conflict_local), "use_as_screen")
	check("conflicto -> pantalla deshabilitada", not conflict.enabled
		and conflict.state == "conflicto" and conflict.reason != "")
	var conflict_serve = _by_id(acts.host_actions(dir_host, conflict_local), "serve_input_here")
	check("conflicto -> serve_input_here deshabilitada", not conflict_serve.enabled
		and conflict_serve.state == "conflicto" and conflict_serve.reason != "")

	# serve_input_here: direccion sin confirmar no genera links; confirmada si.
	var proposed = _by_id(acts.host_actions(dir_host, _merge(dir_local,
		{"direction": "east", "direction_confirm": "proposed", "deskflow_server": true})),
		"serve_input_here")
	check("direccion propuesta -> serve_input_here deshabilitada",
		not proposed.enabled and proposed.reason != "")
	var confirmed = _by_id(acts.host_actions(dir_host, _merge(dir_local,
		{"direction": "east", "direction_confirm": "confirmed", "deskflow_server": true})),
		"serve_input_here")
	check("direccion confirmada -> serve_input_here con layout barrier", confirmed.enabled
		and confirmed.plan.ok and confirmed.plan.has("layout_text")
		and confirmed.plan.layout_text.find("section: screens") >= 0
		and confirmed.plan.layout_text.find("right = tengu") >= 0)
	check("serve_input_here escribe server-settings.ini con externalConfigFile", confirmed.enabled
		and confirmed.plan.config == "/home/u/gdtk/deskflow-server-settings.ini"
		and confirmed.plan.settings_text.find("coreMode=2") >= 0
		and confirmed.plan.settings_text.find("externalConfigFile=/home/u/.config/Deskflow/deskflow-server.conf") >= 0
		and confirmed.plan.layout_path == "/home/u/.config/Deskflow/deskflow-server.conf")

	# Acción cliente sin dirección del servidor: deshabilitada con razón explícita.
	var remote_no_addr = _by_id(acts.host_actions({"id": "h1", "label": "tengu",
		"capabilities": {"deskflow": {"txt": {"role": "server"}, "port": 24800}}},
		dir_local), "use_remote_input")
	check("use_remote_input sin address deshabilitada", not remote_no_addr.enabled
		and remote_no_addr.reason == "sin dirección del servidor")

	# use_remote_input (peer servidor) no depende de la direccion/confirmacion local.
	var remote = _by_id(acts.host_actions({"id": "h1", "label": "tengu",
		"capabilities": {"deskflow": {"txt": {"role": "server"}, "address": "192.168.1.20", "port": 24800}}},
		dir_local), "use_remote_input")
	check("use_remote_input sin direccion confirmada sigue habilitada", remote.enabled)

	# --- Grupo: sumar/quitar equipo (SOLO con local.group_menu) ---
	var group_host = {"id": "h1", "hid": "h1", "label": "tengu",
		"capabilities": {"gvd": gvd_svc}}
	var can_add = acts.host_actions(group_host,
		_merge(dir_local, {"group_menu": true, "group_members": {}}))
	check("grupo: no miembro -> Añadir a mi grupo",
		_by_id(can_add, "add_to_group") != null and _by_id(can_add, "add_to_group").enabled
		and _by_id(can_add, "remove_from_group") == null
		and _by_id(can_add, "add_to_group").label == "Añadir a mi grupo")
	var can_remove = acts.host_actions(group_host,
		_merge(dir_local, {"group_menu": true, "group_members": {"h1": true}}))
	check("grupo: miembro -> Quitar del grupo",
		_by_id(can_remove, "remove_from_group") != null
		and _by_id(can_remove, "add_to_group") == null
		and _by_id(can_remove, "remove_from_group").label == "Quitar del grupo")
	var plain = acts.host_actions(group_host, dir_local)
	check("sin group_menu no hay acciones de grupo",
		_by_id(plain, "add_to_group") == null and _by_id(plain, "remove_from_group") == null)

	OS.exit_code = 1 if failed > 0 else 0
	quit()


func _merge(base, extra):
	var out = base.duplicate()
	for k in extra.keys():
		out[k] = extra[k]
	return out


func _hosts_from(model, text):
	return model.build_hosts(model.parse_services(text, 10), {}, 10, 60)


func _by_id(actions, id):
	for a in actions:
		if a.id == id:
			return a
	return null
