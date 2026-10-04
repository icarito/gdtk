extends Reference

# K13b — Chrome OpenStep/WindowMaker de una ventana flotante (modelo PURO).
#
# Reproduce el marco clásico NeXTSTEP/OpenStep, no el aire "Windows 95":
#   - borde exterior de 1 px (oscuro),
#   - barra de título alta con el título centrado vertical y horizontalmente,
#   - botones cuadrados que ocupan TODO el alto de la barra y van pegados a las
#     esquinas (izquierda = minimizar, derecha = cerrar),
#   - barra inferior de redimensión con asa diagonal en la esquina inferior derecha.
#
#   ┌──────────────────────────────────────────────┐  borde 1 px
#   │[–]           Título centrado            [x]  │  barra TITLE_H (botones full-height)
#   ├──────────────────────────────────────────────┤
#   │              contenido del cliente           │
#   ├──────────────────────────────────────────────┤
#   │ barra de redimensión                      // │  RESIZE_H (asa diagonal)
#   └──────────────────────────────────────────────┘
#
# El chrome pertenece a la ventana (rect exterior); el contenido del cliente se
# pide con el tamaño de `content`. Este modelo sólo calcula rectángulos y
# decisiones deterministas, sin I/O ni ImGui; el shell dibuja y reacciona.

const TITLE_H = 22.0     # alto de la barra de título (px a escala 1)
const BORDER = 1.0       # borde exterior OpenStep
const RESIZE_H = 8.0     # barra inferior de redimensión
const BTN = TITLE_H      # botón cuadrado: todo el alto de la barra
const BTN_MARGIN = 0.0   # pegado a las esquinas (OpenStep)
const BORDER_HIT = 5.0   # franja sensible para redimensionar
const GRIP = 16.0        # ancho del asa diagonal inferior derecha
# Ventanas CSD: el cliente dibuja su barra, el shell sólo superpone un asa de mover
# (pastilla sobre el borde superior, sólo en hover) y una franja de redimensión abajo.
# El asa imita el asa de fronteras del modo tiled: pastilla del acento con puntos de
# agarre; en reposo queda arriba, y al aparecer se desliza desde detrás de la ventana.
const MOVE_GRIP_W = 40.0
const MOVE_GRIP_H = 10.0
const MOVE_GRIP_PAD = 6.0    # tolerancia de clic alrededor del pill
const MOVE_GRIP_DOTS = 3     # puntos de agarre, como el asa de fronteras tiled
const HOVER_TOP = 16.0       # franja sobre el borde superior que cuenta como hover
const CSD_EDGE = 6.0         # franja inferior (dentro del rect) para redimensionar


# Descompone un rect exterior en sus partes. Todas las medidas escala por el
# llamador (el shell las multiplica por get_imgui_scale()).
static func parts(frame_rect, title_h = TITLE_H, border = BORDER, btn = BTN, btn_margin = BTN_MARGIN, resize_h = RESIZE_H):
	var fr = Rect2(frame_rect)
	var empty = {"frame": fr, "title": Rect2(), "resize": Rect2(), "min_btn": Rect2(), "close_btn": Rect2(), "content": Rect2()}
	if fr.size.x <= 0.0 or fr.size.y <= 0.0:
		return empty
	var inner = Rect2(fr.position + Vector2(border, border),
		Vector2(max(fr.size.x - 2.0 * border, 0.0), max(fr.size.y - 2.0 * border, 0.0)))
	var th = clamp(title_h, 0.0, inner.size.y)
	var rh = clamp(resize_h, 0.0, max(inner.size.y - th, 0.0))
	var title = Rect2(inner.position, Vector2(inner.size.x, th))
	var resize = Rect2(Vector2(inner.position.x, inner.end.y - rh), Vector2(inner.size.x, rh))
	var content = Rect2(Vector2(inner.position.x, inner.position.y + th),
		Vector2(inner.size.x, max(inner.size.y - th - rh, 0.0)))
	# Botones cuadrados de todo el alto de la barra, pegados a las esquinas.
	var bw = min(min(btn, max(title.size.y, 1.0)), max(title.size.x * 0.5, 1.0))
	var margin = clamp(btn_margin, 0.0, max(title.size.x * 0.5 - 1.0, 0.0))
	var min_btn = Rect2(Vector2(title.position.x + margin, title.position.y), Vector2(bw, title.size.y))
	var close_btn = Rect2(Vector2(max(title.end.x - margin - bw, title.position.x), title.position.y), Vector2(bw, title.size.y))
	return {"frame": fr, "title": title, "resize": resize, "min_btn": min_btn, "close_btn": close_btn, "content": content}


