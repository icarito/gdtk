extends Reference

# Presencia de vecinos Deskflow (puro). Una pantalla del layout es "ausente"
# cuando su `id` (el hid estable del vecino) no está entre los hosts VISTOS del
# Vecindario; su borde se bloquea (rango 0..0 en el portal InputCapture) para no
# atrapar el puntero hacia un equipo apagado.
#
# Sólo mira `settings["screens"]` (vecinos gdtk). Los extremos externos
# (`deskflow_extra`, p. ej. un teléfono con la app Deskflow que no es host gdtk)
# no viven en `screens` y no pasan por acá: nunca se auto-bloquean.
#
# Selecciona UNA pantalla por dirección (id menor), igual que
# screen_layout.local_links, para no bloquear un borde con conflicto de ids.
# Sin I/O: el caller pasa el layout y los ids presentes.

const SCREEN = preload("res://screen_layout.gd")


# Direcciones (north/south/east/west) de los contactos DIRECTOS de la local cuyo
# vecino no está presente. Lista determinista (orden cardinal).
static func absent_directions(layout, present_ids):
	var out = []
	if typeof(layout) != TYPE_DICTIONARY or typeof(present_ids) != TYPE_ARRAY:
		return out
	var present = {}
	for p in present_ids:
		var s = String(p).strip_edges()
		if s != "":
			present[s] = true
	var lay = SCREEN.normalize_layout(layout)
	var local_id = String(lay.local.id)
	var direct = []
	for e in SCREEN.output(lay):
		if String(e.via) == local_id:
			direct.append(e)
	# id ascendente (orden de inserción determinista).
	var i = 1
	while i < direct.size():
		var cur = direct[i]
		var j = i - 1
		while j >= 0 and String(cur.id) < String(direct[j].id):
			direct[j + 1] = direct[j]
			j -= 1
		direct[j + 1] = cur
		i += 1
	var used = {}
	for e in direct:
		var d = String(e.direction)
		if used.has(d):
			continue
		used[d] = true
		if not present.has(String(e.id)):
			out.append(d)
	var order = ["north", "south", "east", "west"]
	var sorted = []
	for o in order:
		if out.has(o):
			sorted.append(o)
	return sorted


static func selftest():
	var layout = {
		"version": 2,
		"local": {"id": "me", "label": "Este equipo", "local": true,
			"x": 0.0, "y": 0.0, "w": 340.0, "h": 200.0},
		"screens": [
			{"id": "h1", "label": "A", "peer": "a", "x": 340.0, "y": 0.0, "w": 340.0, "h": 200.0},
			{"id": "h2", "label": "B", "peer": "b", "x": -340.0, "y": 0.0, "w": 340.0, "h": 200.0},
		],
	}
	# h1 (este) presente, h2 (oeste) ausente.
	var abs1 = absent_directions(layout, ["h1"])
	assert(abs1 == ["west"], "sólo el ausente: " + str(abs1))
	# Todos presentes: nada bloqueado.
	assert(absent_directions(layout, ["h1", "h2"]).empty(), "nada ausente")
	# Ninguno presente (todos apagados): ambos bordes bloqueados.
	var abs2 = absent_directions(layout, [])
	assert(abs2 == ["east", "west"] or abs2 == ["west", "east"], "ambos ausentes: " + str(abs2))
	# Entradas inválidas no rompen.
	assert(absent_directions(null, ["h1"]).empty(), "layout nulo")
	assert(absent_directions(layout, "h1").empty(), "present_ids no array")
	assert(absent_directions({}, []).empty(), "layout vacío")
	return true


func run_selftest():
	return selftest()
