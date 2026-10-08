extends "res://pages/page.gd"


# Página Pantallas (K11b): diseno de la disposicion local-vecinos, estilo GNOME.
# Arrastrar mueve con imán en vivo (SL.live_snap): por eje se imanta a bordes
# filas/columnas/centros de las demás dentro de SL.MAGNET_TOL. Al soltar, si ya
# toca a alguien queda tal cual; si no, el snap de contacto (> 0, sin solaparse).
# Los bordes y las esquinas redimensionan (SL.resize_live) respetando el aspect
# ratio de la resolución, y el imán evita contactos al 1%/99%.
#
# Toda la geometria vive en el modelo puro shell/screen_layout.gd (otro proyecto
# Godot; se compila desde el fuente, mismo patron que shell/settings_bridge.gd).
# Aca sólo hay presentacion e input; la posicion se guarda en settings["screens"]
# y se persiste con el botón Aplicar de la ventana (Revertir deshace).
#
# Vocabulario visible: Este equipo, Equipo N, Norte/Sur/Este/Oeste. Los ids
# internos (hid) nunca se muestran.

const MODEL_PATH = "shell/screen_layout.gd"
const DIRS_FILE = "neighborhood-directions.json"
const PAD = 48.0
const HANDLE_HIT = 7.0   # px del lienzo para tomar un borde/esquina

var SL = null
var canvas = null
var status_label = null
var layout = {}

var drag_id = ""
var drag_handle = ""
var drag_grab = Vector2.ZERO
var drag_pre = null      # rect previo al resize (para revertir si queda solape)
var guides = []
var hover_handle = ""

var scale = 1.0
var origin = Vector2.ZERO
var bbox = Rect2()

const DIR_LABELS = {"north": "Norte", "south": "Sur", "east": "Este", "west": "Oeste"}


func _build():
	SL = _load_model()
	h_title("Pantallas")
	h_note("Arrastra los equipos: se atraen entre sí (bordes y alineaciones). Al soltar quedan pegados; guarda con Aplicar.")
	h_gap(6)

	canvas = Control.new()
	canvas.rect_min_size = Vector2(520, 320)
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.connect("draw", self, "_draw_canvas")
	canvas.connect("gui_input", self, "_canvas_input")
	canvas.connect("resized", self, "_on_resized")
	box.add_child(canvas)

	status_label = STYLE.note("")
	box.add_child(status_label)

	layout = _ensure_layout()
	_refresh_status()


# El tamano de cada pantalla se ajusta arrastrando sus bordes/esquinas en el
# lienzo (SL.resize_live, con aspect ratio de la resolucion fijo); no hay
# campos numéricos manuales. El local conserva el tamano fisico medido (OS).


func _on_resized():
	if canvas != null:
		canvas.update()


# --- Modelo -------------------------------------------------------------------

func _repo_root():
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _load_model():
	if SL != null:
		return SL
	var path = _repo_root().plus_file(MODEL_PATH)
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return null
	var src = f.get_as_text()
	f.close()
	var g = GDScript.new()
	g.set_source_code(src)
	if g.reload() != OK:
		return null
	return g.new()


func _config_dir():
	var override = OS.get_environment("GDTK_SETTINGS")
	if override != "":
		return override.get_base_dir()
	var xdg = OS.get_environment("XDG_CONFIG_HOME")
	if xdg != "":
		return xdg.plus_file("gdtk")
	return OS.get_environment("HOME").plus_file(".config").plus_file("gdtk")


# Direcciones persistidas por el shell (fuente unica de Pantalla y Teclado y
# mouse). Solo se usan los ids para poblar el catalogo y precargar posiciones.
func _stored_directions():
	var f = File.new()
	if f.open(_config_dir().plus_file(DIRS_FILE), File.READ) != OK:
		return {}
	var txt = f.get_as_text()
	f.close()
	var data = JSON.parse(txt).result
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	return data


