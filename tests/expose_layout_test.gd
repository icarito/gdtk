extends SceneTree

# Autoprueba del layout puro del exposé (shell/expose_layout.gd): el "zoom out" debe
# preservar la proporción de cada workspace, y DENTRO de cada workspace las ventanas
# se reparten en una grilla sin solapes (grandes arriba, chicas abajo). `arrange` es
# la función pura que decide esa grilla; `plan` la usa por workspace.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/expose_layout_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _near(a, b, eps = 0.5):
	return abs(a - b) <= eps


func _overlaps(a, b):
	return a.intersects(b, true)


func _all_pairs_disjoint(rects):
	for i in range(rects.size()):
		for j in range(i + 1, rects.size()):
			if _overlaps(rects[i], rects[j]):
				return false
	return true


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
	# La única ventana llena su marco (misma proporción) sin salirse.
	var c0 = one.cards["a"]
	check("n=1 ventana dentro del marco", f0.grow(0.5).encloses(c0))
	check("n=1 ventana conserva proporción", _near(c0.size.x / c0.size.y, vp_aspect, 0.01))

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
	# Cada ventana queda dentro del marco de su workspace (grilla, no posición real).
	var inside2 = true
	for id in two.cards.keys():
		var frame = two.units[0] if u0.has(id) else two.units[1]
		if not frame.grow(0.5).encloses(two.cards[id]):
			inside2 = false
	check("n=2 tarjetas dentro de su marco", inside2)

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

	# Ranuras visibles: SÓLO las unidades con contenido. Ya NO se agrega la ranura
	# final "Nuevo escritorio": los destinos de arrastre son los huecos.
	check("slots: vacía inicial se descarta", E.visible_slots([false, true]) == [1])
	check("slots: huecos intermedios se descartan", E.visible_slots([true, false, true]) == [0, 2])
	check("slots: sin contenido, sin ranuras", E.visible_slots([false, false]) == [])
	check("slots: una sola unidad", E.visible_slots([true]) == [0])
	check("slots: Escritorio con flotantes se conserva", E.visible_slots([true, false]) == [0])

	# Huecos de inserción: extremos (márgenes) y espacios entre tarjetas. Sobre una
	# tarjeta no hay hueco: el drop mueve a ese escritorio.
	var cards = [Rect2(100, 100, 200, 150), Rect2(400, 100, 200, 150), Rect2(700, 100, 200, 150)]
	check("gap: margen izquierdo -> 0", E.gap_at(cards, 50) == 0)
	check("gap: margen derecho -> n", E.gap_at(cards, 950) == 3)
	check("gap: entre 0 y 1 -> 1", E.gap_at(cards, 350) == 1)
	check("gap: entre 1 y 2 -> 2", E.gap_at(cards, 650) == 2)
	check("gap: sobre una tarjeta -> -1", E.gap_at(cards, 200) == -1 and E.gap_at(cards, 500) == -1)
	check("gap: sin tarjetas -> -1", E.gap_at([], 10) == -1)
	# Gap chico: la zona de hit se ensancha (al menos GAP_MIN_HIT) y aun así no debe
	# tragarse el centro de la tarjeta.
	var tight = [Rect2(100, 100, 200, 150), Rect2(306, 100, 200, 150)]  # gap = 6 px
	check("gap chico: centro -> 1", E.gap_at(tight, 303) == 1)
	check("gap chico: invade un poco la tarjeta -> 1", E.gap_at(tight, 300) == 1)
	check("gap chico: dentro de la tarjeta -> -1", E.gap_at(tight, 260) == -1)

	# x de la barra vertical de inserción.
	check("gap_x extremo izq antes del marco", E.gap_x(cards, 0) < cards[0].position.x)
	check("gap_x extremo der despues del marco", E.gap_x(cards, 3) > cards[2].end.x)
	check("gap_x intermedio centrado", _near(E.gap_x(cards, 1), 350.0))
	check("gap_x inválido -> NAN", is_nan(E.gap_x(cards, -1)))

	# --- arrange: grilla interior de UN workspace -----------------------------
	var cell = Rect2(100, 50, 900, 520)
	var agap = 8.0

	# 1 ventana: encaja en la celda conservando proporción y centrada.
	var r1 = E.arrange(cell, [{"id": "solo", "rect": Rect2(0, 0, 400, 300)}], agap)
	check("arrange 1: una sola tarjeta", r1.size() == 1 and r1.has("solo"))
	var s = r1["solo"]
	check("arrange 1: conserva proporción", _near(s.size.x / s.size.y, 400.0 / 300.0, 0.01))
	check("arrange 1: dentro de la celda", cell.grow(0.5).encloses(s))
	check("arrange 1: centrada", _near(s.position.x + s.size.x * 0.5, cell.position.x + cell.size.x * 0.5) and _near(s.position.y + s.size.y * 0.5, cell.position.y + cell.size.y * 0.5))

	# 2 ventanas solapadas: se separan, quedan dentro de la celda y no se pisan.
	var r2 = E.arrange(cell, [
		{"id": "p", "rect": Rect2(300, 200, 500, 360)},
		{"id": "q", "rect": Rect2(360, 240, 500, 360)},
	], agap)
	check("arrange 2 solapadas: dos tarjetas", r2.size() == 2)
	check("arrange 2 solapadas: no se solapan", _all_pairs_disjoint([r2["p"], r2["q"]]))
	check("arrange 2 solapadas: dentro de la celda", cell.grow(0.5).encloses(r2["p"]) and cell.grow(0.5).encloses(r2["q"]))

	# 6 ventanas de tamaños distintos: las 2 más grandes quedan en la fila superior,
	# ninguna se solapa, todas entran en el marco y dentro de cada fila el orden es x.
	var items6 = [
		{"id": "a", "rect": Rect2(0, 0, 800, 600)},
		{"id": "b", "rect": Rect2(100, 100, 700, 500)},
		{"id": "c", "rect": Rect2(300, 50, 400, 300)},
		{"id": "d", "rect": Rect2(50, 400, 300, 200)},
		{"id": "e", "rect": Rect2(500, 300, 200, 150)},
		{"id": "f", "rect": Rect2(20, 600, 120, 90)},
	]
	var r6 = E.arrange(cell, items6, agap)
	_out = r6
	check("arrange 6: seis tarjetas", r6.size() == 6)
	var rects6 = []
	for k in r6.keys():
		rects6.append(r6[k])
	check("arrange 6: ninguna solapa", _all_pairs_disjoint(rects6))
	var inside6 = true
	var aspect6 = true
	for it in items6:
		var rr = r6[it["id"]]
		if not cell.grow(0.5).encloses(rr):
			inside6 = false
		var src = it["rect"]
		if not _near(rr.size.x / rr.size.y, src.size.x / src.size.y, 0.02):
			aspect6 = false
	check("arrange 6: todas dentro del marco", inside6)
	check("arrange 6: conservan proporción", aspect6)

	# Fila superior = la de y mínima.
	var min_y = 1e9
	for it in items6:
		min_y = min(min_y, r6[it["id"]].position.y)
	var top_ids = []
	for it in items6:
		if _near(r6[it["id"]].position.y, min_y, 1.0):
			top_ids.append(it["id"])
	check("arrange 6: las 2 más grandes arriba", top_ids.has("a") and top_ids.has("b"))

	# Dentro de cada fila, x ascendente (comparado con el x real del centro).
	var rows = {}
	for it in items6:
		var rr = r6[it["id"]]
		var key = int(round(rr.position.y))
		if not rows.has(key):
			rows[key] = []
		rows[key].append(it["id"])
	var row_order_ok = true
	for key in rows.keys():
		var got = rows[key].duplicate()
		got.sort_custom(self, "_by_out_x")
		var want = rows[key].duplicate()
		want.sort_custom(self, "_by_real_cx")
		if got != want:
			row_order_ok = false
	check("arrange 6: orden x dentro de cada fila", row_order_ok)

	# Sin items válidos no rompe.
	check("arrange vacío", E.arrange(cell, [], agap).empty())
	check("arrange tamaños nulos", E.arrange(cell, [{"id": "z", "rect": Rect2(0, 0, 0, 0)}], agap).empty())

	# --- Interpolación de rect (animaciones de ventanas) ----------------------
	var from = Rect2(0, 0, 200, 100)
	var to = Rect2(1000, 500, 400, 800)
	var half = E.lerp_rect(from, to, 0.5)
	check("lerp_rect: mitad posición", _near(half.position.x, 500.0) and _near(half.position.y, 250.0))
	check("lerp_rect: mitad tamaño", _near(half.size.x, 300.0) and _near(half.size.y, 450.0))
	check("lerp_rect: e=0 devuelve el origen", E.lerp_rect(from, to, 0.0) == from)
	check("lerp_rect: e=1 devuelve el destino", E.lerp_rect(from, to, 1.0) == to)

	# Escala de miniatura: achica Y agranda hasta llenar la tarjeta (sin tope 1.0).
	var big_card = Rect2(0, 0, 1000, 800)
	var small_src = Rect2(0, 0, 200, 100)
	var sc = E.thumb_scale(big_card, small_src)
	check("thumb_scale agranda (sin tope 1.0)", sc > 1.0)
	check("thumb_scale conserva proporción", _near(small_src.size.x * sc / (small_src.size.y * sc), 2.0, 0.001))
	var small_card = Rect2(0, 0, 100, 80)
	check("thumb_scale achica", E.thumb_scale(small_card, big_card) < 1.0)
	check("thumb_scale tamaño nulo -> 1", E.thumb_scale(big_card, Rect2(0, 0, 0, 0)) == 1.0)

	# Origen genie: ícono reciente si lo hay; si no, centro escalado 0.2.
	var final = Rect2(400, 300, 800, 600)
	var icon = Rect2(50, 40, 32, 32)
	check("intro_from usa el ícono reciente",
		E.intro_from(final, icon, 1000, 900, 4000) == icon)
	check("intro_from vencido cae al centro", E.intro_from(final, icon, 9000, 900, 4000) == Rect2(final.position + (final.size - final.size * 0.2) * 0.5, final.size * 0.2))
	check("intro_from sin ícono: centro 0.2", E.intro_from(final, null, 1000, 0, 4000) == Rect2(final.position + (final.size - final.size * 0.2) * 0.5, final.size * 0.2))

	OS.exit_code = 1 if failed > 0 else 0
	quit()


func _by_real_cx(a, b):
	var ca = _real_cx[a]
	var cb = _real_cx[b]
	return ca < cb


func _by_out_x(a, b):
	return _out[a].position.x < _out[b].position.x


var _real_cx = {
	"a": 400.0, "b": 450.0, "c": 500.0,
	"d": 200.0, "e": 600.0, "f": 80.0,
}
var _out = {}
