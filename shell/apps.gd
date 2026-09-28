extends Reference

# Apps instaladas: .desktop de XDG (desktop-entry + icon-theme, lo mínimo).
# El escaneo se hace al primer uso de la grilla; los íconos se cargan sólo al
# verse en pantalla y con un tope de tiempo por frame (X200: CPU lenta).

const ICON = 64
const CELL = Vector2(124, 112)
const ICON_BUDGET_USEC = 8000
const SIZES = ["64x64", "48x48", "96x96", "128x128", "scalable", "256x256", "32x32", "192x192", "512x512"]
# Categorías de toolkit/escritorio: ruido al buscar ("gtk" sacaba media grilla).
const NOISE_CATS = ["gtk", "qt", "kde", "gnome", "xfce"]
# Acentos combinantes (NFD, p.ej. "Mu\u0301sica"): la fuente no los tiene.
const COMPOSE = ["aá", "eé", "ií", "oó", "uú", "AÁ", "EÉ", "IÍ", "OÓ", "UÚ"]
const FOLD = ["áàäâã", "a", "éèëê", "e", "íìïî", "i", "óòöôõ", "o", "úùüû", "u", "ñ", "n", "ç", "c"]
# Terminal=true: la misma terminal que la actividad Terminal del anillo.
const TERMINAL = "alacritty -e "

var apps = []
var query = ""
var want_focus = false
var search_active = false
var deselect = false
var shown_query = ""
var scanned = false
var theme_dirs = []
var field_code = RegEx.new()
var path_dirs = []
# pid lanzado desde la grilla -> nombre de la app (ver watch).
var watching = {}


func _init():
	field_code.compile("%[a-zA-Z]")


func data_dirs():
	var home = OS.get_environment("XDG_DATA_HOME")
	if home == "":
		home = OS.get_environment("HOME") + "/.local/share"
	var dirs = OS.get_environment("XDG_DATA_DIRS")
	if dirs == "":
		dirs = "/usr/local/share:/usr/share"
	var out = [home.trim_suffix("/")]
	for d in dirs.split(":", false):
		out.append(d.trim_suffix("/"))
	return out


func scan():
	scanned = true
	apps = []
	path_dirs = OS.get_environment("PATH").split(":", false)
	var desktops = Array(OS.get_environment("XDG_CURRENT_DESKTOP").to_lower().split(":", false))
	desktops.append("gdtk")
	# Precedencia: XDG_DATA_HOME y luego XDG_DATA_DIRS en orden; el primer id gana
	# (aunque sea Hidden: así un .desktop del usuario oculta al del sistema).
	var seen = {}
	for d in data_dirs():
		_scan_dir(d + "/applications", "", seen, desktops)
	apps.sort_custom(self, "_by_key")
	_find_theme_dirs()


func _by_key(a, b):
	return a.key < b.key


func _scan_dir(dir, prefix, seen, desktops):
	var da = Directory.new()
	if da.open(dir) != OK:
		return
	da.list_dir_begin(true, true)
	var f = da.get_next()
	while f != "":
		if da.current_is_dir():
			_scan_dir(dir + "/" + f, prefix + f + "-", seen, desktops)
		elif f.ends_with(".desktop") and not seen.has(prefix + f):
			seen[prefix + f] = true
			var app = parse(dir + "/" + f, desktops)
			if app != null:
				app.id = prefix + f
				apps.append(app)
		f = da.get_next()
	da.list_dir_end()


# Grupo [Desktop Entry] → app, o null si no se debe mostrar.
func parse(path, desktops):
	var file = File.new()
	if file.open(path, File.READ) != OK:
		return null
	var e = {}
	var in_entry = false
	for line in file.get_as_text().split("\n"):
		line = line.strip_edges()
		if line.begins_with("["):
			if in_entry:
				break
			in_entry = line == "[Desktop Entry]"
		elif in_entry and not line.begins_with("#"):
			var eq = line.find("=")
			if eq > 0:
				e[line.substr(0, eq).strip_edges()] = line.substr(eq + 1).strip_edges()
	file.close()

	if e.get("Type", "") != "Application":
		return null
	for k in ["NoDisplay", "Hidden"]:
		if e.get(k, "") == "true":
			return null
	var exec = clean_exec(e.get("Exec", ""))
	# DBusActivatable sin Exec: se activa por D-Bus (el entorno de activación apunta al compositor).
	if exec == "" and e.get("DBusActivatable", "") == "true":
		exec = "gapplication launch " + path.get_file().get_basename()
	# Sin el ejecutable no abriría nunca: TryExec y el programa de Exec tienen que existir.
	if exec == "" or not found(e.get("TryExec", _program(exec))):
		return null
	var cmd = "exec " + exec
	if e.get("Terminal", "") == "true":
		if not found(TERMINAL.split(" ")[0]):
			return null
		cmd = "exec " + TERMINAL + exec
	if e.get("Path", "") != "":
		cmd = "cd '" + e.Path.replace("'", "'\\''") + "' && " + cmd
	if e.has("OnlyShowIn") and not _any_in(e.OnlyShowIn, desktops):
		return null
	if _any_in(e.get("NotShowIn", ""), desktops):
		return null
	var name = e.get("Name[%s]" % OS.get_locale(), e.get("Name[es]", e.get("Name", "")))
	if name == "":
		return null
	for p in COMPOSE:
		name = name.replace(p[0] + "\u0301", p[1])
	name = name.replace("n\u0303", "ñ")
	var cats = ""
	for c in e.get("Categories", "").split(";", false):
		if not c.begins_with("X-") and not c.to_lower() in NOISE_CATS:
			cats += " " + c
	return {
		"id": "", "name": name, "exec": exec, "cmd": cmd, "icon": e.get("Icon", ""),
		"categories": cats, "key": fold(name + cats),
		"tex": null, "icon_tried": false,
	}


