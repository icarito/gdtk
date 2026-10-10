extends SceneTree

# Regresión de SPEC-rendimiento-compositor (issue B): el applet Portapapeles pedía
# un redraw en CADA vuelta del loop en reposo porque `refresh()` comparaba `items`
# (un duplicado) contra `s_items` con `!=`, y en Godot 3 Dictionary/Array-de-Dictionary
# se comparan por REFERENCIA, no por contenido: `duplicate(true) != original` siempre.
# El Frame redibujaba la barra a ~4/s sin que nada cambiara (~x4 de costo ImGui en reposo).
# El fix compara por firma de string (`str(items) != str(s_items)`), que sí es por contenido.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/clipboard_refresh_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _snap(state, value, items):
	return {"state": state, "value": value, "detail": "d", "items": items,
		"latest_name": "n", "latest_kind": "text"}


func _init():
	var Clip = load("res://applet_clipboard.gd")
	# Documenta el gotcha del motor: dos dicts idénticos NO son `==` (identidad, no contenido).
	check("Godot 3: dict == dict por referencia", ({"a": 1} == {"a": 1}) == false)
	check("Godot 3: str(dict) sí es por contenido", str({"a": 1}) == str({"a": 1}))

	var items = [{"name": "n", "summary": "s", "kind": "text"}]
	var a = Clip.new()
	# `_thread` no-null evita que refresh() arranque el worker (no hay compositor acá).
	a._thread = a

	# Primer refresh: el estado interno arranca en "sin_dato" -> hay cambio real.
	a._snap = _snap("activo", "v", items)
	check("primer refresh reporta cambio", a.refresh() == true)

	# Mismo contenido en el snapshot: NO debe reportar cambio (antes: true en cada vuelta).
	check("idle sin cambios no reporta", a.refresh() == false)
	check("idle, segundo sin cambios", a.refresh() == false)

	# Cambio real de contenido (value) sí se detecta.
	a._snap = _snap("activo", "v2", items)
	check("cambio de value sí reporta", a.refresh() == true)

	# Cambio real del historial (otra entrada) también.
	a._snap = _snap("activo", "v2", [{"name": "n2", "summary": "s2", "kind": "text"}])
	check("cambio de items sí reporta", a.refresh() == true)
	check("estabiliza tras el cambio", a.refresh() == false)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
