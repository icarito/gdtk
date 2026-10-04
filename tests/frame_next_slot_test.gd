extends SceneTree

# Prueba pura de `next_free_slot` (alta de bloques nuevos en la barra del Frame).
# Correr:
#   /home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk \
#     --no-window --path shell -s $PWD/tests/frame_next_slot_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var F = load("res://frame.gd")
	check("barra vacía: celda 0", F.next_free_slot([], 1, 10, "w") == 0)
	check("después del último bloque", F.next_free_slot(["a", "b"], 1, 10, "w") == 2)
	check("ignora huecos intermedios", F.next_free_slot(["a", "", "", "b"], 1, 10, "w") == 4)
	check("span 2 al final", F.next_free_slot(["a"], 2, 10, "w") == 1)
	check("tras el tramo de ventanas: extremo de la barra", F.next_free_slot(["a", "w"], 1, 10, "w") == 9)
	check("extremo con span 2", F.next_free_slot(["w"], 2, 10, "w") == 8)
	check("sin entrar al final: primera libre", F.next_free_slot(["a", "", "b", "c", "d"], 1, 5, "w") == 1)
	check("barra llena = -1", F.next_free_slot(["a", "b"], 1, 2, "w") == -1)
	print("FRAME_NEXT_SLOT_TEST_" + ("OK" if failed == 0 else "FAIL"))
	OS.exit_code = 1 if failed > 0 else 0
	quit()