func _any_in(list, desktops):
	for d in list.to_lower().split(";", false):
		if desktops.has(d):
			return true
	return false


# Quita los field codes (%f %U %i ...); %% es un % literal.
func clean_exec(s):
	return field_code.sub(s.replace("%%", "\u0001"), "", true).replace("\u0001", "%").strip_edges()


# Programa de un Exec (sin `env VAR=...` delante ni comillas).
func _program(exec):
	if exec.begins_with("\""):
		return exec.substr(1, exec.find("\"", 1) - 1)
	for w in exec.split(" ", false):
		w = w.replace("\"", "").replace("'", "")
		if w != "env" and not "=" in w:
			return w
	return ""


func found(program):
	if program == "":
		return false
	if program.is_abs_path():
		return File.new().file_exists(program)
	for d in path_dirs:
		if File.new().file_exists(d.plus_file(program)):
			return true
	return false


# Si el proceso lanzado termina sin haber abierto ventana, el shell no se queda
# esperándola: sale del anillo y se avisa (la salida de la app queda en shell.log).
func watch(shell, name, pid):
	if pid <= 0 or shell.pending_wayland != name:
		return
	watching[pid] = name
	if not shell.compositor.is_connected("process_exited", self, "_on_exit"):
		shell.compositor.connect("process_exited", self, "_on_exit", [shell])


func _on_exit(pid, code, shell):
	var name = watching.get(pid, "")
	watching.erase(pid)
	if name == "" or shell.pending_wayland != name:
		return
	shell.pending_wayland = ""
	var i = shell._activity_named(name)
	if i >= 0 and shell.ACTIVITIES[i].get("dynamic", false):
		shell.ACTIVITIES.remove(i)
	if shell.current_activity != null and shell.current_activity.name == name:
		shell._go_home()
	shell.activity_error = "%s terminó sin abrir ventana (código %d, ver shell.log)" % [name, code]
	if code == 0:
		shell.activity_error += "; si ya estaba abierta, lo está en otro display"
	shell.request_redraw()


# Minúsculas y sin tildes, para buscar sin importar mayúsculas ni acentos.
func fold(s):
	s = s.to_lower()
	for i in range(0, FOLD.size(), 2):
		for ch in FOLD[i]:
			s = s.replace(ch, FOLD[i + 1])
	return s


func matches():
	var q = fold(query.strip_edges())
	if q == "":
		return apps
	var out = []
	for a in apps:
		if q in a.key:
			out.append(a)
	return out


# --- Íconos ---

# ponytail: sólo el layout estándar <tema>/<tamaño>/apps y sin seguir Inherits=;
# temas con otro layout (breeze: apps/64) caen a Adwaita/hicolor.
func _find_theme_dirs():
	var bases = [OS.get_environment("HOME") + "/.icons"]
	for d in data_dirs():
		bases.append(d + "/icons")
	theme_dirs = []
	var da = Directory.new()
	for theme in [_user_theme(), "Adwaita", "hicolor"]:
		for b in bases:
			var t = b + "/" + theme
			if theme != "" and not theme_dirs.has(t) and da.dir_exists(t):
				theme_dirs.append(t)


func _user_theme():
	var f = File.new()
	if f.open(OS.get_environment("HOME") + "/.config/gtk-3.0/settings.ini", File.READ) != OK:
		return ""
	for line in f.get_as_text().split("\n"):
		if line.begins_with("gtk-icon-theme-name"):
			return line.split("=")[1].strip_edges()
	return ""


