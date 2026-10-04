extends SceneTree

# Autoprueba G1 del modelo puro del zoom Sugar de 3 niveles (zoom_model.gd):
# niveles, escala continua del ícono central, transformación de capas y tope del
# paso con rueda/pinch. No renderiza ni toca disco.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/zoom_model_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _approx(a, b, eps = 0.0001):
	return abs(float(a) - float(b)) <= eps


func _init():
	var Z = load("res://zoom_model.gd")
	check("nivel Hogar", Z.HOME == 0)
	check("nivel Grupo", Z.GROUP == 1)
	check("nivel Vecindario", Z.NEIGHBORHOOD == 2)

	# --- ease_out ------------------------------------------------------------
	check("ease_out(0) = 0", _approx(Z.ease_out(0.0), 0.0))
	check("ease_out(1) = 1", _approx(Z.ease_out(1.0), 1.0))
	check("ease_out recorta fuera de rango",
		_approx(Z.ease_out(-3.0), 0.0) and _approx(Z.ease_out(9.0), 1.0))
	check("ease_out monótono", Z.ease_out(0.25) < Z.ease_out(0.5)
		and Z.ease_out(0.5) < Z.ease_out(0.75))

	# --- center_icon_scale ---------------------------------------------------
	check("centro Hogar 1.0", _approx(Z.center_icon_scale(0.0), 1.0))
	check("centro Grupo 0.6", _approx(Z.center_icon_scale(1.0), 0.6))
	check("centro Vecindario 0.35", _approx(Z.center_icon_scale(2.0), 0.35))
	check("centro recorta fuera de rango",
		_approx(Z.center_icon_scale(-1.0), 1.0) and _approx(Z.center_icon_scale(5.0), 0.35))
	check("centro se achica continuo",
		Z.center_icon_scale(0.5) < 1.0 and Z.center_icon_scale(0.5) > 0.6
		and Z.center_icon_scale(1.5) < 0.6 and Z.center_icon_scale(1.5) > 0.35)

	# --- center_icon_rect ----------------------------------------------------
	var vp = Vector2(1920.0, 1080.0)
	var r0 = Z.center_icon_rect(0.0, vp, 100.0)
	check("rect centrado en vp/2", (r0.position + r0.size * 0.5).is_equal_approx(vp * 0.5))
	check("rect Hogar usa base completa", _approx(r0.size.x, 100.0) and _approx(r0.size.y, 100.0))
	var r2 = Z.center_icon_rect(2.0, vp, 100.0)
	check("rect Vecindario encoge igual en x/y",
		_approx(r2.size.x, 35.0) and _approx(r2.size.y, 35.0))
	check("rect sigue centrado al encoger",
		(r2.position + r2.size * 0.5).is_equal_approx(vp * 0.5))
	check("rect es cuadrado", _approx(r0.size.x, r0.size.y) and _approx(r2.size.x, r2.size.y))

	# --- layer_transform -----------------------------------------------------
	var home0 = Z.layer_transform(Z.HOME, 0.0)
	check("capa Hogar en su nivel: escala 1, alfa 1",
		_approx(home0.scale, 1.0) and _approx(home0.alpha, 1.0))
	check("capa Hogar desaparece en Grupo",
		_approx(Z.layer_transform(Z.HOME, 1.0).alpha, 0.0))
	check("capa Hogar desaparece en Vecindario",
		_approx(Z.layer_transform(Z.HOME, 2.0).alpha, 0.0))
	var group1 = Z.layer_transform(Z.GROUP, 1.0)
	check("capa Grupo en su nivel: escala 1, alfa 1",
		_approx(group1.scale, 1.0) and _approx(group1.alpha, 1.0))
	check("capa Vecindario en su nivel: escala 1, alfa 1",
		_approx(Z.layer_transform(Z.NEIGHBORHOOD, 2.0).scale, 1.0)
		and _approx(Z.layer_transform(Z.NEIGHBORHOOD, 2.0).alpha, 1.0))
	# Al alejarse hacia niveles mayores: la saliente se encoge hacia 0.72.
	var home_mid = Z.layer_transform(Z.HOME, 0.5)
	check("capa saliente se encoge hacia 0.72",
		home_mid.scale < 1.0 and home_mid.scale > 0.72)
	check("capa saliente cruza su alfa", _approx(home_mid.alpha, 0.5))
	# La entrante (Grupo) viene desde 1.4 -> 1.0.
	var group_in = Z.layer_transform(Z.GROUP, 0.0)
	check("capa entrante arranca en 1.4",
		_approx(group_in.scale, 1.4) and _approx(group_in.alpha, 0.0))
	check("capa entrante ya encogió a mitad de camino",
		Z.layer_transform(Z.GROUP, 0.5).scale < 1.4
		and Z.layer_transform(Z.GROUP, 0.5).scale > 1.0)
	check("capa fuera de alcance: alfa 0",
		_approx(Z.layer_transform(Z.NEIGHBORHOOD, 0.5).alpha, 0.0)
		and _approx(Z.layer_transform(Z.HOME, 1.5).alpha, 0.0))

	# --- step ----------------------------------------------------------------
	check("step sube de Hogar a Grupo", Z.step(0, 1) == 1)
	check("step sube a Vecindario", Z.step(1, 1) == 2)
	check("step no pasa de Vecindario", Z.step(2, 1) == 2)
	check("step baja de Vecindario a Grupo", Z.step(2, -1) == 1)
	check("step baja a Hogar", Z.step(1, -1) == 0)
	check("step no baja de Hogar", Z.step(0, -1) == 0)
	check("step salta varios", Z.step(0, 2) == 2 and Z.step(2, -2) == 0)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
