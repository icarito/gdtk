extends Node

# Composición OFFLINE de la "Vista del grupo" (SPEC-multiview-portal §7/§9 N1).
#
# Cada peer publica sus frames en un archivo shm (contrato GVDSHM1, escrito por
# `gvd recv --sink shmout`); este nodo los lee, los sube como ImageTexture y los
# dispone en una GRILLA espacial alrededor de la pantalla LOCAL (según la dirección
# física del layout) dentro de un Viewport FUERA DE PANTALLA. El feed del portal (F5)
# empuja el texture de ESE viewport.
#
# Reglas:
#  - Sólo se incluyen tiles CON imagen (la local siempre; un peer entra recién cuando
#    llega su primer frame). Un tile sin señal NO reserva celda -> no deja huecos.
#  - Celdas contiguas (sin gutter); celdas de media vista.
#  - PAN: sigue al foco (el tile del cursor) centrándolo, suave (lerp); si no hay foco,
#    sigue al mouse de la pantalla local.
#
# Nunca bloquea: lectura de archivo por tick (tmpfs) y re-render a demanda.

const MAGIC = [0x47, 0x56, 0x44, 0x53, 0x48, 0x4d, 0x31, 0x00]  # "GVDSHM1\0"
const HEADER = 64
const INTERVAL_MS = 66          # cadencia de composición/lectura (~15 fps)
const BG = Color(0.06, 0.06, 0.08, 1.0)
const CELL_FRACTION = 0.7       # cada celda = 70% de la vista (deja recorrido de pan)
const PAN_LERP = 0.12           # suavizado del pan (por tick)

var _vp = null
var _canvas = null
var _slots = []                 # [{path, cell, tex, img, seq}]
var _local_vp = null            # Viewport raíz del shell (pantalla local)
var _local_cell = Vector2()
var _has_local = false
var _composite = Vector2()
var _pan = Vector2()
var _pan_max = Vector2()
var _cell = Vector2()
var _arr = Vector2()
var _min_cell = Vector2()
var _focus_cell = null          # celda del dueño del puntero (Vector2) o null
var _last_ms = 0


# `composite` (Vector2): tamaño del viewport de composición.
# `tiles`: Array de {"path": String, "cell": Vector2}.
# `local_viewport` (Viewport raíz) + `local_cell` (Vector2): tile local; null para no
# incluirlo.
func start(composite, tiles, local_viewport = null, local_cell = null):
	stop()
	_composite = Vector2(composite)
	if _composite.x < 2.0 or _composite.y < 2.0:
		return false
	_vp = Viewport.new()
	_vp.size = _composite
	_vp.usage = Viewport.USAGE_2D
	_vp.transparent_bg = false
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
		_slots.append({"path": path,
			"cell": Vector2(cell) if typeof(cell) == TYPE_VECTOR2 else Vector2(),
			"tex": null, "img": null, "seq": -1})
	_cell = Vector2(max(16.0, _composite.x * CELL_FRACTION),
		max(16.0, _composite.y * CELL_FRACTION))
	_layout()
	_canvas.update()
	_vp.render_target_update_mode = Viewport.UPDATE_ONCE
	return true


func stop():
	_slots = []
	_local_vp = null
	_has_local = false
	_focus_cell = null
	if _vp != null:
		_vp.queue_free()
		_vp = null
	_canvas = null


# Celda del tile dueño del puntero (para centrar el pan). Vector2 o null.
func set_focus_cell(cell):
	_focus_cell = Vector2(cell) if typeof(cell) == TYPE_VECTOR2 else null


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


# Disposición sobre los tiles CON imagen (local + slots con tex): bounding box de
# celdas, sin gutter. Recalcula pan_max.
func _layout():
	var minc = Vector2(1e9, 1e9)
	var maxc = Vector2(-1e9, -1e9)
	var have = false
	if _has_local:
		minc = _local_cell
		maxc = _local_cell
		have = true
	for s in _slots:
		if s.tex == null:
			continue
		minc = Vector2(min(minc.x, s.cell.x), min(minc.y, s.cell.y))
		maxc = Vector2(max(maxc.x, s.cell.x), max(maxc.y, s.cell.y))
		have = true
	if not have:
		minc = Vector2.ZERO
		maxc = Vector2.ZERO
	_min_cell = minc
	_arr = Vector2((maxc.x - minc.x + 1.0) * _cell.x, (maxc.y - minc.y + 1.0) * _cell.y)
	_pan_max = Vector2(max(0.0, _arr.x - _composite.x), max(0.0, _arr.y - _composite.y))


# Rect de una celda SIN pan (base + centrado si la disposición es más chica que la vista).
func _base_rect(cell):
	var base = Vector2((cell.x - _min_cell.x) * _cell.x, (cell.y - _min_cell.y) * _cell.y)
	var center = Vector2(max(0.0, (_composite.x - _arr.x) * 0.5),
		max(0.0, (_composite.y - _arr.y) * 0.5))
	return Rect2(base + center, _cell)


func _cell_rect(cell):
	return Rect2(_base_rect(cell).position - _pan, _cell)


func _process(_delta):
	if _vp == null:
		return
	var now = OS.get_ticks_msec()
	if now - _last_ms < INTERVAL_MS:
		return
	_last_ms = now
	var changed = false
	if _has_local:
		changed = true
	for s in _slots:
		if _read_slot(s):
			changed = true
	if changed:
		_layout()
		_update_pan()
		_canvas.update()
		_vp.render_target_update_mode = Viewport.UPDATE_ONCE


func _update_pan():
	var target = _pan
	if _focus_cell != null:
		var fr = _base_rect(_focus_cell)
		target = fr.position + fr.size * 0.5 - _composite * 0.5
	elif _has_local and _local_vp != null and is_instance_valid(_local_vp):
		var vsize = _local_vp.get_size()
		if vsize.x > 1.0 and vsize.y > 1.0:
			var mn = _local_vp.get_mouse_position() / vsize
			target = Vector2(clamp(mn.x, 0.0, 1.0) * _pan_max.x,
				clamp(mn.y, 0.0, 1.0) * _pan_max.y)
	target = Vector2(clamp(target.x, 0.0, _pan_max.x), clamp(target.y, 0.0, _pan_max.y))
	_pan = _pan.linear_interpolate(target, PAN_LERP)


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


static func _u32(ba, off):
	return int(ba[off]) | (int(ba[off + 1]) << 8) \
		| (int(ba[off + 2]) << 16) | (int(ba[off + 3]) << 24)


static func _u64(ba, off):
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
	for s in _slots:
		if s.tex == null:
			continue
		_canvas.draw_texture_rect(s.tex, _fit_rect(s.tex.get_size(), _cell_rect(s.cell)), false)
	if _has_local and _local_vp != null and is_instance_valid(_local_vp):
		var ltex = _local_vp.get_texture()
		if ltex != null:
			_draw_local(ltex, _fit_rect(ltex.get_size(), _cell_rect(_local_cell)))


# El viewport raíz llega en la orientación opuesta a los frames shm: espejo vertical.
func _draw_local(tex, rect):
	_canvas.draw_set_transform(Vector2(rect.position.x, rect.position.y + rect.size.y),
		0.0, Vector2(1.0, -1.0))
	_canvas.draw_texture_rect(tex, Rect2(Vector2(), rect.size), false)
	_canvas.draw_set_transform(Vector2(), 0.0, Vector2(1.0, 1.0))


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
