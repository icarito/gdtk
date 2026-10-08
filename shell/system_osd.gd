extends Reference

# Volumen / mute / brillo del sistema + OSD nativo.
#
# Las teclas multimedia (XF86Audio* / XF86MonBrightness*) entran por el motor y el
# shell las maneja en `_input` (ver shell.gd). El cambio real se aplica en un worker
# (Thread) para no bloquear el frame; el OSD se dibuja optimista y se desvanece solo.
#
# Audio: wpctl (PipeWire), con fallback a pactl y amixer. Brillo: logind
# (org.freedesktop.login1.Session.SetBrightness, no requiere root), con fallback a
# brightnessctl o sysfs. Si no hay backend, las teclas igual muestran el OSD pero el
# valor no cambia.
#
# Constantes del motor como literales: KEY_BRIGHTNESSUP/DOWN existen recién con el
# binario nuevo; así el script también parsea con un binario viejo (y la recarga no
# rompe la sesión). Los valores coinciden con core/os/keyboard.h.
const SPKEY = 16777216
const KEY_VOLUMEUP = SPKEY | 0x46
const KEY_VOLUMEDOWN = SPKEY | 0x44
const KEY_VOLUMEMUTE = SPKEY | 0x45
const KEY_BRIGHTNESSUP = SPKEY | 0x35
const KEY_BRIGHTNESSDOWN = SPKEY | 0x34

# Log de teclas sin mapear: sólo con GDTK_DEBUG_INPUT=1 (evita ruido por tecla).
var debug_input = OS.get_environment("GDTK_DEBUG_INPUT") != ""

const VOL_STEP = 0.05
const BRI_STEP = 0.05
const BRI_MIN = 0.05        # piso: no dejar la pantalla en negro
const OSD_HOLD_MS = 1400    # tiempo a plena opacidad
const OSD_FADE_MS = 340     # desvanecido final
const WORK_IDLE_MS = 25
# ImGuiWindowFlags_NoMouseInputs (thirdparty/imgui/imgui.h): el módulo no lo expone
# como constante y el OSD no debe robar hover/clics (la ventana es fullscreen).
const WINDOW_NO_MOUSE_INPUTS = 512

var _shell = null

# --- worker (bajo _mutex) ---
var _mutex = Mutex.new()
var _thread = null
var _want_stop = false
var _pending = {}           # kind -> true (comandos a aplicar)
var _want = {}              # kind -> valor deseado (float bool)
var _dirty = false
var _ready = false
var _pub = {"volume": 0.5, "muted": false, "brightness": -1.0}
var _pub_version = 0
var _audio = ""             # "wpctl" | "pactl" | "amixer" | ""
var _bright_dev = ""
var _bright_max = 0

# --- estado del hilo principal (OSD) ---
var volume = 0.5
var muted = false
var brightness = 0.7        # < 0 = desconocido
var _last_pub = -1
var osd_kind = ""           # "" | "volume" | "mute" | "brightness" | "message"
var osd_pct = 0
var osd_muted = false
var osd_text = ""           # etiqueta y ícono cuando osd_kind == "message"
var osd_icon = ""
var osd_started = 0
var _osd_active = false


func setup(shell):
	_shell = shell
	if _thread == null:
		_want_stop = false
		_thread = Thread.new()
		_thread.start(self, "_work")


# Detiene el worker y espera a que termine (llamado en shell._exit_tree).
func shutdown():
	_mutex.lock()
	_want_stop = true
	_mutex.unlock()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


# Atiende una tecla multimedia. Devuelve true si la consumió (no debe ir a la app).
func handle_input(event):
	if event is InputEventKey and event.pressed and not event.echo:
		var d = int(event.physical_scancode) if event.physical_scancode != 0 else int(event.scancode)
		if d == 0 or d >= (1 << 24):
			if debug_input:
				printerr("[osd-key] sc=", int(event.scancode), " phys=", int(event.physical_scancode), " uni=", int(event.unicode))
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return false
	var sc = int(event.physical_scancode) if event.physical_scancode != 0 else int(event.scancode)
	match sc:
		KEY_VOLUMEUP:
			adjust_volume(VOL_STEP)
		KEY_VOLUMEDOWN:
			adjust_volume(-VOL_STEP)
		KEY_VOLUMEMUTE:
			toggle_mute()
		KEY_BRIGHTNESSUP:
			adjust_brightness(BRI_STEP)
		KEY_BRIGHTNESSDOWN:
			adjust_brightness(-BRI_STEP)
		_:
			return false
	return true


