extends Reference

# Memoria de ventanas entre reinicios del shell (~/.config/gdtk/windows.json).
# Puro: sin disco ni compositor. Cada entrada recuerda cómo estaba una ventana
# (app_id + título, modo, rect flotante local, maximizada) para aplicarlo cuando
# una ventana equivalente se vuelve a abrir. Nunca guarda contenido.

const CAP = 64
const TILED = "tiled"
const FLOATING = "floating"


static func entry(app_id, title, mode, rect, maximized):
	var r = null
	if rect != null:
		var q = Rect2(rect)
		r = [q.position.x, q.position.y, q.size.x, q.size.y]
	return {"app_id": String(app_id), "title": String(title),
		"mode": TILED if String(mode) == TILED else FLOATING,
		"rect": r, "maximized": bool(maximized)}


static func serialize(entries):
	return JSON.print({"version": 1, "windows": entries.slice(0, CAP - 1)}, "\t")


# Texto -> entradas válidas; descarta lo malformado (archivo viejo/editado a mano).
static func parse(text):
	var out = []
	var p = JSON.parse(String(text))
	if p.error != OK or typeof(p.result) != TYPE_DICTIONARY:
		return out
	var ws = p.result.get("windows", [])
	if typeof(ws) != TYPE_ARRAY:
		return out
	for w in ws:
		if typeof(w) != TYPE_DICTIONARY or String(w.get("app_id", "")) == "":
			continue
		var r = w.get("rect", null)
		if typeof(r) == TYPE_ARRAY and r.size() == 4:
			r = Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
		else:
			r = null
		out.append(entry(w.get("app_id", ""), w.get("title", ""), w.get("mode", FLOATING),
			r, w.get("maximized", false)))
		if out.size() >= CAP:
			break
	return out


# Saca (y devuelve) la primera entrada que coincide: app_id+título exactos y, si no,
# sólo app_id (FIFO). null si no hay. Una entrada se consume una sola vez.
static func take(entries, app_id, title):
	if String(app_id) == "":
		return null
	var loose = -1
	for i in range(entries.size()):
		var e = entries[i]
		if e.app_id != String(app_id):
			continue
		if e.title == String(title):
			return _pop(entries, i)
		if loose < 0:
			loose = i
	return _pop(entries, loose) if loose >= 0 else null


static func _pop(entries, i):
	var e = entries[i]
	entries.remove(i)
	return e


# Instantánea a guardar: las ventanas vivas primero y, tras ellas, las entradas
# pendientes aún no reabiertas (para que un cierre sin reabrir no las borre).
static func merge(live, pending):
	var out = live.duplicate()
	for e in pending:
		if out.size() >= CAP:
			break
		out.append(e)
	return out.slice(0, CAP - 1)


# Rect recordado encajado en la caja actual (otra resolución/monitor): tamaño
# acotado a la caja y posición dentro de ella.
static func clamp_rect(r, box):
	var b = Rect2(box)
	var q = Rect2(r)
	var sz = Vector2(min(q.size.x, b.size.x), min(q.size.y, b.size.y))
	var pos = Vector2(
		clamp(q.position.x, b.position.x, b.end.x - sz.x),
		clamp(q.position.y, b.position.y, b.end.y - sz.y))
	return Rect2(pos, sz)