# Sólo el rect de contenido (lo que ve el cliente); es el que se pasa a set_size.
static func content_rect(frame_rect, title_h = TITLE_H, border = BORDER, resize_h = RESIZE_H):
	return parts(frame_rect, title_h, border, BTN, BTN_MARGIN, resize_h).content


# Región del asa diagonal (esquina inferior derecha, dentro de la barra inferior).
static func grip_rect(frame_rect, title_h = TITLE_H, border = BORDER, resize_h = RESIZE_H, grip = GRIP):
	var r = parts(frame_rect, title_h, border, BTN, BTN_MARGIN, resize_h).resize
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return Rect2()
	var w = min(grip, r.size.x)
	return Rect2(Vector2(r.end.x - w, r.position.y), Vector2(w, r.size.y))


# Zona bajo el punto: "min" | "close" | "title" | borde ("left","right","top",
# "bottom","tl","tr","bl","br") | "content" | "" (fuera del marco).
static func hit(pos, frame_rect, title_h = TITLE_H, border = BORDER, btn = BTN, border_hit = BORDER_HIT, resize_h = RESIZE_H, btn_margin = BTN_MARGIN, grip_size = GRIP):
	var p = parts(frame_rect, title_h, border, btn, btn_margin, resize_h)
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
	if p.resize.has_point(pt):
		# El asa diagonal de la esquina inferior derecha redimensiona en ambas
		# direcciones; el resto de la barra inferior sólo el alto.
		var g = grip_rect(frame_rect, title_h, border, resize_h, grip_size)
		if g.size.x > 0.0 and g.has_point(pt):
			return "br"
		if pt.x <= fr.position.x + border_hit:
			return "bl"
		return "bottom"
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


# Asa de mover de una ventana CSD: pastilla pegada POR ENCIMA del borde superior
# (como una pestaña). Por defecto va centrada en x; con `inset > 0` se corre a
# `inset` px del borde izquierdo (≈ 1 bloque de la rejilla) para no quedar centrada.
# `reveal` 0..1 la esconde detrás de la ventana (y = borde superior) y la sube hasta
# su lugar; el dibujo recorta con reveal_clip, así parece salir de detrás de la ventana.
static func move_grip_rect(rect, scale = 1.0, reveal = 1.0, inset = 0.0):
	var r = Rect2(rect)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return Rect2()
	var w = min(MOVE_GRIP_W * scale, r.size.x)
	var h = MOVE_GRIP_H * scale
	var p = clamp(float(reveal), 0.0, 1.0)
	var x = r.position.x + (r.size.x - w) * 0.5
	if inset > 0.0:
		x = r.position.x + min(float(inset), max(r.size.x - w, 0.0))
	return Rect2(Vector2(x, r.position.y - h * p), Vector2(w, h))


# Recorta la pastilla a la franja por encima de `top_y` (el borde superior de la
# ventana): lo que todavía no emergió queda oculto detrás de la ventana.
static func reveal_clip(g, top_y):
	var r = Rect2(g)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return Rect2()
	var y = min(r.end.y, float(top_y))
	if y <= r.position.y:
		return Rect2()
	return Rect2(r.position, Vector2(r.size.x, y - r.position.y))


static func move_grip_hit(pos, rect, scale = 1.0, inset = 0.0):
	var g = move_grip_rect(rect, scale, 1.0, inset)
	return g.size.x > 0.0 and g.grow(MOVE_GRIP_PAD * scale).has_point(Vector2(pos))


# ¿El puntero está sobre la ventana CSD o cerca de su borde superior? (muestra el pill)
static func move_grip_hover(pos, rect, scale = 1.0, inset = 0.0):
	var r = Rect2(rect)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return false
	var pad = HOVER_TOP * scale
	return Rect2(r.position - Vector2(0, pad), r.size + Vector2(0, pad)).has_point(Vector2(pos)) \
		or move_grip_hit(pos, r, scale, inset)


