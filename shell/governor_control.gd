extends Reference

# Modelo puro del cambio de governor de CPU (SPEC-power-governor). Sin I/O ni nodos:
# valida el pedido contra la lista del kernel, arma el argv de pkexec+helper y resuelve
# la máquina de estados applying → verified/error. El I/O (File, OS.execute) vive en
# sysmon.gd; acá sólo hay decisiones, así se testea sin tocar /sys ni pkexec.

const STATE_IDLE = "idle"
const STATE_APPLYING = "applying"
const STATE_VERIFIED = "verified"
const STATE_ERROR = "error"
const STATE_UNAVAILABLE = "unavailable"
const STATE_NOT_PROVISIONED = "not_provisioned"

# Rutas absolutas estables. La action polkit las referencia por exec.path; el helper
# valida sus propios argumentos (pkexec no lo hace).
const HELPER_PATH = "/usr/libexec/gdtk-set-governor"
const POLICY_PATH = "/usr/share/polkit-1/actions/org.gdtk.governor.policy"
const PKEXEC_PATH = "/usr/bin/pkexec"
# Token ASCII estricto: nada de shell, espacios, rutas ni metacaracteres.
const TOKEN_PATTERN = "^[A-Za-z0-9_-]+$"


# ¿El nombre es un token ASCII seguro para pasar como un único argv?
static func valid_token(name):
	var s = String(name)
	if s == "":
		return false
	var re = RegEx.new()
	if re.compile(TOKEN_PATTERN) != OK:
		return false
	return re.search(s) != null


# Lista de governors del kernel (separada por espacios), sin vacíos.
static func parse_available(text):
	var out = []
	for w in String(text).split(" ", false):
		var s = String(w).strip_edges()
		if s != "":
			out.append(s)
	return out


# Membresía exacta (palabra completa), no prefijo.
static func governor_available(name, available):
	for g in available:
		if String(g) == String(name):
			return true
	return false


# argv para pkexec: sin agente textual, sin `sh -c`, sólo helper + governor.
static func build_argv(governor):
	if not valid_token(governor):
		return []
	return ["--disable-internal-agent", HELPER_PATH, String(governor)]


# Valida el pedido contra la lista del kernel. Devuelve {ok, state, reason}: un pedido
# no válido no debe llegar nunca a pkexec ni a sysfs.
static func validate_request(governor, available):
	if available.empty():
		return {"ok": false, "state": STATE_UNAVAILABLE, "reason": "sin_governors"}
	if not valid_token(governor):
		return {"ok": false, "state": STATE_ERROR, "reason": "token_invalido"}
	if not governor_available(governor, available):
		return {"ok": false, "state": STATE_ERROR, "reason": "no_disponible"}
	return {"ok": true, "state": STATE_IDLE, "reason": ""}


# Plan completo para el camino privilegiado: {state, reason, program, argv}. Si falta
# helper/policy/pkexec, el estado es not_provisioned (error accionable, sin diálogo).
static func plan_apply(governor, available, helper_present, policy_present, pkexec_present):
	var v = validate_request(governor, available)
	if not v.ok:
		return {"state": v.state, "reason": v.reason, "program": "", "argv": []}
	if not helper_present or not policy_present or not pkexec_present:
		return {"state": STATE_NOT_PROVISIONED, "reason": "sin_helper", "program": "", "argv": []}
	return {"state": STATE_APPLYING, "reason": "", "program": PKEXEC_PATH, "argv": build_argv(governor)}


# Resuelve un estado `applying` con la observación posterior de sysfs. Sin timeout
# vencido sigue esperando; con el valor pedido, verified; con timeout, error.
static func observe_result(state, requested, observed, now_ms, deadline_ms):
	if state != STATE_APPLYING:
		return state
	if String(requested) != "" and String(observed) == String(requested):
		return STATE_VERIFIED
	if now_ms >= deadline_ms:
		return STATE_ERROR
	return STATE_APPLYING