func _safe_peer(s):
	var out = ""
	var raw = String(s)
	for i in range(raw.length()):
		var c = raw.substr(i, 1)
		if "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".find(c) >= 0:
			out += c
		else:
			out += "_"
	out = out.strip_edges()
	if out == "" or out.begins_with(".") or out.begins_with("-") \
			or out.ends_with(".") or out.ends_with("-"):
		return "equipo"
	return out


# Catalogo de vecinos conocidos: los ya guardados en el layout o los que el shell
# publicó en su archivo de direcciones.
func _catalog():
	var stored = settings.get("screens", {})
	var stored_screens = stored.get("screens", []) if typeof(stored) == TYPE_DICTIONARY else []
	if typeof(stored_screens) == TYPE_ARRAY and not stored_screens.empty():
		return stored_screens
	var dirs = _stored_directions()
	var keys = dirs.keys()
	keys.sort()
	var out = []
	var n = 0
	for k in keys:
		var id = String(k)
		if id == "":
			continue
		n += 1
		out.append({"id": id, "label": "Equipo " + str(n), "peer": _safe_peer(id),
			"w": SL.DEFAULT_W, "h": SL.DEFAULT_H})
	return out


func _ensure_layout():
	var stored = settings.get("screens", {})
	if SL == null:
		return {"version": 2, "local": {"id": "local", "label": "Este equipo", "local": true,
			"x": 0.0, "y": 0.0, "w": 340.0, "h": 212.5, "px_w": 1280, "px_h": 800}, "screens": []}
	var lay = SL.normalize_layout(stored if typeof(stored) == TYPE_DICTIONARY else {})
	var size = OS.get_screen_size()
	if size.x > 0.0 and size.y > 0.0:
		lay.local.px_w = int(size.x)
		lay.local.px_h = int(size.y)
		# El tamano fisico del local sigue a la resolucion medida (mismo
		# aspect ratio); el resize interactivo solo toca a los vecinos y el
		# caret de tamaño manual ya no existe.
		var ar = float(size.x) / float(size.y)
		if abs(float(lay.local.w) / float(lay.local.h) - ar) > 0.01:
			lay.local.h = float(lay.local.w) / ar
	if lay.screens.empty():
		for c in _catalog():
			var sc = SL.default_screen(String(c.get("id", "")), String(c.get("label", "")))
			if sc.id == "":
				continue
			sc.peer = String(c.get("peer", ""))
			sc.w = float(c.get("w", SL.DEFAULT_W))
			sc.h = float(c.get("h", SL.DEFAULT_H))
			sc.px_w = int(c.get("px_w", SL.DEFAULT_PX_W))
			sc.px_h = int(c.get("px_h", SL.DEFAULT_PX_H))
			lay.screens.append(sc)
	return lay


func _commit():
	settings["screens"] = layout
	host.set_field("screens", layout)
	_refresh_status()


# --- Input --------------------------------------------------------------------

func _canvas_input(event):
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			var hit = _hit_handle(event.position)
			drag_handle = ""
			drag_id = ""
			if hit.id != "":
				drag_id = String(hit.id)
				drag_handle = String(hit.handle)
				guides = []
				if drag_handle == "":
					drag_grab = _plane_of(event.position) - _screen_pos(drag_id)
				else:
					drag_pre = SL.rect(SL.screen_by_id(layout, drag_id))
				canvas.update()
			_update_cursor("")
		elif drag_id != "":
			_snap_release()
			drag_id = ""
			drag_handle = ""
			drag_pre = null
			guides = []
			canvas.update()
			_update_cursor("")
	elif event is InputEventMouseMotion:
		var plane = _plane_of(event.position)
		if drag_id != "" and drag_handle == "":
			_drag_magnet(plane - drag_grab)
			canvas.update()
		elif drag_id != "" and drag_handle != "":
			_drag_resize(plane)
			canvas.update()
		else:
			_update_cursor(_hit_handle(event.position).handle)


