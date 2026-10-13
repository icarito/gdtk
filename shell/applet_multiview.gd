extends Reference

# Dockapp "Vista del grupo" (multiview del portal ScreenCast, SPEC-multiview-portal).
# Indica el modo del portal, permite prender/apagar, activar el pan y el zoom, y dibuja
# un mini-radar DISTINTIVO del radar de hosts: bloques = pantallas del layout (la local
# resaltada) y un marco ámbar = viewport (ventana) de la composición.
#
# Interacción (la rutea el Frame):
#   - clic izquierdo  -> prende/apaga la Vista del grupo (multiview). Al apagarla, el
#     shell corta los gvd (receptores locales + emisores de los peers).
#   - rueda del mouse -> zoom in/out.
var shell = null
var state = "apagado"
var value = ""
var detail = ""
var _st = {}


func refresh(_force := false):
	var os_state = state
	var os_value = value
	var os_detail = detail
	var st = null
	if shell != null and shell.has_method("multiview_status"):
		st = shell.multiview_status()
	if typeof(st) != TYPE_DICTIONARY:
		state = "no_disponible"
		value = "--"
		detail = "shell sin multiview"
		return state != os_state or value != os_value or detail != os_detail
	_st = st
	var on = bool(st.get("on", false))
	var en = bool(st.get("enabled", false))
	var zoom = float(st.get("zoom", 1.7))
	var pan = bool(st.get("pan", true))
	if on:
		state = "activo"
		value = ("PAN " if pan else "FIJ ") + "x%.1f" % zoom
	elif en:
		state = "listo"
		value = "armado"
	else:
		state = "apagado"
		value = "off"
	detail = "Vista del grupo %s · portal=%s · %d peers · zoom x%.1f · pan %s" % [
		("encendida" if on else ("armada" if en else "apagada")),
		("compartiendo" if bool(st.get("share", false)) else "off"),
		int(st.get("peers", 0)), zoom, ("sí" if pan else "no")]
	return state != os_state or value != os_value or detail != os_detail


func stop():
	pass


func draw(frame, ui, scr, loc, w, h):
	var st = _st
	if typeof(st) != TYPE_DICTIONARY or st.empty():
		return
	var on = bool(st.get("on", false))
	var top = 11.0
	var pad = 3.0
	var box = Rect2(Vector2(scr.x + pad, scr.y + top),
		Vector2(max(4.0, w - pad * 2.0), max(4.0, h - top - pad)))
	ui.imgui_draw_rect_filled(box, Color(0.04, 0.05, 0.06, 0.65), 2.0)
	var mini = st.get("mini", {})
	var rects = mini.get("rects", []) if typeof(mini) == TYPE_DICTIONARY else []
	for r in rects:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var f = r.get("rect", Rect2())
		var rr = Rect2(box.position + Vector2(f.position.x * box.size.x, f.position.y * box.size.y),
			Vector2(max(1.0, f.size.x * box.size.x), max(1.0, f.size.y * box.size.y)))
		var col = Color(0.13, 0.79, 0.77, 0.95) if bool(r.get("local", false)) \
			else Color(0.75, 0.78, 0.85, 0.72)
		ui.imgui_draw_rect_filled(rr, col, 1.0)
	if on:
		var vp = mini.get("viewport", Rect2(0.0, 0.0, 1.0, 1.0))
		var a = box.position + Vector2(vp.position.x * box.size.x, vp.position.y * box.size.y)
		var b = a + Vector2(max(3.0, vp.size.x * box.size.x), max(3.0, vp.size.y * box.size.y))
		var oc = Color(1.0, 0.72, 0.2, 0.95)
		ui.imgui_draw_line(a, Vector2(b.x, a.y), oc, 1.5)
		ui.imgui_draw_line(Vector2(b.x, a.y), b, oc, 1.5)
		ui.imgui_draw_line(b, Vector2(a.x, b.y), oc, 1.5)
		ui.imgui_draw_line(Vector2(a.x, b.y), a, oc, 1.5)
	# Rótulo: "MV" encendido / "mv" apagado / "M!" sin shell.
	var txt = "MV" if on else ("ma" if bool(st.get("enabled", false)) else "mv")
	frame._push_label_font(ui)
	ui.set_cursor_pos(Vector2(loc.x + 3.0, loc.y + 0.5))
	ui.text_colored(frame.NX_TEXT if on else frame.NX_TEXT_DIM, txt)
	ui.pop_font()