# Zonas propias del shell sobre una ventana CSD: "grip" | "bottom" | "bl" | "br" | "".
static func csd_hit(pos, rect, scale = 1.0, inset = 0.0):
	var r = Rect2(rect)
	var pt = Vector2(pos)
	if move_grip_hit(pt, r, scale, inset):
		return "grip"
	if r.size.x <= 0.0 or r.size.y <= 0.0 or not r.has_point(pt):
		return ""
	if pt.y < r.end.y - CSD_EDGE * scale:
		return ""
	var c = GRIP * scale
	if pt.x <= r.position.x + c:
		return "bl"
	if pt.x >= r.end.x - c:
		return "br"
	return "bottom"


# Zona de redimensión más cercana a `pos` dentro del marco: 3x3 en base a la
# posición relativa (centro = esquina de su cuadrante). Se usa para Super+clic
# central, donde no hay un borde señalado explícitamente.
static func zone_at(pos, frame_rect, margin = 0.3):
	var fr = Rect2(frame_rect)
	if fr.size.x <= 0.0 or fr.size.y <= 0.0:
		return "br"
	var dx = (float(pos.x) - (fr.position.x + fr.size.x * 0.5)) / max(fr.size.x * 0.5, 1.0)
	var dy = (float(pos.y) - (fr.position.y + fr.size.y * 0.5)) / max(fr.size.y * 0.5, 1.0)
	var v = ""
	var h = ""
	if dy <= -margin:
		v = "t"
	elif dy >= margin:
		v = "b"
	if dx <= -margin:
		h = "l"
	elif dx >= margin:
		h = "r"
	if h == "" and v == "":
		h = "l" if dx < 0.0 else "r"
		v = "t" if dy < 0.0 else "b"
	if v != "" and h != "":
		return v + h
	if v != "":
		return "top" if v == "t" else "bottom"
	if h != "":
		return "left" if h == "l" else "right"
	return "br"


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
	var p = parts(fr, 22.0, 1.0, 22.0, 0.0, 8.0)
	assert(p.frame == fr, "frame")
	assert(p.title.position == Vector2(101, 201), "título origen")
	assert(p.title.size == Vector2(398, 22), "título tamaño")
	assert(p.resize.position == Vector2(101, 491), "resize origen")
	assert(p.resize.size == Vector2(398, 8), "resize tamaño")
	assert(p.content.position == Vector2(101, 223), "contenido origen")
	assert(p.content.size == Vector2(398, 268), "contenido tamaño")
	assert(p.min_btn.position == Vector2(101, 201), "min pegado a la esquina")
	assert(p.min_btn.size == Vector2(22, 22), "min cuadrado full-height")
	assert(p.close_btn.position == Vector2(477, 201), "close a la derecha")
	assert(p.close_btn.size == Vector2(22, 22), "close cuadrado full-height")
	assert(content_rect(fr, 22.0, 1.0, 8.0) == p.content, "content_rect")
	assert(grip_rect(fr, 22.0, 1.0, 8.0, 16.0).end == Vector2(499, 499), "grip esquina")
	# Hit-test.
	assert(hit(Vector2(103, 203), fr, 22.0, 1.0, 22.0) == "min", "hit min")
	assert(hit(Vector2(479, 203), fr, 22.0, 1.0, 22.0) == "close", "hit close")
	assert(hit(Vector2(300, 210), fr, 22.0, 1.0, 22.0) == "title", "hit título")
	assert(hit(Vector2(300, 300), fr, 22.0, 1.0, 22.0) == "content", "hit contenido")
	assert(hit(Vector2(300, 200), fr, 22.0, 1.0, 22.0) == "top", "hit borde superior")
	assert(hit(Vector2(499, 496), fr, 22.0, 1.0, 22.0) == "br", "hit asa inferior derecha")
	assert(hit(Vector2(300, 496), fr, 22.0, 1.0, 22.0) == "bottom", "hit barra inferior")
	assert(hit(Vector2(499, 300), fr, 22.0, 1.0, 22.0) == "right", "hit borde derecho")
	assert(hit(Vector2(50, 50), fr, 22.0, 1.0, 22.0) == "", "fuera")
	assert(zone_at(Vector2(105, 205), fr, 0.3) == "tl", "zona tl")
	assert(zone_at(Vector2(495, 495), fr, 0.3) == "br", "zona br")
	assert(zone_at(Vector2(300, 205), fr, 0.3) == "top", "zona top")
	assert(zone_at(Vector2(105, 350), fr, 0.3) == "left", "zona left")
	assert(is_edge("tr") and not is_edge("title") and not is_edge("content"), "is_edge")
	# Redimensión: agrandar por la derecha, mínimos, y diagonales.
	var g = resized(fr, "right", Vector2(60, 0), 320.0, 240.0)
	assert(g.size.x == 460.0 and g.position.x == 100.0, "resize derecha")
	var shrink = resized(fr, "left", Vector2(5000, 0), 320.0, 240.0)
	assert(shrink.size.x == 320.0, "resize respeta mínimo")
	var diag = resized(fr, "br", Vector2(40, 50), 320.0, 240.0)
	assert(diag.size == Vector2(440, 350), "resize diagonal")
	# CSD: asa de mover (pastilla del acento, estilo asa de fronteras) y franja inferior.
	assert(move_grip_rect(fr, 1.0) == Rect2(280, 190, 40, 10), "asa encima del borde")
	assert(move_grip_rect(fr, 1.0, 0.0) == Rect2(280, 200, 40, 10), "asa escondida en el borde")
	assert(reveal_clip(move_grip_rect(fr, 1.0, 1.0), 200.0) == Rect2(280, 190, 40, 10), "asa revelada")
	assert(reveal_clip(move_grip_rect(fr, 1.0, 0.5), 200.0) == Rect2(280, 195, 40, 5), "asa a medio salir")
	assert(reveal_clip(move_grip_rect(fr, 1.0, 0.0), 200.0) == Rect2(), "asa oculta detrás")
	assert(csd_hit(Vector2(300, 199), fr, 1.0) == "grip", "csd grip arriba del borde")
	assert(csd_hit(Vector2(300, 205), fr, 1.0) == "grip", "csd grip tolerancia")
	assert(csd_hit(Vector2(150, 205), fr, 1.0) == "", "csd resto del rect es del cliente")
	assert(csd_hit(Vector2(300, 497), fr, 1.0) == "bottom", "csd franja inferior")
	assert(csd_hit(Vector2(102, 497), fr, 1.0) == "bl" and csd_hit(Vector2(498, 497), fr, 1.0) == "br", "csd esquinas")
	assert(csd_hit(Vector2(300, 400), fr, 1.0) == "", "csd contenido")
	assert(csd_hit(Vector2(300, 520), fr, 1.0) == "", "csd fuera abajo")
	assert(move_grip_hover(Vector2(150, 300), fr, 1.0) and move_grip_hover(Vector2(150, 190), fr, 1.0), "hover dentro/arriba")
	assert(not move_grip_hover(Vector2(150, 150), fr, 1.0) and not move_grip_hover(Vector2(150, 520), fr, 1.0), "sin hover lejos")
	assert(move_grip_rect(Rect2(), 1.0).size == Vector2.ZERO, "pill de rect vacío")
	# Asa con desfase: ~1 bloque desde el lado izquierdo (no centrada).
	assert(move_grip_rect(fr, 1.0, 1.0, 40.0) == Rect2(140, 190, 40, 10), "asa desfasada a la izquierda")
	assert(csd_hit(Vector2(145, 205), fr, 1.0, 40.0) == "grip", "grip desfasado")
	assert(csd_hit(Vector2(145, 205), fr, 1.0, 0.0) == "", "sin desfase ese punto es del cliente")
	assert(move_grip_rect(fr, 1.0, 1.0, 5000.0).position.x == 460.0, "desfase no sale del rect")
	# Marco degenerado.
	var empty = parts(Rect2(0, 0, 0, 0), 22.0, 1.0, 22.0, 0.0, 8.0)
	assert(empty.content.size == Vector2.ZERO and empty.resize.size == Vector2.ZERO, "marco vacío")
	return true


func run_selftest():
	return selftest()