func adjust_volume(delta):
	var was_muted = muted
	volume = clamp(volume + delta, 0.0, 1.0)
	muted = false
	_queue("volume")
	if was_muted:
		_queue("mute")  # subir/bajar también desmutea
	_show_osd("volume")


func toggle_mute():
	muted = not muted
	_queue("mute")
	_show_osd("mute")


func adjust_brightness(delta):
	if brightness < 0.0:
		brightness = 0.7
	brightness = clamp(brightness + delta, BRI_MIN, 1.0)
	_queue("brightness")
	_show_osd("brightness")


# Gancho del control remoto (tests/automatización sin teclas físicas).
func rpc_action(params):
	match str(params.get("action", "")):
		"up":
			adjust_volume(VOL_STEP)
		"down":
			adjust_volume(-VOL_STEP)
		"mute":
			toggle_mute()
		"brightness_up":
			adjust_brightness(BRI_STEP)
		"brightness_down":
			adjust_brightness(-BRI_STEP)
		"show":
			_show_osd(str(params.get("kind", "volume")))
		_:
			return false
	return true


# Copia el estado del worker y avanza el temporizador del OSD. Devuelve true
# mientras el OSD sigue visible (para pedir frames).
func poll():
	if _thread == null:
		return _osd_tick()
	_mutex.lock()
	var ready = _ready
	var pub = _pub
	var ver = _pub_version
	var pending = _dirty
	_mutex.unlock()
	if ready and ver != _last_pub:
		_last_pub = ver
		# Sin comandos en vuelo: adoptar cambios externos (otra app cambió el volumen).
		if not pending:
			var nv = float(pub["volume"])
			var nm = bool(pub["muted"])
			var nb = float(pub["brightness"])
			var changed = abs(volume - nv) > 0.005 or muted != nm
			volume = nv
			muted = nm
			if nb >= 0.0:
				changed = changed or abs(brightness - nb) > 0.005
				brightness = nb
			if changed and _shell != null:
				_shell.request_redraw()
	return _osd_tick()


func is_active():
	return _osd_active


# Mensaje breve con ícono (p. ej. "Pantallazo guardado"): reusa la placa y el
# desvanecido del OSD, sin barra de progreso. No pasa por el worker ni bloquea.
func show_message(text, icon_name):
	osd_kind = "message"
	osd_text = str(text)
	osd_icon = str(icon_name)
	osd_started = OS.get_ticks_msec()
	_osd_active = true
	if _shell != null:
		_shell.request_redraw()


# --- OSD --------------------------------------------------------------------


func _show_osd(kind):
	osd_kind = kind
	osd_muted = muted
	if kind == "brightness":
		osd_pct = int(round(max(brightness, 0.0) * 100.0))
	else:
		osd_pct = int(round(volume * 100.0))
	osd_started = OS.get_ticks_msec()
	_osd_active = true
	if _shell != null:
		_shell.request_redraw()


func _osd_tick():
	if not _osd_active:
		return false
	if OS.get_ticks_msec() - osd_started > OSD_HOLD_MS + OSD_FADE_MS:
		_osd_active = false
		osd_kind = ""
		return false
	return true


func _osd_alpha():
	var age = OS.get_ticks_msec() - osd_started
	if age <= OSD_HOLD_MS:
		return 1.0
	return clamp(1.0 - float(age - OSD_HOLD_MS) / float(OSD_FADE_MS), 0.0, 1.0)


func _label():
	match osd_kind:
		"mute":
			return "Silencio" if osd_muted else "Con sonido"
		"brightness":
			return "Brillo %d%%" % osd_pct
		"message":
			return osd_text
		_:
			return "Volumen %d%%" % osd_pct


func _icon_name():
	match osd_kind:
		"mute":
			return "audio-volume-muted" if osd_muted else "audio-volume-high"
		"brightness":
			return "display-brightness"
		"message":
			return osd_icon   # "" = mensaje sin ícono
		_:
			return "audio-volume-high"


