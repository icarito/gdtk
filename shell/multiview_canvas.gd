extends Node

# Composición OFFLINE de la "Vista del grupo" (SPEC-multiview-portal §7/§9 N1).
#
# Cada peer publica sus frames en un archivo shm (contrato GVDSHM1, escrito por
# `gvd recv --sink shmout`); este nodo los lee, los sube como ImageTexture y los
# dispone en un Viewport FUERA DE PANTALLA usando el MISMO LAYOUT que la vista
# Pantallas: cada pantalla en su rect físico (settings["screens"]), y todo el conjunto
# se escala para entrar en el feed. Así la composición respeta la disposición real
# (posiciones y tamaños) sin huecos artificiales: los únicos huecos son los del propio
# layout. El feed del portal (F5) empuja el texture de ESE viewport.
#
# Sólo se incluyen tiles CON imagen (la local siempre; un peer entra recién cuando
# llega su primer frame): un tile sin señal no reserva rect -> no deja hueco.
#
# Nunca bloquea: lectura de archivo por tick (tmpfs) y re-render a demanda.

const MAGIC = [0x47, 0x56, 0x44, 0x53, 0x48, 0x4d, 0x31, 0x00]  # "GVDSHM1\0"
const HEADER = 64
const INTERVAL_MS = 66          # cadencia de composición/lectura (~15 fps)
const BG = Color(0.06, 0.06, 0.08, 1.0)
# Margen relativo entre pantallas del layout físico (mm): 0 = pegadas.
const LAYOUT_MARGIN = 0.0

var _vp = null
var _canvas = null
var _slots = []                 # [{path, rect: Rect2 (físico), tex, img, seq}]
var _local_vp = null            # Viewport raíz del shell (pantalla local)
var _local_phys = Rect2()
var _has_local = false
var _composite = Vector2()
var _bbox_pos = Vector2()
var _scale = 1.0
var _origin = Vector2()
var _last_ms = 0


# `composite` (Vector2): tamaño del viewport de composición.
# `tiles`: Array de {"path": String, "rect": Rect2} (rect físico del layout).
# `local_viewport` (Viewport raíz) + `local_phys` (Rect2 físico): tile local; null para
# no incluirlo.
func start(composite, tiles, local_viewport = null, local_phys = null):
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
	_has_local = local_viewport != null and typeof(local_phys) == TYPE_RECT2 and local_phys.size.x > 0.0
	_local_phys = Rect2(local_phys) if _has_local else Rect2()
	_slots = []
	for t in (tiles if typeof(tiles) == TYPE_ARRAY else []):
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var path = String(t.get("path", "")).strip_edges()
		var r = t.get("rect", null)
		if path == "" or typeof(r) != TYPE_RECT2 or r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		_slots.append({"path": path, "rect": Rect2(r), "tex": null, "img": null, "seq": -1})
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


# Escala el bounding box de los tiles CON imagen (local + slots con tex) para entrar en
# el composite, centrado. Los huecos del layout son los del propio layout físico.
func _layout():
	var minp = Vector2(1e20, 1e20)
	var maxp = Vector2(-1e20, -1e20)
	var have = false
	if _has_local:
		var m = _local_phys.grow(LAYOUT_MARGIN)
		minp = m.position
		maxp = m.position + m.size
		have = true
	for s in _slots:
		if s.tex == null:
			continue
		var r = s.rect.grow(LAYOUT_MARGIN)
		minp = Vector2(min(minp.x, r.position.x), min(minp.y, r.position.y))
		maxp = Vector2(max(maxp.x, r.position.x + r.size.x), max(maxp.y, r.position.y + r.size.y))
		have = true
	if not have:
		minp = Vector2.ZERO
		maxp = Vector2.ONE
	_bbox_pos = minp
	var sz = maxp - minp
	_scale = min(_composite.x / sz.x, _composite.y / sz.y) if sz.x > 0.0 and sz.y > 0.0 else 1.0
	_origin = (_composite - sz * _scale) * 0.5


# Rect en pantalla (composite) de un rect físico del layout.
func _scaled_rect(phys):
	var p = (phys.position - _bbox_pos) * _scale + _origin
	return Rect2(p, phys.size * _scale)


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
		_canvas.update()
		_vp.render_target_update_mode = Viewport.UPDATE_ONCE


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
		_canvas.draw_texture_rect(s.tex, _fit_rect(s.tex.get_size(), _scaled_rect(s.rect)), false)
	if _has_local and _local_vp != null and is_instance_valid(_local_vp):
		var ltex = _local_vp.get_texture()
		if ltex != null:
			_draw_local(ltex, _fit_rect(ltex.get_size(), _scaled_rect(_local_phys)))


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