# Imán en vivo del movimiento: cada eje dentro del alcance (SL.MAGNET_TOL)
# contra bordes/filas/columnas/centros de las demás pantallas, con guías.
func _drag_magnet(p):
	var sn = SL.live_snap(SL.all_screens(layout), drag_id, p.x, p.y, SL.MAGNET_TOL)
	_set_pos(drag_id, float(sn.x), float(sn.y))
	guides = sn.guides


# Redimension: borde/esquina con aspect ratio fijo (SL.resize_live). Si el
# resultado solapea (ok=false), ese frame no se aplica: la pantalla se quedara
# en el último rect válido.
func _drag_resize(p):
	var sn = SL.resize_live(SL.all_screens(layout), drag_id, drag_handle, p.x, p.y, SL.MAGNET_TOL)
	if typeof(sn) != TYPE_DICTIONARY or not bool(sn.get("ok", false)):
		guides = []
		return
	guides = sn.guides
	_set_rect(drag_id, float(sn.x), float(sn.y), float(sn.w), float(sn.h))


func _snap_release():
	var sc = SL.screen_by_id(layout, drag_id)
	if sc == null:
		guides = []
		return
	guides = []
	if drag_handle != "":
		# Redimension: si el rect final solapea, se vuelve al previo.
		if not SL.fits(SL.all_screens(layout), drag_id, sc.x, sc.y, sc.w, sc.h):
			_set_rect(drag_id, float(drag_pre.position.x), float(drag_pre.position.y),
				float(drag_pre.size.x), float(drag_pre.size.y))
		_commit()
		return
	# Movimiento: si el imán ya dejó la pantalla tocando a alguien, queda tal
	# cual (sin salto al soltar).
	if SL.has_contact(SL.all_screens(layout), drag_id):
		_commit()
		return
	var sn = SL.snap(SL.all_screens(layout), drag_id, sc.x, sc.y)
	if bool(sn.snapped):
		_set_pos(drag_id, float(sn.x), float(sn.y))
	_commit()


func _set_rect(id, x, y, w, h):
	if String(id) == String(layout.local.id):
		return
	for i in range(layout.screens.size()):
		if layout.screens[i].id == String(id):
			layout.screens[i].x = float(x)
			layout.screens[i].y = float(y)
			layout.screens[i].w = float(w)
			layout.screens[i].h = float(h)
			return


func _set_pos(id, x, y):
	if String(id) == String(layout.local.id):
		return
	for i in range(layout.screens.size()):
		if layout.screens[i].id == String(id):
			layout.screens[i].x = float(x)
			layout.screens[i].y = float(y)
			return


# Cursor por asa: los nombres salen de _hit_handle (un borde o dos).
func _update_cursor(handle):
	var shape = Input.CURSOR_ARROW
	match String(handle):
		"e", "w":
			shape = Input.CURSOR_HSIZE
		"n", "s":
			shape = Input.CURSOR_VSIZE
		"en", "ws":
			shape = Input.CURSOR_BDIAGSIZE
		"wn", "es":
			shape = Input.CURSOR_FDIAGSIZE
	Input.set_default_cursor_shape(shape)


func _screen_pos(id):
	var sc = SL.screen_by_id(layout, id)
	return Vector2(sc.x, sc.y) if sc != null else Vector2.ZERO


