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
# El LADO (izquierda/derecha) de cada bloque es estable: `to_saved` conserva el lado
# del ancla previa, así un colapso (p. ej. portrait) no reclasifica un bloque; al
# volver a landscape retoma su distancia al borde. El lado sólo cambia cuando el
# usuario vuelve a soltar el bloque (lo fija el Frame según el centro de la barra).
#
# Un ÚNICO algoritmo (`nearest_free`) ubica un bloque que no cabe en su celda anclada:
# los de la izquierda buscan hacia la derecha y los de la derecha hacia la izquierda
# (hacia adentro), con el mismo desempate que los drops. Reserva el ancho (span) del
# bloque, así NUNCA quedan dos bloques en el mismo slot.
#
# Sin I/O y sin depender del Frame: sólo arrays/ints. Ver tests/bar_slots_test.gd.

# Celdas -> lista de anclas {"tok": <token>, "at": k}. Omite celdas vacías y colapsa
# los tramos de un mismo token (su span). `n` = celdas movibles de la barra.
# `prev_anchor` (opcional) es el ancla anterior: el SIGNO de `at` de cada token fija su
# lado, que se conserva aunque el bloque haya colapsado a la otra mitad.
static func to_saved(cells, n, prev_anchor = []):
	var out = []
	var total = int(n)
	var half = total / 2
	var side = {}
	if typeof(prev_anchor) == TYPE_ARRAY:
		for e in prev_anchor:
			if typeof(e) == TYPE_DICTIONARY:
				var pt = String(e.get("tok", ""))
				if pt != "":
					side[pt] = 1 if int(e.get("at", 0)) >= 0 else -1
	var last = null
	for i in range(cells.size()):
		var t = String(cells[i])
		if t == "":
			last = ""
			continue
		if last != null and String(last) == t:
			continue   # continuación del span ya anclado
		last = t
		var s = 0
		if side.has(t):
			s = int(side[t])
		else:
			s = -1 if i >= half else 1
		out.append({"tok": t, "at": (i if s > 0 else i - total)})
	return out


# Anclas -> lista de celdas ("" = libre). k >= 0 = celda desde la izquierda;
# k < 0 = desde la derecha (resuelve como n + k). Un bloque que no cabe en su celda
# anclada busca el hueco más cercano con `nearest_free`, HACIA ADENTRO de su lado; el
# que choca corre a la libre más cercana. `spans` (opcional) reserva el ancho real de
# cada token para que dos bloques nunca compartan slot. Retrocompatible: una lista
# vieja de tokens/"" se trata como celdas desde la izquierda.
static func to_cells(saved, n, spans = {}):
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
				entries.append({"tok": t, "at": i, "side": 1})
		else:
			var t2 = String(e.get("tok", ""))
			if t2 != "":
				var at = int(e.get("at", 0))
				entries.append({"tok": t2, "at": at, "side": (1 if at >= 0 else -1)})
	var seen = {}
	for e in entries:
		var tok = String(e.tok)
		if seen.has(tok):
			continue
		seen[tok] = true
		var span = 1
		if typeof(spans) == TYPE_DICTIONARY and spans.has(tok):
			span = max(1, int(spans[tok]))
		var idx = int(e.at)
		if idx < 0:
			idx = total + idx
		var placed = nearest_free(out, idx, span, total, int(e.side))
		if placed < 0:
			# Barra llena: no se pierde ningún bloque y NO comparte slot (va fuera del
			# tope útil; la normalización del Frame lo descarta si de verdad no cabe).
			for _k in range(span):
				out.append(tok)
		else:
			for k in range(span):
				out[placed + k] = tok
	return out


# ÚNICO buscador de slot libre del Frame. Primera celda de un tramo de `span` celdas
# contiguas libres más cercano a `target`, dentro de [0, max_cells - span]. `prefer`
# (+1/-1) decide el desempate y el orden de barrido: +1 = hacia la derecha, -1 = hacia
# la izquierda. Celdas fuera del arreglo cuentan como libres. -1 si no hay lugar.
static func nearest_free(cells, target, span, max_cells, prefer = 1):
	span = max(1, int(span))
	max_cells = max(0, int(max_cells))
	var last = max_cells - span
	if last < 0:
		return -1
	target = int(clamp(int(target), 0, last))
	var p = 1 if int(prefer) >= 0 else -1
	for d in range(max_cells + 1):
		for s in [target + p * d, target - p * d]:
			if s < 0 or s > last:
				continue
			var ok = true
			for i in range(span):
				var idx = s + i
				if idx < cells.size() and String(cells[idx]) != "":
					ok = false
					break
			if ok:
				return s
	return -1
