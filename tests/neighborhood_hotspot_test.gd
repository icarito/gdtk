extends SceneTree

# Autoprueba del modelo puro de la señal Wi-Fi (shell/neighborhood_hotspot.gd) y
# del estado que publica el worker del Vecindario. Correr:
#   godot --no-window --path shell -s $PWD/tests/neighborhood_hotspot_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var hotspot = load("res://neighborhood_hotspot.gd").new()
	hotspot.run_selftest()
	check("selftest() del modelo", true)

	# Planes argv: sin secretos y con el SSID correcto.
	var add = hotspot.create_plan("bastion")
	check("create_plan arma argv de AP", add.size() > 0 and add.find("con-name") >= 0
		and add[add.find("con-name") + 1] == "Hotspot" and add.find("bastion") >= 0
		and add.find("mode") >= 0 and add[add.find("mode") + 1] == "ap"
		and add.find("802-11-wireless-security.psk") < 0)
	check("create_plan rechaza SSID inválido", hotspot.create_plan("x".repeat(33)).empty())
	var con = hotspot.connect_plan("Casa")
	check("connect_plan arma perfil de estación sin secreto", con.size() > 0
		and con[con.find("con-name") + 1] == "Casa" and con[con.find("ssid") + 1] == "Casa"
		and con.find("802-11-wireless-security.key-mgmt") >= 0
		and con.find("802-11-wireless-security.psk") < 0)
	check("connect_plan rechaza SSID inválido", hotspot.connect_plan("").empty())
	check("up/down/ensure planes", hotspot.up_plan() == ["connection", "up", "id", "Hotspot"]
		and hotspot.down_plan() == ["connection", "down", "id", "Hotspot"]
		and hotspot.ensure_wpa_plan() == ["connection", "modify", "Hotspot",
			"802-11-wireless-security.key-mgmt", "wpa-psk"])
	check("channel_plan sólo con canal", hotspot.channel_plan("Hotspot", 5) == ["connection",
		"modify", "Hotspot", "802-11-wireless.band", "bg", "802-11-wireless.channel", "5"]
		and hotspot.channel_plan("Hotspot", 0).empty())
	check("band_arg de las bandas del worker", hotspot.band_arg("2.4") == "bg"
		and hotspot.band_arg("5") == "a" and hotspot.band_arg("") == "")

	# Archivo de claves: formato documentado `setting.propiedad:clave`.
	check("passwd_file_text con formato documentado",
		hotspot.passwd_file_text("secret12345") == "802-11-wireless-security.psk:secret12345\n")
	check("passwd_file_text rechaza clave corta", hotspot.passwd_file_text("corta") == "")

	# Validación de clave (límites WPA).
	check("psk 7 rechazada / 8 aceptada", not hotspot.valid_psk("1234567")
		and hotspot.valid_psk("12345678"))
	check("psk 63 aceptada / 64 rechazada", hotspot.valid_psk("x".repeat(63))
		and not hotspot.valid_psk("x".repeat(64)))
	check("psk con salto de línea rechazada", not hotspot.valid_psk("abcdefg\n"))

	# Parseo de conexiones activas (muestras reales de bastion).
	var active = "Alvitos_Govista:wlan0:802-11-wireless\nlo:lo:loopback\npan1:pan1:bridge"
	var pa = hotspot.parse_active(active)
	check("parse_active: perfil señal no activo", not pa.active and pa.device == "")
	var pa2 = hotspot.parse_active("Alvitos_Govista:wlan0:802-11-wireless\nHotspot:wlan0:802-11-wireless")
	check("parse_active: perfil señal activo con device", pa2.active and pa2.device == "wlan0")

	# Conexión activa de la red en uso: extrae su canal para el AP en el mismo canal.
	var nets = [{"ssid": "Alvitos_Govista", "in_use": true, "chan": 5, "band": "2.4"},
		{"ssid": "Otra", "in_use": false, "chan": 6, "band": "2.4"}]
	check("_in_use_chan del worker", load("res://neighborhood.gd").new()._in_use_chan(nets) == 5)
	check("_in_use_band del worker", load("res://neighborhood.gd").new()._in_use_band(nets) == "2.4")
	check("_in_use_chan sin red en uso", load("res://neighborhood.gd").new()._in_use_chan([]) == 0)

	# Parseo de perfiles guardados (nombre por línea, escapes).
	check("parse_saved incluye Hotspot", hotspot.parse_saved("Hotspot\nOtra Red").has("Hotspot"))
	check("parse_saved desescapa `:`", hotspot.parse_saved("Rede\\:X").has("Rede:X"))

	# Conectividad (bare y clave:valor) y traducción honesta.
	check("parse_connectivity bare", hotspot.parse_connectivity("full") == "full")
	check("parse_connectivity clave:valor", hotspot.parse_connectivity("CONNECTIVITY:limited") == "limited")
	check("parse_connectivity vacía/desconocida", hotspot.parse_connectivity("") == "sin_dato"
		and hotspot.parse_connectivity("unknown") == "sin_dato")
	check("internet_state", hotspot.internet_state("full") == "sí"
		and hotspot.internet_state("limited") == "limitada"
		and hotspot.internet_state("none") == "no"
		and hotspot.internet_state("sin_dato") == "sin dato")

	# share_line() del worker: honesto según el snapshot publicado.
	var nb = load("res://neighborhood.gd").new()
	check("share_line sin datos", nb.share_line() == "Señal Wi-Fi: leyendo…")
	nb.hotspot = {"available": true, "active": false, "connectivity": "full"}
	check("share_line apagada", nb.share_line() == "Señal Wi-Fi apagada")
	nb.hotspot = {"available": true, "active": true, "connectivity": "full"}
	check("share_line activa con Internet", nb.share_line() == "Señal Wi-Fi activa · Internet: sí")
	nb.hotspot = {"available": true, "active": true, "connectivity": "none"}
	check("share_line activa sin Internet", nb.share_line() == "Señal Wi-Fi activa · Internet: no")
	nb.hotspot = {"available": false, "active": false, "connectivity": "sin_dato"}
	check("share_line sin NetworkManager",
		nb.share_line() == "Señal Wi-Fi: NetworkManager no disponible")

	# Menú de «Este equipo» (filas) y fila de conexión con clave.
	var ui = load("res://neighborhood_ui.gd").new()
	var model = load("res://neighborhood.gd").new()
	model.status = "ok"
	model.hotspot = {"available": true, "active": false, "connectivity": "full", "saved": []}
	ui.model = model
	var items = ui._self_menu_items()
	check("self menú: crear habilitado y sin apagar", items.size() == 2
		and items[0].kind == "hotspot_up" and items[0].enabled)
	check("self menú: info apagada", items[1].kind == "info" and items[1].label == "Señal apagada")
	model.hotspot = {"available": true, "active": true, "connectivity": "none",
		"device": "wlan0", "saved": ["Hotspot"]}
	items = ui._self_menu_items()
	check("self menú: activa deshabilita crear con razón", not items[0].enabled
		and items[0].reason == "ya está encendida")
	check("self menú: apagar visible", items.size() == 3 and items[1].kind == "hotspot_down"
		and items[1].enabled)
	check("self menú: info con Internet honesta",
		items[2].kind == "info" and items[2].label.find("Internet: no") >= 0)
	model.status = "off"
	check("self menú: radio apagada deshabilita crear",
		not ui._self_menu_items()[0].enabled
		and ui._self_menu_items()[0].reason == "Wi-Fi apagado")
	model.status = "no_nmcli"
	check("self menú: sin nmcli deshabilita crear",
		ui._self_menu_items()[0].reason == "nmcli no disponible")

	var wsec = ui._wifi_menu_items({"ssid": "Casa", "security": "WPA2", "in_use": false})
	check("red protegida pide clave", wsec[0].kind == "wifi_connect_psk")
	var wopen = ui._wifi_menu_items({"ssid": "Bar", "security": "", "in_use": false})
	check("red abierta conecta directo", wopen[0].kind == "wifi_connect")
	ui.free()

	OS.exit_code = 1 if failed > 0 else 0
	quit()
