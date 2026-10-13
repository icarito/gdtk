extends SceneTree

# Autoprueba del modelo puro de presencia Deskflow (deskflow_presence.gd):
#   "$BIN" --no-window --path shell -s $PWD/tests/deskflow_presence_test.gd

var failed = 0


func check(name, cond):
	if cond:
		print("ok   " + name)
	else:
		failed += 1
		print("FAIL " + name)


func _init():
	var P = load("res://deskflow_presence.gd")
	var layout = {
		"version": 2,
		"local": {"id": "me", "label": "Este equipo", "local": true,
			"x": 0.0, "y": 0.0, "w": 340.0, "h": 200.0},
		"screens": [
			{"id": "h1", "label": "A", "peer": "a", "x": 340.0, "y": 0.0, "w": 340.0, "h": 200.0},
			{"id": "h2", "label": "B", "peer": "b", "x": -340.0, "y": 0.0, "w": 340.0, "h": 200.0},
			{"id": "h3", "label": "C", "peer": "c", "x": 340.0, "y": 200.0, "w": 340.0, "h": 200.0},
		],
	}
	check("todos vistos: sin bloqueo", P.absent_directions(layout, ["h1", "h2", "h3"]).empty())
	check("sólo oeste ausente", P.absent_directions(layout, ["h1", "h3"]) == ["west"])
	check("este y oeste ausentes", P.absent_directions(layout, ["h3"]) == ["east", "west"])
	check("todos apagados: ambos", P.absent_directions(layout, []).size() == 2)
	check("determinista", P.absent_directions(layout, ["h1"]) == P.absent_directions(layout, ["h1"]))
	check("layout nulo", P.absent_directions(null, ["h1"]).empty())
	check("present_ids no array", P.absent_directions(layout, "h1").empty())
	check("layout vacío", P.absent_directions({}, []).empty())
	OS.exit_code = 1 if failed > 0 else 0
	quit()
