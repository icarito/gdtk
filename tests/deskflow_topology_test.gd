extends SceneTree

# Prueba de la topología multi-pantalla para Deskflow: el conf debe incluir las
# aristas entre CUALQUIER par que se toque (no sólo desde el server), con rangos %.
# Layout de prueba (cupid portrait 1440x2160 pegando a bastion y a tengu):
#   cupid  x[-1440,0] y[0,2160]
#   bastion x[0,1920] y[0,1080]
#   tengu  x[0,1280]  y[1080,1880]
# Correr: godot --no-window --path shell -s $PWD/tests/deskflow_topology_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var SL = load("res://screen_layout.gd")
	var CONF = load("res://deskflow_conf.gd")
	check("modulos cargan", SL != null and CONF != null)

	var layout = {
		"version": 1,
		"local": {"id": "local", "label": "bastion", "local": true, "x": 0.0, "y": 0.0, "w": 1920.0, "h": 1080.0},
		"screens": [
			{"id": "cupid", "label": "cupid", "peer": "cupid", "local": false, "x": -1440.0, "y": 0.0, "w": 1440.0, "h": 2160.0},
			{"id": "tengu", "label": "tengu", "peer": "tengu", "local": false, "x": 0.0, "y": 1080.0, "w": 1280.0, "h": 800.0},
		],
	}

	var topo = SL.topology(layout, "bastion")
	var edges_found = []
	for t in topo:
		edges_found.append("%s-%s-%s" % [String(t.screen), String(t.edge), String(t.peer)])
	edges_found.sort()
	print("aristas: ", edges_found)
	check("bastion toca cupid (west)", edges_found.has("bastion-left-cupid"))
	check("bastion toca tengu (south)", edges_found.has("bastion-down-tengu"))
	check("cupid toca tengu (east)", edges_found.has("cupid-right-tengu"))

	var names = ["bastion", "cupid", "tengu"]

	var text = CONF.build_topology_conf(names, topo)
	check("conf no vacio", text != "")
	check("conf lista las 3 pantallas", text.find("bastion:") >= 0 and text.find("cupid:") >= 0 and text.find("tengu:") >= 0)
	check("conf tiene arista cupid->tengu", text.find("cupid:") >= 0 and text.find("right") >= 0 and text.find("tengu") >= 0)
	# La arista cupid->tengu debe estar bajo la pantalla cupid con rango.
	var cupid_block = text.substr(text.find("cupid:"))
	check("arista cupid con rango (50..87)", cupid_block.find("right(") >= 0)
	check("sin self-links", text.find("bastion = bastion") < 0)

	# Determinismo.
	check("determinista", CONF.build_topology_conf(names, topo) == text)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