# Asas de resize: bordes y esquinas de cada pantalla del vecindario (el local
# es fijo: su tamano físico lo mide el shell). handle "" = mover.
# {id, handle}: interior (handle "") = mover; borde/esquina = redimensionar.
func _hit_handle(mouse):
	var r = {"id": "", "handle": ""}
	if scale <= 0.0:
		return r
	var plane = _plane_of(mouse)
	var tol = HANDLE_HIT / scale
	var items = SL.all_screens(layout)
	for i in range(items.size() - 1, -1, -1):
		var sc = items[i]
		if sc.local:
			continue
		var rc = SL.rect(sc)
		# Con el lienzo muy reducido 7 px de asa son demasiados mm: el asa
		# nunca ocupa mas de un tercio del lado (si no, todo seria borde).
		var tl = min(tol, min(float(rc.size.x), float(rc.size.y)) * 0.33)
		if not rc.grow(tl).has_point(plane):
			continue
		var x0 = float(rc.position.x)
		var y0 = float(rc.position.y)
		var x1 = x0 + float(rc.size.x)
		var y1 = y0 + float(rc.size.y)
		var at_l = abs(plane.x - x0) <= tl
		var at_r = abs(plane.x - x1) <= tl
		var at_t = abs(plane.y - y0) <= tl
		var at_b = abs(plane.y - y1) <= tl
		var handle = ""
		if at_r and plane.y >= y0 - tol and plane.y <= y1 + tol:
			handle += "e"
		elif at_l and plane.y >= y0 - tol and plane.y <= y1 + tol:
			handle += "w"
		if at_b and plane.x >= x0 - tol and plane.x <= x1 + tol:
			handle += "s"
		elif at_t and plane.x >= x0 - tol and plane.x <= x1 + tol:
			handle += "n"
		r.id = String(sc.id)
		r.handle = handle
		return r
	return r


# --- Dibujo -------------------------------------------------------------------

func _draw_canvas():
	var font = get_font("font", "Label")
	canvas.draw_rect(Rect2(Vector2.ZERO, canvas.rect_size), STYLE.BG, true)
	if SL == null or typeof(layout) != TYPE_DICTIONARY:
		if font != null:
			canvas.draw_string(font, Vector2(PAD, PAD), "No se pudo cargar el diseno de pantallas", STYLE.WARN)
		return
	_compute_fit()
	for sc in SL.all_screens(layout):
		var cr = _canvas_rect(sc)
		var col = STYLE.SELECT if sc.local else STYLE.FACE
		canvas.draw_rect(cr, col, true)
		canvas.draw_rect(cr, STYLE.LIGHT, false)
		if sc.id == drag_id:
			canvas.draw_rect(cr, STYLE.WARN, false, 2.0)
		if font != null and cr.size.x > 40.0:
			canvas.draw_string(font, cr.position + Vector2(8, 20), _label_of(sc), STYLE.TEXT)
			if cr.size.y > 34.0:
				canvas.draw_string(font, cr.position + Vector2(8, 20 + font.get_height()), _size_of(sc), STYLE.DIM)
	# Porcentaje del tramo compartido en cada contacto (como los rangos de Deskflow):
	# con pantallas de distinta resolución deja ver cuánto borde se usa realmente.
	if font != null:
		for e in SL.edges(layout):
			var a = SL.screen_by_id(layout, String(e.get("from", "")))
			var b = SL.screen_by_id(layout, String(e.get("to", "")))
			if a == null or b == null:
				continue
			var r = SL.link_ranges(a, b)
			if r.empty():
				continue
			var ra = SL.rect(a)
			var rb = SL.rect(b)
			var dir = String(r.get("direction", ""))
			var mid = Vector2.ZERO
			if dir == "east" or dir == "west":
				var x = (ra.position.x + ra.size.x) if dir == "east" else ra.position.x
				var y0 = max(ra.position.y, rb.position.y)
				var y1 = min(ra.position.y + ra.size.y, rb.position.y + rb.size.y)
				mid = Vector2(x, (y0 + y1) * 0.5)
			else:
				var y = (ra.position.y + ra.size.y) if dir == "south" else ra.position.y
				var x0 = max(ra.position.x, rb.position.x)
				var x1 = min(ra.position.x + ra.size.x, rb.position.x + rb.size.x)
				mid = Vector2((x0 + x1) * 0.5, y)
			var t = str(int(round(float(r.get("overlap_pct", 0.0))))) + "%"
			var cp = _canvas_of(mid)
			canvas.draw_string(font, cp + Vector2(-font.get_string_size(t).x * 0.5, -4), t, STYLE.WARN)
	if layout.screens.empty() and font != null:
		canvas.draw_string(font, Vector2(PAD, PAD), "No hay otros equipos", STYLE.DIM)
	# Asas tomadas: franja en el borde o cuadrado en la esquina arrastrada.
	if drag_id != "" and drag_handle != "":
		for sc in SL.all_screens(layout):
			if String(sc.id) != String(drag_id):
				continue
			var cr = _canvas_rect(sc)
			var th = 3.0
			var hnd = String(drag_handle)
			if hnd.find("e") >= 0:
				canvas.draw_rect(Rect2(cr.position.x + cr.size.x - 4.0, cr.position.y, th, cr.size.y), STYLE.WARN)
			if hnd.find("w") >= 0:
				canvas.draw_rect(Rect2(cr.position.x + 1.0, cr.position.y, th, cr.size.y), STYLE.WARN)
			if hnd.find("s") >= 0:
				canvas.draw_rect(Rect2(cr.position.x, cr.position.y + cr.size.y - 4.0, cr.size.x, th), STYLE.WARN)
			if hnd.find("n") >= 0:
				canvas.draw_rect(Rect2(cr.position.x, cr.position.y + 1.0, cr.size.x, th), STYLE.WARN)
	# Guías del imán: líneas donde el arrastre se imanta (columnas y filas).
	for g in guides:
		var v = float(g.get("value", 0.0))
		if String(g.get("axis", "")) == "x":
			var gx = _canvas_of(Vector2(v, 0.0)).x
			canvas.draw_line(Vector2(gx, 0.0), Vector2(gx, canvas.rect_size.y), STYLE.WARN, 1.0)
		else:
			var gy = _canvas_of(Vector2(0.0, v)).y
			canvas.draw_line(Vector2(0.0, gy), Vector2(canvas.rect_size.x, gy), STYLE.WARN, 1.0)


