extends Reference

# Applet Portapapeles del Frame: historial de lo copiado en las apps embebidas y el
# último ítem a la vista. Es la dockapp de ejemplo de `.operator-shared/guides/dockapp.md`
# (contrato: state/value/detail, refresh(force) -> bool, stop(), draw opcional).
#
# Captura: `session/gdtk-clipboard watch <socket>` deja vigías `wl-paste --watch` vivos
# contra el compositor embebido (ext-data-control-v1) que guardan cada copia como un
# archivo en $XDG_RUNTIME_DIR/gdtk/clipboard. Las imágenes van como `.png` (y una
# miniatura en gdtk/clipboard-thumbs) para mostrarlas como imagen, no como su HTML.
# Este módulo sólo LEE ese directorio.
#
# El hilo de render NUNCA consulta (SPEC-screen-share-compass §14): el worker lista el
# directorio, lee la entrada nueva, arma miniaturas y (re)lanza el vigía; refresh()
# copia el snapshot.

const PERIOD_MS = 1000
const SLEEP_STEP_MS = 100
const RELAUNCH_MS = 10000   # cada cuánto se reintenta el vigía si murió
const MAX_FAILS = 3         # vigía que no arranca N veces -> no_disponible, sin bucle
const READ_MAX = 4096       # bytes leídos de la entrada (sólo para resumir)
const SYNC_MAX = 65536      # tope de lo que se comparte con el Grupo (= tope de `store`)
const ITEMS_MAX = 10        # entradas publicadas en `items` (las más nuevas primero)
const SUMMARY_MAX = 60      # recorte del resumen por ítem
const IMAGE_EXT = ".png"    # extensión de las entradas de imagen
const THUMB_MAX = 160       # lado máximo de la miniatura (px); se genera en el worker

var state = "sin_dato"
var value = ""     # resumen corto del último ítem (una línea)
var detail = ""    # tooltip: más texto + tamaño del historial
# Historial navegable publicado por el worker: [{"name": <archivo>, "summary": <str>,
# "kind": "text"|"image"}], más nuevo primero, hasta ITEMS_MAX. Sólo lo llena el worker.
var items = []
# Última entrada (para el dibujo de la placa): nombre y tipo.
var latest_name = ""
var latest_kind = ""

# Lo fija el Frame antes del primer refresh(): socket del compositor embebido.
var wayland_display = ""

var _mutex = Mutex.new()
var _thread = null
var _want_stop = false
var _snap = {"state": "sin_dato", "value": "", "detail": "", "items": [], "latest_name": "", "latest_kind": ""}
# Portapapeles compartido con el Grupo (SPEC-sugar-group «Portapapeles»): el worker
# deja cada copia local nueva en `_outbox`; el shell la reparte por el canal peer.
var _outbox = []
var _last_received = ""
# Pedidos de pick() (nombres de archivo) que el worker convierte en copia local nueva.
var _picks = []


# --- API del Frame -----------------------------------------------------------

func refresh(_force := false):
	if _thread == null:
		_want_stop = false
		_thread = Thread.new()
		_thread.start(self, "_work", _paths())
	_mutex.lock()
	var s = _snap
	_mutex.unlock()
	var s_items = s.get("items", [])
	var changed = state != s.state or value != s.value or detail != s.detail or items != s_items \
		or latest_name != s.get("latest_name", "") or latest_kind != s.get("latest_kind", "")
	state = s.state
	value = s.value
	detail = s.detail
	items = s_items.duplicate(true)
	latest_name = String(s.get("latest_name", ""))
	latest_kind = String(s.get("latest_kind", ""))
	return changed


# Copias locales nuevas desde la última llamada (texto completo, hasta SYNC_MAX).
func take_outbox():
	_mutex.lock()
	var out = _outbox
	_outbox = []
	_mutex.unlock()
	return out


# Texto que llegó de otro equipo: pasa a ser la selección local. No se reenvía
# (el vigía lo guarda como entrada nueva y el worker lo reconoce por `_last_received`).
func receive(text):
	var t = String(text)
	var d = String(wayland_display)
	if t == "" or d == "" or not d.is_valid_filename():
		return false
	var p = _paths()
	Directory.new().make_dir_recursive(p.dir.get_base_dir())
	var tmp = p.dir.get_base_dir().plus_file("clip-in.%d" % OS.get_ticks_usec())
	var f = File.new()
	if f.open(tmp, File.WRITE) != OK:
		return false
	f.store_string(t)
	f.close()
	_mutex.lock()
	_last_received = t
	_mutex.unlock()
	_run_set(p, tmp)
	return true