func resolve_icon(icon):
	var f = File.new()
	if icon.is_abs_path():
		return icon if f.file_exists(icon) else ""
	if icon.get_extension() in ["png", "svg", "xpm"]:
		icon = icon.get_basename()
	if icon == "":
		return ""
	for t in theme_dirs:
		for s in SIZES:
			for ext in [".png", ".svg"]:
				var p = t + "/" + s + "/apps/" + icon + ext
				if f.file_exists(p):
					return p
	for ext in [".png", ".svg"]:
		if f.file_exists("/usr/share/pixmaps/" + icon + ext):
			return "/usr/share/pixmaps/" + icon + ext
	return ""


func _load_icon(app):
	app.icon_tried = true
	var path = resolve_icon(app.icon)
	if path == "":
		return
	# Caché en disco ya reducida a ICON: un SVG grande tarda cientos de ms en
	# rasterizarse y en la X200 bloquearía el frame en cada arranque.
	# ponytail: la clave es la ruta; si el ícono cambia, borrar user://iconos.
	var cached = "user://iconos/" + path.md5_text() + ".png"
	var img = Image.new()
	if not File.new().file_exists(cached) or img.load(cached) != OK:
		if img.load(path) != OK or img.get_width() == 0:
			return
		if img.get_width() > ICON:
			img.resize(ICON, ICON * img.get_height() / img.get_width(), Image.INTERPOLATE_BILINEAR)
		Directory.new().make_dir_recursive("user://iconos")
		img.save_png(cached)
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	app.tex = tex


# --- Vista ---

# Teclear en el Home: el carácter va a la búsqueda y ésta toma el foco.
func type(ch):
	query += ch
	want_focus = true


# Búsqueda + grilla en la ventana actual. Devuelve la app a lanzar o null.
func draw(ui):
	if not scanned:
		scan()
	if want_focus:
		ui.set_keyboard_focus_here()
		want_focus = false
		deselect = true
	ui.push_item_width(-1)
	query = ui.input_text("##buscar", query)
	search_active = ui.is_item_active()
	# El foco por teclado selecciona todo y la próxima tecla lo pisaría. Un End
	# ya activo el campo (en el frame de activación ImGui ignora las teclas)
	# deja el cursor al final.
	if deselect and search_active:
		deselect = false
		for pressed in [true, false]:
			var end = InputEventKey.new()
			end.scancode = KEY_END
			end.pressed = pressed
			Input.parse_input_event(end)
	ui.pop_item_width()
	var list = matches()
	var chosen = null
	if ui.is_key_pressed(KEY_ESCAPE):
		query = ""
	elif (ui.is_key_pressed(KEY_ENTER) or ui.is_key_pressed(KEY_KP_ENTER)) and query != "" and list.size() > 0:
		chosen = list[0]
	if list.empty():
		ui.text("Sin resultados")

	if ui.begin_child("##grilla", Vector2.ZERO):
		if query != shown_query:
			shown_query = query
			ui.set_scroll_here_y(0.0)
		var cols = max(1, int(ui.get_content_region_avail().x / CELL.x))
		var top = ui.get_window_pos().y
		var bottom = top + ui.get_window_size().y
		# ProggyClean (fuente por defecto) es monoespaciada: 7 px por carácter.
		var char_w = 7.0 * ui.get_imgui_scale()
		var t0 = OS.get_ticks_usec()
		var more = false
		for i in range(list.size()):
			var app = list[i]
			var cell = Vector2((i % cols) * CELL.x, (i / cols) * CELL.y)
			ui.set_cursor_pos(cell + Vector2((CELL.x - ICON) * 0.5 - 4.0, 4.0))
			var y = ui.get_cursor_screen_pos().y
			if y > bottom or y + CELL.y < top:
				continue
			if not app.icon_tried:
				if OS.get_ticks_usec() - t0 < ICON_BUDGET_USEC:
					_load_icon(app)
				else:
					more = true
			var clicked = false
			if app.tex != null:
				clicked = ui.image_button("##" + app.id, app.tex, Vector2(ICON, ICON))
			else:
				clicked = ui.button(app.name.substr(0, 8) + "##" + app.id, Vector2(ICON + 8, ICON + 6))
			if ui.is_item_hovered():
				ui.set_tooltip(app.name)
			if clicked:
				chosen = app
			var label = app.name if app.name.length() <= 16 else app.name.substr(0, 15) + "."
			ui.set_cursor_pos(cell + Vector2(max(0.0, (CELL.x - label.length() * char_w) * 0.5), ICON + 14.0))
			ui.text(label)
		if more:
			ui.request_redraw()
		# El alto del contenido (scroll) lo fija un item al final, no set_cursor_pos.
		ui.set_cursor_pos(Vector2(0.0, ceil(list.size() / float(cols)) * CELL.y))
		ui.dummy(Vector2(1, 1))
	ui.end_child()
	return chosen
