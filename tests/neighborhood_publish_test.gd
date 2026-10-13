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


func _has_prefix(txt, prefix):
	for entry in txt:
		if String(entry).begins_with(prefix):
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

	# res: resolución real del emisor para que los vecinos reflejen rotación/cambio.
	var with_res = identity.duplicate()
	with_res["res"] = "1920x1080"
	check("deskflow res se anuncia", pub.build_deskflow_txt(with_res, {}).has("res=1920x1080"))
	var res_upper = identity.duplicate()
	res_upper["res"] = "1920X1080"
	check("deskflow res normaliza a minúsculas", pub.build_deskflow_txt(res_upper, {}).has("res=1920x1080"))
	var res_bad = identity.duplicate()
	res_bad["res"] = "big"
	check("deskflow res inválida se omite", not _has_prefix(pub.build_deskflow_txt(res_bad, {}), "res="))
	check("deskflow sin res no agrega clave", not _has_prefix(pub.build_deskflow_txt(identity, {}), "res="))
	check("deskflow res dentro del presupuesto", pub.validate_txt(pub.build_deskflow_txt(with_res, {})).ok)

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

	# Hospedaje multiview opcional (SPEC-multiview-portal §5): sólo en el TXT de
	# gvd, ausente por defecto y sin entradas mal formadas.
	var mv_plain = pub.build_gvd_txt(identity, {})
	check("gvd sin mv por defecto", not _has_prefix(mv_plain, "mv=")
		and not _has_prefix(mv_plain, "mv_slots=") and not _has_prefix(mv_plain, "mv_base="))
	var mv_full = pub.build_gvd_txt(identity, {"mv": 1, "mv_slots": 4, "mv_base": 5700})
	var mv_full_check = pub.validate_txt(mv_full)
	check("gvd mv=1 + slots + base presentes y válido", mv_full.has("mv=1")
		and mv_full.has("mv_slots=4") and mv_full.has("mv_base=5700") and mv_full_check.ok)
	check("gvd mv presupuesto <= 200", mv_full_check.bytes <= 200)
	var mv_bool = pub.build_gvd_txt(identity, {"mv": true, "mv_slots": "2", "mv_base": "6000"})
	check("gvd mv acepta bool y strings válidos", mv_bool.has("mv=1")
		and mv_bool.has("mv_slots=2") and mv_bool.has("mv_base=6000"))
	var mv_bad = pub.build_gvd_txt(identity, {"mv": 1, "mv_slots": 0, "mv_base": 70000})
	check("gvd mv con enteros inválidos se omiten", mv_bad.has("mv=1")
		and not _has_prefix(mv_bad, "mv_slots=") and not _has_prefix(mv_bad, "mv_base="))
	var mv_range = pub.build_gvd_txt(identity, {"mv": 1, "mv_slots": 17, "mv_base": 1023})
	check("gvd mv fuera de rango se omiten", mv_range.has("mv=1")
		and not _has_prefix(mv_range, "mv_slots=") and not _has_prefix(mv_range, "mv_base="))
	var mv_no = pub.build_gvd_txt(identity, {"mv": 0, "mv_slots": 4, "mv_base": 5700})
	check("gvd slots/base sin mv no se anuncian", not _has_prefix(mv_no, "mv=")
		and not _has_prefix(mv_no, "mv_slots=") and not _has_prefix(mv_no, "mv_base="))
	check("gvd mv inválido sigue validando", pub.validate_txt(mv_bad).ok and pub.validate_txt(mv_range).ok)
	check("deskflow no anuncia mv", not _has_prefix(
		pub.build_deskflow_txt(identity, {"mv": 1, "mv_slots": 4, "mv_base": 5700}), "mv="))

	var plan_mod = load("res://neighborhood_publish_plan.gd").new()
	var plan = plan_mod.build(identity, {"gvd": true, "deskflow": false,
		"mv": 1, "mv_slots": 4, "mv_base": 5700}, "/bin/avahi-publish-service")
	var gvd_entry = null
	for s in plan.services:
		if s.capability == "gvd":
			gvd_entry = s
	check("plan gvd pasa mv desde caps", gvd_entry != null and gvd_entry.args.has("mv=1")
		and gvd_entry.args.has("mv_slots=4") and gvd_entry.args.has("mv_base=5700"))

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
