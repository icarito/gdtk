extends Reference

# Dockapp de notificaciones del Frame (SPEC-notificaciones.md).
#
# No tiene worker propio: el bus vive en el shell (`shell/notify.gd`) y este módulo
# sólo copia su snapshot (`refresh`) y dibuja la última notificación. El Frame le
# asigna `notif` en `_ready()`.
#
# Contrato de dockapp: `.operator-shared/guides/dockapp.md` (state/value/detail,
# refresh(force) -> bool, stop(), draw opcional).

var state = "sin_dato"
var value = ""
var detail = ""
var icon_path = ""      # ruta resuelta del ícono de la app ("" si no hay)
var unread = 0
var total = 0

# Lo asigna el Frame: el bus central (`shell.notify`).
var notif = null


func refresh(_force := false):
	if notif == null:
		var changed = state != "sin_dato" or value != "" or detail != ""
		state = "sin_dato"
		value = ""
		detail = ""
		icon_path = ""
		return changed
	var l = notif.latest()
	var new_items = notif.items()
	var n_state = "activo" if not l.empty() else "listo"
	var n_value = label(l)
	var n_detail = tooltip(l, new_items.size())
	var n_icon = ""
	var n_unread = 0
	for it in new_items:
		if not bool(it.get("read", false)):
			n_unread += 1
	if not l.empty():
		n_icon = resolve_icon_name(l.get("icon", ""), l.get("app_id", ""))
	var changed = state != n_state or value != n_value or detail != n_detail \
		or icon_path != n_icon or unread != n_unread or total != new_items.size()
	state = n_state
	value = n_value
	detail = n_detail
	icon_path = n_icon
	unread = n_unread
	total = new_items.size()
	return changed


# Sin worker propio: el bus vive en el shell.
func stop():
	pass


func draw(frame, ui, scr, loc, w, h):
	var g = min(w, h) * 0.46
	var col = frame._lcd(frame.NX_TEXT, "on" if state == "activo" else "off")
	var tex = null
	if icon_path != "" and frame.shell != null:
		tex = frame.shell._load_png_file(icon_path)
	if tex == null:
		# Sin ícono de app: campana genérica del tema Sugar (o glifo propio).
		if frame.shell != null:
			tex = frame.shell._load_sugar_svg("notifications",
				Color(0.88, 0.90, 0.95, 1.0), Color(0.97, 0.96, 0.92, 1.0))
	if tex != null:
		ui.set_cursor_pos(loc + Vector2((w - g) * 0.5, h * 0.08))
		ui.image(tex, Vector2(g, g))
	else:
		frame._draw_shared_glyph(ui, Rect2(scr + Vector2((w - g) * 0.5, h * 0.10), Vector2(g, g)),
			"clipboard", col)
	var text = value
	if state != "activo":
		text = "sin notif."
	var small = frame._push_label_font(ui)
	text = frame._truncate_w(ui, text, w - 6.0)
	ui.set_cursor_pos(loc + Vector2(max(3.0, (w - frame._text_w(ui, text)) * 0.5), h * 0.66))
	ui.text_colored(col, text)
	# Insignia de no leídas (esquina superior derecha): puntito con el acento.
	if unread > 0 and w > 20.0:
		var r = max(2.0, min(w, h) * 0.09)
		ui.imgui_draw_circle_filled(scr + Vector2(w - r - 2.0, r + 2.0), r,
			frame.shell.accent if frame.shell != null else Color(0.55, 0.80, 1.0), 8)
	if small:
		ui.pop_font()


# --- puro (testeable) --------------------------------------------------------

# Etiqueta corta de una notificación: el resumen; si viene vacío, el cuerpo; si no,
# "(sin texto)". Recortada a `limit` (o SUMMARY_MAX).
static func label(record, limit = 40):
	if typeof(record) != TYPE_DICTIONARY or record.empty():
		return ""
	var s = String(record.get("summary", "")).strip_edges()
	if s == "":
		s = summary(String(record.get("body", "")))
	if s == "":
		s = "(sin texto)"
	var lim = int(limit)
	if lim > 0 and s.length() > lim:
		s = s.substr(0, lim)
	return s


# Primera línea no vacía con espacios colapsados (mismo criterio que Portapapeles).
static func summary(text):
	for line in String(text).split("\n", false):
		var s = String(line).strip_edges().replace("\t", " ")
		while s.find("  ") >= 0:
			s = s.replace("  ", " ")
		if s != "":
			return s
	return ""


static func tooltip(record, count):
	if typeof(record) != TYPE_DICTIONARY or record.empty():
		return "Notificaciones: sin novedades"
	var app = String(record.get("app", ""))
	var body = String(record.get("body", ""))
	var head = label(record, -1)
	var text = ("%s: %s" % [app, head]) if app != "" else head
	if body != "" and body != head:
		text += "\n\n" + body
	return "%s\n\n%d en el historial" % [text, int(count)]


# Nombre/ícono del registro: prefiere `icon`, cae a `app_id`.
static func resolve_icon_name(icon, app_id):
	var i = String(icon)
	if i != "":
		return i
	return String(app_id)


# --- selftest (puro) ---------------------------------------------------------

static func selftest():
	assert(label({}) == "")
	assert(label({"summary": "Hola"}) == "Hola")
	assert(label({"body": "cuerpo\nmás"}) == "cuerpo")
	assert(label({"summary": "x"}, 1) == "x")
	assert(summary("\n\n  a   b \n c") == "a b")
	assert(resolve_icon_name("firefox", "org.mozilla") == "firefox")
	assert(resolve_icon_name("", "org.mozilla") == "org.mozilla")
	print("applet_notif selftest ok")
