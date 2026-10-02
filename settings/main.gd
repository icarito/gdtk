extends Control

# App Configuración (K11a), proyecto Godot propio lanzado por el shell como una
# actividad wayland (`godot-gdtk --path settings`). Escribe el estado compartido
# ~/.config/gdtk/settings.json que el shell relee en vivo (shell/settings_bridge.gd).
#
# UI por código: barra lateral de páginas + contenido. Sin dependencias del shell
# ni del módulo ImGui.

const MODEL = preload("res://settings_model.gd")
const STORE = preload("res://store.gd")
const STYLE = preload("res://ui/style.gd")

const PAGES = [
	{"id": "keyboard", "label": "Teclado", "path": "res://pages/keyboard.gd"},
	{"id": "touchpad", "label": "Desplazamiento", "path": "res://pages/touchpad.gd"},
	{"id": "locale", "label": "Idioma", "path": "res://pages/locale.gd"},
	{"id": "accent", "label": "Color de acento", "path": "res://pages/accent.gd"},
	{"id": "appearance", "label": "Apariencia", "path": "res://pages/appearance.gd"},
	{"id": "wallpaper", "label": "Fondo de pantalla", "path": "res://pages/wallpaper.gd"},
	{"id": "displays", "label": "Pantallas", "path": "res://pages/displays.gd"},
	{"id": "shared_control", "label": "Compartir control", "path": "res://pages/shared_control.gd"},
]

var model = null
var store = null
var settings = {}
var original = {}
var current = ""

var page_holder = null
var nav_buttons = {}
var status_label = null


func _ready():
	model = MODEL.new()
	store = STORE.new()
	settings = store.load_settings()
	original = settings.duplicate(true)
	_build_ui()
	_select("keyboard")
	if "--settings-selftest" in OS.get_cmdline_args():
		# Dev aid: arma todas las páginas y guarda (con GDTK_SETTINGS redirigido).
		for p in PAGES:
			_select(p.id)
		var err = store.save(settings)
		print("settings app ok: ", settings.get("keyboard", ""), " ", settings.get("accent", ""), " save=", err)
		call_deferred("_quit_selftest")


func _quit_selftest():
	get_tree().quit()


func _draw():
	draw_rect(Rect2(Vector2.ZERO, rect_size), STYLE.BG)


func tree_dir():
	return store.tree_dir()


# --- Construcción de la UI ----------------------------------------------------

func _build_ui():
	var root = HBoxContainer.new()
	root.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	root.add_constant_override("separation", 0)
	add_child(root)

	var side = _panel(STYLE.SIDEBAR, 220)
	root.add_child(side[0])
	var side_box = VBoxContainer.new()
	side_box.add_constant_override("separation", 6)
	side[1].add_child(side_box)
	side_box.add_child(STYLE.title("Configuración", 18))
	side_box.add_child(STYLE.note("Ajustes de la sesión"))
	var sep = HSeparator.new()
	side_box.add_child(sep)
	for p in PAGES:
		var b = Button.new()
		b.text = p.label
		b.align = Button.ALIGN_LEFT
		STYLE.apply_nav(b, false)
		b.connect("pressed", self, "_select", [p.id])
		nav_buttons[p.id] = b
		side_box.add_child(b)
	var spacer = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_box.add_child(spacer)
	side_box.add_child(STYLE.note("Se guarda en la carpeta\nde configuración de la sesión."))

	var content = _panel(STYLE.PANEL, 0)
	content[0].size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(content[0])
	var cbox = VBoxContainer.new()
	cbox.add_constant_override("separation", 8)
	content[1].add_child(cbox)

	status_label = STYLE.note("")
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cbox.add_child(status_label)

	page_holder = Control.new()
	page_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cbox.add_child(page_holder)

	var buttons = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGN_END
	buttons.add_constant_override("separation", 8)
	cbox.add_child(buttons)
	var revert = Button.new()
	revert.text = "Revertir"
	STYLE.apply_button(revert)
	revert.connect("pressed", self, "_revert")
	buttons.add_child(revert)
	var save = Button.new()
	save.text = "Aplicar"
	STYLE.apply_button(save)
	save.connect("pressed", self, "_save")
	buttons.add_child(save)


# Panel con margen interno: devuelve [Panel, MarginContainer].
func _panel(color, min_x):
	var p = Panel.new()
	STYLE.apply_panel(p, color)
	if min_x > 0:
		p.rect_min_size.x = min_x
	var m = MarginContainer.new()
	m.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	m.add_constant_override("margin_left", 14)
	m.add_constant_override("margin_right", 14)
	m.add_constant_override("margin_top", 14)
	m.add_constant_override("margin_bottom", 14)
	p.add_child(m)
	return [p, m]


func _select(id):
	current = id
	for p in PAGES:
		if p.id == id:
			for c in page_holder.get_children():
				page_holder.remove_child(c)
				c.free()
			var page = load(p.path).new()
			page_holder.add_child(page)
			page.setup(model, settings.duplicate(true), self)
		STYLE.apply_nav(nav_buttons[p.id], p.id == id)


# --- Cambios de las páginas ---------------------------------------------------

func set_field(field, value):
	settings[field] = value
	_status("Hay cambios sin guardar", true)


func set_wallpaper(w):
	settings["wallpaper"] = w
	_status("Hay cambios sin guardar", true)


func _save():
	var err = store.save(settings)
	if err != "":
		_status(err, true)
		return
	original = settings.duplicate(true)
	_status("Guardado", false)


func _revert():
	settings = original.duplicate(true)
	_select(current)
	_status("Cambios revertidos", false)


func _status(text, warn):
	status_label.text = text
	status_label.add_color_override("font_color", STYLE.WARN if warn else STYLE.DIM)


func _unhandled_input(event):
	if event is InputEventKey and event.pressed and not event.echo:
		if event.scancode == KEY_ESCAPE:
			get_tree().quit()
		elif event.scancode == KEY_S and event.control:
			_save()
