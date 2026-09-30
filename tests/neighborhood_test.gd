extends SceneTree

# Autoprueba del parser de Vecindario (shell/neighborhood.gd). Correr:
#   godot --no-window --path shell -s $PWD/tests/neighborhood_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var nb = load("res://neighborhood.gd").new()
	# selftest() usa assert: si algo falla, aborta antes de llegar acá.
	nb.run_selftest()
	check("selftest() del parser", true)
	# Caso extra: línea con SSID y BSSID escapados y red abierta (sin seguridad).
	var sample = ":Café\\:cito:0A\\:1B\\:2C\\:3D\\:4E\\:5F:11:2462 MHz:88:"
	var nets = nb.parse_nmcli(sample)
	check("SSID con \\: y red abierta", nets.size() == 1 and nets[0].ssid == "Café:cito"
		and nets[0].security == "" and nets[0].chan == 11 and nets[0].ring == "cerca")
	OS.exit_code = 1 if failed > 0 else 0
	quit()
