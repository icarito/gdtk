extends Node

# Composición OFFLINE de la "Vista del grupo" (SPEC-multiview-portal §7/§9 N1).
#
# Cada peer publica sus frames en un archivo shm (contrato GVDSHM1, escrito por
# `gvd recv --sink shmout`); este nodo los lee, los sube como ImageTexture y los
# dibuja en una GRILLA dentro de un Viewport FUERA DE PANTALLA. El feed del portal
# (F5) empuja el texture de ESE viewport, nunca el del shell: así el escritorio no
# se espeja (no incluye la ventana de Meet), no hay toplevels que roben foco y la
# carga no toca el camino de render del escritorio.
#
# Nunca bloquea de forma grave: lectura de archivo por tick (tmpfs) y re-render a
# demanda; sólo se re-renderiza cuando llegó un frame nuevo.
#
# Formato del archivo (little endian, espeja shell/window_cast.gd y gvd.py
# shm_capture): magic[8] | seq u64 | width u32 | height u32 | stride u32 |
# fourcc[4] | relleno hasta 64 | frame RGBA. `seq` impar = frame a medio escribir
# (seqlock): se descarta.

const MAGIC = [0x47, 0x56, 0x44, 0x53, 0x48, 0x4d, 0x31, 0x00]  # "GVDSHM1\0"
const HEADER = 64
# Cadencia de composición/lectura (no la del emisor): ~15 fps.
const INTERVAL_MS = 66
# Fondo opaco del canvas: el feed no debe salir con alfa.
const BG = Color(0.06, 0.06, 0.08, 1.0)

var _vp = null
var _canvas = null
var _slots = []        # [{path, rect, tex, img, seq}]
var _last_ms = 0
var _composite = Vector2()
# Pantalla LOCAL del host (el escritorio real): su viewport raíz se dibuja como un tile
# más, siempre fresco (a diferencia de los peers, que llegan por shm). Null = sin tile
# local. `_local_rect` en coordenadas del composite.
var _local_vp = null
var _local_rect = null


# `composite` (Vector2) es el tamaño del viewport de composición; `slots` es un
# Array de {"path": String, "rect": Rect2} (rect en coordenadas del composite).
# `local_viewport` (Viewport raíz del shell) + `local_rect` (Rect2) agregan el tile de
# la pantalla local; se pasan como null para no incluirlo.
func start(composite, slots, local_viewport = null, local_rect = null):
	stop()
	_composite = Vector2(composite)
	if _composite.x < 2.0 or _composite.y < 2.0:
		return false
	_vp = Viewport.new()
	_vp.size = _composite
	_vp.usage = Viewport.USAGE_2D
	_vp.transparent_bg = false
	# Igual que window_cast.gd: el texture queda en la orientación que consume gvd.
	_vp.render_target_v_flip = true
	_vp.render_target_update_mode = Viewport.UPDATE_ONCE
	_canvas = Node2D.new()
	_canvas.connect("draw", self, "_draw")
	_vp.add_child(_canvas)
	add_child(_vp)
	_local_vp = local_viewport
	_local_rect = local_rect if typeof(local_rect) == TYPE_RECT2 else null
	_slots = []
	for s in (slots if typeof(slots) == TYPE_ARRAY else []):
		if typeof(s) != TYPE_DICTIONARY:
			continue
		var path = String(s.get("path", "")).strip_edges()
		var rect = s.get("rect", null)
		if path == "" or typeof(rect) != TYPE_RECT2:
			continue
		_slots.append({"path": path, "rect": rect, "tex": null, "img": null, "seq": -1})
	# Fuerzo un primer render (fondo) para que el texture exista aunque aún no
	# haya frames.
	_canvas.update()
	_vp.render_target_update_mode = Viewport.UPDATE_ONCE
	return true


func stop():
	_slots = []
	_local_vp = null
	_local_rect = null
	if _vp != null:
		_vp.queue_free()
		_vp = null
	_canvas = null


# Texture del canvas compuesto (para el feed F5). Null si no está listo.
func get_texture():
	return _vp.get_texture() if _vp != null else null


func is_active():
	return _vp != null


func composite_size():
	return _composite


func _exit_tree():
	if _vp != null:
		_vp.queue_free()
		_vp = null


