extends Node

# Composición OFFLINE de la "Vista del grupo" (SPEC-multiview-portal §7/§9 N1).
#
# Cada peer publica frames en un archivo shm (GVDSHM1, escrito por `gvd recv --sink
# shmout`); este nodo los lee, los sube como ImageTexture y los dispone en un Viewport
# FUERA DE PANTALLA usando el MISMO LAYOUT que la vista Pantallas (rect físico por
# pantalla). F5 empuja ese texture.
#
# Cámara: una pantalla "enfocada" (la que está bajo el puntero) LLENA el viewport
# (cover: usa todo el ancho/alto según su aspecto) x zoom; el eje que sobra se panea con
# el mouse. El centro y la escala se suavizan (lerp) para animar el paso entre pantallas.
# Sólo se incluyen tiles con imagen (local siempre; un peer entra con su primer frame).

const MAGIC = [0x47, 0x56, 0x44, 0x53, 0x48, 0x4d, 0x31, 0x00]  # "GVDSHM1\0"
const HEADER = 64
const INTERVAL_MS = 100         # composición/lectura ~10 fps (barato para peers lentos)
const STALE_MS = 2500           # un tile sin frames frescos sale de la vista
const BG = Color(0.06, 0.06, 0.08, 1.0)
const CAM_LERP = 0.14           # suavizado de la cámara (por tick): anima el paso

var _vp = null
var _canvas = null
var _slots = []                 # [{path, rect: Rect2 (físico), tex, img, seq, last_ms}]
var _local_vp = null
var _local_phys = Rect2()
var _has_local = false
var _composite = Vector2()
var _bbox_pos = Vector2()
var _sz = Vector2.ONE
var _focus_phys = null
var _zoom = 1.7
var _pan_enabled = true
var _cam_center = Vector2()
var _cam_scale = 1.0
var _cam_ready = false
var _frame_seq = 0
var _last_ms = 0


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
		_slots.append({"path": path, "rect": Rect2(r), "tex": null, "img": null, "seq": -1, "last_ms": 0})
	_cam_ready = false
	_recompute_bbox()
	_layout_cam(true)
	_canvas.update()
	_vp.render_target_update_mode = Viewport.UPDATE_ONCE
	return true


func stop():
	_slots = []
	_local_vp = null
	_has_local = false
	_focus_phys = null
	_cam_ready = false
	if _vp != null:
		_vp.queue_free()
		_vp = null
	_canvas = null


func set_focus_rect(phys):
	_focus_phys = Rect2(phys) if typeof(phys) == TYPE_RECT2 else null


func set_zoom(z):
	_zoom = clamp(float(z), 0.5, 8.0)


func get_zoom():
	return _zoom


func set_pan_enabled(b):
	_pan_enabled = bool(b)


func is_pan_enabled():
	return _pan_enabled


func get_texture():
	return _vp.get_texture() if _vp != null else null


func is_active():
	return _vp != null


func composite_size():
	return _composite


func frame_seq():
	return _frame_seq


func _exit_tree():
	if _vp != null:
		_vp.queue_free()
		_vp = null


# Bounding box del layout (para el mini-radar y el fallback sin foco).
func _recompute_bbox():
	var minp = Vector2(1e20, 1e20)
	var maxp = Vector2(-1e20, -1e20)
	var have = false
	if _has_local:
		minp = _local_phys.position
		maxp = _local_phys.position + _local_phys.size
		have = true
	var now = OS.get_ticks_msec()
	for s in _slots:
		if not _is_live(s, now):
			continue
		minp = Vector2(min(minp.x, s.rect.position.x), min(minp.y, s.rect.position.y))
		maxp = Vector2(max(maxp.x, s.rect.position.x + s.rect.size.x),
			max(maxp.y, s.rect.position.y + s.rect.size.y))
		have = true
	if not have:
		minp = Vector2.ZERO
		maxp = Vector2.ONE
	_bbox_pos = minp
	_sz = maxp - minp