# Elige una entrada del historial: el worker la copia a un temporal y la pone como
# selección local. No setea `_last_received`: el vigía la guarda como copia nueva y
# se sincroniza al Grupo como cualquier copia local. `name` viene del popup (frontera
# de confianza): sólo se acepta un nombre simple del directorio de historial.
func pick(name):
	var n = String(name)
	if not valid_name(n):
		return false
	_mutex.lock()
	_picks.append(n)
	_mutex.unlock()
	return true


func stop():
	_mutex.lock()
	_want_stop = true
	_mutex.unlock()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


# Dibujo propio dentro de la placa (scr: coords de pantalla, loc: locales a la ventana).
# `frame` presta sus helpers de fuente/glifo para que la tesela combine con el resto.
func draw(frame, ui, scr, loc, w, h):
	var g = min(w, h) * 0.48
	var col = frame._lcd(frame.NX_TEXT, "on" if state == "activo" else "off")
	# Imagen: la placa muestra la miniatura (encajada, sin deformar) en vez del texto.
	var thumb = null
	if latest_kind == "image" and latest_name != "" and frame.shell != null:
		thumb = frame.shell._load_png_file(thumb_file(latest_name))
	if thumb != null:
		var side = min(w, h) * 0.82
		var tw = max(1.0, float(thumb.get_width()))
		var th = max(1.0, float(thumb.get_height()))
		var k = min(side / tw, side / th)
		var d = Vector2(tw * k, th * k)
		ui.set_cursor_pos(loc + (Vector2(w, h) - d) * 0.5)
		ui.image(thumb, d)
		return
	# El clip de icons/np, plano (el relieve es de los bloques de navegación, no de
	# las dockapps).
	var icon = frame.shell._load_np_icon("clips") if frame.shell != null else null
	if icon != null:
		ui.set_cursor_pos(loc + Vector2((w - g) * 0.5, h * 0.08))
		ui.image(icon, Vector2(g, g))
	else:
		frame._draw_shared_glyph(ui, Rect2(scr + Vector2((w - g) * 0.5, h * 0.10), Vector2(g, g)),
			"clipboard", col)
	var text = value
	if state != "activo":
		text = "no disp." if state == "no_disponible" else "vacío"
	var small = frame._push_label_font(ui)
	text = frame._truncate_w(ui, text, w - 6.0)
	ui.set_cursor_pos(loc + Vector2(max(3.0, (w - frame._text_w(ui, text)) * 0.5), h * 0.66))
	ui.text_colored(col, text)
	if small:
		ui.pop_font()


# Ruta de la miniatura de una entrada de imagen ("" si no es imagen). La genera el
# worker; el Frame la carga como textura para el popup y la placa.
func thumb_file(name):
	var n = String(name)
	if not is_image(n):
		return ""
	return _paths().thumbs.plus_file(n)


# --- puro (testeable) --------------------------------------------------------

# Primera línea no vacía, con espacios colapsados y recortada a `limit` chars. "" si no hay texto.
static func summary(text, limit = -1):
	var lim = SUMMARY_MAX if int(limit) < 0 else int(limit)
	for line in String(text).split("\n", false):
		var s = String(line).strip_edges().replace("\t", " ")
		while s.find("  ") >= 0:
			s = s.replace("  ", " ")
		if s != "":
			return s.substr(0, lim)
	return ""


# Etiqueta de menú para una entrada del historial: nunca vacía y sin el token "##"
# (ImGui lo toma como separador de ID y recortaría el texto a la izquierda). El ID
# único del ítem NO sale de acá: dos copias con el mismo texto chocarían; lo aporta
# el nombre de archivo con push_id (ver frame.gd).
static func item_label(summary_text):
	var s = String(summary_text)
	if s == "":
		return "(sin texto)"
	return s.replace("##", "# #")


# ¿La entrada es una imagen? Las imágenes se guardan con extensión .png (el vigía las
# separa del texto para no mostrar el HTML `<meta ...>` que copian los navegadores).
static func is_image(name):
	return String(name).ends_with(IMAGE_EXT)


# Ancho x alto leídos del IHDR de un PNG (primeros 24 bytes), o [] si no es PNG.
# Puro: recibe los bytes, no toca disco.
static func png_size(header):
	if header == null or header.size() < 24:
		return []
	if int(header[0]) != 0x89 or int(header[1]) != 0x50 or int(header[2]) != 0x4E or int(header[3]) != 0x47:
		return []
	var w = (int(header[16]) << 24) | (int(header[17]) << 16) | (int(header[18]) << 8) | int(header[19])
	var h = (int(header[20]) << 24) | (int(header[21]) << 16) | (int(header[22]) << 8) | int(header[23])
	return [w, h]


