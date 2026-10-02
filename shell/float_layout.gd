extends Reference

# K13c — Colocación PURA del modo flotante (WindowMaker).
#
# Mantiene un rect EXTERIOR por ventana (incluye la barra de título y el borde),
# el z-order y el foco. El shell deriva el rect de contenido con
# window_chrome.gd::content_rect y dibuja el chrome encima. Sin I/O ni procesos.
#
# - place_new: cascada determinista dentro de la caja de contenido.
# - move_to / resize_to: aplican y encajan con content_layout::clamp_inside para
#   que nada quede fuera del hueco central (K12).
# - raise / set_focus: reordenan el z-order; la enfocada va arriba.
# - from_units: materializa el modo tiled a cascada al cambiar de modo.
# - to_row: orden de fila por centro (y, x) para volver a tiled.

const CONTENT = preload("res://content_layout.gd")

const CASCADE = 28.0     # desplazamiento diagonal entre ventanas nuevas
const MARGIN = 8.0       # aire contra el borde de la caja de contenido
const MIN_W = 320.0      # tamaño mínimo exterior
const MIN_H = 240.0
const MAX_FRAC = 0.74    # fracción máxima de la caja que ocupa una ventana nueva
const WRAP = 8           # cada cuántas ventanas se reinicia la cascada

var rects = {}           # id -> Rect2 exterior
var order = []           # ids en z-order; el último está arriba
var focus_id = -1


func reset():
	rects = {}
	order = []
	focus_id = -1


func has(id):
	return rects.has(id)


func rect(id):
	return rects.get(id, null)


func set_rect(id, r):
	rects[id] = Rect2(r)


func ids_z():
	return order.duplicate()


func top_id():
	return order[order.size() - 1] if order.size() > 0 else -1


func focused():
	return focus_id


# Ventana nueva: cascada dentro de la caja. El offset crece con las ventanas ya
# colocadas y se reinicia cada WRAP para no salirse; el tamaño se ajusta al hueco
# dejado por el offset (nunca tapa por completo a la anterior).
func place_new(id, box):
	var r = _cascade_rect(box, order.size())
	rects[id] = r
	raise(id)
	return r


# Materializa una lista de unidades tiled (array de arrays de ids) como flotantes
# en cascada, dejando `focused` arriba. Devuelve el dict de rects.
func from_units(units, box, focused = null):
	reset()
	var i = 0
	for u in units:
		for id in u:
			rects[id] = _cascade_rect(box, i)
			order.append(id)
			i += 1
	if focused != null and rects.has(focused):
		raise(focused)
	return rects


# Mueve el rect exterior a `pos`, encajado dentro de la caja.
func move_to(id, pos, box):
	if not rects.has(id):
		return null
	var r = rects[id]
	var p = CONTENT.clamp_inside(box, pos, r.size)
	rects[id] = Rect2(p, r.size)
	return rects[id]


# Aplica un rect (exterior), respetando mínimos y la caja.
func resize_to(id, new_rect, box):
	if not rects.has(id):
		return null
	var size = Vector2(max(new_rect.size.x, MIN_W), max(new_rect.size.y, MIN_H))
	size.x = min(size.x, box.size.x)
	size.y = min(size.y, box.size.y)
	var pos = CONTENT.clamp_inside(box, new_rect.position, size)
	rects[id] = Rect2(pos, size)
	return rects[id]


func raise(id):
	if not rects.has(id):
		return
	order.erase(id)
	order.append(id)
	focus_id = id


func set_focus(id):
	if rects.has(id):
		raise(id)
	elif id < 0:
		focus_id = -1


func remove(id):
	rects.erase(id)
	order.erase(id)
	if focus_id == id:
		focus_id = top_id()


# Orden de fila (para volver a tiled): por centro vertical y luego horizontal.
func to_row(box):
	var ids = order.duplicate()
	var n = ids.size()
	for i in range(n):
		for j in range(n - 1 - i):
			var a = rects[ids[j]]
			var b = rects[ids[j + 1]]
			var ca = a.position + a.size * 0.5
			var cb = b.position + b.size * 0.5
			var swap = false
			if abs(ca.y - cb.y) > 1.0:
				swap = ca.y > cb.y
			else:
				swap = ca.x > cb.x
			if swap:
				var tmp = ids[j]
				ids[j] = ids[j + 1]
				ids[j + 1] = tmp
	return ids


func _cascade_rect(box, n):
	var b = Rect2(box)
	if b.size.x <= 0.0 or b.size.y <= 0.0:
		return Rect2()
	var k = n % WRAP
	var off = CASCADE * float(k)
	var max_w = max(b.size.x * MAX_FRAC, min(MIN_W, b.size.x))
	var max_h = max(b.size.y * MAX_FRAC, min(MIN_H, b.size.y))
	var w = clamp(b.size.x - 2.0 * MARGIN - off, min(MIN_W, b.size.x), max_w)
	var h = clamp(b.size.y - 2.0 * MARGIN - off, min(MIN_H, b.size.y), max_h)
	var pos = CONTENT.clamp_inside(b, b.position + Vector2(MARGIN + off, MARGIN + off), Vector2(w, h))
	return Rect2(pos, Vector2(w, h))


# Autoprueba del modelo (instanciable; ver tests/float_layout_test.gd).
func run_selftest():
	var box = Rect2(0, 80, 1280, 640)
	var m = get_script().new()
	m.reset()
	var a = m.place_new(1, box)
	var b = m.place_new(2, box)
	assert(a.size.x > 0.0 and a.size.y > 0.0, "rect válido")
	assert(box.encloses(a) and box.encloses(b), "dentro de la caja")
	assert(m.top_id() == 2 and m.focused() == 2, "foco y z-order")
	assert(m.to_row(box).size() == 2, "to_row")
	# Escalado desde unidades.
	m.from_units([[10], [20, 30]], box, 30)
	assert(m.has(10) and m.has(20) and m.has(30), "from_units materializa")
	assert(m.focused() == 30 and m.top_id() == 30, "from_units foco")
	# Mover y redimensionar encajan en la caja.
	var moved = m.move_to(10, Vector2(-9999, -9999), box)
	assert(box.encloses(moved), "move encaja")
	var rz = m.resize_to(10, Rect2(Vector2(0, 0), Vector2(50, 50)), box)
	assert(rz.size.x == MIN_W and rz.size.y == MIN_H, "resize mínimo")
	assert(box.encloses(rz), "resize encaja")
	# Minimizar (remove) y foco de reemplazo.
	m.remove(30)
	assert(not m.has(30) and m.top_id() == 20, "remove y foco")
	# from_units determinista.
	var m2 = get_script().new()
	m2.from_units([[1], [2], [3]], box, 1)
	var m3 = get_script().new()
	m3.from_units([[1], [2], [3]], box, 1)
	assert(m2.ids_z() == m3.ids_z(), "orden determinista")
	for id in m2.rects.keys():
		assert(m2.rects[id] == m3.rects[id], "rect determinista")
	return true
