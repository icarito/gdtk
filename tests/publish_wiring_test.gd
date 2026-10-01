extends SceneTree

# Autoprueba del plan puro de publicación mDNS (shell/neighborhood_publish_plan.gd),
# la parte pura que cablea el shell. No carga res://shell.gd. Correr:
#   godot --no-window --path shell -s $PWD/tests/publish_wiring_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func find_service(services, service):
	for s in services:
		if s.service == service:
			return s
	return null


func joined_args(entry):
	return PoolStringArray(entry.args).join(" ")


func safe_args(entry):
	var joined = joined_args(entry)
	for word in ["token", "secret", "password", "credential", "/home", "~/", "\\"]:
		if joined.find(word) >= 0:
			return false
	for bad in ["\n", "\r", "\t"]:
		if joined.find(bad) >= 0:
			return false
	return true


func _init():
	var plan = load("res://neighborhood_publish_plan.gd").new()
	var pub = load("res://neighborhood_publish.gd").new()

	var identity = plan.local_identity("Tengu")
	check("identidad usa hostname como nombre", identity.name == "Tengu")
	check("identidad hid opaco", identity.hid.length() == plan.IDENTITY_HID_LEN and identity.hid != "Tengu")
	check("identidad hid estable", plan.local_identity("Tengu").hid == identity.hid)
	check("identidad distinta para otro host", plan.local_identity("Cupid").hid != identity.hid)
	check("identidad sin hostname no falla", plan.local_identity("").name == "gdtk")
	check("identidad campos comunes", identity.kind == "unknown" and identity.icon == "unknown" and identity.auth == "ask")

	var caps = {"gvd": true, "deskflow": true}
	var result = plan.build(identity, caps, "/usr/bin/avahi-publish-service")
	check("plan con avahi listo", result.ok and result.state == "ready")
	check("un anuncio por servicio", result.services.size() == 2)

	var gvd = find_service(result.services, pub.SERVICE_GVD)
	check("_gvd anunciado", gvd != null)
	check("_gvd prog resuelto", gvd != null and gvd.prog == "/usr/bin/avahi-publish-service")
	check("_gvd puerto 5600", gvd != null and gvd.port == 5600)
	check("_gvd role=recv", gvd != null and gvd.args.has("role=recv"))
	check("_gvd state=capable (no finge receptor vivo)", gvd != null and gvd.args.has("state=capable"))
	check("_gvd args con nombre/servicio/puerto", gvd != null
		and gvd.args[0] == gvd.name and gvd.args[1] == pub.SERVICE_GVD and gvd.args[2] == "5600")
	check("_gvd sin secretos", gvd != null and safe_args(gvd))

	var deskflow = find_service(result.services, pub.SERVICE_DESKFLOW)
	check("_deskflow anunciado", deskflow != null)
	check("_deskflow rol por defecto client", deskflow != null and deskflow.args.has("role=client"))
	check("_deskflow tls required", deskflow != null and deskflow.args.has("tls=required"))
	check("_deskflow puerto 24800", deskflow != null and deskflow.port == 24800)
	check("_deskflow sin secretos", deskflow != null and safe_args(deskflow))

	# role=server sólo si el caller lo pide explícitamente.
	var server_role = plan.build(identity, {"gvd": false, "deskflow": true,
		"deskflow_role": "server"}, "/x/avahi-publish-service")
	var server_desk = find_service(server_role.services, pub.SERVICE_DESKFLOW)
	check("_deskflow role=server explícito", server_desk != null and server_desk.args.has("role=server"))

	var no_avahi = plan.build(identity, caps, "")
	check("sin avahi queda degradado", not no_avahi.ok and no_avahi.state == "degraded" and no_avahi.services.empty())
	check("sin avahi explica el motivo", not no_avahi.errors.empty())

	var only_gvd = plan.build(identity, {"gvd": true, "deskflow": false}, "/x/avahi-publish-service")
	check("capacidad desactiva un anuncio", only_gvd.services.size() == 1
		and find_service(only_gvd.services, pub.SERVICE_GVD) != null
		and find_service(only_gvd.services, pub.SERVICE_DESKFLOW) == null)

	var layout = plan.build(identity, {"gvd": true, "deskflow": false, "layout": 1}, "/x/avahi-publish-service")
	check("layout=1 propagado", layout.services.size() == 1 and layout.services[0].args.has("layout=1"))

	var none = plan.build(identity, {"gvd": false, "deskflow": false}, "/x/avahi-publish-service")
	check("sin capacidades degradado", not none.ok and none.services.empty())

	OS.exit_code = 1 if failed > 0 else 0
	quit()
