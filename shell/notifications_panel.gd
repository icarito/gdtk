extends Reference

# Columna overlay de notificaciones (SPEC-notificaciones): cada aviso es un BLOQUE
# estilo dockapp (bisel + placa LCD + ícono de la app + resumen DENTRO del bloque),
# apilado en el borde izquierdo.
#
# Los bloques son TRANSITORIOS y ANIMADOS: entran con un fade-in corto, se sostienen
# un rato y salen con fade-out en el orden en que aparecieron (los más viejos primero,
# con un pequeño escalonado si llegan varios juntos). Con la columna "fijada"
# (`notify.panel_open` o `columna_modo`) no se desvanecen: quedan para inspeccionarlos.
#
# No obstruye: la ventana ImGui usa WINDOW_NO_MOUSE_INPUTS (nunca captura el ratón) y
# el hover/clic se resuelve a mano contra los rects del último dibujo; un clic fuera de
# los bloques pasa a la app de abajo. El hover sólo resalta el bloque (sin overlay).
#
# Dibujo ImGui llamado desde `shell._frame`/`_imgui_frame`; input desde `shell._input`.

const MAX_BLOCKS = 12
const FADE_IN_MS = 180
const HOLD_MS = 5200
const FADE_OUT_MS = 650
const STAGGER_MS = 320
const ROW_GAP = 3.0
const CARD_W = 320.0
const CARD_PAD = 8.0
const CARD_LINE = 16.0
# ImGuiCanvas no expone esta constante (sólo WINDOW_NO_SCROLLBAR): valor fijado.
const WINDOW_NO_MOUSE_INPUTS = 512
const WINDOW_TOP_LAYER = 33554432

var blocks = []                # [{"rect": Rect2 (pantalla), "id": int}]
var hover_index = -1
var _pressed = false
var _anim = {}                 # id -> {"born": ms} controla el ciclo de vida
var _primed = false            # el primer dibujo no reproduce el historial viejo
var _rect = Rect2()            # ventana completa del último dibujo (para el hueco)


# ¿Hay algo que pueda reaccionar al puntero ahora?
func active(shell):
	var n = shell.notify
	if n == null:
		return false
	if not blocks.empty():
		return true
	return n.panel_open and not n.items().empty()


