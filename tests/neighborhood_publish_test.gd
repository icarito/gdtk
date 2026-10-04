extends SceneTree

# Autoprueba del publisher DNS-SD de Vecindario. Correr:
#   godot --no-window --path shell -s $PWD/tests/neighborhood_publish_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func has_layout(txt):
	for entry in txt:
		if String(entry).begins_with("layout"):
			return true
	return false


func _tmp_bin_dir():
	var base = OS.get_environment("TMPDIR").strip_edges()
	if base == "":
		base = "/tmp"
	base = base + "/gdtk_publish_test_bin"
	var dir = Directory.new()
	dir.make_dir_recursive(base)
	var f = File.new()
	var err = f.open(base + "/avahi-publish-service", File.WRITE)
	if err == OK:
		f.store_string("#!/bin/sh\n")
		f.close()
	return base


func _init():
	var pub = load("res://neighborhood_publish.gd").new()
	var identity = {
		"hid": "b6f4e13b8a2f4d88",
		"name": "Tengu",
		"kind": "laptop",
		"icon": "laptop",
		"auth": "ask"
	}

	var common = pub.build_common_txt(identity)
	check("TXT común explícito", common == ["v=1", "hid=b6f4e13b8a2f4d88", "name=Tengu", "kind=laptop", "icon=laptop", "auth=ask"])

	var with_ctl = identity.duplicate()
	with_ctl["ctl"] = "7788"
	check("ctl sólo si hay canal", pub.build_common_txt(with_ctl).has("ctl=7788")
		and not String(common).find("ctl=") >= 0)
	var with_accent = identity.duplicate()
	with_accent["accent"] = "#AABBCC"
	check("accent válido aparece al final y normalizado",
		pub.build_common_txt(with_accent) == common + ["accent=#aabbcc"])
	var with_accent_ctl = with_accent.duplicate()
	with_accent_ctl["ctl"] = "9911"
	check("accent válido no rompe el TXT", pub.validate_txt(pub.build_common_txt(with_accent_ctl)).ok)
	for bad in ["red", "#12345", "#gggggg"]:
		var with_bad = identity.duplicate()
		with_bad["accent"] = bad
		check("accent inválido no aparece: " + bad, pub.build_common_txt(with_bad) == common)
	check("sin accent la lista no cambia", pub.build_common_txt(identity) == common)

	var gvd = pub.build_gvd_txt(identity, {"state": "ready", "size": "1280x800"})
	var gvd_check = pub.validate_txt(gvd)
	check("gvd TXT chico y válido", gvd_check.ok and gvd_check.bytes < 200 and gvd.has("role=recv") and gvd.has("cursor_port=+1"))
	var gvd_plan = pub.build_gvd_launch(identity, 5600, {"size": "1280x800"})
	check("gvd argv sin shell", gvd_plan.ok and gvd_plan.cmd == "avahi-publish-service"
		and gvd_plan.args[1] == pub.SERVICE_GVD and gvd_plan.args[2] == "5600")

	var desk_plan = pub.build_deskflow_launch(identity, 24800, {"role": "server", "clip": "1"})
	check("deskflow argv seguro", desk_plan.ok and desk_plan.args[1] == pub.SERVICE_DESKFLOW
		and desk_plan.args.has("tls=required") and desk_plan.txt_bytes < 200)

	check("rechaza servicio ajeno", not pub.build_publish_args("_http._tcp", 80, common, "web").ok)
	check("rechaza token", not pub.validate_txt(["v=1", "token=abc"]).ok)
	check("rechaza ruta privada", not pub.validate_txt(["v=1", "model=/home/icarito/host.glb"]).ok)
	check("rechaza TXT grande", not pub.validate_txt(common + ["note=" + "x".repeat(220)]).ok)
	check("rechaza layout vacío", not pub.validate_txt(["v=1", "layout="]).ok)

	var gvd_plain = pub.build_gvd_txt(identity, {})
	check("gvd sin layout por defecto", not has_layout(gvd_plain))
	var gvd_layout = pub.build_gvd_txt(identity, {"layout": 1})
	var gvd_layout_check = pub.validate_txt(gvd_layout)
	check("gvd layout=1 presente y válido", has_layout(gvd_layout) and gvd_layout.has("layout=1") and gvd_layout_check.ok)
	check("gvd layout=1 no agrega layout=0", not gvd_layout.has("layout=0"))
	var gvd_layout_zero = pub.build_gvd_txt(identity, {"layout": 0})
	check("gvd layout=0 no se anuncia", not has_layout(gvd_layout_zero))
	var gvd_layout_bool = pub.build_gvd_txt(identity, {"layout": true})
	check("gvd layout true se anuncia", gvd_layout_bool.has("layout=1") and pub.validate_txt(gvd_layout_bool).ok)
	check("gvd presupuesto con layout <= 200", gvd_layout_check.bytes <= 200)

	var desk_plain = pub.build_deskflow_txt(identity, {})
	check("deskflow sin layout por defecto", not has_layout(desk_plain))
	check("deskflow role=client por defecto", desk_plain.has("role=client"))
	var desk_server = pub.build_deskflow_txt(identity, {"role": "server"})
	check("deskflow role=server explícito", desk_server.has("role=server"))
	check("deskflow role inválido cae a client", pub.build_deskflow_txt(identity, {"role": "x"}).has("role=client"))
	var desk_layout = pub.build_deskflow_txt(identity, {"layout": 1})
	var desk_layout_check = pub.validate_txt(desk_layout)
	check("deskflow layout=1 presente y válido", desk_layout.has("layout=1") and desk_layout_check.ok)
	var desk_layout_zero = pub.build_deskflow_txt(identity, {"layout": 0})
	check("deskflow layout=0 no se anuncia", not has_layout(desk_layout_zero))
	check("deskflow presupuesto con layout <= 200", desk_layout_check.bytes <= 200)

	var avahi = pub.detect_avahi()
	check("detect_avahi contrato", avahi.has("available") and avahi.has("path") and avahi.has("state"))
	check("detect_avahi available es bool", typeof(avahi["available"]) == TYPE_BOOL)
	check("detect_avahi state coherente", avahi["state"] == ("ready" if avahi["available"] else "degraded"))
	check("detect_avahi path sólo si available", (String(avahi["path"]) != "") == avahi["available"])
	var avahi2 = pub.detect_avahi()
	check("detect_avahi estable", avahi2["available"] == avahi["available"]
		and avahi2["path"] == avahi["path"] and avahi2["state"] == avahi["state"])
	var mutable = pub.detect_avahi()
	mutable["path"] = "/mutado"
	var again = pub.detect_avahi()
	check("detect_avahi no expone su caché", again["path"] != "/mutado" and again["available"] == avahi["available"])
	check("sin avahi queda degradado", pub.prepare_launch_args(pub.SERVICE_GVD, 5600, common, "gdtk gvd Tengu", "").state == "degraded")

	var bin = _tmp_bin_dir()
	var found = pub.which_in_path("avahi-publish-service", bin)
	check("which_in_path encuentra", found == bin + "/avahi-publish-service" and File.new().file_exists(found))
	check("which_in_path no encontrado", pub.which_in_path("avahi-publish-service", bin + "_inexistente") == "")
	check("which_in_path PATH vacío", pub.which_in_path("avahi-publish-service", "") == "")
	check("which_in_path programa vacío", pub.which_in_path("", bin) == "")
	check("which_in_path ignora entradas vacías", pub.which_in_path("avahi-publish-service", ":" + bin + ":") == bin + "/avahi-publish-service")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
