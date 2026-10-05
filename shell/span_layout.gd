extends Reference

# Fase E / modo span (SPEC-physical-multi-monitor.md): modelo PURO del
# descubrimiento de monitores fisicos del anfitrion sway y del plan de span.
#
# Sin I/O: recibe el texto ya capturado por el worker del shell
# (`swaymsg -t get_outputs -r`) y devuelve el plan de geometria y los comandos
# sway. El shell es el unico que ejecuta procesos; aca solo se decide que hacer.
#
# Decision (spec): una sola ventana de Godot cubre el rectangulo envolvente de
# todos los monitores. La principal queda en (0,0) y el resto se reordena a su
# derecha con `swaymsg output <n> pos x y`; el shell parte el viewport en salidas
# logicas. El Frame y las vistas Sugar viven solo en la principal.

const APP_ID = "godot-gdtk"

# Nombre de salida logica del compositor embebido para un monitor fisico.
const PRIMARY_ID = "primary"
const PHYS_PREFIX = "physical:"


# --- Parseo del anfitrion ------------------------------------------------------

# JSON de `swaymsg -t get_outputs -r` -> [{name, width, height, scale, x, y}] con
# tamanos LOGICOS (mode/scale o rect.width/height). Descarta inactivas/ invalidas.
static func parse_outputs(text):
	var res = JSON.parse(String(text))
	if res.error != OK or typeof(res.result) != TYPE_ARRAY:
		return []
	var out = []
	for raw in res.result:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		if not bool(raw.get("active", false)):
			continue
		var name = String(raw.get("name", "")).strip_edges()
		if name == "" or name.find(" ") >= 0 or name.find("/") >= 0:
			continue
		var scale = float(raw.get("scale", 1.0))
		if scale <= 0.0:
			scale = 1.0
		var size = _logical_size(raw, scale)
		if size.x <= 0.0 or size.y <= 0.0:
			continue
		var x = 0.0
		var y = 0.0
		var rect = raw.get("rect", null)
		if typeof(rect) == TYPE_DICTIONARY:
			x = float(rect.get("x", 0.0))
			y = float(rect.get("y", 0.0))
		out.append({"name": name, "width": size.x, "height": size.y,
			"scale": scale, "x": x, "y": y})
	return out


static func _logical_size(raw, scale):
	var rect = raw.get("rect", null)
	if typeof(rect) == TYPE_DICTIONARY:
		var rw = float(rect.get("width", 0.0))
		var rh = float(rect.get("height", 0.0))
		if rw > 0.0 and rh > 0.0:
			return Vector2(rw, rh)
	var mode = raw.get("current_mode", null)
	if typeof(mode) == TYPE_DICTIONARY:
		return Vector2(float(mode.get("width", 0.0)), float(mode.get("height", 0.0))) / scale
	return Vector2.ZERO


# --- Eleccion y orden ----------------------------------------------------------

# Principal: la forzada si esta activa; si no, una externa (DP/HDMI) antes que la
# interna (eDP/LVDS/DSI); si no hay, la primera. Igual criterio que session/gdtk-outputs.
static func choose_primary(outputs, forced = ""):
	if typeof(outputs) != TYPE_ARRAY or outputs.empty():
		return ""
	var want = String(forced).strip_edges()
	if want != "":
		for o in outputs:
			if String(o.name) == want:
				return want
	for o in outputs:
		if not _internal(String(o.name)):
			return String(o.name)
	return String(outputs[0].name)


static func _internal(name):
	return name.begins_with("eDP") or name.begins_with("LVDS") or name.begins_with("DSI")


# Orden estable: principal primero; luego los nombres de `order` en ese orden y el
# resto por (x, y, nombre). `order` es el orden izquierda->derecha de las demás
# salidas elegido por el usuario (SPEC-physical-multi-monitor §ajustes).
static func order_outputs(outputs, primary_name, order = []):
	var out = []
	var want = String(primary_name)
	for o in outputs:
		if String(o.name) == want:
			out.append(o)
	var rest = []
	for o in outputs:
		if String(o.name) != want:
			rest.append(o)
	if typeof(order) == TYPE_ARRAY:
		for n in order:
			var name = String(n)
			for i in range(rest.size() - 1, -1, -1):
				if String(rest[i].name) == name:
					out.append(rest[i])
					rest.remove(i)
	var sorted = []
	for o in rest:
		var pos = sorted.size()
		for j in range(sorted.size()):
			if _before(o, sorted[j]):
				pos = j
				break
		sorted.insert(pos, o)
	for o in sorted:
		out.append(o)
	return out


