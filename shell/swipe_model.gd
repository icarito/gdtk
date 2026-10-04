extends Reference

# Modelo puro del gesto continuo de 3 dedos (estilo GNOME): sigue el arrastre,
# bloquea un eje tras LOCK_PX y al soltar decide un paso por snap o por fling.
#
# Convención de signo (libinput): delta positivo = dedos a la derecha/abajo.
# Sin I/O ni nodos: sólo estado y matemática.

const LOCK_PX = 12.0
const DISTANCE_FACTOR = 0.6
const FLING = 0.4
const VELOCITY_WINDOW_MS = 100.0
const SNAP_RATIO = 0.5

# active: hay un gesto en curso. axis: "" hasta bloquear, luego "x" o "y".
var active = false
var fingers = 0
var axis = ""

var _accum = Vector2.ZERO
var _samples = []
var _last_size = 0.0


func begin(fingers_count, now_ms):
	active = true
	fingers = int(fingers_count)
	axis = ""
	_accum = Vector2.ZERO
	_last_size = 0.0
	_samples = [{"t": float(now_ms), "x": 0.0, "y": 0.0}]


func update(delta, now_ms):
	if not active:
		return
	_accum += delta
	if axis == "":
		var ax = abs(_accum.x)
		var ay = abs(_accum.y)
		if ax > LOCK_PX or ay > LOCK_PX:
			axis = "x" if ax >= ay else "y"
	_samples.append({"t": float(now_ms), "x": _accum.x, "y": _accum.y})
	_prune(now_ms)


# Desplazamiento acumulado en el eje / (size * DISTANCE_FACTOR), sin clamp.
func progress(size):
	_last_size = float(size)
	if axis == "" or _last_size <= 0.0:
		return 0.0
	return _axis_accum() / (_last_size * DISTANCE_FACTOR)


# px/ms en el eje, usando sólo muestras dentro de la ventana reciente.
func velocity(now_ms):
	if axis == "":
		return 0.0
	_prune(now_ms)
	if _samples.size() < 2:
		return 0.0
	var a = _samples[0]
	var b = _samples[_samples.size() - 1]
	if float(now_ms) - float(b["t"]) > VELOCITY_WINDOW_MS:
		return 0.0
	var dt = float(b["t"]) - float(a["t"])
	if dt <= 0.0:
		return 0.0
	var dv = float(b[axis]) - float(a[axis])
	return dv / dt


func end(cancelled, now_ms, size = null):
	if size != null:
		_last_size = float(size)
	var v = velocity(now_ms)
	var p = 0.0
	if axis != "" and _last_size > 0.0:
		p = _axis_accum() / (_last_size * DISTANCE_FACTOR)
	var s = 0
	if not cancelled and axis != "":
		if abs(v) > FLING:
			s = 1 if v > 0.0 else -1
		elif abs(p) >= SNAP_RATIO:
			s = 1 if p > 0.0 else -1
	active = false
	return {"axis": axis, "progress": p, "velocity": v, "step": s}


func reset():
	active = false
	fingers = 0
	axis = ""
	_accum = Vector2.ZERO
	_samples.clear()
	_last_size = 0.0


func _axis_accum():
	return _accum.x if axis == "x" else _accum.y


func _prune(now_ms):
	while _samples.size() > 2 \
			and float(now_ms) - float(_samples[1]["t"]) > VELOCITY_WINDOW_MS:
		_samples.pop_front()
