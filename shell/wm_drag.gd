extends Reference

# K13d — Decisiones PURAS de arrastre/soltar entre tiled y flotante.
#
# El shell aporta posiciones y rects; acá se decide el destino del drop y si una
# ventana tiled/maximizada salió de su celda (se vuelve flotante bajo el cursor).
# Sin I/O ni input real.

const DRAG_OUT = 40.0  # px fuera del rect para "sacar" una ventana de su celda


# Destino de un drop en modo flotante:
#   {kind: "maximize"|"reincorporate"|"float", target: ...}
# - Sobre un bloque del Frame (over_block) o fuera del hueco central -> reincorporar
#   al mosaico en ese lado/bloque.
# - Con la ventana claramente fuera de su rect -> flotante libre (conserva lugar).
# - Caso normal -> flotante.
static func drop_zone(pos, content_rect, frame_edges, over_block, mode):
	var pt = Vector2(pos)
	if over_block:
		return {"kind": "reincorporate", "target": "block"}
	var cr = Rect2(content_rect)
	if not cr.has_point(pt):
		var target = "left"
		if pt.y < cr.position.y:
			target = "top"
		elif pt.y > cr.end.y:
			target = "bottom"
		elif pt.x > cr.end.x:
			target = "right"
		return {"kind": "reincorporate", "target": target}
	return {"kind": "float", "target": ""}


# ¿El punto está lo bastante fuera del rect como para desprender la ventana de su
# celda (tiled/maximizada -> flotante bajo el cursor)?
static func drag_out(rect, pos, threshold = DRAG_OUT):
	if rect == null:
		return true
	return not Rect2(rect).grow(threshold).has_point(Vector2(pos))


# ¿La posición de caída corresponde a la franja superior o inferior del Frame?
# (para reincorporar; `block` es el alto de una barra). Puro.
static func over_frame_bar(pos, viewport, block):
	var y = float(Vector2(pos).y)
	return y <= float(block) or y >= float(viewport.y) - float(block)


# Tamaño recordado al desmaximizar en flotante, o el fallback.
static func restore_size(remembered, fallback):
	if typeof(remembered) == TYPE_VECTOR2 and remembered.x > 0.0 and remembered.y > 0.0:
		return remembered
	return fallback


# Autoprueba del modelo.
static func selftest():
	var cr = Rect2(0, 80, 1280, 640)
	assert(drop_zone(Vector2(400, 300), cr, {}, false, "floating").kind == "float", "drop dentro")
	assert(drop_zone(Vector2(400, 40), cr, {}, false, "floating").kind == "reincorporate", "drop arriba")
	assert(drop_zone(Vector2(400, 40), cr, {}, false, "floating").target == "top", "target top")
	assert(drop_zone(Vector2(-5, 300), cr, {}, false, "floating").target == "left", "target left")
	assert(drop_zone(Vector2(1400, 300), cr, {}, false, "floating").target == "right", "target right")
	assert(drop_zone(Vector2(400, 300), cr, {}, true, "floating").kind == "reincorporate", "sobre bloque")
	assert(not drag_out(Rect2(0, 0, 100, 100), Vector2(50, 50)), "dentro no desprende")
	assert(drag_out(Rect2(0, 0, 100, 100), Vector2(200, 50)), "fuera desprende")
	assert(drag_out(Rect2(0, 0, 100, 100), Vector2(115, 50), 10.0), "margen chico")
	assert(restore_size(Vector2(400, 300), Vector2(800, 600)) == Vector2(400, 300), "restore_size")
	assert(restore_size(null, Vector2(800, 600)) == Vector2(800, 600), "restore_size fallback")
	assert(over_frame_bar(Vector2(10, 5), Vector2(1280, 800), 80.0), "barra superior")
	assert(over_frame_bar(Vector2(10, 790), Vector2(1280, 800), 80.0), "barra inferior")
	assert(not over_frame_bar(Vector2(10, 400), Vector2(1280, 800), 80.0), "centro")
	return true


func run_selftest():
	return selftest()