static func _before(a, b):
	var ax = float(a.x)
	var bx = float(b.x)
	if ax != bx:
		return ax < bx
	var ay = float(a.y)
	var by = float(b.y)
	if ay != by:
		return ay < by
	return String(a.name) < String(b.name)


# --- Plan ----------------------------------------------------------------------

# Plan de span: salidas habilitadas ordenadas, con la principal en (0,0) y el
# resto a su derecha. `order` es el orden izquierda->derecha de las demás ([] =
# automático por posición física). Devuelve {ok, primary, entries, descriptors,
# desktop, screen, active, single}. `descriptors` alimenta
# output_layout.reconcile_outputs.
static func plan(outputs, forced_primary = "", order = []):
	if typeof(outputs) != TYPE_ARRAY or outputs.empty():
		return {"ok": false, "error": "sin salidas", "primary": "",
			"entries": [], "descriptors": [], "desktop": Rect2(),
			"screen": Rect2(), "active": false, "single": true}
	var primary = choose_primary(outputs, forced_primary)
	if primary == "":
		return {"ok": false, "error": "sin principal", "primary": "",
			"entries": [], "descriptors": [], "desktop": Rect2(),
			"screen": Rect2(), "active": false, "single": true}
	var ordered = order_outputs(outputs, primary, order)
	var entries = []
	var descriptors = []
	var x = 0.0
	var max_h = 0.0
	for o in ordered:
		var w = float(o.width)
		var h = float(o.height)
		var rect = Rect2(x, 0.0, w, h)
		var is_primary = String(o.name) == primary
		var id = PRIMARY_ID if is_primary else PHYS_PREFIX + String(o.name)
		entries.append({"id": id, "name": String(o.name), "rect": rect,
			"scale": float(o.scale), "primary": is_primary})
		var desc = {"id": id, "kind": "physical", "rect": rect,
			"scale": float(o.scale), "enabled": true, "primary": is_primary,
			"target": "main_viewport" if is_primary else "span", "direction": ""}
		descriptors.append(desc)
		x += w
		max_h = max(max_h, h)
	var desktop = Rect2(0.0, 0.0, x, max_h)
	var screen = Rect2(0.0, 0.0, float(entries[0].rect.size.x), float(entries[0].rect.size.y))
	var active = entries.size() >= 2 and desktop.size.x > screen.size.x
	return {"ok": true, "error": "", "primary": primary, "entries": entries,
		"descriptors": descriptors, "desktop": desktop, "screen": screen,
		"active": active, "single": not active}


# --- Comandos sway -------------------------------------------------------------

# Comandos para reordenar las salidas fisicas segun el plan (la principal a 0,0).
# Cada item es un argv para `swaymsg` (el shell los ejecuta fuera del frame).
static func position_commands(plan):
	var cmds = []
	if typeof(plan) != TYPE_DICTIONARY or not bool(plan.get("ok", false)):
		return cmds
	for e in plan.entries:
		var r = e.rect
		cmds.append(["output", String(e.name), "pos",
			str(int(round(r.position.x))), str(int(round(r.position.y)))])
	return cmds


# Ventana del shell cubriendo el envolvente: flotante, sin borde, en 0,0, del
# tamano del escritorio completo. Sin fullscreen (el fullscreen ata a una salida).
static func span_window_command(desktop):
	var w = int(round(desktop.size.x))
	var h = int(round(desktop.size.y))
	return '[app_id="' + APP_ID + '"] fullscreen disable, floating enable, border none, ' \
		+ 'move absolute position 0 0, resize set ' + str(w) + ' ' + str(h)


# Vuelta a una sola salida: fullscreen en la salida enfocada (comportamiento actual).
static func single_window_command():
	return '[app_id="' + APP_ID + '"] fullscreen enable'


# Descriptor de salida del compositor embebido -> {id, name, rect, scale, primary}.
# El shell lo usa para crear/actualizar/quitar sus wl_output logicos.
static func output_ops(plan):
	var ops = []
	if typeof(plan) != TYPE_DICTIONARY or not bool(plan.get("ok", false)):
		return ops
	for e in plan.entries:
		ops.append({"id": String(e.id), "name": String(e.name), "rect": e.rect,
			"scale": float(e.scale), "primary": bool(e.primary)})
	return ops


# Version JSON-friendly del plan para el RPC `state` (sin Rect2 ni bool crudos).
static func state_entries(plan):
	var out = []
	if typeof(plan) != TYPE_DICTIONARY or not bool(plan.get("ok", false)):
		return out
	for e in plan.entries:
		var r = e.rect
		out.append({"id": String(e.id), "name": String(e.name), "primary": bool(e.primary),
			"rect": [r.position.x, r.position.y, r.size.x, r.size.y]})
	return out
