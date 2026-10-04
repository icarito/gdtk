extends SceneTree

# Autoprueba del modelo de hosts del Vecindario. Correr:
#   godot --no-window --path shell -s $PWD/tests/neighborhood_hosts_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var nb = load("res://neighborhood_hosts.gd").new()
	nb.run_selftest()
	check("selftest() del modelo hosts", true)

	var parsed = nb.parse_services("service _gdtk-gvd._udp name=Mini host=mini.local port=5600 hid=h2 kind=tablet", 5)
	check("formato simple parseado", parsed.size() == 1 and parsed[0].txt.hid == "h2"
		and parsed[0].port == 5600 and parsed[0].seen_at == 5)

	# avahi-browse -p real: todos los TXT llegan en un solo campo entre comillas.
	var real = "=;mlan0;IPv4;gdtk\\032gvd\\032cupid;_gdtk-gvd._udp;local;cupid-156.local;192.168.18.30;5600;\"v=1\" \"hid=61950c8964e60e15\" \"name=cupid\" \"role=recv\""
	var rs = load("res://neighborhood_hosts.gd").parse_services(real, 1)
	check("txt multiple en un campo", rs.size() == 1 and rs[0].txt.get("hid", "") == "61950c8964e60e15" and rs[0].txt.get("role", "") == "recv")

	# Filtrar el host local que se descubre a si mismo por mDNS: por hid opaco y
	# por nombre visible (hostname).
	var local_hid = "61950c8964e60e15"
	var sample = PoolStringArray([
		"=;mlan0;IPv4;gdtk gvd cupid;_gdtk-gvd._udp;local;cupid-156.local;192.168.18.30;5600;\"hid=61950c8964e60e15\";\"name=cupid\"",
		"=;mlan0;IPv4;gdtk gvd tengu;_gdtk-gvd._udp;local;tengu.local;192.168.18.31;5600;\"hid=aaaa1111\";\"name=tengu\"",
		"service _gdtk-deskflow._tcp name=vecino host=x.local port=24800 hid=bbbb2222 kind=desktop",
	]).join("\n")
	var all = nb.model_from_text(sample, {}, 5)
	check("modelo trae los tres hosts", all.size() == 3)
	var filtered = nb.exclude_local(all, local_hid, "cupid")
	check("exclude_local quita por hid", filtered.size() == 2)
	var kept_ids = []
	for h in filtered:
		kept_ids.append(h.id)
	check("exclude_local conserva vecinos", kept_ids.has("aaaa1111") and kept_ids.has("bbbb2222")
		and not kept_ids.has(local_hid))
	check("exclude_local quita solo por nombre",
		nb.exclude_local(all, "", "cupid").size() == 2)
	check("exclude_local sin identidad no quita",
		nb.exclude_local(all, "", "").size() == 3)

	# Orden determinista: nombre ascendente y, a igual nombre, id.
	var unordered = [
		{"id": "z", "label": "zeta"},
		{"id": "b", "label": "Ana"},
		{"id": "a", "label": "ana"},
		{"id": "c", "label": "Ana"},
	]
	var ordered = nb.sort_hosts(unordered)
	var order_ids = []
	for h in ordered:
		order_ids.append(h.id)
	check("sort_hosts por nombre e id", order_ids == ["a", "b", "c", "z"])
	var reordered = nb.model_from_text(sample, {}, 5)
	var sorted_twice = nb.sort_hosts(reordered)
	check("sort_hosts estable/repetible", nb.sort_hosts(sorted_twice)[0].id == sorted_twice[0].id)

	# Acento del host: "#rrggbb" normalizado; el primer servicio válido lo fija.
	check("valid_accent normaliza", nb.valid_accent("#AABBCC") == "#aabbcc")
	check("valid_accent recorta espacios", nb.valid_accent("  #00ff00 ") == "#00ff00")
	check("valid_accent rechaza inválidos",
		nb.valid_accent("red") == "" and nb.valid_accent("#12345") == ""
		and nb.valid_accent("#gggggg") == "" and nb.valid_accent("#aabbccdd") == "")
	var color_sample = PoolStringArray([
		"service _gdtk-gvd._udp name=Color host=color.local port=5600 hid=c1 kind=laptop",
		"service _gdtk-deskflow._tcp name=Color host=color.local port=24800 hid=c1 kind=laptop accent=#AABBCC",
		"service _gdtk-clip._tcp name=NoColor host=nc.local port=9911 hid=c2 kind=desktop",
		"service _gdtk-gvd._udp name=BadColor host=bc.local port=5600 hid=c3 kind=desktop accent=red",
	]).join("\n")
	var color_hosts = nb.model_from_text(color_sample, {}, 5)
	var c1 = nb._find_host(color_hosts, "c1")
	var c2 = nb._find_host(color_hosts, "c2")
	var c3 = nb._find_host(color_hosts, "c3")
	check("accent de un servicio del host se lee", c1 != null and c1.accent == "#aabbcc")
	check("host sin accent queda vacío", c2 != null and c2.accent == "")
	check("host con accent inválido queda vacío", c3 != null and c3.accent == "")
	var saved_hosts = nb.model_from_text("", {"sv1": {"label": "Guardado"}}, 5)
	check("host guardado sin accent", saved_hosts.size() == 1 and saved_hosts[0].accent == "")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