func draw(shell):
	var n = shell.notify
	if n == null:
		return
	var now = OS.get_ticks_msec()
	var vp = shell._screen_size()
	var bar_h = shell.frame_bar_h(vp)
	# Misma grilla que el Frame: bloque = una unidad (pitch/side, PAD=0), pegado al
	# borde; sin margen extra alrededor.
	var frame = shell.frame
	var grid = {"side": bar_h, "pitch": bar_h, "margin": 0.0}
	if frame != null and frame.has_method("bar_grid"):
		grid = frame.bar_grid(vp.x, bar_h, 0.0)
	var side = float(grid.side)
	var pitch = float(grid.pitch)
	var margin = float(grid.margin)
	var scale = shell.get_imgui_scale()
	var pinned = n.panel_open or (n.panel_mode and not n.items().empty())
	var items = n.items()
	# Asigna nacimiento a los ítems nuevos y descarta la animación de los que ya no
	# están en el historial.
	var live = {}
	var new_ids = []          # más nuevo primero
	for it in items:
		var id = int(it.get("id", 0))
		live[id] = true
		if not _anim.has(id):
			new_ids.append(id)
	if not _primed:
		# Primer dibujo: no reproducir el historial; sólo el más nuevo "nace ahora".
		for k in range(new_ids.size()):
			var born0 = now if k == 0 else now - (FADE_IN_MS + HOLD_MS + FADE_OUT_MS + 1)
			_anim[new_ids[k]] = {"born": born0}
		_primed = true
	else:
		# En una ráfaga, el más nuevo nace último: los viejos se desvanecen primero.
		var cnt = new_ids.size()
		for k in range(cnt):
			_anim[new_ids[k]] = {"born": now + (cnt - 1 - k) * STAGGER_MS}
	for id in _anim.keys():
		if not live.has(id):
			_anim.erase(id)
	# Arma la lista visible (más nuevo primero) con su alpha de ciclo de vida.
	var shown = []
	var animating = false
	var avail = max(1, int((vp.y - 2.0 * bar_h - 8.0) / pitch))
	var maxn = min(MAX_BLOCKS, avail)
	for it in items:
		var id = int(it.get("id", 0))
		var age = now - int(_anim[id].get("born", now))
		var a = _life_alpha(age, pinned)
		if a <= 0.0 and not pinned:
			continue
		if a < 1.0 or (not pinned and age < FADE_IN_MS + HOLD_MS + FADE_OUT_MS):
			animating = true
		shown.append({"it": it, "alpha": a})
		if shown.size() >= maxn:
			break
	if shown.empty():
		blocks = []
		hover_index = -1
		return
	if animating:
		shell.request_redraw()
	var h = shown.size() * pitch
	# El borde de la ventana ImGui recorta ~1 px del contenido: se deja 1 px de relleno
	# transparente para que el bloque use TODA su unidad sin que se le coma el borde.
	var edge = 1.0
	shell.set_next_window_pos(Vector2(margin - edge, bar_h - edge), true)
	shell.set_next_window_size(Vector2(side + 2.0 * edge, h + 2.0 * edge), true)
	shell.set_next_window_bg_alpha(0.0)
	shell.push_style_var_vec2(shell.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	var flags = shell.WINDOW_NO_DECORATION | shell.WINDOW_NO_BACKGROUND | shell.WINDOW_NO_MOVE \
		| shell.WINDOW_NO_RESIZE | shell.WINDOW_NO_SAVED_SETTINGS | shell.WINDOW_NO_TITLE_BAR \
		| shell.WINDOW_NO_COLLAPSE | shell.WINDOW_NO_BRING_TO_FRONT_ON_FOCUS \
		| shell.WINDOW_NO_SCROLLBAR | WINDOW_NO_MOUSE_INPUTS | WINDOW_TOP_LAYER
	if shell.begin("##gdtk_notif_col", flags):
		var win = shell.get_window_pos()
		_rect = Rect2(win, Vector2(side + 2.0 * edge, h + 2.0 * edge))
		blocks = []
		var y = edge
		var idx = 0
		for e in shown:
			var local = Vector2(edge, y)
			_draw_block(shell, n, e["it"], win + local, local, side, e["alpha"], scale, idx == hover_index)
			blocks.append({"rect": Rect2(win + local, Vector2(side, side)), "id": int(e["it"].get("id", 0))})
			y += pitch
			idx += 1
	shell.end()
	shell.pop_style_var()
	_draw_hover_card(shell)


# Alpha del ciclo de vida de un bloque (0 sin aparecer, 1 pleno, 0 ya salido).
func _life_alpha(age, pinned):
	if age < 0:
		return 0.0
	if age < FADE_IN_MS:
		return float(age) / float(FADE_IN_MS)
	if pinned:
		return 1.0
	if age < FADE_IN_MS + HOLD_MS:
		return 1.0
	if age < FADE_IN_MS + HOLD_MS + FADE_OUT_MS:
		return 1.0 - float(age - FADE_IN_MS - HOLD_MS) / float(FADE_OUT_MS)
	return 0.0


# Un bloque estilo dockapp: bisel + placa con ícono de la app y resumen adentro.
func _draw_block(shell, n, it, scr, local, side, alpha, scale, hovered):
	var frame = shell.frame
	if frame == null or alpha <= 0.0:
		return
	# Salto del aviso recién llegado (desplaza el bloque unos px).
	if n != null and n.has_method("bounce_alpha"):
		var bo = float(n.bounce_alpha(int(it.get("id", 0))))
		scr += Vector2(4.0 * bo, 0.0)
		local += Vector2(4.0 * bo, 0.0)
	var face = frame.NX_FACE_SEL if hovered else frame.NX_FACE
	# Fondo del bloque explícito (por si el bisel no rellena en la ventana overlay).
	shell.imgui_draw_rect_filled(Rect2(scr, Vector2(side, side)),
		Color(face.r, face.g, face.b, alpha), 0.0)
	frame._bevel(shell, Rect2(scr, Vector2(side, side)),
		Color(face.r, face.g, face.b, alpha), false, hovered)
	var m = max(3.0, 4.0 * scale)
	var inner = Rect2(scr + Vector2(m, m), Vector2(side - 2.0 * m, side - 2.0 * m))
	var accent = _accent(frame, shell, it)
	var plate = frame.NX_LCD_TOP.linear_interpolate(accent, 0.20 if hovered else 0.12)
	shell.imgui_draw_rect_filled(inner, Color(plate.r, plate.g, plate.b, alpha), 2.0 * scale)
	shell.imgui_draw_rect_filled(Rect2(inner.position + Vector2(1.0, 1.0) * scale,
		Vector2(inner.size.x - 2.0 * scale, max(1.0, scale))), Color(1, 1, 1, 0.10 * alpha), 0.0)
	# Ícono de la app (o campana Sugar) centrado arriba.
	var icon = _icon(shell, it)
	if icon == null:
		icon = shell._load_sugar_svg("notifications",
			Color(0.88, 0.90, 0.95, 1.0), Color(0.97, 0.96, 0.92, 1.0))
	var g = side * 0.40
	if icon != null:
		shell.set_cursor_pos(local + Vector2((side - g) * 0.5, side * 0.10))
		shell.image(icon, Vector2(g, g), Color(1, 1, 1, alpha))
	# Resumen de una línea al pie (como el dockapp).
	var small = frame._push_label_font(shell)
	var col = frame.NX_TEXT if hovered else frame.NX_TEXT_DIM
	var txt = frame._truncate_w(shell, _label(it), side - 6.0)
	shell.set_cursor_pos(local + Vector2(max(3.0, (side - frame._text_w(shell, txt)) * 0.5), side * 0.66))
	shell.text_colored(Color(col.r, col.g, col.b, alpha), txt)
	if small:
		shell.pop_font()
	# Punto de no leída (arriba a la derecha).
	if not bool(it.get("read", false)) and side > 20.0:
		var r = max(2.0, side * 0.06)
		shell.imgui_draw_circle_filled(scr + Vector2(side - r - 4.0 * scale, r + 4.0 * scale), r,
			shell.accent if shell.accent != null else frame.NX_SEL, 10)


func _accent(frame, shell, it):
	if String(it.get("urgency", "normal")) == "critical":
		return Color(0.95, 0.30, 0.24, 1.0)
	return shell.accent if shell.accent != null else frame.NX_TEXT


# --- input (pass-through salvo sobre un bloque) ------------------------------

# Devuelve true si el evento fue consumido por la columna. Un clic fuera de los
# bloques la cierra pero NO se consume (pasa a la app de abajo).
func handle_input(shell, event):
	var n = shell.notify
	if n == null or not active(shell):
		return false
	var mm = event as InputEventMouseMotion
	if mm != null:
		var i = _index_at(Vector2(event.position))
		if i != hover_index:
			hover_index = i
			shell.request_redraw()
		return false
	var mb = event as InputEventMouseButton
	if mb == null:
		return false
	var pos = Vector2(event.position)
	if not mb.pressed:
		if _pressed:
			_pressed = false
			return true
		return false
	var i = _index_at(pos)
	if i >= 0 and i < blocks.size():
		_pressed = true
		var id = int(blocks[i]["id"])
		var it = _item_by_id(n, id)
		if int(mb.button_index) == BUTTON_LEFT:
			_activate(shell, n, it)
		elif int(mb.button_index) == BUTTON_RIGHT:
			n.dismiss(id)
		shell.request_redraw()
		return true
	# Dentro de la columna pero en un hueco entre bloques: consumir sin acción (nunca
	# atravesar a la app).
	if _rect.has_point(pos):
		_pressed = true
		return true
	# Clic fuera: despinchar (cierra) sin consumir.
	if n.panel_open:
		n.panel_open = false
		shell.request_redraw()
	return false


func _index_at(p):
	for i in range(blocks.size()):
		if blocks[i]["rect"].has_point(p):
			return i
	return -1


func _item_by_id(n, id):
	for it in n.items():
		if int(it.get("id", 0)) == id:
			return it
	return {}


# Acción del bloque: enfocar si trae ventana; si no, la acción "default" de la app.
func _activate(shell, n, it):
	if it.empty():
		return
	n.mark_read(int(it.get("id", 0)))
	var win = int(it.get("target_window", 0))
	if win > 0 and shell.has_method("_focus_tile"):
		shell._focus_tile(win)
		n.panel_open = false
		shell.request_redraw()
		return
	var actions = it.get("actions", [])
	if typeof(actions) == TYPE_ARRAY and not actions.empty():
		n.invoke(int(it.get("id", 0)), String(actions[0].get("key", "default")))
	shell.request_redraw()


# --- helpers de contenido ----------------------------------------------------

func _icon(shell, it):
	var icon = String(it.get("icon", ""))
	if icon == "":
		icon = String(it.get("app_id", ""))
	if icon == "":
		return null
	var path = ""
	if shell.apps != null and shell.apps.has_method("resolve_icon"):
		path = shell.apps.resolve_icon(icon)
	if path != "":
		return shell._load_png_file(path)
	return null


func _label(it):
	var s = String(it.get("summary", "")).strip_edges()
	if s == "":
		s = String(it.get("body", "")).strip_edges()
	if s == "":
		s = "(sin texto)"
	return s.replace("##", "# #")


# --- tarjeta de texto al pasar el puntero ------------------------------------

# Muestra summary + body completo (multilínea) del bloque bajo el puntero o de la
# última notificación cuando el puntero está sobre el dockapp. Se dibuja como ventana
# propia (top layer, sin mouse inputs) para no depender del tooltip de ImGui.
func _draw_hover_card(shell):
	var n = shell.notify
	if n == null or not n.hover_card:
		return
	var frame = shell.frame
	if frame == null:
		return
	var it = {}
	var anchor = Vector2.ZERO
	var above = false
	if hover_index >= 0 and hover_index < blocks.size():
		it = _item_by_id(n, int(blocks[hover_index]["id"]))
		var r = blocks[hover_index]["rect"]
		anchor = Vector2(r.position.x + r.size.x + 6.0, r.position.y)
	else:
		if not frame.applet_mods.has("notificaciones"):
			return
		var ap = frame.applet_mods["notificaciones"]
		if ap == null or not ap.hovered:
			return
		it = n.latest()
		var hr = ap.hover_rect
		if hr.size.x <= 0.0:
			return
		anchor = Vector2(hr.position.x + hr.size.x * 0.5 - CARD_W * 0.5, hr.position.y)
		above = true
	if it.empty():
		return
	var vp = shell._screen_size()
	anchor.x = clamp(anchor.x, 6.0, max(6.0, vp.x - CARD_W - 6.0))
	var rows = _card_rows(frame, shell, it)
	var h = CARD_PAD * 2.0 + float(rows.size()) * CARD_LINE
	if above:
		anchor.y -= h + 6.0
	anchor.y = clamp(anchor.y, 6.0, max(6.0, vp.y - h - 6.0))
	shell.set_next_window_pos(anchor, true)
	shell.set_next_window_size(Vector2(CARD_W, h), true)
	shell.set_next_window_bg_alpha(0.0)
	shell.push_style_var_vec2(shell.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	var flags = shell.WINDOW_NO_DECORATION | shell.WINDOW_NO_BACKGROUND | shell.WINDOW_NO_MOVE \
		| shell.WINDOW_NO_RESIZE | shell.WINDOW_NO_SAVED_SETTINGS | shell.WINDOW_NO_TITLE_BAR \
		| shell.WINDOW_NO_COLLAPSE | shell.WINDOW_NO_BRING_TO_FRONT_ON_FOCUS \
		| shell.WINDOW_NO_SCROLLBAR | WINDOW_NO_MOUSE_INPUTS | WINDOW_TOP_LAYER
	if shell.begin("##gdtk_notif_card", flags):
		# Fondo sólido propio (la ventana no trae background) + borde, para que el
		# texto se lea sobre cualquier cosa de abajo (p. ej. ventana fullscreen).
		# OJO: imgui_draw_rect_filled usa coordenadas de PANTALLA, no locales.
		var bg = frame.NX_BG
		shell.imgui_draw_rect_filled(Rect2(anchor, Vector2(CARD_W, h)),
			Color(bg.r, bg.g, bg.b, 0.97), 4.0)
		var hi = frame.NX_LIGHT
		var lo = frame.NX_DARK
		shell.imgui_draw_rect_filled(Rect2(anchor, Vector2(CARD_W, 1.0)), hi, 0.0)
		shell.imgui_draw_rect_filled(Rect2(anchor, Vector2(1.0, h)), hi, 0.0)
		shell.imgui_draw_rect_filled(Rect2(anchor + Vector2(0.0, h - 1.0), Vector2(CARD_W, 1.0)), lo, 0.0)
		shell.imgui_draw_rect_filled(Rect2(anchor + Vector2(CARD_W - 1.0, 0.0), Vector2(1.0, h)), lo, 0.0)
		var icon = _icon(shell, it)
		var x0 = CARD_PAD
		if icon != null:
			var g = CARD_LINE * 1.6
			shell.set_cursor_pos(Vector2(CARD_PAD, CARD_PAD))
			shell.image(icon, Vector2(g, g), Color(1, 1, 1, 1.0))
			x0 = CARD_PAD + g + 6.0
		var y = CARD_PAD
		for k in range(rows.size()):
			var x = x0 if k == 0 else CARD_PAD
			shell.set_cursor_pos(Vector2(x, y))
			shell.text_colored(rows[k].get("color", frame.NX_TEXT), String(rows[k].get("text", "")))
			y += CARD_LINE
	shell.end()
	shell.pop_style_var()


func _card_rows(frame, ui, it):
	var rows = []
	var app = String(it.get("app", ""))
	if app != "":
		rows.append({"text": frame._truncate_w(ui, app, CARD_W - 2.0 * CARD_PAD), "color": frame.NX_TEXT_DIM})
	var summary = String(it.get("summary", "")).strip_edges()
	if summary != "":
		rows.append({"text": frame._truncate_w(ui, summary, CARD_W - 2.0 * CARD_PAD), "color": frame.NX_TEXT})
	var body = String(it.get("body", "")).strip_edges()
	if body != "" and body != summary:
		for line in _wrap(frame, ui, body, CARD_W - 2.0 * CARD_PAD):
			rows.append({"text": line, "color": frame.NX_TEXT})
	var stamp = _stamp(it)
	if stamp != "":
		rows.append({"text": stamp, "color": frame.NX_TEXT_DIM})
	if rows.empty():
		rows.append({"text": "(sin texto)", "color": frame.NX_TEXT_DIM})
	return rows


func _wrap(frame, ui, text, maxw):
	var out = []
	for raw in String(text).split("\n"):
		var line = ""
		for word in String(raw).split(" ", false):
			var cand = word if line == "" else line + " " + word
			if line != "" and frame._text_w(ui, cand) > maxw:
				out.append(line)
				line = word
			else:
				line = cand
		out.append(line)
	return out


func _stamp(it):
	var c = int(it.get("created_ms", 0))
	if c <= 0:
		return ""
	var d = OS.get_datetime_from_unix_time(int(c / 1000))
	return "%02d:%02d" % [int(d.get("hour", 0)), int(d.get("minute", 0))]
