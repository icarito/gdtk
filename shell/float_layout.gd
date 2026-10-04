extends Reference

# K13c — Colocación PURA del modo flotante (WindowMaker).
#
# Mantiene un rect EXTERIOR por ventana (incluye la barra de título y el borde),
# el z-order y el foco. El shell deriva el rect de contenido con
# window_chrome.gd::content_rect y dibuja el chrome encima. Sin I/O ni procesos.
#
# - place_new: busca el hueco con menor solapamiento; cascada como desempate.
# - move_to / resize_to: aplican y encajan con content_layout::clamp_inside para
#   que nada quede fuera del hueco central (K12).
# - raise / set_focus: reordenan el z-order; la enfocada va arriba.
# - from_units: materializa el modo tiled a cascada al cambiar de modo.
# - to_row: orden de fila por centro (y, x) para volver a tiled.

const CONTENT = preload("res://content_layout.gd")

const CASCADE = 28.0     # desplazamiento diagonal entre ventanas nuevas
const KEEP_VISIBLE = 48.0  # px de la ventana que deben quedar dentro al arrastrarla fuera
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


# Ventana nueva: prueba posiciones útiles (cascada, esquinas y centros de borde)
# y elige la de menor solapamiento con las ventanas visibles. La cercanía al punto
# de cascada desempata para que el resultado siga siendo estable y predecible.
func place_new(id, box):
	var r = _smart_rect(box, order.size())
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


# Mover por arrastre: la ventana puede salir parcialmente de la caja (izquierda,
# derecha, abajo) dejando al menos KEEP_VISIBLE px dentro; arriba no pasa del borde
# para que la barra de título siga alcanzable.
func drag_to(id, pos, box):
	if not rects.has(id):
		return null
	var r = rects[id]
	var b = Rect2(box)
	var keep = min(KEEP_VISIBLE, r.size.x)
	var p = Vector2(clamp(pos.x, b.position.x - r.size.x + keep, b.end.x - keep),
		clamp(pos.y, b.position.y, b.end.y - min(KEEP_VISIBLE, r.size.y)))
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


# Encaja un rect arbitrario dentro de la caja (cap de tamaño + clamp de posición).
# Puro: lo usa el overlay de redimensión diferida para mostrar la geometría
# objetivo sin aplicarla. No impone mínimos (el chrome ya los aplicó).
func clamp_rect(box, r):
	return _clamped_rect(r, box)


# Encaje interno de tamaño + posición (sin mínimos): reutilizado por restore_one
# y clamp_rect.
func _clamped_rect(r, box):
	var b = Rect2(box)
	var rr = Rect2(r)
	var size = Vector2(min(rr.size.x, b.size.x), min(rr.size.y, b.size.y))
	var pos = CONTENT.clamp_inside(b, rr.position, size)
	return Rect2(pos, size)


# Coloca una ventana recordada: mismo encaje que clamp_rect y la sube al tope.
# Puro; lo usa el shell al volver a flotante para restaurar el lugar previo.
func restore_one(id, r, box):
	rects[id] = _clamped_rect(r, box)
	raise(id)
	return rects[id]


# Materializa unidades restaurando el rect recordado de cada ventana (`memory`:
# id -> Rect2) y cayendo a cascada sólo para las nuevas. Al volver a flotante se
# usa esto en vez de from_units para no perder la posición previa.
func restore_units(units, box, memory, focused = null):
	reset()
	var i = 0
	for u in units:
		for id in u:
			if memory != null and memory.has(id) and memory[id] != null:
				rects[id] = _clamped_rect(memory[id], box)
			else:
				rects[id] = _smart_rect(box, i)
			order.append(id)
			i += 1
	if focused != null and rects.has(focused):
		raise(focused)
	return rects


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


func _overlap_area(a, b):
	var left = max(a.position.x, b.position.x)
	var top = max(a.position.y, b.position.y)
	var right = min(a.end.x, b.end.x)
	var bottom = min(a.end.y, b.end.y)
	return max(right - left, 0.0) * max(bottom - top, 0.0)


func _placement_score(candidate, preferred):
	var overlap = 0.0
	# Las ventanas superiores pesan un poco más: evita tapar justo la que el usuario
	# estaba usando cuando abrió la nueva, sin volver no determinista el layout.
	for i in range(order.size()):
		var id = order[i]
		if not rects.has(id):
			continue
		var weight = 1.0 + 0.15 * float(i + 1) / float(max(order.size(), 1))
		overlap += _overlap_area(candidate, rects[id]) * weight
	return overlap + candidate.position.distance_squared_to(preferred.position) * 0.001


func _smart_rect(box, n):
	var preferred = _cascade_rect(box, n)
	if rects.empty() or preferred.size.x <= 0.0 or preferred.size.y <= 0.0:
		return preferred
	var b = Rect2(box)
	var size = preferred.size
	var left = b.position.x + MARGIN
	var top = b.position.y + MARGIN
	var right = b.end.x - MARGIN - size.x
	var bottom = b.end.y - MARGIN - size.y
	var center_x = (left + right) * 0.5
	var center_y = (top + bottom) * 0.5
	var points = [preferred.position,
		Vector2(left, top), Vector2(right, top),
		Vector2(left, bottom), Vector2(right, bottom),
		Vector2(center_x, top), Vector2(center_x, bottom),
		Vector2(left, center_y), Vector2(right, center_y),
		Vector2(center_x, center_y)]
	var best = preferred
	var best_score = _placement_score(best, preferred)
	for p in points:
		var pos = CONTENT.clamp_inside(b, p, size)
		var candidate = Rect2(pos, size)
		var score = _placement_score(candidate, preferred)
		if score < best_score:
			best = candidate
			best_score = score
	return best


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
	assert(b.position != a.position, "colocación inteligente separa ventanas")
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
