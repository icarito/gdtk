extends Node

# Comparte UNA ventana del compositor embebido con gvd (Grupo: soltar el bloque de la
# ventana sobre un equipo). La compone en un Viewport fuera de pantalla (capas de
# get_layers, recortadas a get_geometry y escaladas a un tamaño fijo) y publica cada
# frame RGBA en un archivo de tmpfs que lee `gvd send --capture shm`.
#
# Archivo (little endian, contrato con tools/gvd/gvd.py shm_capture): magic[8] |
# seq u64 | width u32 | height u32 | stride u32 | fourcc[4] | relleno hasta 64 |
# frame. seq impar = frame a medio escribir (seqlock). Archivo y no FIFO: escribir a
# un FIFO sin lector mataría al shell (y a todas sus apps) con SIGPIPE.
#
# Nunca bloquea el render: la escritura va en un Thread y gana el frame más nuevo.
# Llamar get_layers cada tick además mantiene los frame callbacks de la ventana
# aunque no esté a la vista.
# ponytail: readback GL síncrono (get_data) por tick y sin popups fuera del rect;
# el broker dmabuf de SPEC-embedded-multi-output.md lo reemplaza.

const MAGIC = "GVDSHM1"
const HEADER = 64
const MAX_SIZE = Vector2(1920, 1080)
# Un cambio de tamaño de la ventana se publica cuando se queda quieto este tiempo
# (arrastrar el borde no rearma el encoder en cada píxel).
const RESIZE_SETTLE_MS = 300

var compositor = null
var wid = -1
var path = ""
var fps = 20
var size = Vector2()

var _vp = null
var _canvas = null
var _layers = []
var _geo = Rect2()
var _acc = 0.0
var _thread = null
var _sem = Semaphore.new()
var _mutex = Mutex.new()
var _pending = null
var _quit = false
var _want = Vector2()
var _want_since = 0


# Tamaño de salida: el de la ventana, achicado sin deformar hasta MAX_SIZE y con
# lados pares (H.264 4:2:0). Puro.
static func out_size(geo_size, max_size = MAX_SIZE):
	var s = Vector2(geo_size)
	if s.x < 2 or s.y < 2:
		return Vector2()
	var k = min(1.0, min(max_size.x / s.x, max_size.y / s.y))
	return Vector2(int(s.x * k / 2) * 2, int(s.y * k / 2) * 2)


# Rect de destino de una capa: geometría de la ventana -> viewport, escala uniforme
# centrada. Puro.
static func layer_rect(layer_rect, geo, out):
	var k = min(out.x / geo.size.x, out.y / geo.size.y)
	var off = (out - geo.size * k) * 0.5
	return Rect2((layer_rect.position - geo.position) * k + off, layer_rect.size * k)


func start(p_compositor, p_wid, p_path, p_fps = 20):
	compositor = p_compositor
	wid = int(p_wid)
	path = String(p_path)
	fps = int(clamp(int(p_fps), 1, 60))
	_geo = compositor.get_geometry(wid)
	size = out_size(_geo.size)
	if size == Vector2():
		return false
	_vp = Viewport.new()
	_vp.size = size
	_vp.usage = Viewport.USAGE_2D
	_vp.transparent_bg = false
	_vp.render_target_v_flip = true
	_vp.render_target_update_mode = Viewport.UPDATE_ALWAYS
	_canvas = Node2D.new()
	_canvas.connect("draw", self, "_draw_window")
	_vp.add_child(_canvas)
	add_child(_vp)
	_thread = Thread.new()
	_thread.start(self, "_writer", null)
	return true


func stop():
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	_sem.post()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	# Sin archivo, el lector de gvd termina solo.
	Directory.new().remove(path)


func _exit_tree():
	if _thread != null:
		stop()


func _process(delta):
	_acc += delta
	if _vp == null or _acc < 1.0 / fps:
		return
	_acc = 0.0
	_layers = compositor.get_layers(wid)
	var g = compositor.get_geometry(wid)
	if g.size.x >= 2 and g.size.y >= 2:
		_geo = g
	# La ventana cambió de tamaño: el video la sigue (gvd rearma su pipeline al ver
	# la cabecera nueva y el shell avisa al receptor).
	var want = out_size(_geo.size)
	if want != Vector2() and want != size:
		if want != _want:
			_want = want
			_want_since = OS.get_ticks_msec()
		elif OS.get_ticks_msec() - _want_since >= RESIZE_SETTLE_MS:
			_mutex.lock()
			size = want
			_pending = null
			_mutex.unlock()
			_vp.size = want
			_canvas.update()
			return   # el viewport recién se re-renderiza al nuevo tamaño el próximo tick
	_canvas.update()
	# Lo que se lee es el render del tick anterior: un frame de latencia, sin esperar.
	var img = _vp.get_texture().get_data()
	if img == null or img.is_empty():
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	_mutex.lock()
	_pending = img.get_data()
	_mutex.unlock()
	_sem.post()


func _draw_window():
	_canvas.draw_rect(Rect2(Vector2(), size), Color(0, 0, 0))
	for l in _layers:
		var tex = l.get("texture")
		if tex != null:
			_canvas.draw_texture_rect(tex, layer_rect(Rect2(l.get("rect")), _geo, size), false)


func _writer(_u):
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		printerr("window_cast: no pude abrir ", path)
		return
	_mutex.lock()
	var w = int(size.x)
	var h = int(size.y)
	_mutex.unlock()
	f.store_buffer(MAGIC.to_ascii())
	f.store_8(0)
	f.store_64(0)
	f.store_32(w)
	f.store_32(h)
	f.store_32(w * 4)
	f.store_buffer("AB24".to_ascii())
	var pad = PoolByteArray()
	pad.resize(HEADER - 32)
	for i in range(pad.size()):
		pad[i] = 0
	f.store_buffer(pad)
	f.flush()
	var seq = 0
	while true:
		_sem.wait()
		_mutex.lock()
		var quit = _quit
		var data = _pending
		_pending = null
		var cur = size
		_mutex.unlock()
		if quit:
			break
		if data == null or data.size() != int(cur.x) * int(cur.y) * 4:
			continue
		seq += 1
		f.seek(8)
		f.store_64(seq)
		f.flush()
		if int(cur.x) != w or int(cur.y) != h:
			# Tamaño nuevo: la cabecera cambia dentro del mismo seqlock que el frame.
			w = int(cur.x)
			h = int(cur.y)
			f.seek(16)
			f.store_32(w)
			f.store_32(h)
			f.store_32(w * 4)
		f.seek(HEADER)
		f.store_buffer(data)
		seq += 1
		f.seek(8)
		f.store_64(seq)
		f.flush()
	f.close()
