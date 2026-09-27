extends Node

# Runner del benchmark (SPEC-hud D). Carga godot_ui.tscn o imgui_ui.tscn,
# calienta `warmup` frames, mide `frames` frames y escribe un JSON con la media
# y el p95 de cada metrica.

var ui_kind = "godot"
var mode = "static"
var count = 20
var warmup = 120
var frames_total = 600
var out_path = ""

var scene_root = null
var frame = 0
var last_usec = 0
var samples = []
var finished = false


func _ready():
	_parse_args()

	OS.vsync_enabled = false
	Engine.target_fps = 0
	Engine.time_scale = 1.0

	var packed = load("res://%s_ui.tscn" % ui_kind)
	if packed == null:
		printerr("ui_bench: no se pudo cargar ", ui_kind)
		get_tree().quit(1)
		return
	scene_root = packed.instance()
	add_child(scene_root)
	if scene_root.has_method("configure"):
		scene_root.configure(count, mode)

	set_process(true)


func _parse_args():
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--ui="):
			ui_kind = arg.substr(5)
		elif arg.begins_with("--mode="):
			mode = arg.substr(7)
		elif arg.begins_with("--n="):
			count = int(arg.substr(4))
		elif arg.begins_with("--warmup="):
			warmup = int(arg.substr(9))
		elif arg.begins_with("--frames="):
			frames_total = int(arg.substr(9))
		elif arg.begins_with("--out="):
			out_path = arg.substr(6)


func _process(_delta):
	if finished:
		return
	var now = OS.get_ticks_usec()
	if last_usec == 0:
		last_usec = now
		return
	var frame_ms = float(now - last_usec) / 1000.0
	last_usec = now

	if frame >= warmup:
		samples.append({
			"frame_ms": frame_ms,
			"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"draw_calls": Performance.get_monitor(Performance.RENDER_DRAW_CALLS_IN_FRAME),
			"items_2d": Performance.get_monitor(Performance.RENDER_2D_ITEMS_IN_FRAME),
			"draw_2d": Performance.get_monitor(Performance.RENDER_2D_DRAW_CALLS_IN_FRAME),
			"mem_static": Performance.get_monitor(Performance.MEMORY_STATIC),
			"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		})

	if mode == "dynamic" and scene_root != null and scene_root.has_method("set_frame_values"):
		scene_root.set_frame_values(frame)

	frame += 1
	if frame >= warmup + frames_total:
		_finish()


func _stats(key):
	var values = []
	for sample in samples:
		values.append(float(sample[key]))
	values.sort()
	var n = values.size()
	if n == 0:
		return {"mean": 0.0, "p95": 0.0}
	var total = 0.0
	for v in values:
		total += v
	var idx = int(round(0.95 * float(n - 1)))
	return {"mean": total / float(n), "p95": values[idx]}


func _finish():
	finished = true
	var result = {
		"ui": ui_kind,
		"mode": mode,
		"n": count,
		"frames": samples.size(),
		"metrics": {},
	}
	for key in ["frame_ms", "process_ms", "draw_calls", "items_2d", "draw_2d", "mem_static", "nodes"]:
		result["metrics"][key] = _stats(key)

	var text = JSON.print(result)
	if out_path != "":
		var file = File.new()
		if file.open(out_path, File.WRITE) == OK:
			file.store_string(text)
			file.close()
	print("BENCH_RESULT ", text)
	get_tree().quit(0)
