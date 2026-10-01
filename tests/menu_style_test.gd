extends SceneTree

# Autoprueba de shell/menu_style.gd (look WindowMaker de los menús). No renderiza
# sin canvas ImGui: sólo verifica carga, instanciabilidad, paleta y firmas.
#   godot --no-window --path shell -s $PWD/tests/menu_style_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var S = load("res://menu_style.gd")
	check("menu_style.gd carga", S != null)
	check("can_instance()", S != null and S.can_instance())

	# begin/end/chrome/item/bevel_rect deben existir en el script.
	var names = []
	if S != null:
		for m in S.get_script_method_list():
			names.append(m.name)
	check("metodo begin()", names.has("begin"))
	check("metodo end()", names.has("end"))
	check("metodo chrome()", names.has("chrome"))
	check("metodo item()", names.has("item"))
	check("metodo bevel_rect()", names.has("bevel_rect"))

	# Paleta: constantes Color válidas (alfa > 0).
	var cmap = {}
	if S != null:
		cmap = S.get_script_constant_map()
	for k in ["FACE", "LIGHT", "DARK", "TITLE_BG", "HILITE", "ACTIVE", "TEXT", "TEXT_DISABLED"]:
		var v = cmap.get(k, null)
		check("paleta " + k + " es Color", typeof(v) == TYPE_COLOR and float(v.a) > 0.0)

	# begin/end documentan un par balanceado de pushes: verifica los contadores
	# que end() usa en pop_style_var/pop_style_color.
	check("COLOR_COUNT declarado", typeof(cmap.get("COLOR_COUNT", null)) == TYPE_INT)
	check("VAR_COUNT declarado", typeof(cmap.get("VAR_COUNT", null)) == TYPE_INT)
	check("COLOR_COUNT cuenta los colores empujados", int(cmap.get("COLOR_COUNT", 0)) == 13)
	check("VAR_COUNT cuenta las vars empujadas", int(cmap.get("VAR_COUNT", 0)) == 5)

	print("MENU_STYLE_OK" if failed == 0 else "MENU_STYLE_FAIL")
	OS.exit_code = 1 if failed > 0 else 0
	quit()
