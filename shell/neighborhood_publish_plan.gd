extends Reference

# Plan puro de publicación mDNS del Vecindario (SPEC-screen-share-compass §2/§14).
# No ejecuta procesos ni hace I/O: dada la identidad local y las capacidades
# devuelve la lista de anuncios {prog, args} lista para lanzar con
# avahi-publish-service. El shell sólo resuelve el binario una vez (fuera del
# frame) y lanza cada entrada sin bloquear.
#
# Reusa shell/neighborhood_publish.gd (TXT, validación, argv) sin duplicar reglas
# de seguridad.

const PUBLISH = preload("res://neighborhood_publish.gd")

const DEFAULT_GVD_PORT = 5600
const DEFAULT_DESKFLOW_PORT = 24800
const IDENTITY_HID_LEN = 16


# Identidad local no secreta: el hostname es sólo la etiqueta visible; el `hid`
# es opaco (hash del hostname) para no publicar el hostname real como identidad
# (SPEC-sugar-neighborhood-host-actions §Identidad local). Puro y testeable.
static func local_identity(hostname):
	var label = String(hostname).strip_edges()
	if label == "":
		label = "gdtk"
	return {
		"hid": _opaque_id(label),
		"name": label,
		"kind": "unknown",
		"icon": "unknown",
		"auth": "ask",
	}


static func _opaque_id(value):
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(String(value).to_utf8())
	var digest = ctx.finish()
	var hex = ""
	for b in digest:
		hex += "%02x" % int(b)
	return hex.substr(0, IDENTITY_HID_LEN)


# Plan de anuncios. `caps` -> {gvd: bool, gvd_port, gvd_state, deskflow: bool,
# deskflow_port, deskflow_role, clip, layout}. `deskflow_role` es "client" por
# defecto (un host gdtk acepta ser controlado); "server" sólo si se pide. Devuelve
# {ok, state, services: [{capability, name, service, port, prog, args}], errors}.
# Sin avahi (avahi_path vacío) o sin capacidades queda `degraded`, sin excepción.
func build(identity, caps, avahi_path):
	var pub = PUBLISH.new()
	var services = []
	var errors = []
	var path = String(avahi_path).strip_edges()

	if bool(caps.get("gvd", true)):
		var gvd = pub.build_gvd_launch(identity, int(caps.get("gvd_port", DEFAULT_GVD_PORT)), {
			"role": "recv",
			# "capable": gdtk no mantiene un receptor escuchando; se abre por
			# canal autorizado (SPEC-sugar-neighborhood-host-actions §11).
			"state": String(caps.get("gvd_state", "capable")),
			"layout": caps.get("layout", 0),
		})
		_append(pub, services, errors, gvd, path, "gvd")

	if bool(caps.get("deskflow", true)):
		var deskflow = pub.build_deskflow_launch(identity, int(caps.get("deskflow_port", DEFAULT_DESKFLOW_PORT)), {
			"role": String(caps.get("deskflow_role", "client")),
			"clip": String(caps.get("clip", "1")),
			"layout": caps.get("layout", 0),
		})
		_append(pub, services, errors, deskflow, path, "deskflow")

	var ok = errors.empty() and not services.empty()
	return {
		"ok": ok,
		"state": "ready" if ok else "degraded",
		"services": services,
		"errors": errors,
	}


# Convierte un launch crudo del publisher a una entrada {prog, args} con la ruta
# real de avahi inyectada por `prepare_launch_args` (misma validación de TXT).
func _append(pub, services, errors, launch, avahi_path, capability):
	if not launch.ok:
		errors.append(String(launch.error))
		return
	if avahi_path == "":
		errors.append("avahi-publish-service no disponible")
		return
	var txt = launch.args.slice(3, launch.args.size())
	var ready = pub.prepare_launch_args(launch.args[1], launch.args[2], txt, launch.args[0], avahi_path)
	if not ready.ok:
		errors.append(String(ready.error))
		return
	services.append({
		"capability": capability,
		"name": String(launch.args[0]),
		"service": String(launch.args[1]),
		"port": int(launch.args[2]),
		"prog": String(ready.cmd),
		"args": ready.args,
	})
