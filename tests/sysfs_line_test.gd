extends SceneTree

# Regresión del bug "Cupid no se veía como tablet": `File.get_as_text()` devuelve ""
# en archivos de sysfs/procfs (st_size reportado = 0) aunque `open()` dé OK. El shell
# leía el DMI (product_name/chassis_type) con get_as_text() y obtenía "", así que
# `device_kind.detect` caía a la heurística de batería -> siempre "laptop". La lectura
# correcta es `get_line()` (lee hasta el salto sin depender del tamaño).
#
#   "$BIN" --no-window --path shell -s $PWD/tests/sysfs_line_test.gd

var failed = 0


func check(name, cond):
	if cond:
		print("ok   " + name)
	else:
		failed += 1
		print("FAIL " + name)


func _init():
	var p = "/proc/self/stat"   # siempre existe y reporta tamaño 0
	var f = File.new()
	if f.open(p, File.READ) != OK:
		check("procfs disponible", false)
		OS.exit_code = 1
		quit()
		return
	var as_text = f.get_as_text()
	f.close()
	var f2 = File.new()
	f2.open(p, File.READ)
	var line = f2.get_line()
	f2.close()
	check("get_as_text vacío en procfs de tamaño 0", String(as_text).strip_edges() == "")
	check("get_line lee procfs de tamaño 0", String(line).strip_edges() != "")
	OS.exit_code = 1 if failed > 0 else 0
	quit()
