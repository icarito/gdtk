extends SceneTree

# Autoprueba G2 del layout puro del anillo del Hogar (shell/ring_layout.gd):
# elipse en landscape (ítems 0/1 a izquierda/derecha) y en portrait (arriba/
# abajo), todos dentro de la vista y sin solapes; espiral sin cambios.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/ring_layout_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


# Mismos valores que el shell pasa como parámetros (ui_scale_factor = 1).
func _u(vp):
	return max(80.0, floor(min(vp.x, vp.y) / 10.0))


func _top(vp):
	var u = _u(vp)
	return ceil(u) if vp.y >= 3.0 * u else max(64.0, floor(u * 0.5))


func _inside(pos, btn, vp):
	return pos.x >= 0.0 and pos.y >= 0.0 \
		and pos.x + btn <= vp.x + 0.001 and pos.y + btn <= vp.y + 0.001


# Dos cuadrados iguales se solapan si sus centros distan menos que el lado en
# ambos ejes.
func _overlap(a, b, btn):
	return abs(a.x - b.x) < btn and abs(a.y - b.y) < btn


func _all_inside(out, btn, vp):
	for pos in out:
		if not _inside(pos, btn, vp):
			return false
	return true


func _no_overlaps(out, btn):
	for i in range(out.size()):
		for j in range(i + 1, out.size()):
			if _overlap(out[i], out[j], btn):
				return false
	return true


func _init():
	var RL = load("res://ring_layout.gd")
	var cmax = RL.RING_CIRCLE_MAX

	# --- Landscape 1920x1080: los dos primeros a izquierda y derecha ----------
	var land = Vector2(1920.0, 1080.0)
	var ul = _u(land)
	var tl = _top(land)
	var btnl = ul * 1.25
	var l2 = RL.orbit_layout(land, 2, [], ul, tl, cmax)
	check("landscape n=2 devuelve 2", l2.size() == 2)
	check("landscape n=2 igual y", abs(l2[0].y - l2[1].y) < 0.01)
	check("landscape n=2 distinta x", abs(l2[0].x - l2[1].x) > btnl)

	# --- Portrait 800x1280: los dos primeros arriba y abajo ------------------
	var port = Vector2(800.0, 1280.0)
	var up = _u(port)
	var tp = _top(port)
	var btnp = up * 1.25
	var p2 = RL.orbit_layout(port, 2, [], up, tp, cmax)
	check("portrait n=2 devuelve 2", p2.size() == 2)
	check("portrait n=2 igual x", abs(p2[0].x - p2[1].x) < 0.01)
	check("portrait n=2 distinta y", abs(p2[0].y - p2[1].y) > btnp)

	# --- n=6: dentro de la vista y sin solapes en ambas orientaciones --------
	for vp in [land, port]:
		var u = _u(vp)
		var btn = u * 1.25
		var out = RL.orbit_layout(vp, 6, [], u, _top(vp), cmax)
		check("n=6 devuelve 6 (%dx%d)" % [int(vp.x), int(vp.y)], out.size() == 6)
		check("n=6 dentro de la vista (%dx%d)" % [int(vp.x), int(vp.y)],
			_all_inside(out, btn, vp))
		check("n=6 sin solapes (%dx%d)" % [int(vp.x), int(vp.y)],
			_no_overlaps(out, btn))

	# --- Espiral n=20 (más que circle_max): dentro de la vista --------------
	var entries = []
	for i in range(20):
		entries.append({"name": "actividad-%02d" % i})
	for vp in [land, port]:
		var u = _u(vp)
		var btn = u * 1.25
		var out = RL.orbit_layout(vp, 20, entries, u, _top(vp), cmax)
		check("espiral n=20 devuelve 20 (%dx%d)" % [int(vp.x), int(vp.y)], out.size() == 20)
		check("espiral n=20 dentro de la vista (%dx%d)" % [int(vp.x), int(vp.y)],
			_all_inside(out, btn, vp))

	# n=0 no devuelve posiciones.
	check("n=0 vacío", RL.orbit_layout(land, 0, [], ul, tl, cmax).empty())

	OS.exit_code = 1 if failed > 0 else 0
	quit()
