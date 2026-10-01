extends Reference

# Handshake de dirección del Vecindario (SPEC-screen-share-compass, §1 §6 §9 §14
# "Kilo G"). Modelo PURO y simulable: construye/parsea DTOs JSON y calcula las
# transiciones de confirmación del vínculo (unconfirmed -> proposed -> confirmed).
#
# No ejecuta nada: no hace ssh, no hace JSON-RPC, no toca red, fs ni procesos. El
# envío real por el canal autorizado (ssh o control de shell/remote.gd) lo hace el
# caller; este módulo sólo produce el payload, lo reinterpreta y aplica el mensaje
# recibido sobre el entry local.
#
# Forma del entry local (igual que neighborhood-directions.json, §12):
#   {"direction": "north|south|east|west|none",
#    "confirm":   "unconfirmed|proposed|confirmed",
#    ... otros campos (mode, link, updated) se conservan tal cual ...
#
# Reglas de `apply`:
#   - proposal con direction != "none": confirm -> "proposed", direction = esa.
#   - response accepted == true:  confirm -> "confirmed".
#   - response accepted == false: confirm -> "unconfirmed".
#   - mensaje inválido: se devuelve el entry local normalizado, sin cambios.
#   La dirección sólo cambia por proposal; un response nunca la pisa.

const VERSION = 1
const DIRECTIONS = ["north", "south", "east", "west", "none"]
const CONFIRMS = ["unconfirmed", "proposed", "confirmed"]
const KIND_PROPOSAL = "direction_proposal"
const KIND_RESPONSE = "direction_response"
const KINDS = [KIND_PROPOSAL, KIND_RESPONSE]


# Dirección válida o "none". Nunca lanza: un valor raro degrada a "none".
static func sanitize_direction(direction):
	var d = String(direction).strip_edges().to_lower()
	return d if DIRECTIONS.has(d) else "none"


# Estado de confirmación válido o "unconfirmed".
static func sanitize_confirm(confirm):
	var c = String(confirm).strip_edges().to_lower()
	return c if CONFIRMS.has(c) else "unconfirmed"


# DTO de propuesta: {"v":1, "kind":"direction_proposal", "from", "to", "direction"}.
static func proposal(from_hid, to_hid, direction):
	return {"v": VERSION, "kind": KIND_PROPOSAL, "from": String(from_hid),
		"to": String(to_hid), "direction": sanitize_direction(direction)}


# DTO de respuesta: igual que la propuesta más "accepted": bool.
static func response(from_hid, to_hid, direction, accepted):
	return {"v": VERSION, "kind": KIND_RESPONSE, "from": String(from_hid),
		"to": String(to_hid), "direction": sanitize_direction(direction),
		"accepted": bool(accepted)}


# Serializa un DTO. `to_json` de Godot 3.6 ordena las claves, así que la salida es
# determinista para el mismo payload.
static func encode(payload):
	return to_json(payload)


# Parsea un DTO. Entrada inválida o kind desconocido -> {"ok": false, "error"}.
# Válida -> {"ok": true, "kind", "v", "from", "to", "direction", ["accepted"]}.
# Sin secretos: sólo se copian los campos del contrato.
static func decode(text):
	var parsed = JSON.parse(String(text))
	if parsed.error != OK:
		return {"ok": false, "error": "json inválido"}
	var data = parsed.result
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "error": "json no es objeto"}
	var kind = String(data.get("kind", "")).strip_edges()
	if not KINDS.has(kind):
		return {"ok": false, "error": "kind desconocido"}
	var out = {"ok": true, "v": int(data.get("v", VERSION)), "kind": kind,
		"from": String(data.get("from", "")), "to": String(data.get("to", "")),
		"direction": sanitize_direction(data.get("direction", "none"))}
	if kind == KIND_RESPONSE:
		out["accepted"] = bool(data.get("accepted", false))
	return out


