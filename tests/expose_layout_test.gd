extends SceneTree

# Autoprueba del layout puro del exposé (shell/expose_layout.gd): el "zoom out" debe
# preservar la proporción de cada workspace y la posición relativa de sus ventanas,
# con TODOS los workspaces visibles en una fila.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/expose_layout_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _near(a, b, eps = 0.5):
	return abs(a - b) <= eps


func _init():
	var E = load("res://expose_layout.gd")
	check("expose_layout.gd carga", E != null)

	var vp = Vector2(1600, 900)
	var pad = 28.0
	var gap = 18.0
	var maxk = 0.62
	var vp_aspect = vp.x / vp.y

	# Un solo workspace: se limita a max_scale (si no, el zoom sería imperceptible) y
	# conserva la proporción de la pantalla.
	var one = E.plan(vp, [{"a": Rect2(0, 0, vp.x, vp.y)}], pad, gap, maxk)
	check("n=1 escala = max_scale", _near(one.scale, maxk))
	var f0 = one.units[0]
	check("n=1 proporción de pantalla", _near(f0.size.x / f0.size.y, vp_aspect, 0.01))
	check("n=1 centrado", _near(f0.position.x, (vp.x - f0.size.x) * 0.5) and _near(f0.position.y, (vp.y - f0.size.y) * 0.5))

	# Dos workspaces: fila centrada, sin solape, ambos dentro del viewport y con la
	# misma proporción.
	var u0 = {"a": Rect2(0, 0, vp.x * 0.5, vp.y * 0.5)}
	var u1 = {"b": Rect2(vp.x * 0.1, vp.y * 0.2, vp.x * 0.3, vp.y * 0.4)}
	var two = E.plan(vp, [u0, u1], pad, gap, maxk)
	check("n=2 dos marcos", two.units.size() == 2)
	check("n=2 proporción", _near(two.units[0].size.x / two.units[0].size.y, vp_aspect, 0.01) and _near(two.units[1].size.x / two.units[1].size.y, vp_aspect, 0.01))
	check("n=2 sin solape", two.units[0].end.x <= two.units[1].position.x + 0.01)
	check("n=2 fila centrada", _near(two.units[0].position.x, pad) and _near(two.units[1].end.x, vp.x - pad))
	check("n=2 dentro del viewport", two.units[0].position.x >= -0.01 and two.units[1].end.x <= vp.x + 0.01)

	# La ventana conserva su posición/tamaño RELATIVOS dentro del workspace.
	var ca = two.cards["a"]
	check("ventana escala con el marco", _near(ca.size.x, u0["a"].size.x * two.scale) and _near(ca.size.y, u0["a"].size.y * two.scale))
	check("ventana relativa a su marco", _near(ca.position.x - two.units[0].position.x, u0["a"].position.x * two.scale))
	var cb = two.cards["b"]
	check("ventana b relativa", _near(cb.position.x - two.units[1].position.x, u1["b"].position.x * two.scale) and _near(cb.position.y - two.units[1].position.y, u1["b"].position.y * two.scale))

	# Todos los rects caen dentro de la pantalla.
	var inside = true
	for id in two.cards.keys():
		var r = two.cards[id]
		if r.position.x < -0.01 or r.position.y < -0.01 or r.end.x > vp.x + 0.01 or r.end.y > vp.y + 0.01:
			inside = false
	check("tarjetas dentro del viewport", inside)

	# Más workspaces => escala menor (se achica para que todos entren).
	var many = []
	for i in range(6):
		many.append({"w%d" % i: Rect2(0, 0, vp.x, vp.y * 0.5)})
	var six = E.plan(vp, many, pad, gap, maxk)
	check("n=6 escala menor que n=2", six.scale < two.scale)
	check("n=6 seis marcos", six.units.size() == 6)
	var fits = six.units[5].end.x <= vp.x + 0.01 and six.units[0].position.x >= -0.01
	check("n=6 todos visibles", fits)

	check("n=0 no rompe", E.plan(vp, [], pad, gap, maxk).units.empty())

	OS.exit_code = 1 if failed > 0 else 0
	quit()
