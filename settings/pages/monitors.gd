extends "res://pages/page.gd"

# Página Monitores (SPEC-physical-multi-monitor.md): configura el escritorio
# extendido multi-monitor del shell. Hasta ahora el modo span se activaba por
# variable de entorno; acá vive el ajuste persistente en settings["span"]:
#   enabled: usar todos los monitores como un escritorio extendido (una superficie)
#   primary: qué monitor es el principal (Frame/Hogar viven ahí)
#   order:   orden izquierda->derecha de los demás monitores
#
# La app corre como actividad del compositor embebido y hereda SWAYSOCK: puede
# preguntarle al anfitrion por sus salidas (`swaymsg -t get_outputs -r`) sin
# bloquear la UI (Thread + reap en `_process`). El modelo de parseo/orden es puro y
# vive en shell/span_layout.gd (otro proyecto Godot; se compila desde el fuente,
# mismo patrón que la página Pantallas). Sin compositor la página igual se puede
# usar: el ajuste se guarda y el shell lo aplica al releer.

const MODEL_PATH = "shell/span_layout.gd"
const PREVIEW_H = 150.0
const PAD = 24.0

var SL = null
var cfg = {"enabled": false, "primary": "", "order": []}
var outputs = []          # [{name,width,height,scale,x,y}] detectadas por sway
var detected = false

var enabled_cb = null
var primary_ob = null
var preview = null
var rows_box = null
var status_label = null

var _threads = []
var _states = []
var _mutex = Mutex.new()


func _build():
	SL = _load_model()
	cfg = _cfg()
	h_title("Monitores")
	h_note("Escritorio extendido: todos los monitores forman un solo escritorio de gdtk. El Frame y el Hogar viven en el monitor principal; los demás se acomodan a su derecha.")
	h_gap(6)

	enabled_cb = CheckBox.new()
	enabled_cb.text = "Usar varios monitores"
	enabled_cb.pressed = bool(cfg.enabled)
	STYLE.apply_button(enabled_cb)
	enabled_cb.connect("toggled", self, "_on_enabled")
	box.add_child(enabled_cb)
	h_gap(4)

	var prow = h_row()
	h_label("Monitor principal", prow)
	primary_ob = OptionButton.new()
	primary_ob.rect_min_size.x = 240
	STYLE.apply_option(primary_ob)
	primary_ob.connect("item_selected", self, "_on_primary")
	prow.add_child(primary_ob)

	preview = Control.new()
	preview.rect_min_size = Vector2(480, PREVIEW_H)
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.connect("draw", self, "_draw_preview")
	box.add_child(preview)

	h_note("Orden de izquierda a derecha. Movés los monitores que no son el principal:")
	rows_box = VBoxContainer.new()
	rows_box.add_constant_override("separation", 6)
	box.add_child(rows_box)

	status_label = STYLE.note("")
	box.add_child(status_label)

	_refresh()
	set_process(true)
	_detect()


# --- Estado -------------------------------------------------------------------

func _cfg():
	var s = settings.get("span", {})
	if typeof(s) != TYPE_DICTIONARY:
		s = {}
	return {"enabled": bool(s.get("enabled", false)),
		"primary": String(s.get("primary", "")),
		"order": s.get("order", []) if typeof(s.get("order", [])) == TYPE_ARRAY else []}


func _commit():
	host.set_field("span", {"enabled": bool(cfg.enabled), "primary": String(cfg.primary),
		"order": cfg.order})


func _on_enabled(on):
	cfg.enabled = bool(on)
	_commit()
	_refresh()


func _on_primary(index):
	var names = _known_names()
	cfg.primary = "" if index <= 0 else String(names[index - 1])
	# La principal no lleva orden; se saca de la lista de orden.
	cfg.order.erase(String(cfg.primary))
	_commit()
	_refresh()


func _known_names():
	var names = []
	for o in _ordered_outputs():
		names.append(String(o.name))
	if names.empty():
		for n in cfg.order:
			if not names.has(String(n)):
				names.append(String(n))
		if cfg.primary != "" and not names.has(String(cfg.primary)):
			names.push_front(String(cfg.primary))
	return names


# Salidas detectadas en el orden de span (principal primero, luego cfg.order, resto
# por posición física).
func _ordered_outputs():
	if SL == null or outputs.empty():
		return []
	return SL.order_outputs(outputs, String(cfg.primary), cfg.order)


# --- Detección (fuera de la UI) -----------------------------------------------

func _detect():
	if SL == null or OS.get_environment("SWAYSOCK").strip_edges() == "":
		_refresh()
		return
	var exe = "/usr/bin/swaymsg"
	if not File.new().file_exists(exe):
		_refresh()
		return
	var state = {"done": false, "text": ""}
	var th = Thread.new()
	_threads.append(th)
	_states.append(state)
	th.start(self, "_run_outputs", {"exe": exe, "state": state})


func _run_outputs(userdata):
	var out = []
	OS.execute(String(userdata.exe), ["-t", "get_outputs", "-r"], true, out, true)
	userdata.state.text = String(out[0]) if out.size() > 0 else ""
	_mutex.lock()
	userdata.state.done = true
	_mutex.unlock()


func _process(_delta):
	for i in range(_threads.size() - 1, -1, -1):
		_mutex.lock()
		var done = _states[i].get("done", false)
		_mutex.unlock()
		if not done:
			continue
		_threads[i].wait_to_finish()
		var text = String(_states[i].get("text", ""))
		_threads.remove(i)
		_states.remove(i)
		_on_outputs(text)


func _exit_tree():
	for t in _threads:
		t.wait_to_finish()
	_threads.clear()
	_states.clear()


