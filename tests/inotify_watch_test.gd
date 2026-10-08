extends SceneTree

# Autoprueba del vigilante inotify (modules/inotify, GdtkFileWatch): crear un
# archivo en un directorio vigilado debe disparar la señal `changed` (vía
# call_deferred, en el hilo principal) sin sondeo. Requiere el motor nuevo.
# Correr:
#   <godot con módulo inotify> --no-window --path shell -s tests/inotify_watch_test.gd

var failed = 0
var w = null
var base = ""
var frames = 0
var got = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _on_changed():
	got += 1


func _finish():
	if w != null:
		w.stop()
	OS.exit_code = 1 if failed > 0 else 0
	quit()


func _init():
	check("clase GdtkFileWatch", ClassDB.class_exists("GdtkFileWatch"))
	base = "/tmp/gdtk_inotify_test_%d" % OS.get_ticks_msec()
	Directory.new().make_dir_recursive(base)
	w = ClassDB.instance("GdtkFileWatch")
	check("instancia", w != null)
	if w == null:
		_finish()
		return
	check("watch()", w.watch(base))
	check("is_watching()", w.is_watching())
	w.connect("changed", self, "_on_changed")
	w.start()
	var f = File.new()
	if f.open(base + "/nueva.desktop", File.WRITE) == OK:
		f.store_string("x")
		f.close()
	check("archivo creado", File.new().file_exists(base + "/nueva.desktop"))


func _idle(_delta):
	frames += 1
	if frames == 6:
		check("señal changed tras crear archivo", got > 0)
		_finish()
