extends Reference

# Modelo puro (K12) del hueco central del Frame.
#
# Ventanas, diálogos, popups y ventanas hijas deben ocupar por defecto el rectángulo
# que deja el Frame en el centro de la pantalla, quitando un bloque por lado
# (izquierda, derecha, arriba y abajo), no sólo arriba y abajo. Este helper concentra
# ese cálculo para que el layout de tiles (shell.gd) y los diálogos usen una única
# fuente y no repitan rests.
#
# Es puro: sin I/O, sin procesos, sin estado global. Sólo geometría determinista:
#   - content_rect(viewport, block, frame_edges): rect central de contenido. Las
#     ventanas (top-level) y los diálogos usan SÓLO los lados que el Frame reserva:
#     con autohide (default) no reserva nada y la ventana usa todo el viewport; una
#     barra fijada (pin) reserva su franja. El autohide no redimensiona la ventana.
#   - clamp_inside(outer, pos, size): encaja un rect (p. ej. un diálogo) dentro del
#     hueco, alineándolo si no cabe (la capa recortada termina el trabajo).
#   - dialog_area(viewport, block): hueco para diálogos: viewport menos un bloque
#     por cada lado (siempre, no sólo lo que el Frame reserva).
#
# Vocabulario: no produce texto visible; los nombres de lados son internos
# (inglés/cardinales) y nunca salen a la UI.

static func content_rect(viewport, block, frame_edges):
	var origin = _viewport_origin(viewport)
	var vp = _viewport_size(viewport)
	if vp.x <= 0.0 or vp.y <= 0.0:
		return Rect2()
	var b = max(float(block), 0.0)
	var edges = frame_edge_set(frame_edges)
	var left = b if edges.has("left") else 0.0
	var top = b if edges.has("top") else 0.0
	var right = b if edges.has("right") else 0.0
	var bottom = b if edges.has("bottom") else 0.0
	var w = max(vp.x - left - right, 0.0)
	var h = max(vp.y - top - bottom, 0.0)
	return Rect2(origin + Vector2(left, top), Vector2(w, h))


# Área reservada a los diálogos: el viewport completo menos un bloque por CADA
# lado, haya o no barras fijadas. Los diálogos (p. ej. el selector de archivos del
# portal) se centran/recortan ahí y conservan el tamaño natural que pide el cliente;
# así respiran y no quedan bajo el Frame aunque las barras estén en autohide.
static func dialog_area(viewport, block):
	return content_rect(viewport, block, ["top", "bottom", "left", "right"])


# Encaja un rect (origen `pos`, tamaño `size`) dentro de `outer`: lo recorta para que
# no invada el Frame. Si no cabe, se alinea al borde superior-izquierdo y el recorte
# de la capa termina el trabajo. No centra: eso lo decide el llamador.
static func clamp_inside(outer, pos, size):
	var p = Vector2(pos)
	if size.x <= outer.size.x:
		p.x = clamp(p.x, outer.position.x, outer.end.x - size.x)
	else:
		p.x = outer.position.x
	if size.y <= outer.size.y:
		p.y = clamp(p.y, outer.position.y, outer.end.y - size.y)
	else:
		p.y = outer.position.y
	return p


# Conjunto canónico de lados ocupados: acepta dict lado->bool o array de lados, con
# alias arriba/abajo y cardinales (north/south/east/west) para el mismo vocabulario.
static func frame_edge_set(frame_edges):
	var out = {}
	if typeof(frame_edges) == TYPE_DICTIONARY:
		for key in frame_edges:
			if bool(frame_edges[key]):
				var e = canonical_edge(key)
				if e != "":
					out[e] = true
	elif typeof(frame_edges) == TYPE_ARRAY:
		for key in frame_edges:
			var e = canonical_edge(key)
			if e != "":
				out[e] = true
	return out


static func canonical_edge(edge):
	match String(edge).to_lower():
		"top", "up", "north":
			return "top"
		"bottom", "down", "south":
			return "bottom"
		"left", "west":
			return "left"
		"right", "east":
			return "right"
	return ""


static func _viewport_origin(viewport):
	return viewport.position if typeof(viewport) == TYPE_RECT2 else Vector2.ZERO


static func _viewport_size(viewport):
	if typeof(viewport) == TYPE_RECT2:
		return viewport.size
	if typeof(viewport) == TYPE_VECTOR2:
		return viewport
	return Vector2.ZERO


# Autoprueba del modelo (mismo espíritu que screen_layout.gd). Devuelve true si pasa.
static func selftest():
	var top_bottom = content_rect(Vector2(1280, 800), 80.0, {"top": true, "bottom": true})
	assert(top_bottom.position == Vector2(0, 80) and top_bottom.size == Vector2(1280, 640), "arriba/abajo")
	var all4 = content_rect(Vector2(1280, 800), 80.0,
		{"top": true, "bottom": true, "left": true, "right": true})
	assert(all4.position == Vector2(80, 80) and all4.size == Vector2(1120, 640), "cuatro lados")
	assert(content_rect(Vector2(1280, 800), 80.0, ["up", "down"]) == top_bottom, "alias")
	assert(content_rect(Vector2(1000, 600), 0.0, {}) == Rect2(0, 0, 1000, 600), "bloque 0")
	assert(content_rect(Rect2(10, 20, 1000, 600), 50.0, ["top", "left"])
		== Rect2(60, 70, 950, 550), "origen del Rect2")
	assert(clamp_inside(all4, Vector2(-99, -99), Vector2(100, 100)) == all4.position, "encaje")
	# Con autohide (sin lados reservados) la ventana usa todo el viewport; una barra
	# fijada reserva su franja. No hay deslizamiento: no se redimensiona al mostrarse.
	assert(content_rect(Vector2(1280, 800), 80.0, {}) == Rect2(0, 0, 1280, 800), "autohide: viewport completo")
	assert(content_rect(Vector2(1280, 800), 80.0, {"top": true}) == Rect2(0, 80, 1280, 720), "pin superior reserva")
	assert(content_rect(Vector2(1280, 800), 80.0, {"bottom": true}) == Rect2(0, 0, 1280, 720), "pin inferior reserva")
	# Diálogos: viewport menos un bloque por cada lado, sin importar el Frame.
	assert(dialog_area(Vector2(1280, 800), 80.0) == Rect2(80, 80, 1120, 640), "área de diálogos")
	assert(dialog_area(Vector2(1280, 800), 0.0) == Rect2(0, 0, 1280, 800), "área de diálogos sin bloque")
	return true


func run_selftest():
	return selftest()
