extends SceneTree

# Prueba la política de pausa del scanout directo (P4) sin arrancar compositor ni
# sesión gráfica: extrae `_scanout_overlay_active` del shell real y la evalúa con
# dobles de Frame/OSD. Ver SPEC-scanout-directo.md y HANDOFF-scanout-directo.md.
var failed = 0

class OsdProbe:
	extends Reference
	var active = false
	func is_active():
		return active

class FrameProbe:
	extends Reference
	var visible = false

func check(label, ok):
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		failed += 1

func _function(source, name):
	var start = source.find("func " + name + "(")
	if start < 0:
		return ""
	var end = source.find("\nfunc ", start + 1)
	return source.substr(start, end - start if end >= 0 else source.length() - start)

func _init():
	var f = File.new()
	if f.open("res://shell.gd", File.READ) != OK:
		check("abre shell.gd", false)
		OS.exit_code = 1
		quit()
		return
	var source = f.get_as_text()
	f.close()

	var body = _function(source, "_scanout_overlay_active")
	check("extrae _scanout_overlay_active", body != "")
	if body == "":
		OS.exit_code = 1
		quit()
		return

	var harness = "extends Reference\nvar expose = false\nvar neighborhood_view = false\nvar system_osd = null\nvar frame = null\n"
	harness += body
	var script = GDScript.new()
	script.set_source_code(harness)
	var err = script.reload()
	check("política compila", err == OK)
	if err != OK:
		OS.exit_code = 1
		quit()
		return

	var shell = script.new()
	check("reposo: no pausa", not shell._scanout_overlay_active())

	shell.expose = true
	check("exposé pausa", shell._scanout_overlay_active())
	shell.expose = false

	shell.neighborhood_view = true
	check("Vecindario pausa", shell._scanout_overlay_active())
	shell.neighborhood_view = false

	var osd = OsdProbe.new()
	shell.system_osd = osd
	check("OSD inactivo no pausa", not shell._scanout_overlay_active())
	osd.active = true
	check("OSD activo pausa", shell._scanout_overlay_active())
	osd.active = false

	var frame = FrameProbe.new()
	shell.frame = frame
	check("Frame oculto no pausa", not shell._scanout_overlay_active())
	frame.visible = true
	check("Frame visible pausa", shell._scanout_overlay_active())
	frame.visible = false
	shell.frame = null

	check("vuelto a reposo no pausa", not shell._scanout_overlay_active())

	if failed > 0:
		OS.exit_code = 1
	quit()
