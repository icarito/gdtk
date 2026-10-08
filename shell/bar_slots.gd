extends Reference

# Modelo PURO de las posiciones de los bloques de barra ancladas al costado
# (shell/frame.gd). El orden viejo guardaba celdas contadas SIEMPRE desde la
# izquierda: un bloque en la última celda (N-1) se quedaba a N-1 del borde al rotar a
# portrait o conectar un monitor más grande. Acá los bloques de la mitad izquierda se
# guardan contados desde la izquierda (k >= 0, k < n/2) y los de la mitad derecha
# desde el borde derecho (k < 0; -1 = última celda). Al cambiar `n` (cantidad de
# celdas movibles de la barra), `to_cells` reconstruye la grilla y el bloque vuelve a
# quedar pegado a su costado, sin que el usuario toque nada.
#
# Sin I/O y sin depender del Frame: sólo arrays/ints. Ver tests/bar_slots_test.gd.

# Celdas -> lista de anclas {"tok": <token>, "at": k}. Omite celdas vacías y colapsa
# los tramos de un mismo token (su span). `n` = celdas movibles de la barra.
static func to_saved(cells, n):
	var out = []
	var total = int(n)
	var half = total / 2
	var prev = null
	for i in range(cells.size()):
		var t = String(cells[i])
		if t == "":
			prev = t
			continue
		if prev != null and String(prev) == t:
			continue   # continuación del span ya anclado
		prev = t
		var at = i
		if i >= half:
			at = i - total   # offset desde la derecha (-1 = última celda)
		out.append({"tok": t, "at": at})
	return out


# Anclas -> lista de `n` celdas ("" = libre). k >= 0 = celda desde la izquierda;
# k < 0 = desde la derecha (resuelve como n + k). Choques o fuera de rango: el bloque
# se corre a la celda libre más cercana hacia el centro; si no hay ninguna, se agrega
# al final (igual que hoy: no se pierde ningún bloque). Retrocompatible: una lista
# vieja de tokens/"" se trata como celdas desde la izquierda.
static func to_cells(saved, n):
	var total = int(max(0, n))
	var out = []
	for _i in range(total):
		out.append("")
	var src = saved if typeof(saved) == TYPE_ARRAY else []
	var legacy = not src.empty() and typeof(src[0]) != TYPE_DICTIONARY
	var entries = []
	for i in range(src.size()):
		var e = src[i]
		if legacy or typeof(e) != TYPE_DICTIONARY:
			var t = String(e)
			if t != "":
				entries.append({"tok": t, "at": i})
		else:
			var t2 = String(e.get("tok", ""))
			if t2 != "":
				entries.append({"tok": t2, "at": int(e.get("at", 0))})
	var seen = {}
	for e in entries:
		var tok = String(e.tok)
		if seen.has(tok):
			continue
		seen[tok] = true
		var idx = int(e.at)
		if idx < 0:
			idx = total + idx
		idx = _nearest_free(out, idx, total)
		if idx < 0:
			out.append(tok)   # barra llena: no se pierde el bloque
		else:
			out[idx] = tok
	return out


# Primera celda libre más cercana a `target` dentro de [0, total-1], con empate hacia
# el centro. -1 si no queda ninguna libre.
static func _nearest_free(out, target, total):
	if total <= 0:
		return -1
	var t = int(clamp(int(target), 0, total - 1))
	if out[t] == "":
		return t
	var dir = 1 if 2 * t < total - 1 else -1   # paso hacia el centro
	for d in range(1, total + 1):
		for idx in [t + dir * d, t - dir * d]:
			if idx >= 0 and idx < total and out[idx] == "":
				return idx
	return -1
