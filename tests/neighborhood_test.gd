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

	# 20 redes simuladas (2.4 y 5 GHz, señales de -55 a -95 dBm): verifica
	# el parser y la relajación por cápsulas del modelo, independiente de la vista.
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

	# Hosts DNS-SD de gdtk: `_read_hosts()` delega en el modelo puro. Acá se verifica
	# el parseo desde texto avahi -rtp equivalente (sin invocar avahi-browse real).
	var hosts_model = load("res://neighborhood_hosts.gd").new()
	var avahi = PoolStringArray([
		"=;eth0;IPv4;Tengu GVD;_gdtk-gvd._udp;local;tengu.local;192.168.1.20;5600;\"v=1\";\"hid=h1\";\"name=Tengu\";\"kind=laptop\"",
		"=;eth0;IPv4;Tengu Deskflow;_gdtk-deskflow._tcp;local;tengu.local;192.168.1.20;24800;v=1;hid=h1;name=Tengu;kind=laptop",
		"=;eth0;IPv4;Tengu Clip;_gdtk-clip._tcp;local;tengu.local;192.168.1.20;9911;v=1;hid=h1;name=Tengu;kind=laptop",
	]).join("\n")
	var gdtk_hosts = hosts_model.model_from_text(avahi)
	check("avahi: un host por hid", gdtk_hosts.size() == 1)
	var h = gdtk_hosts[0] if gdtk_hosts.size() == 1 else {}
	var caps = h.get("capabilities", {})
	check("avahi: capacidades gvd/deskflow/clip", caps.has("gvd") and caps.has("deskflow")
		and caps.has("clip"))
	check("avahi: tres servicios gdtk y otros ignorados", h.get("services", []).size() == 3
		and hosts_model.parse_services("=;eth0;IPv4;Web;_http._tcp;local;x.local;10.0.0.1;80;v=1").empty())

	OS.exit_code = 1 if failed > 0 else 0
	quit()