# Etiqueta de una entrada de imagen: "Imagen 1920×1080" si se conocen las dimensiones.
static func image_label(dims):
	if dims != null and dims.size() >= 2 and int(dims[0]) > 0 and int(dims[1]) > 0:
		return "Imagen %d×%d" % [int(dims[0]), int(dims[1])]
	return "Imagen"


# Entrada más nueva: nombres = reloj en ns de igual largo, el mayor lexicográfico gana.
static func newest(names):
	var best = ""
	for n in names:
		if not String(n).begins_with(".") and String(n) > best:
			best = String(n)
	return best


# Nombres visibles del historial ordenados del más nuevo al más viejo (descendente).
# Los archivos ocultos (`.lock`, `.in.N`) no son entradas.
static func sorted_names(names):
	var out = []
	for n in names:
		var s = String(n)
		if s != "" and not s.begins_with("."):
			out.append(s)
	out.sort()
	out.invert()
	return out


# Frontera de confianza del popup: sólo un nombre simple del directorio de historial.
# Rechaza vacío, ocultos, separadores y cualquier `..`.
static func valid_name(name):
	var n = String(name)
	if n == "" or n == "." or n == "..":
		return false
	if n.begins_with("."):
		return false
	if n.find("/") >= 0 or n.find("\\") >= 0 or n.find("..") >= 0:
		return false
	return true


# --- hilo de trabajo ---------------------------------------------------------

func _paths():
	var run = OS.get_environment("XDG_RUNTIME_DIR")
	if run == "":
		run = "/tmp"
	return {
		"dir": run + "/gdtk/clipboard",
		"thumbs": run + "/gdtk/clipboard-thumbs",
		"script": ProjectSettings.globalize_path("res://").plus_file("../session/gdtk-clipboard").simplify_path(),
		"log": run + "/gdtk-clipboard.log",
		"display": wayland_display,
	}


func _stopped():
	_mutex.lock()
	var s = _want_stop
	_mutex.unlock()
	return s


func _work(p):
	var last_name = null   # null: la primera vuelta siempre publica (listo/activo)
	var last_sig = null
	var fails = 0
	var launch_at = 0
	var snap = {"state": "sin_dato", "value": "", "detail": "", "items": []}
	while not _stopped():
		_drain_picks(p)
		var now = OS.get_ticks_msec()
		if fails < MAX_FAILS and now >= launch_at:
			launch_at = now + RELAUNCH_MS
			if _watcher_alive(p.dir):
				fails = 0
			else:
				_launch(p)
				fails += 1   # se confirma vivo en la próxima vuelta (lock tomado)
		var names = _list(p.dir)
		var ordered = sorted_names(names)
		var name = ordered[0] if not ordered.empty() else ""
		var sig = PoolStringArray(ordered).join("\n")
		var cur_items = snap.get("items", [])
		if last_name == null or sig != last_sig:
			# Sincronizar al Grupo sólo texto; las imágenes no viajan por el canal peer.
			if last_name != null and name != "" and name != last_name and not is_image(name):
				_queue_sync(_read(p.dir.plus_file(name), SYNC_MAX))
			last_name = name
			last_sig = sig
			cur_items = _build_items(p.dir, ordered)
			var lk = "image" if (name != "" and is_image(name)) else "text"
			var lv = ""
			var ld = ""
			if name == "":
				ld = "Portapapeles: sin copias"
			elif lk == "image":
				lv = image_label(_image_dims(p, name))
				ld = "Portapapeles: %s (PNG)\n\n%d en el historial" % [lv, names.size()]
			else:
				var text = _read(p.dir.plus_file(name))
				lv = summary(text)
				ld = "Portapapeles: %s\n\n%d en el historial" % [text.substr(0, 300), names.size()]
			snap = {"state": "activo" if name != "" else "listo",
				"value": lv, "detail": ld, "items": cur_items,
				"latest_name": name, "latest_kind": lk}
		if fails >= MAX_FAILS and name == "":
			snap = {"state": "no_disponible", "value": "",
				"detail": "Portapapeles: no se pudo vigilar (falta wl-paste o el motor no trae ext-data-control). Ver %s" % p.log,
				"items": cur_items, "latest_name": "", "latest_kind": ""}
		_mutex.lock()
		_snap = snap
		_mutex.unlock()
		var waited = 0
		while waited < PERIOD_MS and not _stopped():
			OS.delay_msec(SLEEP_STEP_MS)
			waited += SLEEP_STEP_MS


# Saca los pedidos de pick() y los aplica como copia local nueva (lee en el worker).
func _drain_picks(p):
	_mutex.lock()
	var picks = _picks
	_picks = []
	_mutex.unlock()
	for nm in picks:
		_apply_pick(p, nm)


