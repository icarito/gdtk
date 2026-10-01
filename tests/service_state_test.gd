extends SceneTree

# Autoprueba del estado de servicios de shell.gd: parser puro de pgrep y merge del
# snapshot. No hace I/O ni arranca Threads. Correr:
#   godot --no-window --path shell -s $PWD/tests/service_state_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var S = load("res://shell.gd")

	# parse_pgrep_pids: vacío, válido con varias líneas y basura.
	check("parse_pgrep_pids vacío", S.parse_pgrep_pids("").empty())
	check("parse_pgrep_pids solo espacios", S.parse_pgrep_pids("\n  \n").empty())
	var pids = S.parse_pgrep_pids("1234\n5678\n9\n")
	check("parse_pgrep_pids varias líneas", pids == [1234, 5678, 9])
	var junk = S.parse_pgrep_pids("abc\n12x\n0\n-5\n42\n")
	check("parse_pgrep_pids ignora basura/0/negativos", junk == [42])

	# merge: sin proceso y sin gracia -> parado.
	var m = S.merge_service_snapshot({"Deskflow": []}, {}, 1000, {}, {})
	check("merge: sin proceso", not m.Deskflow.running and m.Deskflow.pids.empty())

	# merge: proceso medido -> corriendo con sus pids.
	m = S.merge_service_snapshot({"Deskflow": [11, 22]}, {}, 1000, {}, {})
	check("merge: con pids", m.Deskflow.running and m.Deskflow.pids == [11, 22])

	# merge: recién lanzado (gracia) y aún no visible -> sostiene el estado previo.
	var prev = {"Deskflow": {"running": true, "pids": [7]}}
	m = S.merge_service_snapshot({"Deskflow": []}, prev, 1000, {"Deskflow": 3000}, {})
	check("merge: gracia de lanzamiento sostiene", m.Deskflow.running and m.Deskflow.pids == [7])
	m = S.merge_service_snapshot({"Deskflow": []}, prev, 4000, {"Deskflow": 3000}, {})
	check("merge: gracia vencida -> parado", not m.Deskflow.running)

	# merge: recién parado con pids residuales -> se ignoran.
	m = S.merge_service_snapshot({"Deskflow": [5]}, prev, 1000, {}, {"Deskflow": 3000})
	check("merge: gracia de parada ignora residual",
		not m.Deskflow.running and m.Deskflow.pids.empty())

	# snapshot_equal: mismo contenido vs. cambios de running/pids/tamaño.
	check("snapshot_equal iguales",
		S.snapshot_equal({"a": {"running": true, "pids": [1]}},
			{"a": {"running": true, "pids": [1]}}))
	check("snapshot_equal distinto pid",
		not S.snapshot_equal({"a": {"running": true, "pids": [1]}},
			{"a": {"running": true, "pids": [2]}}))
	check("snapshot_equal distinto tamaño",
		not S.snapshot_equal({"a": {"running": false, "pids": []}}, {}))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
