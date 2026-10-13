extends SceneTree

# Autoprueba del resolver puro del dueño del puntero (SPEC-multiview-portal §8,
# "seguir el puntero"). No renderiza, no ejecuta procesos ni toca el disco.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/pointer_owner_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _matches(res, peer, direction):
	return typeof(res) == TYPE_DICTIONARY \
		and String(res.get("peer", "")) == peer \
		and String(res.get("direction", "")) == direction


func _init():
	var mod = load("res://pointer_owner.gd").new()
	check("selftest() de pointer_owner", mod.run_selftest())

	var vp = Vector2(1000, 800)

	# Un único link cubriendo todo el borde: cada dirección cardinal.
	check("east borde medio",
		_matches(mod.owner_at(Vector2(999, 400), vp,
			[{"direction": "east", "peer": "cupid", "local_range": [0, 100]}]),
			"cupid", "east"))
	check("west borde medio",
		_matches(mod.owner_at(Vector2(1, 400), vp,
			[{"direction": "west", "peer": "tengu", "local_range": [0, 100]}]),
			"tengu", "west"))
	check("north borde medio",
		_matches(mod.owner_at(Vector2(500, 1), vp,
			[{"direction": "north", "peer": "bastion", "local_range": [0, 100]}]),
			"bastion", "north"))
	check("south borde medio",
		_matches(mod.owner_at(Vector2(500, 799), vp,
			[{"direction": "south", "peer": "ana", "local_range": [0, 100]}]),
			"ana", "south"))

	# Dos pares en el mismo borde por tramos: gana el tramo que contiene la
	# fracción; en el borde exacto 50 gana el peer ascendente.
	var split = [
		{"direction": "east", "peer": "b", "local_range": [0, 50]},
		{"direction": "east", "peer": "a", "local_range": [50, 100]},
	]
	check("tramo [0,50] -> b", _matches(mod.owner_at(Vector2(999, 80), vp, split), "b", "east"))
	check("tramo [50,100] -> a", _matches(mod.owner_at(Vector2(999, 720), vp, split), "a", "east"))
	check("borde exacto 50 -> peer ascendente",
		_matches(mod.owner_at(Vector2(999, 400), vp, split), "a", "east"))

	# El borde más cercano manda aunque el link del borde lejano exista.
	var two = [
		{"direction": "east", "peer": "e", "local_range": [0, 100]},
		{"direction": "west", "peer": "w", "local_range": [0, 100]},
	]
	check("punta oeste elige west", _matches(mod.owner_at(Vector2(10, 400), vp, two), "w", "west"))
	check("punta este elige east", _matches(mod.owner_at(Vector2(990, 400), vp, two), "e", "east"))

	# Dirección deshabilitada o borde sin link: sin dueño.
	var east = [{"direction": "east", "peer": "cupid", "local_range": [0, 100]}]
	check("dirección deshabilitada -> {}", mod.owner_at(Vector2(999, 400), vp, east, ["east"]).empty())
	check("dirección deshabilitada normaliza mayúsculas",
		mod.owner_at(Vector2(999, 400), vp, east, ["EAST"]).empty())
	check("borde sin link -> {}", mod.owner_at(Vector2(500, 1), vp, east).empty())

	# Ningún tramo contiene: gana el más cercano; empate -> peer ascendente.
	check("tramo más cercano",
		_matches(mod.owner_at(Vector2(999, 80), vp,
			[{"direction": "east", "peer": "z", "local_range": [60, 100]}]), "z", "east"))
	check("empate de distancia -> peer ascendente",
		_matches(mod.owner_at(Vector2(999, 80), vp, [
			{"direction": "east", "peer": "z", "local_range": [60, 100]},
			{"direction": "east", "peer": "a", "local_range": [60, 100]},
		]), "a", "east"))

	# Link sin local_range cubre todo el borde.
	check("sin local_range cubre el borde",
		_matches(mod.owner_at(Vector2(999, 400), vp,
			[{"direction": "east", "peer": "full"}]), "full", "east"))

	# Entradas inválidas / vacías.
	check("viewport nulo -> {}", mod.owner_at(Vector2(999, 400), Vector2(0, 0), east).empty())
	check("viewport negativo -> {}", mod.owner_at(Vector2(999, 400), Vector2(-1, 800), east).empty())
	check("pos inválida -> {}", mod.owner_at("nope", vp, east).empty())
	check("links no-array -> {}", mod.owner_at(Vector2(999, 400), vp, "nope").empty())
	check("links vacío -> {}", mod.owner_at(Vector2(999, 400), vp, []).empty())
	check("link sin peer -> {}",
		mod.owner_at(Vector2(999, 400), vp, [{"direction": "east", "peer": ""}]).empty())

	OS.exit_code = 1 if failed > 0 else 0
	quit()
