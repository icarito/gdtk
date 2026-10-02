extends SceneTree

# K13a — Autoprueba del modelo puro del modo de ventanas (flotante por defecto vs
# mosaico). Sin I/O, sin procesos, sin instanciar shell.gd.
#   godot --no-window --path shell -s $PWD/tests/wm_mode_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var S = load("res://wm_mode.gd")
	check("wm_mode.gd carga", S != null)
	check("selftest() del modelo", S.selftest())

	check("default flotante", S.default_mode() == S.FLOATING)
	check("normalize tiled", S.normalize("tiled") == S.TILED)
	check("normalize mosaico", S.normalize("mosaico") == S.TILED)
	check("normalize desconocido -> flotante", S.normalize("??") == S.FLOATING)
	check("is_floating", S.is_floating("floating") and not S.is_floating("tiled"))
	check("is_tiled", S.is_tiled("tiled") and not S.is_tiled("floating"))
	check("toggle ida y vuelta", S.toggled(S.toggled(S.FLOATING)) == S.FLOATING)

	# Parse/serialize: string, dict persistido y dict alternativo. Sin dato -> default.
	check("parse string", S.parse("tiled") == S.TILED)
	check("parse dict window_mode", S.parse({"window_mode": "tiled"}) == S.TILED)
	check("parse dict mode", S.parse({"mode": "floating"}) == S.FLOATING)
	check("parse dict vacío -> default", S.parse({}) == S.FLOATING)
	check("serialize canónico", S.serialize("TILED") == S.TILED)

	# Vocabulario visible en español; nunca jerga.
	check("label flotante", S.label("floating") == "Flotante")
	check("label mosaico", S.label("tiled") == "Mosaico")
	check("describe humano", S.describe("floating") == "Ventanas flotantes"
		and S.describe("tiled") == "Ventanas en mosaico")
	var terms = ["tiling", "layout", " wm", "server/client"]
	var blob = (S.label("floating") + S.label("tiled") + S.describe("floating") + S.describe("tiled")).to_lower()
	var clean = true
	for t in terms:
		if blob.find(t) >= 0:
			clean = false
	check("sin jerga en el vocabulario", clean)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