# Cámara objetivo: la pantalla enfocada LLENA el viewport (cover) x zoom; el mouse panea
# el eje que sobra. Sin foco, encaja el layout entero.
func _view_target():
	if _focus_phys != null and _focus_phys.size.x > 0.0 and _focus_phys.size.y > 0.0:
		var s = max(_composite.x / _focus_phys.size.x, _composite.y / _focus_phys.size.y) * _zoom
		var c = _focus_phys.position + _focus_phys.size * 0.5
		if _pan_enabled and _has_local and _local_vp != null and is_instance_valid(_local_vp):
			var vs = _local_vp.get_size()
			if vs.x > 1.0 and vs.y > 1.0:
				var mn = _local_vp.get_mouse_position() / vs
				var over = Vector2(max(0.0, _focus_phys.size.x * s - _composite.x) / s,
					max(0.0, _focus_phys.size.y * s - _composite.y) / s)
				c += Vector2((clamp(mn.x, 0.0, 1.0) - 0.5) * over.x,
					(clamp(mn.y, 0.0, 1.0) - 0.5) * over.y)
		return {"scale": s, "center": c}
	var sz = _sz if _sz.x > 0.0 and _sz.y > 0.0 else Vector2.ONE
	var s2 = min(_composite.x / sz.x, _composite.y / sz.y) * _zoom
	return {"scale": s2, "center": _bbox_pos + sz * 0.5}


# Avanza la cámara hacia el objetivo (o la fija si `snap`).
func _layout_cam(snap = false):
	var t = _view_target()
	if snap or not _cam_ready:
		_cam_scale = float(t.scale)
		_cam_center = Vector2(t.center)
		_cam_ready = true
	else:
		_cam_scale = lerp(_cam_scale, float(t.scale), CAM_LERP)
		_cam_center = _cam_center.linear_interpolate(Vector2(t.center), CAM_LERP)


func _process(_delta):
	if _vp == null:
		return
	var now = OS.get_ticks_msec()
	if now - _last_ms < INTERVAL_MS:
		return
	_last_ms = now
	for s in _slots:
		_read_slot(s)
	_recompute_bbox()
	_layout_cam(false)
	_canvas.update()
	_vp.render_target_update_mode = Viewport.UPDATE_ONCE
	_frame_seq += 1


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
	s.last_ms = OS.get_ticks_msec()
	return true


func _is_live(s, now):
	return s.tex != null and (now - int(s.last_ms)) < STALE_MS


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


# Rect en pantalla de un rect físico, con la cámara actual.
func _cam_rect(phys):
	var p = (phys.position - _cam_center) * _cam_scale + _composite * 0.5
	return Rect2(p, phys.size * _cam_scale)


func _draw():
	_canvas.draw_rect(Rect2(Vector2(), _composite), BG)
	var now = OS.get_ticks_msec()
	for s in _slots:
		if not _is_live(s, now):
			continue
		_canvas.draw_texture_rect(s.tex, _cam_rect(s.rect), false)
	if _has_local and _local_vp != null and is_instance_valid(_local_vp):
		var ltex = _local_vp.get_texture()
		if ltex != null:
			_draw_local(ltex, _cam_rect(_local_phys))


# El viewport raíz llega en la orientación opuesta a los frames shm: espejo vertical.
func _draw_local(tex, rect):
	_canvas.draw_set_transform(Vector2(rect.position.x, rect.position.y + rect.size.y),
		0.0, Vector2(1.0, -1.0))
	_canvas.draw_texture_rect(tex, Rect2(Vector2(), rect.size), false)
	_canvas.draw_set_transform(Vector2(), 0.0, Vector2(1.0, 1.0))


func _frac_of(phys):
	if _sz.x <= 0.0 or _sz.y <= 0.0:
		return Rect2()
	return Rect2((phys.position - _bbox_pos) / _sz, phys.size / _sz)


func mini_rects():
	var out = []
	if _has_local:
		out.append({"rect": _frac_of(_local_phys), "local": true})
	var now = OS.get_ticks_msec()
	for s in _slots:
		if _is_live(s, now):
			out.append({"rect": _frac_of(s.rect), "local": false})
	return out


# Ventana visible normalizada dentro del bbox del layout (0..1).
func viewport_frac():
	if _sz.x <= 0.0 or _sz.y <= 0.0 or _cam_scale <= 0.0:
		return Rect2(0.0, 0.0, 1.0, 1.0)
	var half = (_composite * 0.5) / _cam_scale
	var tl = (_cam_center - half - _bbox_pos) / _sz
	var size = (_composite / _cam_scale) / _sz
	return Rect2(Vector2(clamp(tl.x, 0.0, 1.0), clamp(tl.y, 0.0, 1.0)),
		Vector2(clamp(size.x, 0.0, 1.0), clamp(size.y, 0.0, 1.0)))


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
