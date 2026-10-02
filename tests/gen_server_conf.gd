extends SceneTree

# Genera el deskflow-server.conf con la topología completa desde el layout fisico.
# Salida fija en /tmp/kilo/deskflow-server.conf (se copia a mano al conf real).
# Uso: godot --no-window --path shell -s $PWD/tests/gen_server_conf.gd

const LOCAL = "bastion"
const OUT = "/tmp/kilo/deskflow-server.conf"

func _init():
	var SL = load("res://screen_layout.gd")
	var CONF = load("res://deskflow_conf.gd")
	# bastion arriba; tengu abajo-izquierda; cupid portrait a la izquierda tocando a ambos.
	var layout = {
		"version": 1,
		"local": {"id": "local", "label": LOCAL, "local": true, "x": 0.0, "y": 0.0, "w": 1920.0, "h": 1080.0},
		"screens": [
			{"id": "cupid", "label": "cupid", "peer": "cupid", "local": false, "x": -1440.0, "y": 0.0, "w": 1440.0, "h": 2160.0},
			{"id": "tengu", "label": "tengu", "peer": "tengu", "local": false, "x": 0.0, "y": 1080.0, "w": 1280.0, "h": 800.0},
		],
	}
	var topo = SL.topology(layout, LOCAL)
	var text = CONF.build_topology_conf([LOCAL, "cupid", "tengu"], topo)
	var f = File.new()
	if f.open(OUT, File.WRITE) != OK:
		print("FAIL no pude escribir ", OUT)
		OS.exit_code = 1
		quit()
		return
	f.store_string(text)
	f.close()
	print("escrito ", OUT, " (", text.length(), " bytes)")
	quit()