# Dibuja el OSD dentro del frame ImGui del shell (llamado al final de _imgui_frame).
# Necesita su propia ventana ImGui: dibujar primitivas fuera de una las manda a la
# ventana de debug del módulo (era el bug de la "ventana de debug" que tapaba el OSD).
func draw(shell):
	if not _osd_active or osd_kind == "":
		return
	var alpha = _osd_alpha()
	if alpha <= 0.0:
		return
	var vp = shell._screen_size()
	var s = shell.ui_scale(vp)
	var w = min(vp.x * 0.46, 430.0 * s)
	var h = 94.0 * s
	var rect = Rect2((vp.x - w) * 0.5, vp.y - h - 88.0 * s, w, h)
	# Ventana fullscreen sin fondo, sin decoración y sin mouse (NoMouseInputs): queda
	# por encima sin robar clics. Padding 0 para que las coordenadas absolutas coincidan.
	shell.set_next_window_pos(Vector2.ZERO, true)
	shell.set_next_window_size(vp, true)
	shell.set_next_window_bg_alpha(0.0)
	shell.push_style_var_vec2(shell.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	var flags = shell.WINDOW_NO_DECORATION | shell.WINDOW_NO_BACKGROUND | shell.WINDOW_NO_MOVE \
		| shell.WINDOW_NO_RESIZE | shell.WINDOW_NO_SAVED_SETTINGS | shell.WINDOW_NO_SCROLLBAR \
		| shell.WINDOW_NO_TITLE_BAR | shell.WINDOW_NO_COLLAPSE \
		| shell.WINDOW_NO_BRING_TO_FRONT_ON_FOCUS | WINDOW_NO_MOUSE_INPUTS
	if shell.begin("##gdtk_osd", flags):
		_draw_plate(shell, rect, s, alpha)
	shell.end()
	shell.pop_style_var()


func _draw_plate(shell, rect, s, alpha):
	var rounding = 14.0 * s
	# Sombra, contorno y placa biselada (misma familia que el anillo/Hogar).
	shell.imgui_draw_rect_filled(Rect2(rect.position + Vector2(0.0, 3.0 * s), rect.size),
		Color(0.0, 0.0, 0.0, 0.32 * alpha), rounding)
	shell.imgui_draw_rect_filled(Rect2(rect.position - Vector2(2.0, 2.0) * s, rect.size + Vector2(4.0, 4.0) * s),
		Color(0.72, 0.78, 0.90, 0.16 * alpha), rounding + 2.0 * s)
	shell.imgui_draw_rect_filled(rect, Color(0.10, 0.11, 0.14, 0.94 * alpha), rounding)

	var pad = 18.0 * s
	var icon_side = rect.size.y - 2.0 * pad
	var icon_name = _icon_name()
	var icon_tex = shell._load_sugar_svg(icon_name,
		Color(0.88, 0.90, 0.95, 1.0), Color(0.97, 0.96, 0.92, 1.0)) if icon_name != "" else null
	if icon_tex != null:
		shell.set_cursor_pos(Vector2(rect.position.x + pad, rect.position.y + (rect.size.y - icon_side) * 0.5))
		shell.image(icon_tex, Vector2(icon_side, icon_side))

	var tx = rect.position.x + pad + icon_side + pad * 0.9
	var tw = rect.end.x - pad - tx
	shell.set_cursor_pos(Vector2(tx, rect.position.y + pad * 0.75))
	shell.text_colored(Color(0.92, 0.93, 0.97, alpha), _label())

	if osd_kind != "message":
		var bar_h = 9.0 * s
		var bar_y = rect.end.y - pad - bar_h
		shell.imgui_draw_rect_filled(Rect2(tx, bar_y, tw, bar_h),
			Color(1.0, 1.0, 1.0, 0.16 * alpha), bar_h * 0.5)
		var frac = clamp(float(osd_pct) / 100.0, 0.0, 1.0)
		var fill = Color(0.55, 0.80, 1.0, alpha) if not osd_muted else Color(0.70, 0.72, 0.78, alpha)
		if not osd_muted and osd_kind == "brightness":
			fill = Color(0.98, 0.82, 0.42, alpha)
		if osd_muted:
			shell.imgui_draw_rect_filled(Rect2(tx, bar_y, tw, bar_h), fill, bar_h * 0.5)
			shell.imgui_draw_line(Vector2(tx + 2.0, bar_y + bar_h - 2.0),
				Vector2(tx + tw - 2.0, bar_y + 2.0), Color(1, 1, 1, 0.55 * alpha), 1.5 * s)
		elif tw * frac > 0.5:
			shell.imgui_draw_rect_filled(Rect2(tx, bar_y, tw * frac, bar_h), fill, bar_h * 0.5)


# --- worker -----------------------------------------------------------------


func _queue(kind):
	_mutex.lock()
	_pending[kind] = true
	_want[kind] = (volume if kind == "volume" else (muted if kind == "mute" else brightness))
	_dirty = true
	_mutex.unlock()


func _stopped():
	_mutex.lock()
	var s = _want_stop
	_mutex.unlock()
	return s


func _work(_userdata):
	_detect_backends()
	_read_state()
	_mutex.lock()
	_ready = true
	_pub_version += 1
	_mutex.unlock()
	while true:
		if _stopped():
			return
		_mutex.lock()
		var jobs = _pending
		var wants = _want.duplicate()
		_pending = {}
		_want = {}
		_dirty = false
		_mutex.unlock()
		if jobs.empty():
			OS.delay_msec(WORK_IDLE_MS)
			continue
		if jobs.has("volume") or jobs.has("mute"):
			_apply_audio(wants)
		if jobs.has("brightness"):
			_apply_brightness(wants)
		_read_state()
		_mutex.lock()
		_pub_version += 1
		_mutex.unlock()


func _detect_backends():
	if which("wpctl") != "":
		_audio = "wpctl"
	elif which("pactl") != "":
		_audio = "pactl"
	elif which("amixer") != "":
		_audio = "amixer"
	else:
		_audio = ""
	_bright_dev = ""
	_bright_max = 0
	var d = Directory.new()
	if d.open("/sys/class/backlight") == OK:
		d.list_dir_begin(true, true)
		var n = d.get_next()
		while n != "":
			if n != "." and n != "..":
				_bright_dev = n
				break
			n = d.get_next()
		d.list_dir_end()
	if _bright_dev != "":
		_bright_max = int(read_file("/sys/class/backlight/%s/max_brightness" % _bright_dev))


func _apply_audio(wants):
	var out = []
	if wants.has("volume"):
		var pct = int(round(clamp(float(wants["volume"]), 0.0, 1.0) * 100.0))
		match _audio:
			"wpctl":
				OS.execute("wpctl", ["set-volume", "@DEFAULT_AUDIO_SINK@", "%d%%" % pct], true, out)
			"pactl":
				OS.execute("pactl", ["set-sink-volume", "@DEFAULT_SINK@", "%d%%" % pct], true, out)
			"amixer":
				OS.execute("amixer", ["-q", "set", "Master", "%d%%" % pct], true, out)
	if wants.has("mute"):
		var on = bool(wants["mute"])
		match _audio:
			"wpctl":
				OS.execute("wpctl", ["set-mute", "@DEFAULT_AUDIO_SINK@", ("1" if on else "0")], true, out)
			"pactl":
				OS.execute("pactl", ["set-sink-mute", "@DEFAULT_SINK@", ("1" if on else "0")], true, out)
			"amixer":
				OS.execute("amixer", ["-q", "set", "Master", ("mute" if on else "unmute")], true, out)


func _apply_brightness(wants):
	if _bright_dev == "" or _bright_max <= 0:
		return
	var pct = clamp(float(wants.get("brightness", -1.0)), 0.0, 1.0)
	var raw = int(clamp(round(pct * float(_bright_max)), 1.0, float(_bright_max)))
	var out = []
	var code = OS.execute("busctl",
		["--system", "call", "org.freedesktop.login1",
			"/org/freedesktop/login1/session/auto",
			"org.freedesktop.login1.Session", "SetBrightness",
			"ssu", "backlight", _bright_dev, str(raw)], true, out)
	if code != 0:
		if which("brightnessctl") != "":
			OS.execute("brightnessctl", ["set", "%d%%" % int(round(pct * 100.0))], true, out)
		else:
			var f = File.new()
			if f.open("/sys/class/backlight/%s/brightness" % _bright_dev, File.WRITE) == OK:
				f.store_string(str(raw))
				f.close()


func _read_state():
	var vol = -1.0
	var mut = false
	var out = []
	match _audio:
		"wpctl":
			if OS.execute("wpctl", ["get-volume", "@DEFAULT_AUDIO_SINK@"], true, out) == 0:
				var p = parse_wpctl(out)
				vol = float(p["volume"])
				mut = bool(p["muted"])
		"pactl":
			out = []
			if OS.execute("pactl", ["get-sink-volume", "@DEFAULT_SINK@"], true, out) == 0:
				vol = parse_pactl_volume(out)
			out = []
			if OS.execute("pactl", ["get-sink-mute", "@DEFAULT_SINK@"], true, out) == 0:
				mut = parse_pactl_mute(out)
		"amixer":
			out = []
			if OS.execute("amixer", ["get", "Master"], true, out) == 0:
				var p = parse_amixer(out)
				vol = float(p["volume"])
				mut = bool(p["muted"])
	var bri = -1.0
	if _bright_dev != "" and _bright_max > 0:
		var raw = int(read_file("/sys/class/backlight/%s/brightness" % _bright_dev))
		bri = clamp(float(raw) / float(_bright_max), 0.0, 1.0)
	_mutex.lock()
	_pub = {
		"volume": (vol if vol >= 0.0 else float(_pub["volume"])),
		"muted": mut,
		"brightness": (bri if bri >= 0.0 else float(_pub["brightness"])),
	}
	_mutex.unlock()


# --- helpers puros ----------------------------------------------------------


static func join_lines(lines):
	var t = ""
	for l in lines:
		t += str(l) + "\n"
	return t


static func which(name):
	var path = OS.get_environment("PATH")
	if path == "":
		path = "/usr/local/bin:/usr/bin:/bin"
	for dir in path.split(":"):
		if dir == "":
			continue
		var f = File.new()
		if f.file_exists(dir.plus_file(name)):
			return dir.plus_file(name)
	return ""


static func read_file(path):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return ""
	# get_line() y no get_as_text(): los atributos de sysfs reportan size 0 y
	# get_as_text() devuelve "" (get_line() lee hasta el salto igual).
	var s = f.get_line().strip_edges()
	f.close()
	return s


# "Volume: 0.98" / "Volume: 0.98 [MUTED]" (wpctl).
static func parse_wpctl(lines):
	var text = join_lines(lines)
	var vol = -1.0
	var muted = false
	for raw in text.split("\n", false):
		var l = raw.strip_edges()
		if not l.begins_with("Volume:"):
			continue
		var rest = l.substr("Volume:".length()).strip_edges()
		if rest.find("[MUTED]") >= 0:
			muted = true
			rest = rest.replace("[MUTED]", "").strip_edges()
		if rest.is_valid_float():
			vol = float(rest)
	return {"volume": vol, "muted": muted}


# "Volume: front-left: 65536 / 100% / 0.00 dB, ..." (pactl get-sink-volume).
static func parse_pactl_volume(lines):
	var text = join_lines(lines)
	var re = RegEx.new()
	re.compile("([0-9]+)%")
	var m = re.search(text)
	if m != null:
		return clamp(float(m.get_string(1)) / 100.0, 0.0, 1.5)
	return -1.0


# "Mute: yes" / "Mute: no" (pactl get-sink-mute).
static func parse_pactl_mute(lines):
	var text = join_lines(lines)
	for raw in text.split("\n", false):
		var l = raw.strip_edges()
		if l.begins_with("Mute:"):
			return l.substr("Mute:".length()).strip_edges() == "yes"
	return false


# "[50%] [on]" de `amixer get Master`.
static func parse_amixer(lines):
	var text = join_lines(lines)
	var re = RegEx.new()
	re.compile("\\[([0-9]+)%\\]")
	var m = re.search(text)
	var vol = -1.0
	if m != null:
		vol = clamp(float(m.get_string(1)) / 100.0, 0.0, 1.0)
	var muted = text.find("[off]") >= 0
	return {"volume": vol, "muted": muted}


static func parse_pct(pct):
	return clamp(float(pct) / 100.0, 0.0, 1.0)


static func pct_of(frac):
	return int(round(clamp(frac, 0.0, 1.0) * 100.0))
