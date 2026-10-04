extends Reference

# Exposé: layout PURO de un "zoom out" del escritorio. Cada workspace (unidad de
# `shell._units()`) es una miniatura del viewport COMPLETO y sus ventanas se reparten
# DENTRO del marco en una grilla sin solapes (`arrange`): las más grandes arriba y las
# más chicas abajo, para que todas se vean (estilo overview). Los workspaces se ordenan
# en una fila horizontal, tal como se navegan con el paneo (`_compute_slide_layout`), y
# se escalan para que TODOS entren a la vista. Sin estado: recibe las geometrías
# locales ya resueltas por el shell y devuelve los rects de pantalla.
#
# No conoce ImGui ni el compositor: testeable en headless (tests/expose_layout_test.gd).

# Zona mínima de hit por hueco (px): si el gap visual entre marcos es más chico, el
# hueco se ensancha simétricamente hacia las tarjetas vecinas.
const GAP_MIN_HIT = 16.0
# Separación de la barra de inserción respecto del borde del marco en los extremos.
const GAP_BAR_MARGIN = 6.0


# Factor de escala común para que la fila entera entre en el viewport, preservando la
# proporción de cada workspace. `max_scale` evita que con un solo workspace el "zoom
# out" sea imperceptible (queda igual de grande que la pantalla).
static func scale(vp, n, pad, gap, max_scale):
	if n <= 0 or vp.x <= 0.0 or vp.y <= 0.0:
		return 0.0
	var row_gaps = gap * float(max(n - 1, 0))
	var kx = (vp.x - 2.0 * pad - row_gaps) / (float(n) * vp.x)
	var ky = (vp.y - 2.0 * pad) / vp.y
	return clamp(min(kx, ky), 0.05, max_scale)


# Ranuras a mostrar en exposé a partir de `has_content` (una entrada por unidad de
# `_units()`). Sólo las unidades con contenido: los escritorios vacíos (incluida la
# vieja ranura final "Nuevo escritorio") NO se muestran. Los destinos de arrastre son
# los HUECOS entre tarjetas (ver `gap_at`), no ranuras visibles. Devuelve índices de
# unidad.
static func visible_slots(has_content):
	var out = []
	for i in range(has_content.size()):
		if bool(has_content[i]):
			out.append(i)
	return out


# Hueco de inserción bajo la coordenada `x` (0..n; -1 si el punto cae sobre una
# tarjeta). `cards_rects` son los marcos de los escritorios mostrados, en orden. Los
# extremos (margen izquierdo/derecho) son los huecos 0 y n; entre dos marcos está el
# hueco intermedio (i + 1). La zona es al menos `GAP_MIN_HIT` ancha, centrada en el gap
# real: si el gap es más chico, invade un poco las tarjetas vecinas.
static func gap_at(cards_rects, x):
	var n = cards_rects.size()
	if n <= 0:
		return -1
	if x < cards_rects[0].position.x:
		return 0
	if x > cards_rects[n - 1].end.x:
		return n
	for i in range(n - 1):
		var lo = cards_rects[i].end.x
		var hi = cards_rects[i + 1].position.x
		if hi < lo:
			continue
		var half = max((hi - lo) * 0.5, GAP_MIN_HIT * 0.5)
		var c = (lo + hi) * 0.5
		if x >= c - half and x <= c + half:
			return i + 1
	return -1


# x de la barra vertical de inserción del hueco `gap` (NAN si `gap` no es válido). En
# los extremos la barra queda pegada al borde del primer/último marco.
static func gap_x(cards_rects, gap):
	var n = cards_rects.size()
	if n <= 0 or gap < 0 or gap > n:
		return NAN
	if gap == 0:
		return cards_rects[0].position.x - GAP_BAR_MARGIN
	if gap == n:
		return cards_rects[n - 1].end.x + GAP_BAR_MARGIN
	return (cards_rects[gap - 1].end.x + cards_rects[gap].position.x) * 0.5



# Interpola un Rect2 (posición y tamaño) para llevar una ventana desde su
# transformación VISIBLE actual hasta su destino, sin saltos. La usan todas las
# animaciones de ventanas del shell (exposé, entrada genie, reacomodo, maximizar).
static func lerp_rect(from, to, e):
	var f = Rect2(from)
	var t = Rect2(to)
	return Rect2(f.position.linear_interpolate(t.position, e),
		f.size.linear_interpolate(t.size, e))


# Escala uniforme para que `src` llene `cell` conservando su relación de aspecto.
# SIN tope en 1.0: una miniatura chica también CRECE hasta su tarjeta; antes quedaba
# en su tamaño real y no se redimensionaba al cambiar de escritorio en el exposé.
static func thumb_scale(cell, src):
	if src.size.x <= 0.0 or src.size.y <= 0.0:
		return 1.0
	return min(cell.size.x / src.size.x, cell.size.y / src.size.y)


# Rect de origen de la entrada de una ventana nueva: el del ícono que la lanzó si se
# conoce y es reciente (`max_age` ms); si no, un cuadrado centrado en su rect final
# escalado `k` (genie desde el centro con fade). `origin`/`since` pueden ser null/0.
static func intro_from(rect, origin, now, since, max_age, k = 0.2):
	var r = Rect2(rect)
	if origin != null:
		var o = Rect2(origin)
		if now - int(since) <= max_age and o.size.x > 0.0 and o.size.y > 0.0:
			return o
	var s = r.size * k
	return Rect2(r.position + (r.size - s) * 0.5, s)


