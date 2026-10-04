extends SceneTree

# G3 — Vecindario sin solapes y a pantalla completa. Con 5 hosts + 30 APs + 10 BT
# el mapa debe repartir las cápsulas (centro + ícono + rótulo truncado) sin que
# ningún par se solape, todas dentro de la vista y con el bounding box ocupando
# >= 70% del ancho y alto útiles, en landscape, full-hd y portrait.
#
#   godot --no-window --path shell -s $PWD/tests/neighborhood_spread_test.gd

const MAP_PATH = "res://neighborhood_map.gd"
const NB_PATH = "res://neighborhood.gd"

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


# 30 líneas de `nmcli -t` alternando 2.4/5 GHz con señales variadas.
func _nmcli_sample(n):
	var lines = PoolStringArray()
	var chans24 = [1, 6, 11, 3, 9]
	var chans5 = [36, 40, 44, 48, 149, 153, 157, 161]
	for i in range(n):
		var ssid = "Red%02d" % i
		var bssid = "AA\\:BB\\:CC\\:DD\\:EE\\:%02X" % i
		var chan = chans24[i % chans24.size()] if i % 2 == 0 else chans5[i % chans5.size()]
		var freq = 2412 + (chan - 1) * 5 if i % 2 == 0 else 5000 + chan * 5
		lines.append(":%s:%s:%d:%d MHz:%d:WPA2" % [ssid, bssid, chan, freq, 92 - (i % 10) * 4])
	return lines.join("\n")


# Construye el snapshot completo (hosts + wifi + bt), corre spread_all y devuelve
# las cápsulas para verificar. No dibuja ni toca red/procesos.
func _build(MAP, nb, vp, bar):
	var hosts = []
	var dirs = {}
	var cardinals = ["north", "south", "east", "west"]
	for i in range(5):
		var id = "h%d" % i
		hosts.append({"id": id, "label": "Equipo%d" % i, "kind": "laptop", "capabilities": {}})
		if i < cardinals.size():
			dirs[id] = {"direction": cardinals[i], "confirm": "confirmed"}
	var nodes = MAP.map_layout(hosts, dirs, vp, bar)
	var nets = nb.parse_nmcli(_nmcli_sample(30))
	var wdots = MAP.wifi_dots(nets, vp, bar)
	var bts = []
	for i in range(10):
		bts.append({"address": "AA:BB:CC:DD:EE:%02X" % i, "name": "Dispositivo%02d" % i,
			"connected": i % 3 == 0, "paired": i % 3 != 2, "rssi": -40 - i})
	nb._place_bt(bts)
	var btdots = MAP.bt_dots(bts, vp, bar)

	var items = []
	for node in nodes:
		items.append({"kind": "host", "id": String(node.id), "center": Vector2(node.center),
			"size": float(node.size), "label": "Equipo%d" % int(node.index)})
	for w in wdots:
		items.append({"kind": "wifi", "id": String(w.ssid), "center": Vector2(w.pos),
			"size": MAP.WIFI_ICON_SIZE, "label": String(w.ssid)})
	for d in btdots:
		items.append({"kind": "bt", "id": String(d.address), "center": Vector2(d.pos),
			"size": MAP.BT_ICON_SIZE, "label": String(d.name)})
	var spread = MAP.spread_all(items, vp, bar)
	var pts = []
	var hw = []
	var hh = []
	for it in spread:
		pts.append(Vector2(it.center))
		hw.append(float(it.hw))
		hh.append(float(it.hh))
	return {"count": items.size(), "pts": pts, "hw": hw, "hh": hh}


func _run_size(view):
	var MAP = load(MAP_PATH)
	var nb = load(NB_PATH).new()
	var vp = view.vp
	var bar = view.bar
	var r = _build(MAP, nb, vp, bar)
	var tag = view.tag

	check(tag + ": 45 ítems (5 hosts + 30 AP + 10 BT)", r.count == 45)
	check(tag + ": ningún par de cápsulas se solapa",
		not MAP.capsules_overlap(r.pts, r.hw, r.hh, 2.0))

	var inside = true
	for i in range(r.pts.size()):
		var p = r.pts[i]
		if p.x - r.hw[i] < -0.5 or p.x + r.hw[i] > vp.x + 0.5 \
				or p.y - r.hh[i] < bar - 0.5 or p.y + r.hh[i] > vp.y - bar + 0.5:
			inside = false
	check(tag + ": todas dentro de la vista (con barras)", inside)

	var min_x = INF
	var max_x = -INF
	var min_y = INF
	var max_y = -INF
	for i in range(r.pts.size()):
		min_x = min(min_x, r.pts[i].x - r.hw[i])
		max_x = max(max_x, r.pts[i].x + r.hw[i])
		min_y = min(min_y, r.pts[i].y - r.hh[i])
		max_y = max(max_y, r.pts[i].y + r.hh[i])
	var useful_w = vp.x
	var useful_h = vp.y - 2.0 * bar
	var bbox_w = max_x - min_x
	var bbox_h = max_y - min_y
	check(tag + ": bbox ancho >= 70%% (%.0f/%.0f)" % [bbox_w, useful_w],
		bbox_w >= 0.70 * useful_w)
	check(tag + ": bbox alto >= 70%% (%.0f/%.0f)" % [bbox_h, useful_h],
		bbox_h >= 0.70 * useful_h)


func _init():
	_run_size({"tag": "1280x720", "vp": Vector2(1280, 720), "bar": 64.0})
	_run_size({"tag": "1920x1080", "vp": Vector2(1920, 1080), "bar": 64.0})
	_run_size({"tag": "800x1280", "vp": Vector2(800, 1280), "bar": 64.0})
	OS.exit_code = 1 if failed > 0 else 0
	quit()
