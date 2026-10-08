extends SceneTree

# Autoprueba del modelo puro shell/window_memory.gd (memoria de ventanas entre
# reinicios). Sin disco ni compositor:
#   godot --no-window --path shell -s $PWD/tests/window_memory_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var WM = load("res://window_memory.gd")

	var es = [
		WM.entry("foot", "a", "tiled", null, false),
		WM.entry("foot", "b", "floating", Rect2(10, 20, 300, 200), true),
		WM.entry("foot", "c", "floating", null, false),
		WM.entry("firefox", "x", "floating", Rect2(0, 0, 100, 100), false)]

	var back = WM.parse(WM.serialize(es))
	check("roundtrip cuenta", back.size() == 4)
	check("roundtrip rect", back[1].rect == [10.0, 20.0, 300.0, 200.0] and back[1].maximized)
	check("roundtrip modo", back[0].mode == "tiled" and back[0].rect == null)
	check("parse basura", WM.parse("no json").empty() and WM.parse("[1]").empty())
	check("parse descarta sin app_id", WM.parse('{"windows":[{"title":"x"},{"app_id":"a"}]}').size() == 1)

	var t = WM.take(es, "foot", "b")
	check("take exacto", t != null and t.title == "b" and es.size() == 3)
	t = WM.take(es, "foot", "zzz")
	check("take app_id FIFO", t != null and t.title == "a")
	t = WM.take(es, "foot", "zzz")
	check("take segundo FIFO", t != null and t.title == "c")
	check("take agotado", WM.take(es, "foot", "zzz") == null)
	check("take sin app_id", WM.take(es, "", "x") == null)

	var m = WM.merge([WM.entry("a", "", "tiled", null, false)], [WM.entry("b", "", "tiled", null, false)])
	check("merge vivas primero", m.size() == 2 and m[0].app_id == "a" and m[1].app_id == "b")
	var many = []
	for i in range(100):
		many.append(WM.entry("a" + str(i), "", "tiled", null, false))
	check("cap", WM.merge(many, many).size() == WM.CAP and WM.parse(WM.serialize(many)).size() == WM.CAP)

	var box = Rect2(0, 0, 1000, 600)
	check("clamp dentro igual", WM.clamp_rect(Rect2(10, 20, 300, 200), box) == Rect2(10, 20, 300, 200))
	check("clamp fuera", WM.clamp_rect(Rect2(900, 500, 300, 200), box) == Rect2(700, 400, 300, 200))
	check("clamp tamaño", WM.clamp_rect(Rect2(-50, -50, 2000, 900), box) == Rect2(0, 0, 1000, 600))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
