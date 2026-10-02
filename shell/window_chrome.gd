extends Reference

# K13b — Chrome WindowMaker de una ventana flotante (modelo PURO).
#
# Calcula la geometría del marco exterior (barra de título + borde) y hace el
# hit-test de sus zonas. El shell dibuja y reacciona; acá sólo hay rectángulos y
# decisiones deterministas, sin I/O ni ImGui.
#
#   ┌──────────────────────────────────────────────┐  bisel exterior BORDER
#   │ [–]        Título centrado            [x]    │  barra TITLE_H
#   ├──────────────────────────────────────────────┤  bisel
#   │              contenido del cliente           │
#   └──────────────────────────────────────────────┘
#
# Botón izquierdo = minimizar, derecho = cerrar. Zonas de borde/corner para
# redimensionar. El chrome pertenece a la ventana (rect exterior); el contenido
# del cliente se pide con el tamaño de `content`.

const TITLE_H = 20.0     # alto de la barra de título (px a escala 1)
const BORDER = 2.0       # bisel del marco
const BEVEL = 1.0        # bisel fino de la barra
const BTN = 16.0         # tesela de minimizar/cerrar
const BTN_MARGIN = 3.0   # aire de la tesela contra el borde de la barra
const BORDER_HIT = 6.0   # franja sensible para redimensionar


# Descompone un rect exterior en sus partes. Todas las medidas escala por el
# llamador (el shell las multiplica por get_imgui_scale()).
static func parts(frame_rect, title_h = TITLE_H, border = BORDER, btn = BTN, btn_margin = BTN_MARGIN):
	var fr = Rect2(frame_rect)
	if fr.size.x <= 0.0 or fr.size.y <= 0.0:
		return {"frame": fr, "title": Rect2(), "min_btn": Rect2(), "close_btn": Rect2(), "content": Rect2()}
	var inner = Rect2(fr.position + Vector2(border, border),
		Vector2(max(fr.size.x - 2.0 * border, 0.0), max(fr.size.y - 2.0 * border, 0.0)))
	var th = clamp(title_h, 0.0, inner.size.y)
	var title = Rect2(inner.position, Vector2(inner.size.x, th))
	var content = Rect2(Vector2(inner.position.x, inner.position.y + th),
		Vector2(inner.size.x, max(inner.size.y - th, 0.0)))
	var by = title.position.y + max((th - btn) * 0.5, 0.0)
	var bsize = min(btn, max(title.size.y, 1.0))
	var min_btn = Rect2(Vector2(title.position.x + btn_margin, by), Vector2(bsize, bsize))
	var close_btn = Rect2(Vector2(max(title.end.x - btn_margin - bsize, title.position.x), by), Vector2(bsize, bsize))
	return {"frame": fr, "title": title, "min_btn": min_btn, "close_btn": close_btn, "content": content}


# Sólo el rect de contenido (lo que ve el cliente); es el que se pasa a set_size.
static func content_rect(frame_rect, title_h = TITLE_H, border = BORDER):
	return parts(frame_rect, title_h, border).content


# Zona bajo el punto: "min" | "close" | "title" | borde ("left","right","top",
# "bottom","tl","tr","bl","br") | "content" | "" (fuera del marco).
static func hit(pos, frame_rect, title_h = TITLE_H, border = BORDER, btn = BTN, border_hit = BORDER_HIT):
	var p = parts(frame_rect, title_h, border, btn)
	var fr = p.frame
	var pt = Vector2(pos)
	if not fr.has_point(pt):
		return ""
	if p.min_btn.has_point(pt):
		return "min"
	if p.close_btn.has_point(pt):
		return "close"
	if p.title.has_point(pt):
		return "title"
	var near_l = pt.x <= fr.position.x + border_hit
	var near_r = pt.x >= fr.end.x - border_hit
	var near_t = pt.y <= fr.position.y + border_hit
	var near_b = pt.y >= fr.end.y - border_hit
	if near_l and near_t:
		return "tl"
	if near_r and near_t:
		return "tr"
	if near_l and near_b:
		return "bl"
	if near_r and near_b:
		return "br"
	if near_l:
		return "left"
	if near_r:
		return "right"
	if near_t:
		return "top"
	if near_b:
		return "bottom"
	if p.content.has_point(pt):
		return "content"
	return ""


# ¿La zona es un borde redimensionable?
static func is_edge(zone):
	return zone in ["left", "right", "top", "bottom", "tl", "tr", "bl", "br"]


# Nuevo rect exterior al arrastrar una zona de borde, tomando como base `start`
# (rect original) y el desplazamiento `delta` del puntero. Respeta el mínimo y no
# invierte el rect (las mitades opuestas quedan fijas).
static func resized(start, zone, delta, min_w = 320.0, min_h = 240.0):
	var r = Rect2(start)
	var d = Vector2(delta)
	var l = r.position.x
	var t = r.position.y
	var rr = r.end.x
	var b = r.end.y
	if zone in ["left", "tl", "bl"]:
		l = min(l + d.x, rr - min_w)
	if zone in ["right", "tr", "br"]:
		rr = max(rr + d.x, l + min_w)
	if zone in ["top", "tl", "tr"]:
		t = min(t + d.y, b - min_h)
	if zone in ["bottom", "bl", "br"]:
		b = max(b + d.y, t + min_h)
	return Rect2(Vector2(l, t), Vector2(rr - l, b - t))


# Autoprueba del modelo.
static func selftest():
	var fr = Rect2(100, 200, 400, 300)
	var p = parts(fr, 20.0, 2.0, 16.0, 3.0)
	assert(p.frame == fr, "frame")
	assert(p.title.position == Vector2(102, 202), "título origen")
	assert(p.title.size == Vector2(396, 20), "título tamaño")
	assert(p.content.position == Vector2(102, 222), "contenido origen")
	assert(p.content.size == Vector2(396, 276), "contenido tamaño")
	assert(p.min_btn.position == Vector2(105, 204), "min a la izquierda")
	assert(p.close_btn.position == Vector2(479, 204), "close a la derecha")
	assert(content_rect(fr, 20.0, 2.0) == p.content, "content_rect")
	# Hit-test.
	assert(hit(Vector2(108, 212), fr, 20.0, 2.0) == "min", "hit min")
	assert(hit(Vector2(483, 212), fr, 20.0, 2.0) == "close", "hit close")
	assert(hit(Vector2(300, 210), fr, 20.0, 2.0) == "title", "hit título")
	assert(hit(Vector2(300, 300), fr, 20.0, 2.0) == "content", "hit contenido")
	assert(hit(Vector2(101, 201), fr, 20.0, 2.0) == "tl", "hit esquina")
	assert(hit(Vector2(499, 300), fr, 20.0, 2.0) == "right", "hit borde derecho")
	assert(hit(Vector2(50, 50), fr, 20.0, 2.0) == "", "fuera")
	assert(is_edge("tr") and not is_edge("title") and not is_edge("content"), "is_edge")
	# Redimensión: agrandar por la derecha, mínimos, y diagonales.
	var g = resized(fr, "right", Vector2(60, 0), 320.0, 240.0)
	assert(g.size.x == 460.0 and g.position.x == 100.0, "resize derecha")
	var shrink = resized(fr, "left", Vector2(5000, 0), 320.0, 240.0)
	assert(shrink.size.x == 320.0, "resize respeta mínimo")
	var diag = resized(fr, "br", Vector2(40, 50), 320.0, 240.0)
	assert(diag.size == Vector2(440, 350), "resize diagonal")
	return true


func run_selftest():
	return selftest()
