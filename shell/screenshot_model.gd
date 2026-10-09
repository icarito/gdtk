extends Reference

# Modelo PURO del selector de pantallazos (ventana / pantalla / selección).
# Sin I/O, sin ImGui y sin relojes: sólo geometría, para poder testearlo. El overlay
# vivo (shell/screenshot_ui.gd) y el shell usan estas funciones.

# Mínimo de lado (px de UI) para aceptar una selección: por debajo se descarta (un
# clic sin arrastre no debe generar un recorte de 0x0).
const MIN_SIDE = 4.0


# Rect normalizado entre dos puntos (el arrastre puede ir en cualquier dirección),
# recortado a `bounds`. Devuelve Rect2() si queda más chico que `min_side`.
static func normalize_rect(a, b, bounds, min_side = MIN_SIDE):
	var x0 = min(a.x, b.x)
	var y0 = min(a.y, b.y)
	var x1 = max(a.x, b.x)
	var y1 = max(a.y, b.y)
	x0 = clamp(x0, bounds.position.x, bounds.end.x)
	y0 = clamp(y0, bounds.position.y, bounds.end.y)
	x1 = clamp(x1, bounds.position.x, bounds.end.x)
	y1 = clamp(y1, bounds.position.y, bounds.end.y)
	var r = Rect2(x0, y0, x1 - x0, y1 - y0)
	if r.size.x < min_side or r.size.y < min_side:
		return Rect2()
	return r


# RELACIÓN entre el espacio de la UI (`vp`, Viewport) y los píxeles de la imagen
# congelada. En HiDPI la textura es más grande que el Viewport: la captura se recorta
# en píxeles de imagen, no de UI.
static func scale_for(image_size, vp):
	return Vector2(float(image_size.x) / max(1.0, vp.x), float(image_size.y) / max(1.0, vp.y))


# Rect de la imagen (píxeles enteros) que corresponde a `rect` de la UI, encajado a
# los límites de la imagen. Rect2() si no queda nada capturable.
static func crop_rect(rect, vp, image_size):
	var k = scale_for(image_size, vp)
	var x0 = int(clamp(floor(rect.position.x * k.x), 0.0, image_size.x))
	var y0 = int(clamp(floor(rect.position.y * k.y), 0.0, image_size.y))
	var x1 = int(clamp(ceil(rect.end.x * k.x), 0.0, image_size.x))
	var y1 = int(clamp(ceil(rect.end.y * k.y), 0.0, image_size.y))
	if x1 <= x0 or y1 <= y0:
		return Rect2()
	return Rect2(x0, y0, x1 - x0, y1 - y0)


# Geometría de la barra de botones: fila centrada arriba. `items` = [{id, label}].
# Devuelve [{id, label, rect}] en coords de pantalla. El ancho estima el texto con la
# métrica empírica del shell (7.5 px/carácter a escala 1); el dibujo usa el ancho real,
# por eso se suma padding de sobra.
static func toolbar_layout(vp, scale, items, pad = 16.0, gap = 8.0, h = 34.0, top = 14.0):
	var s = max(0.5, float(scale))
	var ph = h * s
	var ppad = pad * s
	var pgap = gap * s
	var widths = []
	var total = 0.0
	for it in items:
		var w = max(88.0 * s, float(String(it.get("label", "")).length()) * 7.5 * s + 2.0 * ppad)
		widths.append(w)
		total += w
	total += pgap * float(max(0, items.size() - 1))
	var x = (vp.x - total) * 0.5
	var y = top * s
	var out = []
	for i in range(items.size()):
		var w = widths[i]
		out.append({"id": String(items[i].get("id", "")), "label": String(items[i].get("label", "")),
			"rect": Rect2(x, y, w, ph)})
		x += w + pgap
	return out


# Id del botón bajo `pos` ("" si ninguno).
static func button_at(pos, buttons):
	for b in buttons:
		if Rect2(b["rect"]).has_point(pos):
			return String(b["id"])
	return ""


# Nombre del archivo según el tipo de captura ("", "region" o "window").
static func suggest_name(kind, stamp):
	var suffix = ""
	match String(kind):
		"region":
			suffix = "-region"
		"window":
			suffix = "-ventana"
	return "Pantallazo%s-%s.png" % [suffix, String(stamp)]
