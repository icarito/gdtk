extends Reference

# Exposé: layout PURO de un "zoom out" del escritorio. Cada workspace (unidad de
# `shell._units()`) es una miniatura del viewport COMPLETO, con la misma proporción y
# las ventanas en su posición/tamaño reales (escalados). Los workspaces se ordenan en
# una fila horizontal, tal como se navegan con el paneo (`_compute_slide_layout`), y
# se escalan para que TODOS entren a la vista. Sin estado: recibe las geometrías
# locales ya resueltas por el shell y devuelve los rects de pantalla.
#
# No conoce ImGui ni el compositor: testeable en headless (tests/expose_layout_test.gd).


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
	for u in range(n):
		var ox = x0 + float(u) * (unit_w + gap)
		var frame = Rect2(ox, y0, unit_w, unit_h)
		out["units"].append(frame)
		var local = unit_local[u]
		for id in local.keys():
			var lr = local[id]
			out["cards"][id] = Rect2(ox + lr.position.x * k, y0 + lr.position.y * k,
				lr.size.x * k, lr.size.y * k)
	return out
