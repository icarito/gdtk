extends "res://pages/page.gd"

# Página Pantallas (K11b): diseno de la disposicion local-vecinos, estilo GNOME.
# Arrastrar mueve; al soltar se imanta para quedar pegada por un borde (contacto
# minimo > 0, sin solaparse) y permite deslizarse a lo largo del borde.
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

var SL = null
var canvas = null
var status_label = null
var layout = {}

var drag_id = ""
var drag_grab = Vector2.ZERO

var scale = 1.0
var origin = Vector2.ZERO
var bbox = Rect2()

const DIR_LABELS = {"north": "Norte", "south": "Sur", "east": "Este", "west": "Oeste"}


func _build():
	SL = _load_model()
	h_title("Pantallas")
	h_note("Arrastra los equipos para ordenarlos alrededor de Este equipo. Al soltar se pegan por un borde; guarda con Aplicar.")
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
	_build_sizes()


# La geometria usa tamaño fisico; resolución queda como metadata para gvd/UI.
func _build_sizes():
	h_gap(6)
	h_note("Tamaño físico (cm) y resolución (px). La disposición usa los centímetros.")
	var row = h_row()
	h_label("Este equipo", row)
	_dim_spin(layout.local.w / 10.0, row, layout.local.id, true)
	_dim_spin(layout.local.h / 10.0, row, layout.local.id, false)
	_px_spin(layout.local.px_w, row, layout.local.id, true)
	_px_spin(layout.local.px_h, row, layout.local.id, false)
	for sc in layout.screens:
		row = h_row()
		h_label(_label_of(sc), row)
		_dim_spin(sc.w / 10.0, row, sc.id, true)
		_dim_spin(sc.h / 10.0, row, sc.id, false)
		_px_spin(sc.px_w, row, sc.id, true)
		_px_spin(sc.px_h, row, sc.id, false)


func _dim_spin(value, row, sc_id, is_w):
	var sp = SpinBox.new()
	sp.min_value = 5
	sp.max_value = 300
	sp.step = 0.1
	sp.value = float(value)
	sp.suffix = " cm"
	sp.rect_min_size.x = 88
	sp.connect("value_changed", self, "_on_dim_changed", [String(sc_id), bool(is_w)])
	row.add_child(sp)
	return sp


func _px_spin(value, row, sc_id, is_w):
	var sp = SpinBox.new()
	sp.min_value = 100
	sp.max_value = 16384
	sp.step = 1
	sp.value = float(value)
	sp.suffix = " px"
	sp.rect_min_size.x = 104
	sp.connect("value_changed", self, "_on_px_changed", [String(sc_id), bool(is_w)])
	row.add_child(sp)
	return sp


func _on_dim_changed(value, sc_id, is_w):
	_apply_size(sc_id, value * 10.0 if is_w else null, null if is_w else value * 10.0)
	# Cambiar el tamaño físico puede dejar un hueco con el vecino: sin contacto no
	# hay enlace Deskflow y el puntero deja de cruzar.
	drag_id = String(sc_id)
	_snap_release()
	drag_id = ""
	if canvas != null:
		canvas.update()
	_commit()


func _on_px_changed(value, sc_id, is_w):
	_apply_pixels(sc_id, int(value) if is_w else null, null if is_w else int(value))
	_commit()


func _apply_size(id, w, h):
	if String(id) == String(layout.local.id):
		if w != null:
			layout.local.w = float(w)
		if h != null:
			layout.local.h = float(h)
		return
	for i in range(layout.screens.size()):
		if String(layout.screens[i].id) == String(id):
			if w != null:
				layout.screens[i].w = float(w)
			if h != null:
				layout.screens[i].h = float(h)
			return


func _apply_pixels(id, w, h):
	var sc = layout.local if String(id) == String(layout.local.id) else null
	if sc == null:
		for item in layout.screens:
			if String(item.id) == String(id):
				sc = item
				break
	if sc == null:
		return
	if w != null:
		sc.px_w = int(w)
	if h != null:
		sc.px_h = int(h)


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
			drag_id = _hit(event.position)
			if drag_id != "":
				drag_grab = _plane_of(event.position) - _screen_pos(drag_id)
				canvas.update()
		elif drag_id != "":
			_snap_release()
			drag_id = ""
			canvas.update()
	elif event is InputEventMouseMotion and drag_id != "":
		var p = _plane_of(event.position) - drag_grab
		_set_pos(drag_id, p.x, p.y)
		canvas.update()


func _snap_release():
	var sc = SL.screen_by_id(layout, drag_id)
	if sc == null:
		return
	var sn = SL.snap(SL.all_screens(layout), drag_id, sc.x, sc.y)
	if bool(sn.snapped):
		_set_pos(drag_id, float(sn.x), float(sn.y))
	_commit()


func _set_pos(id, x, y):
	if String(id) == String(layout.local.id):
		return
	for i in range(layout.screens.size()):
		if layout.screens[i].id == String(id):
			layout.screens[i].x = float(x)
			layout.screens[i].y = float(y)
			return


func _screen_pos(id):
	var sc = SL.screen_by_id(layout, id)
	return Vector2(sc.x, sc.y) if sc != null else Vector2.ZERO


func _hit(mouse):
	var items = SL.all_screens(layout)
	for i in range(items.size() - 1, -1, -1):
		var sc = items[i]
		if sc.local:
			continue
		if SL.rect(sc).has_point(_plane_of(mouse)):
			return sc.id
	return ""


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
