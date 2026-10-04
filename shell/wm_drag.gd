extends Reference

# K13d — Decisiones PURAS de arrastre/soltar entre tiled y flotante.
#
# El shell aporta posiciones y rects; acá se decide el destino del drop y si una
# ventana tiled/maximizada salió de su celda (se vuelve flotante bajo el cursor).
# Sin I/O ni input real.

const DRAG_OUT = 40.0  # px fuera del rect para "sacar" una ventana de su celda


# El backend FRT/SDL puede llevar Meta correctamente en el evento de mouse aunque
# Input.is_key_pressed(KEY_META/SUPER_*) aún dé falso. La decisión acepta ambos.
static func super_active(event_meta, meta_pressed, left_pressed, right_pressed):
	return bool(event_meta) or bool(meta_pressed) or bool(left_pressed) or bool(right_pressed)


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


# Puntero proporcional al desmaximizar: la fracción del punto de agarre dentro del
# rect maximizado (old_size) se conserva en el rect restaurado (new_size), para que
# la ventana achicada quede bajo el cursor en la misma posición relativa.
static func proportional_grab(grab, old_size, new_size):
	var o = Vector2(max(float(old_size.x), 1.0), max(float(old_size.y), 1.0))
	var n = Vector2(max(float(new_size.x), 1.0), max(float(new_size.y), 1.0))
	var fx = clamp(float(grab.x) / o.x, 0.0, 1.0)
	var fy = clamp(float(grab.y) / o.y, 0.0, 1.0)
	return Vector2(fx * n.x, min(fy * n.y, n.y - 1.0))


# K13f — Snap flotante: al arrastrar una ventana contra el borde del hueco central,
# el drop propone usar una mitad (izquierda/derecha) o maximizar (borde superior).
# La decisión se toma del puntero (estándar de los compositores: la franja pegada al
# borde es la zona de drop). Puro: rect resultante desde el box del hueco.
const EDGE_SNAP = 14.0  # px de franja sensible junto a cada borde

static func edge_zone(pos, box, threshold = EDGE_SNAP):
	var r = Rect2(box)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return ""
	var p = Vector2(pos)
	var t = max(float(threshold), 1.0)
	if p.y <= r.position.y + t:
		return "max"
	if p.x <= r.position.x + t:
		return "left"
	if p.x >= r.end.x - t:
		return "right"
	return ""


# Rect exterior objetivo del snap sobre el box (Rect2()). Vacío si la zona no es de snap.
static func snap_rect(zone, box):
	var r = Rect2(box)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return Rect2()
	if zone == "left":
		return Rect2(r.position, Vector2(r.size.x * 0.5, r.size.y))
	if zone == "right":
		return Rect2(Vector2(r.position.x + r.size.x * 0.5, r.position.y),
			Vector2(r.size.x * 0.5, r.size.y))
	if zone == "max":
		return Rect2(r)
	return Rect2()


# K13i — Snap contextual: mismo borde, destino distinto según la pantalla centrada.
# Si ya tiene miembros tiled, la ventana se inserta en mosaico (mitad); si no, se
# redimensiona como flotante. Arriba siempre maximiza.
#   kind ∈ {"float-half", "tile-half", "maximize"}
#   dir  ∈ {"left", "right", "top"}
const ZONE_HOLD = 16.0  # px extra que conserva la zona activa (histéresis)

static func hybrid_target(pos, box, has_tiled_member, threshold = EDGE_SNAP):
	var zone = edge_zone(pos, box, threshold)
	if zone == "":
		return null
	if zone == "max":
		return {"kind": "maximize", "dir": "top", "zone": zone}
	if has_tiled_member:
		return {"kind": "tile-half", "dir": zone, "zone": zone}
	return {"kind": "float-half", "dir": zone, "zone": zone}


# Histéresis de zona: una zona activa se conserva mientras el puntero no salga del
# umbral extendido (`threshold + ZONE_HOLD`). Evita parpadeo en arrastres lentos.
static func zone_hold(prev, pos, box, threshold = EDGE_SNAP, hold = ZONE_HOLD):
	var z = edge_zone(pos, box, threshold)
	if z != "":
		return z
	if String(prev) == "":
		return ""
	if edge_zone(pos, box, threshold + hold) == prev:
		return prev
	return ""


# Bitfield WLR_EDGE_* de un xdg_toplevel.resize (top=1, bottom=2, left=4, right=8)
# a la zona del chrome que entiende WINDOW_CHROME.resized. Puro.
static func edges_zone(edges):
	var e = int(edges)
	var top = (e & 1) != 0
	var bottom = (e & 2) != 0
	var left = (e & 4) != 0
	var right = (e & 8) != 0
	if top and left:
		return "tl"
	if top and right:
		return "tr"
	if bottom and left:
		return "bl"
	if bottom and right:
		return "br"
	if top:
		return "top"
	if bottom:
		return "bottom"
	if left:
		return "left"
	if right:
		return "right"
	return "br"