# Grilla interior de UN workspace (pura). Coloca sus ventanas dentro del marco `cell`
# evitando el solape: las MÁS GRANDES arriba y las más chicas abajo, en varias filas
# (~sqrt(n), para no armar una cinta larga), y dentro de cada fila de izquierda a
# derecha por el x real de su centro. Cada ventana conserva su relación de aspecto
# (escala uniforme) y `gap` separa ventanas y filas; todo queda dentro de `cell`.
#   cell:  Rect2 destino (el marco del workspace en pantalla)
#   items: Array de {"id": <id>, "rect": Rect2} con el tamaño/posición real local
#   gap:   separación en píxeles
# Devuelve {id -> Rect2} en las mismas coordenadas que `cell`.
static func arrange(cell, items, gap):
	var out = {}
	var valid = []
	for it in items:
		var r = it.get("rect", null)
		if r == null or r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		valid.append({"id": it.get("id", null), "rect": r, "area": r.size.x * r.size.y})
	if valid.empty():
		return out
	if valid.size() == 1:
		out[valid[0]["id"]] = _fit(cell, valid[0]["rect"])
		return out
	# Área descendente: define el reparto en filas (grandes arriba).
	var by_area = _area_desc(valid)
	var n = by_area.size()
	var rows = int(clamp(int(round(sqrt(float(n)))), 1, max(n - 1, 1)))
	var counts = _row_counts(n, rows)
	var row_items = []
	var at = 0
	for ri in range(rows):
		var row = []
		for k in range(counts[ri]):
			row.append(by_area[at + k])
		at += counts[ri]
		row_items.append(_cx_asc(row))
	# Altura de fila proporcional al tamaño de sus ventanas (sqrt(área)).
	var weights = []
	var total_w = 0.0
	for row in row_items:
		var w = 0.0
		for it in row:
			w += sqrt(it["area"])
		weights.append(max(w, 0.0001))
		total_w += weights[weights.size() - 1]
	var avail_h = max(cell.size.y - gap * float(rows - 1), 0.0)
	# Cada fila se escala a su altura y se achica si no entra a lo ancho; se centra.
	var y = cell.position.y
	for ri in range(rows):
		var row = row_items[ri]
		var k = row.size()
		var h = avail_h * weights[ri] / total_w
		var slot_w = max(cell.size.x - gap * float(k - 1), 1.0)
		var nat = []
		var sum_w = 0.0
		for it in row:
			var r = it["rect"]
			var wd = h * (r.size.x / max(r.size.y, 0.0001))
			nat.append(wd)
			sum_w += wd
		var fit = 1.0 if sum_w <= slot_w else slot_w / sum_w
		var used_h = h * fit
		var x = cell.position.x + (cell.size.x - (sum_w * fit + gap * float(k - 1))) * 0.5
		for j in range(k):
			out[row[j]["id"]] = Rect2(x, y + (h - used_h) * 0.5, nat[j] * fit, used_h)
			x += nat[j] * fit + gap
		y += h + gap
	return out


# Encaja `src` en `cell` conservando la relación de aspecto y centrado.
static func _fit(cell, src):
	var sc = min(cell.size.x / max(src.size.x, 0.0001), cell.size.y / max(src.size.y, 0.0001))
	var sz = src.size * sc
	return Rect2(cell.position + (cell.size - sz) * 0.5, sz)


# Orden estable por área descendente (inserción; n chico).
static func _area_desc(a):
	var out = a.duplicate()
	for i in range(1, out.size()):
		var v = out[i]
		var j = i - 1
		while j >= 0 and out[j]["area"] < v["area"]:
			out[j + 1] = out[j]
			j -= 1
		out[j + 1] = v
	return out


# Orden estable por x del centro real ascendente.
static func _cx_asc(a):
	var out = a.duplicate()
	for i in range(1, out.size()):
		var v = out[i]
		var vx = v["rect"].position.x + v["rect"].size.x * 0.5
		var j = i - 1
		while j >= 0:
			if out[j]["rect"].position.x + out[j]["rect"].size.x * 0.5 <= vx:
				break
			out[j + 1] = out[j]
			j -= 1
		out[j + 1] = v
	return out


# Reparto equilibrado de `n` ventanas en `rows` filas (las primeras reciben el sobrante).
static func _row_counts(n, rows):
	var out = []
	var base = int(n / rows)
	var rem = n % rows
	for i in range(rows):
		out.append(base + (1 if i < rem else 0))
	return out


# Plan completo. `unit_local` es un Array de Dictionary {id -> Rect2} en coordenadas
# locales del workspace (origen (0,0), tamaño vp). Devuelve:
#   {"scale": k, "units": [Rect2...], "cards": {id -> Rect2}}
static func plan(vp, unit_local, pad, gap, max_scale):
	var n = unit_local.size()
	var out = {"scale": 0.0, "units": [], "cards": {}}
	if n <= 0:
		return out
	var k = scale(vp, n, pad, gap, max_scale)
	var unit_w = vp.x * k
	var unit_h = vp.y * k
	var row_w = gap * float(max(n - 1, 0)) + unit_w * float(n)
	var x0 = (vp.x - row_w) * 0.5
	var y0 = (vp.y - unit_h) * 0.5
	out["scale"] = k
	# Separación interior más chica que la de los marcos: grilla de ventanas por
	# workspace (ver `arrange`), sin solapes.
	var inner_gap = max(gap * 0.4, 3.0)
	for u in range(n):
		var ox = x0 + float(u) * (unit_w + gap)
		var frame = Rect2(ox, y0, unit_w, unit_h)
		out["units"].append(frame)
		var local = unit_local[u]
		var items = []
		for id in local.keys():
			items.append({"id": id, "rect": local[id]})
		var placed = arrange(frame, items, inner_gap)
		for id in placed.keys():
			out["cards"][id] = placed[id]
	return out
