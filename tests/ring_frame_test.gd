extends SceneTree

# Autoprueba de la lógica nueva del Hogar/anillo y del Frame que no necesita
# compositor: favoritos del anillo (persistencia, entradas), layout animado,
# inserción con hueco de applets/pines y helpers de basurero/zona del anillo.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/ring_frame_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	# XDG_CONFIG_HOME temporal para no tocar los favoritos reales del usuario.
	var base = OS.get_user_data_dir() + "/ringframe_test"
	Directory.new().make_dir_recursive(base)
	OS.set_environment("XDG_CONFIG_HOME", base)
	Directory.new().remove(base + "/gdtk/ring-favorites.json")

	var shell = load("res://shell.gd").new()
	var frame = load("res://frame.gd").new()
	shell.frame = frame   # en producción lo setea _ready
	frame.shell = shell   # onready get_parent() fuera del árbol

	# 1) Salir ya no es actividad del anillo.
	var names = []
	for a in shell.ACTIVITIES:
		names.append(a.name)
	check("ACTIVITIES sin Salir: " + str(names), not names.has("Salir"))

	# 2) Layout orbital generalizado (actividades + favoritos).
	var lay = shell._orbit_layout(Vector2(1024, 600), 9)
	check("_orbit_layout(9) devuelve 9", lay.size() == 9)
	var in_bounds = true
	for p in lay:
		if p.x < 0 or p.x > 1024 or p.y < 80 or p.y > 600:
			in_bounds = false
	check("posiciones dentro del lienzo", in_bounds)
	check("_home_layout coincide con ACTIVITIES", shell._home_layout(Vector2(1024, 600)).size() == shell.ACTIVITIES.size())

	# 3) Entradas del anillo: actividades primero; favoritos sin app resuelta se omiten.
	var entries = shell._ring_entries()
	var kinds_ok = true
	for i in range(shell.ACTIVITIES.size()):
		if entries[i].kind != "activity":
			kinds_ok = false
	check("entradas del anillo empiezan por actividades", kinds_ok and entries.size() >= shell.ACTIVITIES.size())

	# 4) Persistencia de favoritos (tmp + rename) y recarga.
	shell.ring_favorites = ["zzz-a.desktop", "zzz-b.desktop"]
	shell._save_ring()
	var f = File.new()
	var wrote = f.open(shell._ring_path(), File.READ) == OK
	var body = f.get_as_text() if wrote else ""
	if wrote:
		f.close()
	check("ring-favorites.json escrito", wrote and body.find("zzz-a.desktop") >= 0)
	shell.ring_favorites = []
	shell._load_ring()
	check("recarga conserva el orden", shell.ring_favorites == ["zzz-a.desktop", "zzz-b.desktop"])
	var saved = shell.ring_saved.duplicate()
	shell._save_ring()
	check("_save_ring no-op sin cambios", shell.ring_saved == saved)

	# 5) Animación del layout del anillo: ease-out y retarget.
	shell.ring_pos = {}
	shell.ring_anim = {}
	shell.ring_intro = {}
	var target = Vector2(100, 200)
	var p0 = shell._ring_show("X", target, 1000)
	check("entrada nueva aparece en destino", p0 == target and shell.ring_intro.has("X"))
	var target2 = Vector2(300, 200)
	shell._ring_show("X", target2, 1000)  # arranca el retarget
	var mid = shell._ring_show("X", target2, 1000 + shell.LAYOUT_MS / 2)
	check("animación en curso entre from y to", mid.x > 100 and mid.x < 300)
	var endv = shell._ring_show("X", target2, 1000 + shell.LAYOUT_MS + 1)
	check("al terminar llega al objetivo", (endv - target2).length() < 0.5)
	check("ease_out acota 0..1", shell._ease_out(-1.0) == 0.0 and shell._ease_out(2.0) == 1.0)
	shell._ring_prune([])
	check("_ring_prune limpia estado", shell.ring_pos.empty() and shell.ring_intro.empty())

	# 6) Inserción con hueco (applets y pines comparten el mismo helper).
	check("order gap slot 0", frame._order_with_gap(["a", "b", "c"], "a", 0) == ["a", "b", "c"])
	check("order gap slot 1", frame._order_with_gap(["a", "b", "c"], "a", 1) == ["b", "a", "c"])
	check("order gap slot fin", frame._order_with_gap(["a", "b", "c"], "a", 3) == ["b", "c", "a"])
	check("order gap item externo", frame._order_with_gap(["a", "b"], "z", 1) == ["a", "z", "b"])

	# 7) Slot de applets: cuenta centros a la izquierda, saltando el arrastrado.
	frame.applets_layout = [
		{"id": "a", "x": 0, "y": 0, "w": 80},
		{"id": "b", "x": 80, "y": 0, "w": 80},
		{"id": "c", "x": 160, "y": 0, "w": 80}]
	frame.applet_drag = "b"
	check("_applet_slot x=50 -> 1", frame._applet_slot(50) == 1)
	check("_applet_slot x=10 -> 0", frame._applet_slot(10) == 0)
	check("_applet_slot x=200 -> 1 (sin b, borde)", frame._applet_slot(200) == 1)
	check("_applet_slot x=240 -> 2 (sin b)", frame._applet_slot(240) == 2)
	frame.applet_drag = null

	# 8) Slot de pines por zona, saltando el arrastrado.
	frame.pinned_prev = [
		{"app": {"id": "p1"}, "rect": Rect2(100, 0, 80, 80), "zone": "top"},
		{"app": {"id": "p2"}, "rect": Rect2(190, 0, 80, 80), "zone": "top"},
		{"app": {"id": "d1"}, "rect": Rect2(6, 0, 80, 80), "zone": "dock"}]
	frame.app_drag = {"id": "p1"}
	check("_pin_slot top x=150 -> 0 (p1 se salta)", frame._pin_slot("top", 150) == 0)
	check("_pin_slot top x=250 -> 1 (sin p1)", frame._pin_slot("top", 250) == 1)
	check("_pin_slot dock no mezcla top", frame._pin_slot("dock", 90) == 1)
	frame.app_drag = null

	# 9) Basurero y estado de drag.
	check("is_trash falso sin layout", not frame.is_trash(Vector2(10, 10)))
	frame.trash_layout = Rect2(900, 0, 80, 80)
	check("is_trash verdadero dentro", frame.is_trash(Vector2(950, 40)))
	check("is_trash falso fuera", not frame.is_trash(Vector2(10, 40)))
	check("_drag_active falso en reposo", not frame._drag_active())
	frame.app_drag = {"id": "x"}
	check("_drag_active con drag", frame._drag_active())
	frame.app_drag = null

	# 10) Reorden de favoritos: el arrastrado toma el lugar del más cercano.
	shell.ring_favorites = ["a", "b", "c"]
	shell.ring_layout = [
		{"entry": {"kind": "favorite", "app": {"id": "b"}, "name": "B"}, "screen": Vector2(100, 100), "size": Vector2(80, 80)},
		{"entry": {"kind": "favorite", "app": {"id": "c"}, "name": "C"}, "screen": Vector2(300, 300), "size": Vector2(80, 80)}]
	shell.ring_drag = {"kind": "favorite", "app": {"id": "a"}, "name": "A"}
	check("target cerca de C", shell._favorite_target_near(Vector2(330, 330)) == "c")
	check("target lejos -> sin reorden", shell._favorite_target_near(Vector2(800, 800)) == "")
	shell._finish_ring_drag(Vector2(330, 330))
	check("A toma el lugar de C: [b, a, c]", shell.ring_favorites == ["b", "a", "c"])
	shell.ring_drag = null

	# 11) Ring -> basurero borra el favorito (una actividad no).
	frame.trash_layout = Rect2(900, 0, 80, 80)
	shell.ring_favorites = ["a", "b"]
	shell.ring_drag = {"kind": "favorite", "app": {"id": "a"}, "name": "A"}
	shell._finish_ring_drag(Vector2(950, 40))
	check("basurero borra el favorito", shell.ring_favorites == ["b"])
	shell.ring_drag = {"kind": "activity", "app": null, "name": "Chat"}
	shell._finish_ring_drag(Vector2(950, 40))
	check("basurero no borra una actividad", shell.ring_favorites == ["b"])
	shell.ring_drag = null
	frame.trash_layout = null

	# 12) Animación de la barra: arranca en el destino, retarget con ease-out y asienta.
	check("_bar_x primera vez = destino", frame._bar_x("t", 100.0, 1000) == 100.0)
	frame._bar_x("t", 200.0, 1000)  # arranca el retarget
	var bx = frame._bar_x("t", 200.0, 1000 + shell.LAYOUT_MS / 2)
	check("_bar_x interpola hacia el destino", bx > 100.0 and bx < 200.0)
	check("_bar_x al final = destino", frame._bar_x("t", 200.0, 1000 + shell.LAYOUT_MS + 1) == 200.0)
	frame._bar_set("t", 50.0)
	check("_bar_x arranca desde el cursor", frame._bar_x("t", 200.0, 5000) == 50.0)
	check("_bar_x asienta en el destino", frame._bar_x("t", 200.0, 5000 + shell.LAYOUT_MS + 1) == 200.0)

	frame.free()
	shell.free()
	print("RING_FRAME_TEST_" + ("OK" if failed == 0 else "FAIL"))
	OS.exit_code = 1 if failed > 0 else 0
	quit()