func _size_of(sc):
	return "%.1f×%.1f cm · %d×%d px" % [float(sc.w) / 10.0, float(sc.h) / 10.0,
		int(sc.px_w), int(sc.px_h)]


func _label_of(sc):
	if sc.local:
		return "Este equipo"
	return String(sc.label) if String(sc.label) != "" else "Equipo"


func _compute_fit():
	bbox = Rect2()
	var first = true
	for sc in SL.all_screens(layout):
		var r = SL.rect(sc)
		if first:
			bbox = r
			first = false
		else:
			bbox = bbox.merge(r)
	if bbox.size.x <= 0.0 or bbox.size.y <= 0.0:
		scale = 1.0
		origin = Vector2.ZERO
		return
	var avail = canvas.rect_size - Vector2(PAD, PAD) * 2.0
	if avail.x <= 1.0 or avail.y <= 1.0:
		scale = 0.05
	else:
		scale = min(avail.x / bbox.size.x, avail.y / bbox.size.y)
	scale = max(scale, 0.02)
	var drawn = bbox.size * scale
	origin = (canvas.rect_size - drawn) * 0.5 - bbox.position * scale


func _canvas_of(plane):
	return plane * scale + origin


func _plane_of(canvas_pos):
	if scale <= 0.0:
		return Vector2.ZERO
	return (canvas_pos - origin) / scale


func _canvas_rect(sc):
	var r = SL.rect(sc)
	return Rect2(_canvas_of(r.position), r.size * scale)


func _refresh_status():
	if status_label == null:
		return
	if SL == null:
		status_label.text = "No se pudo cargar el diseno de pantallas."
		status_label.add_color_override("font_color", STYLE.WARN)
		return
	if typeof(layout) != TYPE_DICTIONARY:
		status_label.text = ""
		return
	var outs = SL.output(layout)
	if outs.empty():
		if layout.screens.empty():
			status_label.text = "No hay otros equipos. Se muestran los equipos cercanos cuando aparezcan."
		else:
			status_label.text = "Ningún equipo está colocado. Arrástralo hasta pegar su borde a otro."
		status_label.add_color_override("font_color", STYLE.DIM)
		return
	var parts = PoolStringArray()
	for e in outs:
		var dir = String(DIR_LABELS.get(String(e.direction), e.direction))
		parts.append(String(e.label) + ": al " + dir)
	status_label.text = " · ".join(parts)
	status_label.add_color_override("font_color", STYLE.DIM)
