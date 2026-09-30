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

	# 20 redes simuladas (2.4 y 5 GHz, señales de -55 a -95 dBm): tras la relajación
	# por cápsulas (nodo de 64 px + etiqueta debajo) ningún par se solapa. Reproduce
	# la geometría que arma shell._draw_neighborhood.
	var lines = PoolStringArray()
	var chans24 = [1, 6, 11, 3]
	var chans5 = [36, 40, 44, 48, 149, 153, 157, 161]
	for i in range(20):
		var ssid = "Red%02d" % i
		var bssid = "AA\\:BB\\:CC\\:DD\\:EE\\:%02X" % i
		var chan = chans24[i % chans24.size()] if i % 2 == 0 else chans5[i % chans5.size()]
		var freq = 2412 + (chan - 1) * 5 if i % 2 == 0 else 5000 + chan * 5
		lines.append(":%s:%s:%d:%d MHz:%d:WPA2" % [ssid, bssid, chan, freq, 95 - i * 4])
	var many = nb.parse_nmcli(lines.join("\n"))
	check("20 redes parseadas", many.size() == 20)
	var rad = []
	var shrink = many.size() > 14
	for n in many:
		var r = clamp(32.0 + float(int(n.congestion) - 1) * 3.0, 32.0, 58.0)
		if shrink and float(n.dbm) <= -80.0:
			r = 24.0
		rad.append(r)
	var max_rad = 32.0
	for r in rad:
		max_rad = max(max_rad, r)
	var R = max(80.0, min(960.0 * 0.5 - 20.0, (698.0 - 144.0) * 0.5 - max_rad - 40.0))
	var pos = []
	var hw = []
	var hh = []
	for i in range(many.size()):
		var n = many[i]
		pos.append(Vector2(480.0, 421.0) + Vector2(cos(n.angle), sin(n.angle)) * (n.r_frac * R))
		hw.append(rad[i])
		hh.append(nb.capsule_half_h(rad[i]))
	pos = nb.relax_capsules(pos, hw, hh, 2.0, 48, 0.02)
	check("20 redes: ninguna cápsula se solapa", not nb.capsules_overlap(pos, hw, hh, 2.0))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