# Los ITEMS_MAX más nuevos con su resumen/etiqueta; los archivos se leen acá, nunca en
# el render. Las imágenes se resumen por dimensiones y generan su miniatura.
func _build_items(dir, ordered):
	var out = []
	var n = min(ordered.size(), ITEMS_MAX)
	for i in range(n):
		var nm = ordered[i]
		if is_image(nm):
			out.append({"name": nm, "summary": image_label(_image_dims_from_dir(dir, nm)), "kind": "image"})
		else:
			out.append({"name": nm, "summary": summary(_read(dir.plus_file(nm), READ_MAX)), "kind": "text"})
	return out


# Dimensiones de una entrada de imagen del directorio `p` (o []).
func _image_dims(p, name):
	return _image_dims_from_dir(p.dir, name)


# Lee el IHDR (sin decodificar) y asegura la miniatura. Sólo lo llama el worker.
func _image_dims_from_dir(dir, name):
	var src = String(dir).plus_file(name)
	var dims = []
	var f = File.new()
	if f.open(src, File.READ) == OK:
		dims = png_size(f.get_buffer(min(f.get_len(), 24)))
		f.close()
	_ensure_thumb(dir, name, src)
	return dims


# Genera (una vez) la miniatura encajada en THUMB_MAX px, para que el render cargue un
# PNG chico y no la imagen completa. Idempotente por existencia del archivo.
func _ensure_thumb(dir, name, src):
	var thumbs = _paths().thumbs
	var dst = thumbs.plus_file(name)
	if File.new().file_exists(dst):
		return
	Directory.new().make_dir_recursive(thumbs)
	var img = Image.new()
	if img.load(src) != OK or img.get_width() == 0:
		return
	var w = img.get_width()
	var h = img.get_height()
	var k = min(1.0, float(THUMB_MAX) / float(max(w, h)))
	if k < 1.0:
		img.resize(max(1, int(round(w * k))), max(1, int(round(h * k))), Image.INTERPOLATE_BILINEAR)
	img.save_png(dst)


# Copia una entrada del historial a un temporal y la pone como selección local. Las
# imágenes se copian COMPLETAS y con su extensión (no truncar un PNG ni perder el tipo).
func _apply_pick(p, name):
	if not valid_name(name):
		return
	var src = p.dir.plus_file(name)
	var f = File.new()
	if f.open(src, File.READ) != OK:
		return
	var n = f.get_len() if is_image(name) else min(f.get_len(), SYNC_MAX)
	var data = f.get_buffer(n)
	f.close()
	Directory.new().make_dir_recursive(p.dir.get_base_dir())
	var ext = IMAGE_EXT if is_image(name) else ""
	var tmp = p.dir.get_base_dir().plus_file("clip-pick.%d%s" % [OS.get_ticks_usec(), ext])
	var o = File.new()
	if o.open(tmp, File.WRITE) != OK:
		return
	o.store_buffer(data)
	o.close()
	_run_set(p, tmp)


# El vigía vivo tiene el lock: `flock -n` falla (≠ 0) si está tomado.
func _watcher_alive(dir):
	if not Directory.new().file_exists(dir.plus_file(".lock")):
		return false
	return OS.execute("flock", ["-n", dir.plus_file(".lock"), "true"], true) != 0


# `sh -c '... &'` para que el vigía quede colgado de init (sin zombies en Godot).
# El socket viene del motor; se valida igual porque va dentro de un comando de shell.
func _launch(p):
	var d = String(p.display)
	if d == "" or not d.is_valid_filename() or d.find("'") >= 0:
		return
	OS.execute("sh", ["-c", "'%s' watch '%s' </dev/null >>'%s' 2>&1 &" % [p.script, d, p.log]], true)


func _list(dir):
	var out = []
	var da = Directory.new()
	if da.open(dir) != OK:
		return out
	da.list_dir_begin(true, true)
	var n = da.get_next()
	while n != "":
		if not da.current_is_dir():
			out.append(n)
		n = da.get_next()
	da.list_dir_end()
	return out


func _queue_sync(text):
	_mutex.lock()
	if text != "" and text != _last_received:
		_outbox.append(text)
	_mutex.unlock()


# `gdtk-clipboard set <display> <archivo>`: pone el texto del archivo como selección
# local (el script borra el temporal). El texto viaja por archivo, nunca por argumentos.
func _run_set(p, path):
	var d = String(p.display)
	if d == "" or not d.is_valid_filename() or d.find("'") >= 0:
		return false
	OS.execute("sh", ["-c", "'%s' set '%s' '%s' </dev/null >>'%s' 2>&1 &" % [p.script, d, path, p.log]], true)
	return true


func _read(path, limit = READ_MAX):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var t = f.get_buffer(min(f.get_len(), limit)).get_string_from_utf8()
	f.close()
	return t
