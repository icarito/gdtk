extends SceneTree

# Genera el deskflow-server.conf con la topología COMPLETA a partir de
# ~/.config/gdtk/settings.json (resoluciones y disposición reales de Pantallas).
# Salida: /tmp/kilo/deskflow-server.conf
# Uso: godot --no-window --path shell -s $PWD/tests/gen_server_conf.gd

const OUT = "/tmp/kilo/deskflow-server.conf"


func _config_dir():
	var override = OS.get_environment("GDTK_SETTINGS")
	if override != "":
		return override.get_base_dir()
	var xdg = OS.get_environment("XDG_CONFIG_HOME")
	if xdg != "":
		return xdg.plus_file("gdtk")
	return OS.get_environment("HOME").plus_file(".config").plus_file("gdtk")


func _init():
	var SL = load("res://screen_layout.gd")
	var CONF = load("res://deskflow_conf.gd")
	var LAYOUT = load("res://deskflow_layout.gd")
	var path = _config_dir().plus_file("settings.json")
	var f = File.new()
	if f.open(path, File.READ) != OK:
		print("FAIL no pude leer ", path)
		OS.exit_code = 1
		quit()
		return
	var data = JSON.parse(f.get_as_text()).result
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		print("FAIL settings.json invalido")
		OS.exit_code = 1
		quit()
		return
	var layout = data.get("screens", {})
	var df = data.get("deskflow", {})
	var local = String(df.get("name", "")).strip_edges()
	if local == "":
		local = OS.get_environment("HOSTNAME")
	if not LAYOUT.valid_peer(local):
		local = "gdtk-local"
	var lay = SL.normalize_layout(layout)
	var topo = SL.topology(lay, local)
	var names = []
	for s in SL.all_screens(lay):
		var nm = local if s.local else (String(s.peer) if String(s.peer) != "" else String(s.id))
		if nm != "" and not names.has(nm):
			names.append(nm)
	var text = CONF.build_topology_conf(names, topo)
	var w = File.new()
	if w.open(OUT, File.WRITE) != OK:
		print("FAIL no pude escribir ", OUT)
		OS.exit_code = 1
		quit()
		return
	w.store_string(text)
	w.close()
	print("escrito ", OUT, " (", text.length(), " bytes)")
	quit()