# Esquina (tl/tr/bl/br) de `rect` más cercana a `pos`: el rect se parte en mitades.
# Para Super+arrastre derecho, que redimensiona ambas dimensiones de esa esquina.
static func quadrant_zone(pos, rect):
	var r = Rect2(rect)
	var c = r.position + r.size * 0.5
	var p = Vector2(pos)
	return ("t" if p.y < c.y else "b") + ("l" if p.x < c.x else "r")


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
	assert(proportional_grab(Vector2(640, 320), Vector2(1280, 640), Vector2(800, 480)) == Vector2(400, 240), "grab proporcional centro")
	assert(proportional_grab(Vector2(0, 0), Vector2(1280, 640), Vector2(800, 480)) == Vector2(0, 0), "grab proporcional esquina")
	assert(proportional_grab(Vector2(1280, 640), Vector2(1280, 640), Vector2(800, 480)) == Vector2(800, 479), "grab proporcional borde")
	assert(over_frame_bar(Vector2(10, 5), Vector2(1280, 800), 80.0), "barra superior")
	assert(over_frame_bar(Vector2(10, 790), Vector2(1280, 800), 80.0), "barra inferior")
	assert(not over_frame_bar(Vector2(10, 400), Vector2(1280, 800), 80.0), "centro")
	assert(edges_zone(1) == "top", "edge top")
	assert(edges_zone(2) == "bottom", "edge bottom")
	assert(edges_zone(4) == "left", "edge left")
	assert(edges_zone(8) == "right", "edge right")
	assert(edges_zone(1 | 4) == "tl", "edge tl")
	assert(edges_zone(2 | 8) == "br", "edge br")
	assert(edges_zone(0) == "br", "edge default")
	var qr = Rect2(100, 100, 400, 200)
	assert(quadrant_zone(Vector2(110, 110), qr) == "tl", "cuadrante tl")
	assert(quadrant_zone(Vector2(490, 110), qr) == "tr", "cuadrante tr")
	assert(quadrant_zone(Vector2(110, 290), qr) == "bl", "cuadrante bl")
	assert(quadrant_zone(Vector2(490, 290), qr) == "br", "cuadrante br")
	assert(super_active(true, false, false, false), "meta del evento")
	assert(super_active(false, false, true, false), "super físico")
	assert(not super_active(false, false, false, false), "sin super")
	# Snap flotante (K13f): franjas del borde del box -> mitades / maximizar.
	assert(edge_zone(Vector2(9, 300), cr) == "left", "snap franja izquierda")
	assert(edge_zone(Vector2(1274, 300), cr) == "right", "snap franja derecha")
	assert(edge_zone(Vector2(400, 92), cr) == "max", "snap franja superior")
	assert(edge_zone(Vector2(400, 300), cr) == "", "sin snap en el centro")
	assert(edge_zone(Vector2(8, 92), cr) == "max", "esquina superior: gana maximizar")
	assert(edge_zone(Vector2(400, 700), cr) == "", "borde inferior no snappea")
	assert(edge_zone(Vector2(400, 91), cr, 20.0) == "max", "umbral configurable")
	assert(snap_rect("left", cr) == Rect2(0, 80, 640, 640), "rect mitad izquierda")
	assert(snap_rect("right", cr) == Rect2(640, 80, 640, 640), "rect mitad derecha")
	assert(snap_rect("max", cr) == cr, "rect maximizar")
	assert(snap_rect("centro", cr) == Rect2(), "zona desconocida: rect vacío")
	# Snap contextual (K13i): sin tiled -> flotante; con tiled -> mosaico; arriba max.
	assert(hybrid_target(Vector2(9, 300), cr, false).kind == "float-half", "sin tiled: flotante")
	assert(hybrid_target(Vector2(9, 300), cr, true).kind == "tile-half", "con tiled: mosaico")
	assert(hybrid_target(Vector2(400, 92), cr, true).kind == "maximize", "arriba maximiza")
	assert(hybrid_target(Vector2(400, 300), cr, true) == null, "centro sin target")
	# Histéresis: la zona activa se conserva fuera del umbral pero dentro del hold.
	assert(zone_hold("left", Vector2(40, 300), cr) == "", "fuera del hold suelta")
	assert(zone_hold("left", Vector2(24, 300), cr) == "left", "dentro del hold conserva")
	assert(zone_hold("", Vector2(40, 300), cr) == "", "sin previa nada")
	return true


func run_selftest():
	return selftest()
