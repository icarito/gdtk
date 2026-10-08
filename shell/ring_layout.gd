extends Reference

# G2 — Hogar: anillo según orientación (SPEC-sugar-group-2026-10).
#
# Lógica PURA de distribución de las entradas del Hogar alrededor del equipo
# central. Extraída de shell.gd `_orbit_layout`/`_ring_clamp` para poder probarla
# sin render ni estado global. El anillo es un círculo centrado (como el Hogar de
# Sugar). Pocas entradas (n <= circle_max) → anillo ordenado; muchas → espiral de
# ángulo áureo con dispersión orgánica, dentro del mismo radio (no se pega a los
# costados en pantallas anchas).
#
# La unidad de rejilla `u` (= grid_unit(vp)) y el alto de barra del Frame `top`
# (= frame_bar_h(vp)) se reciben como parámetros: el shell los calcula una sola
# vez y este módulo no depende de él. Devuelve la esquina superior izquierda de
# cada ítem (lado `btn`), ya limitada al lienzo útil.

const GOLDEN_ANGLE = 2.399963229728653  # PI * (3 - sqrt(5))
const RING_JITTER_A = 0.18
const RING_JITTER_R = 0.05

# Umbral por defecto del modo círculo/elipse; el caller lo pasa en `circle_max`.
const RING_CIRCLE_MAX = 7


# Distribución del anillo. `entries` sólo aporta el nombre para la dispersión de
# la espiral (hash estable) y viene por último uso. `u` es la unidad de rejilla y
# `top` el alto de las barras del Frame.
static func orbit_layout(vp, n, entries, u, top, circle_max):
	var out = []
	if n <= 0:
		return out
	var btn = u * 1.25
	var cx = vp.x * 0.5
	var cy = vp.y * 0.5
	var avail_x = min(cx, vp.x - cx)
	var avail_y = min(cy - (top + 2.0), (vp.y - top - 18.0) - cy)
	# Radio del anillo: un CÍRCULO centrado (como el Hogar de Sugar), no una elipse
	# estirada al ancho de la pantalla. El mínimo de los dos ejes evita que el anillo
	# se pegue a los costados en 16:9; el margen deja aire contra el borde del Frame.
	var radius = min(avail_x, avail_y) - btn * 0.5
	if n <= circle_max:
		# Radio del anillo (círculo centrado, como Sugar); el piso evita que dos
		# ítems se encimen cuando la pantalla es muy chica.
		var r = max(btn * 1.15, radius)
		# Ángulo base según orientación: landscape → 0° a izquierda/derecha
		# (base PI, ítems 0 y 1 al oeste/este); portrait → arriba/abajo (base -PI/2).
		var base = PI if vp.x >= vp.y else -PI * 0.5
		for i in range(n):
			var a = base + TAU * float(i) / float(n)
			var center = Vector2(cx + cos(a) * r, cy + sin(a) * r)
			out.append(ring_clamp(center, btn, vp, top))
		return out
	var margin = 10.0
	var srad = max(btn * 1.4, radius - margin)
	var f_in = clamp(max(u * 0.62, btn * 0.85) / srad, 0.12, 0.60)
	for i in range(n):
		var t = (float(i) + 0.5) / float(n)
		var f = lerp(f_in, 1.0, sqrt(t))
		var a = -PI * 0.5 + GOLDEN_ANGLE * float(i)
		var jr = 0.0
		var ja = 0.0
		if i < entries.size() and typeof(entries[i]) == TYPE_DICTIONARY:
			var h = abs(String(entries[i].get("name", "")).hash())
			ja = (float(h % 1000) / 1000.0 - 0.5) * RING_JITTER_A
			jr = (float(int(h / 1000) % 1000) / 1000.0 - 0.5) * RING_JITTER_R
		var ff = clamp(f + jr, f_in, 1.0)
		var aa = a + ja
		var center = Vector2(cx + cos(aa) * srad * ff, cy + sin(aa) * srad * ff)
		out.append(ring_clamp(center, btn, vp, top))
	return out


# Pasa un centro de ítem (lado `btn`) a la esquina, dentro del lienzo.
static func ring_clamp(center, btn, vp, top):
	return Vector2(clamp(center.x - btn * 0.5, 2.0, vp.x - btn - 2.0),
		clamp(center.y - btn * 0.5, top + 2.0, vp.y - top - btn - 18.0))