func _process(_delta):
	if _vp == null:
		return
	var now = OS.get_ticks_msec()
	if now - _last_ms < INTERVAL_MS:
		return
	_last_ms = now
	var changed = false
	if _local_vp != null and is_instance_valid(_local_vp):
		changed = true   # el escritorio local cambia cada frame: se re-renderiza siempre
	for s in _slots:
		if _read_slot(s):
			changed = true
	if changed:
		_canvas.update()
		_vp.render_target_update_mode = Viewport.UPDATE_ONCE


# Lee el archivo del slot y, si hay un frame nuevo completo (seqlock par y seq
# distinto), actualiza su ImageTexture. Devuelve true si cambió.
func _read_slot(s):
	var f = File.new()
	if f.open(String(s.path), File.READ) != OK:
		return false
	var head = f.get_buffer(HEADER)
	if head.size() != HEADER or not _is_magic(head):
		f.close()
		return false
	var seq = _u64(head, 8)
	var w = _u32(head, 16)
	var h = _u32(head, 20)
	var stride = _u32(head, 24)
	if seq % 2 != 0 or seq < 2 or w <= 0 or h <= 0 or stride < w * 4:
		f.close()
		return false
	if seq == int(s.seq):
		f.close()
		return false
	if h > 4096 or w > 8192:
		f.close()
		return false
	f.seek(HEADER)
	var data = f.get_buffer(stride * h)
	# Relectura del seq: si cambió, el escritor avanzó a mitad de frame.
	f.seek(8)
	var seq2 = _u64(f.get_buffer(8), 0)
	f.close()
	if data.size() != stride * h or seq2 != seq:
		return false
	# Godot exige RGBA8 apretado (stride == w*4); si el emisor alineó, se reempaqueta.
	if stride != w * 4:
		data = _pack_rows(data, w, h, stride)
		if data == null:
			return false
	if s.img == null:
		s.img = Image.new()
	s.img.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)
	if s.tex == null:
		s.tex = ImageTexture.new()
		s.tex.create_from_image(s.img, 0)
	else:
		s.tex.set_data(s.img)
	s.seq = seq
	return true


func _is_magic(head):
	for i in range(8):
		if int(head[i]) != int(MAGIC[i]):
			return false
	return true


# Enteros little-endian a mano: StreamPeerBuffer::get_u64 devolvió basura en este
# fork del motor, y el contrato es simple. Puro.
static func _u32(ba, off):
	return int(ba[off]) | (int(ba[off + 1]) << 8) \
		| (int(ba[off + 2]) << 16) | (int(ba[off + 3]) << 24)


static func _u64(ba, off):
	# Por mitades u32 con corrimiento constante (el corrimiento variable por i daba
	# resultados erróneos en este fork).
	var lo = _u32(ba, off)
	var hi = _u32(ba, off + 4)
	return lo | (hi << 32)


func _pack_rows(data, w, h, stride):
	var row = w * 4
	var out = PoolByteArray()
	out.resize(row * h)
	for y in range(h):
		for x in range(row):
			out[y * row + x] = data[y * stride + x]
	return out


func _draw():
	_canvas.draw_rect(Rect2(Vector2(), _composite), BG)
	if _local_vp != null and is_instance_valid(_local_vp) and _local_rect != null:
		var ltex = _local_vp.get_texture()
		if ltex != null:
			_canvas.draw_texture_rect(ltex, _fit_rect(ltex.get_size(), _local_rect), false)
	for s in _slots:
		var tex = s.tex
		if tex == null:
			continue
		_canvas.draw_texture_rect(tex, _fit_rect(tex.get_size(), s.rect), false)


# Rect de destino con aspecto preservado (letterbox) dentro de `rect`. Puro.
static func fit_rect(tex_size, rect):
	return _fit_rect_static(tex_size, rect)


static func _fit_rect_static(tex_size, rect):
	var t = Vector2(tex_size)
	if t.x <= 0.0 or t.y <= 0.0 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return rect
	var k = min(rect.size.x / t.x, rect.size.y / t.y)
	var size = t * k
	var off = rect.position + (rect.size - size) * 0.5
	return Rect2(off, size)


func _fit_rect(tex_size, rect):
	return _fit_rect_static(tex_size, rect)