func _on_outputs(text):
	if SL == null:
		return
	outputs = SL.parse_outputs(text)
	detected = not outputs.empty()
	if detected:
		# La principal configurada que ya no está cae a automática; el orden se
		# poda a lo conectado (el shell igual vuelve a fallback a la principal).
		var names = []
		for o in outputs:
			names.append(String(o.name))
		if cfg.primary != "" and not names.has(String(cfg.primary)):
			cfg.primary = ""
		var kept = []
		for n in cfg.order:
			if names.has(String(n)):
				kept.append(String(n))
		cfg.order = kept
	_refresh()


# --- UI -----------------------------------------------------------------------

func _refresh():
	_rebuild_primary()
	_rebuild_rows()
	_refresh_status()
	if preview != null:
		preview.update()


func _rebuild_primary():
	if primary_ob == null:
		return
	primary_ob.clear()
	primary_ob.add_item("Automática (externa si hay)")
	var names = _known_names()
	for n in names:
		primary_ob.add_item(n)
	var idx = 0
	if cfg.primary != "":
		idx = names.find(String(cfg.primary)) + 1
	primary_ob.select(idx)


func _rebuild_rows():
	if rows_box == null:
		return
	for c in rows_box.get_children():
		rows_box.remove_child(c)
		c.free()
	var ordered = _ordered_outputs()
	if ordered.empty():
		if not cfg.order.empty():
			for n in cfg.order:
				_add_row(String(n), false, 0.0, 0.0)
		return
	for i in range(ordered.size()):
		var o = ordered[i]
		_add_row(String(o.name), String(o.name) == String(cfg.primary),
			float(o.width), float(o.height))


func _add_row(name, is_primary, w, h):
	var row = HBoxContainer.new()
	row.add_constant_override("separation", 8)
	rows_box.add_child(row)
	var label = name
	if is_primary:
		label += "  ·  principal"
	elif w > 0.0:
		label += "  ·  %d×%d" % [int(w), int(h)]
	else:
		label += "  ·  no conectada"
	var l = Label.new()
	l.text = label
	l.rect_min_size.x = 260
	l.add_color_override("font_color", STYLE.TEXT if not is_primary else STYLE.SELECT)
	row.add_child(l)
	if is_primary:
		return
	var left = Button.new()
	left.text = "◀"
	STYLE.apply_button(left)
	left.connect("pressed", self, "_move", [name, -1])
	row.add_child(left)
	var right = Button.new()
	right.text = "▶"
	STYLE.apply_button(right)
	right.connect("pressed", self, "_move", [name, 1])
	row.add_child(right)


func _move(name, delta):
	var order = _non_primary_order()
	var i = order.find(String(name))
	if i < 0:
		return
	var j = i + int(delta)
	if j < 0 or j >= order.size():
		return
	var tmp = order[i]
	order[i] = order[j]
	order[j] = tmp
	cfg.order = order
	_commit()
	_refresh()


# Orden de las salidas que no son la principal, tal como se muestran.
func _non_primary_order():
	var out = []
	for o in _ordered_outputs():
		var n = String(o.name)
		if n != String(cfg.primary):
			out.append(n)
	if out.empty():
		out = cfg.order.duplicate()
	return out


func _refresh_status():
	if status_label == null:
		return
	if SL == null:
		status_label.text = "No se pudo cargar el modelo de monitores."
		status_label.add_color_override("font_color", STYLE.WARN)
		return
	if not detected:
		status_label.text = "No se detectan monitores conectados. El ajuste se guarda y se aplica en la sesión."
		status_label.add_color_override("font_color", STYLE.DIM)
		return
	status_label.text = "Detectados %d monitores. Se aplica en vivo al guardar." % outputs.size()
	status_label.add_color_override("font_color", STYLE.DIM)


# --- Vista previa -------------------------------------------------------------

func _draw_preview():
	if preview == null:
		return
	var font = get_font("font", "Label")
	preview.draw_rect(Rect2(Vector2.ZERO, preview.rect_size), STYLE.BG, true)
	var items = _preview_items()
	if items.empty():
		if font != null:
			preview.draw_string(font, Vector2(PAD, PAD + 12), "Sin monitores para mostrar", STYLE.DIM)
		return
	var total_w = 0.0
	var max_h = 0.0
	for it in items:
		total_w += float(it.w)
		max_h = max(max_h, float(it.h))
	if total_w <= 0.0 or max_h <= 0.0:
		return
	var avail = preview.rect_size - Vector2(PAD, PAD) * 2.0
	var scale = min(avail.x / total_w, avail.y / max_h)
	scale = max(scale, 0.01)
	var drawn_w = total_w * scale
	var x = (preview.rect_size.x - drawn_w) * 0.5
	var base_y = (preview.rect_size.y - max_h * scale) * 0.5
	for it in items:
		var r = Rect2(x, base_y, float(it.w) * scale, float(it.h) * scale)
		var col = STYLE.SELECT if it.primary else STYLE.FACE
		preview.draw_rect(r, col, true)
		preview.draw_rect(r, STYLE.LIGHT, false)
		if font != null and r.size.x > 60.0:
			preview.draw_string(font, r.position + Vector2(6, 18), it.label, STYLE.TEXT)
		x += r.size.x


func _preview_items():
	var ordered = _ordered_outputs()
	var items = []
	if not ordered.empty():
		for o in ordered:
			var name = String(o.name)
			items.append({"label": name + (" · principal" if name == String(cfg.primary) else ""),
				"w": max(float(o.width), 1.0), "h": max(float(o.height), 1.0),
				"primary": name == String(cfg.primary)})
		return items
	# Sin detección: mostramos el ajuste guardado con un tamaño de referencia.
	var names = _known_names()
	for n in names:
		items.append({"label": String(n), "w": 1920.0, "h": 1080.0,
			"primary": String(n) == String(cfg.primary)})
	return items


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