# Aplica un mensaje decodificado al entry local y devuelve un entry NUEVO: no muta
# `local_entry`. Los campos ajenos a direction/confirm se conservan.
static func apply(local_entry, message):
	var entry = _normalize_entry(local_entry)
	if typeof(message) != TYPE_DICTIONARY or not bool(message.get("ok", false)):
		return entry
	var kind = String(message.get("kind", ""))
	if kind == KIND_PROPOSAL:
		var d = sanitize_direction(message.get("direction", "none"))
		if d != "none":
			entry["direction"] = d
			entry["confirm"] = "proposed"
	elif kind == KIND_RESPONSE:
		entry["confirm"] = "confirmed" if bool(message.get("accepted", false)) else "unconfirmed"
	return entry


# Cálculo directo del estado siguiente sin pasar por el DTO, para pruebas/uso UI.
# Devuelve el nuevo confirm: unconfirmed|proposed|confirmed.
static func next_confirm(confirm, accepted):
	if not bool(accepted):
		return "unconfirmed"
	return "confirmed"


static func _normalize_entry(local_entry):
	var out = {}
	if typeof(local_entry) == TYPE_DICTIONARY:
		for k in local_entry.keys():
			out[k] = local_entry[k]
	out["direction"] = sanitize_direction(out.get("direction", "none"))
	out["confirm"] = sanitize_confirm(out.get("confirm", "unconfirmed"))
	return out


static func selftest():
	# DTOs y saneamiento.
	var p = proposal("hidA", "hidB", "east")
	assert(p.v == VERSION and p.kind == KIND_PROPOSAL and p.from == "hidA" and p.to == "hidB"
		and p.direction == "east", "proposal bien formada")
	assert(proposal("a", "b", "diagonal").direction == "none", "dirección inválida -> none")
	var r = response("hidB", "hidA", "east", true)
	assert(r.kind == KIND_RESPONSE and r.accepted == true and r.direction == "east",
		"response bien formada")

	# Round-trip determinista.
	var pe = encode(p)
	assert(pe == encode(proposal("hidA", "hidB", "east")), "encode determinista")
	var pd = decode(pe)
	assert(pd.ok and pd.kind == KIND_PROPOSAL and pd.from == "hidA" and pd.to == "hidB"
		and pd.direction == "east", "round-trip proposal")
	var rd = decode(encode(r))
	assert(rd.ok and rd.kind == KIND_RESPONSE and rd.accepted == true, "round-trip response")

	# Decode inválido.
	assert(not decode("{no json").ok, "json basura rechazado")
	assert(not decode("{\"kind\":\"otra_cosa\"}").ok, "kind desconocido rechazado")
	assert(decode("{no json").error != "", "error no vacío")

	# apply: transiciones.
	var e0 = {"direction": "none", "confirm": "unconfirmed", "mode": "extend"}
	var e1 = apply(e0, decode(encode(proposal("hidB", "hidA", "west"))))
	assert(e1.direction == "west" and e1.confirm == "proposed", "proposal -> proposed")
	assert(e0.direction == "none" and e0.confirm == "unconfirmed", "apply no muta el entry")
	assert(e1.mode == "extend", "apply conserva campos ajenos")
	var e2 = apply(e1, decode(encode(response("hidA", "hidB", "west", true))))
	assert(e2.confirm == "confirmed" and e2.direction == "west", "accept -> confirmed")
	var e3 = apply(e1, decode(encode(response("hidA", "hidB", "west", false))))
	assert(e3.confirm == "unconfirmed" and e3.direction == "west", "reject -> unconfirmed")

	# Un response de otra dirección no pisa la dirección local.
	var e4 = apply({"direction": "north", "confirm": "proposed"},
		decode(encode(response("hidA", "hidB", "south", true))))
	assert(e4.direction == "north" and e4.confirm == "confirmed", "response no pisa dirección")

	# proposal con direction none no propone nada.
	var e5 = apply({"direction": "east", "confirm": "confirmed"},
		decode(encode(proposal("hidB", "hidA", "none"))))
	assert(e5.direction == "east" and e5.confirm == "confirmed", "proposal none no cambia")

	# Mensaje inválido: entry normalizado sin cambios.
	var bad = apply({"direction": "oops", "confirm": "raro"}, {"ok": false, "error": "x"})
	assert(bad.direction == "none" and bad.confirm == "unconfirmed", "inválido normaliza")
	assert(next_confirm("proposed", true) == "confirmed"
		and next_confirm("proposed", false) == "unconfirmed", "next_confirm")
	return true


func run_selftest():
	return selftest()
