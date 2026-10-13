extends Node

# Composición OFFLINE de la "Vista del grupo" (SPEC-multiview-portal §7/§9 N1).
#
# Cada peer publica sus frames en un archivo shm (contrato GVDSHM1, escrito por
# `gvd recv --sink shmout`); este nodo los lee, los sube como ImageTexture y los
# dispone en una GRILLA espacial alrededor de la pantalla LOCAL (según la dirección
# física del layout) dentro de un Viewport FUERA DE PANTALLA. El feed del portal (F5)
# empuja el texture de ESE viewport, nunca el del shell: el escritorio no se espeja.
#
# Disposición: la pantalla local va en la celda (0,0); cada peer en su celda según su
# dirección (west=(-1,0), east=(1,0), north=(0,-1), south=(0,1)). Cada celda mide media
# vista, así se ven hasta ~4 pantallas y el conjunto puede exceder la vista: un PAN
# suave sigue al mouse para revelar el resto (lerp por tick).
#
# Nunca bloquea: lectura de archivo por tick (tmpfs) y re-render a demanda.

const MAGIC = [0x47, 0x56, 0x44, 0x53, 0x48, 0x4d, 0x31, 0x00]  # "GVDSHM1\0"
const HEADER = 64
const INTERVAL_MS = 66          # cadencia de composición/lectura (~15 fps)
const BG = Color(0.06, 0.06, 0.08, 1.0)
# Tamaño de cada celda como fracción de la vista: 0.5 = 2x2 visibles; el pan revela el
# resto cuando la disposición es más ancha/alta que la vista.
const CELL_FRACTION = 0.5
const CELL_GUTTER = 8.0
const PAN_LERP = 0.14           # suavizado del pan (por tick)

var _vp = null
var _canvas = null
var _slots = []                 # [{path, cell, tex, img, seq}]
var _local_vp = null            # Viewport raíz del shell (pantalla local)
var _local_cell = Vector2()
var _composite = Vector2()
var _pan = Vector2()
var _pan_max = Vector2()
var _cell = Vector2()
var _arr = Vector2()
var _min_cell = Vector2()
var _last_ms = 0
var _has_local = false


# `composite` (Vector2): tamaño del viewport de composición.
# `tiles`: Array de {"path": String, "cell": Vector2} (celda de la grilla).
# `local_viewport` (Viewport raíz del shell) + `local_cell` (Vector2): tile de la
# pantalla local; se pasan como null para no incluirlo.
func start(composite, tiles, local_viewport = null, local_cell = null):
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
	_has_local = local_viewport != null and typeof(local_cell) == TYPE_VECTOR2
	_local_cell = Vector2(local_cell) if _has_local else Vector2()
	_slots = []
	for t in (tiles if typeof(tiles) == TYPE_ARRAY else []):
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var path = String(t.get("path", "")).strip_edges()
		if path == "":
			continue
		var cell = t.get("cell", Vector2())
		_slots.append({"path": path, "cell": Vector2(cell) if typeof(cell) == TYPE_VECTOR2 else Vector2(),
			"tex": null, "img": null, "seq": -1})
	_layout()
	_canvas.update()
	_vp.render_target_update_mode = Viewport.UPDATE_ONCE
	return true


func stop():
	_slots = []
	_local_vp = null
	_has_local = false
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


# Recalcula la disposición (celdas -> rects) y el recorrido del pan. Puro salvo estado.
func _layout():
	_cell = Vector2(max(16.0, _composite.x * CELL_FRACTION),
		max(16.0, _composite.y * CELL_FRACTION))
	var minc = _local_cell if _has_local else Vector2(1e9, 1e9)
	var maxc = _local_cell if _has_local else Vector2(-1e9, -1e9)
	for s in _slots:
		minc = Vector2(min(minc.x, s.cell.x), min(minc.y, s.cell.y))
		maxc = Vector2(max(maxc.x, s.cell.x), max(maxc.y, s.cell.y))
	if not _has_local and _slots.empty():
		minc = Vector2.ZERO
		maxc = Vector2.ZERO
	_min_cell = minc
	_arr = Vector2((maxc.x - minc.x + 1.0) * (_cell.x + CELL_GUTTER),
		(maxc.y - minc.y + 1.0) * (_cell.y + CELL_GUTTER))
	_pan_max = Vector2(max(0.0, _arr.x - _composite.x), max(0.0, _arr.y - _composite.y))


func _cell_rect(cell):
	# Posición base + centrado si la disposición es más chica que la vista + pan.
	var base = Vector2((cell.x - _min_cell.x) * (_cell.x + CELL_GUTTER),
		(cell.y - _min_cell.y) * (_cell.y + CELL_GUTTER))
	var center = Vector2(max(0.0, (_composite.x - _arr.x) * 0.5),
		max(0.0, (_composite.y - _arr.y) * 0.5))
	return Rect2(base + center - _pan, _cell)


func _process(_delta):
	if _vp == null:
		return
	var now = OS.get_ticks_msec()
	if now - _last_ms < INTERVAL_MS:
		return
	_last_ms = now
	# Pan suave siguiendo el mouse de la pantalla local (0..1 -> 0..pan_max).
	if _has_local and _local_vp != null and is_instance_valid(_local_vp):
		var vsize = _local_vp.get_size()
		if vsize.x > 1.0 and vsize.y > 1.0:
			var mn = _local_vp.get_mouse_position() / vsize
			mn = Vector2(clamp(mn.x, 0.0, 1.0), clamp(mn.y, 0.0, 1.0))
			var target = Vector2(mn.x * _pan_max.x, mn.y * _pan_max.y)
			_pan = _pan.linear_interpolate(target, PAN_LERP)
	var changed = false
	if _has_local:
		changed = true          # el escritorio local cambia cada frame
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
	if _has_local and _local_vp != null and is_instance_valid(_local_vp):
		var ltex = _local_vp.get_texture()
		if ltex != null:
			# El viewport raíz llega en la orientación opuesta a los frames shm: se
			# dibuja espejado en vertical para que coincida (ver render_target_v_flip).
			_draw_tex(ltex, _fit_rect(ltex.get_size(), _cell_rect(_local_cell)), true)
	for s in _slots:
		if s.tex == null:
			continue
		_draw_tex(s.tex, _fit_rect(s.tex.get_size(), _cell_rect(s.cell)), false)


# Dibuja una textura en `rect`; `flip_v` la espeja verticalmente (para el tile local).
func _draw_tex(tex, rect, flip_v):
	if not flip_v:
		_canvas.draw_texture_rect(tex, rect, false)
		return
	_canvas.draw_set_transform(Vector2(rect.position.x, rect.position.y + rect.size.y),
		0.0, Vector2(1.0, -1.0))
	_canvas.draw_texture_rect(tex, Rect2(Vector2(), rect.size), false)
	_canvas.draw_set_transform(Vector2(), 0.0, Vector2(1.0, 1.0))


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
