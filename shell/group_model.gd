extends Reference

# Modelo PURO del "Grupo" (SPEC-sugar-group-2026-10, G4a). El Grupo son los equipos
# conocidos o pareados aunque estén apagados, más los Bluetooth pareados. A
# diferencia del Vecindario, que sólo muestra lo vivo, el Grupo persiste.
#
# Sin I/O: recibe los snapshots ya leídos por el shell y devuelve las fichas listas
# para la vista:
#   directions:  {hid: {direction, confirm, mode, link, updated}}  (host_directions)
#   tokens:      {"cli:<hid>": token}                              (peer-tokens.json)
#   screens:     [{id, label, peer, local, x, y, w, h, offset}]    (settings screens)
#   live_hosts:  modelo de neighborhood_hosts.build_hosts (Array)
#   bt_devices:  modelo de neighborhood._read_bt (Array)
#
# Nunca copia el token al resultado. Deduplica por hid (identidad física) y por
# nombre visible; el orden es estable: primero los ubicados N, E, S, O, después los
# sin ubicar y al final los Bluetooth (sólo los que están al alcance).

const SL = preload("res://screen_layout.gd")

const DIRECTIONS = ["north", "east", "south", "west"]   # orden N, E, S, O
const DIR_RANK = {"north": 0, "east": 1, "south": 2, "west": 3}

const KIND_HOST = "host"
const KIND_BT = "bt"


static func members(directions, tokens, screens, live_hosts, bt_devices):
	var idx = _index_hosts(live_hosts)
	var entries = []

	# 1. Direcciones: equipos ya ubicados o propuestos.
	if typeof(directions) == TYPE_DICTIONARY:
		for k in directions.keys():
			var hid = String(k).strip_edges()
			if hid == "":
				continue
			var dir = ""
			var along = -1.0
			var entry = directions[k]
			if typeof(entry) == TYPE_DICTIONARY:
				var d = String(entry.get("direction", "")).strip_edges()
				if DIR_RANK.has(d):
					dir = d
					along = _along(entry.get("along", -1.0))
			entries.append({"hid": hid, "name": "", "direction": dir, "along": along, "host": null})

	# 2. Tokens por-par (claves "cli:<hid>"); el valor del token NUNCA se copia.
	if typeof(tokens) == TYPE_DICTIONARY:
		for k in tokens.keys():
			var key = String(k)
			# cli: lo pareamos nosotros; srv: nos pareó él. Ambos son del Grupo.
			if not (key.begins_with("cli:") or key.begins_with("srv:")):
				continue
			var hid2 = key.substr(4).strip_edges()
			if hid2 == "":
				continue
			entries.append({"hid": hid2, "name": "", "direction": "", "host": null})

	# 3. Pantallas configuradas. El vínculo con un host vivo es por hid (id de la
	# pantalla) o por nombre visible (label/peer), tal como los asocia el shell.
	if typeof(screens) == TYPE_ARRAY:
		for s in screens:
			if typeof(s) != TYPE_DICTIONARY:
				continue
			if bool(s.get("local", false)):
				continue
			var sid = String(s.get("id", "")).strip_edges()
			var nm = _screen_name(s)
			if sid == "" and nm == "":
				continue
			var host = _match_host(sid, nm, idx)
			var hid3 = sid
			if host != null:
				var hhid = _host_hid(host)
				if hhid != "":
					hid3 = hhid
			entries.append({"hid": hid3, "name": nm, "direction": "", "host": host})

	# Mezcla: clave canónica por hid (o por nombre si no hay hid). Un host vivo
	# unifica todas las fuentes que lo referencian.
	var by_key = {}
	var order = []
	for e in entries:
		var hid = String(e.get("hid", "")).strip_edges()
		var nm = String(e.get("name", "")).strip_edges()
		var host = e.get("host", null)
		if host == null:
			host = _match_host(hid, nm, idx)
		var key = ""
		if host != null:
			var hh = _host_hid(host)
			key = "h:" + (hh if hh != "" else String(host.get("id", hid)))
		elif hid != "":
			key = "h:" + hid
		else:
			key = "n:" + _norm(nm)
		var m = by_key.get(key, null)
		if m == null:
			m = _new_member("", KIND_HOST)
			by_key[key] = m
			order.append(key)
		if hid != "" and (m.id == "" or host != null):
			m.id = hid
		if host != null:
			_apply_host(m, host)
		if nm != "" and (m.name == "" or m.name == m.id):
			m.name = nm
		var dr = String(e.get("direction", ""))
		if dr != "" and m.direction == "":
			m.direction = dr
			m.along = _along(e.get("along", -1.0))

	# 4. Enriquecer TODA ficha host con el host vivo (por hid o por nombre).
	for key in order:
		var m = by_key[key]
		if m.kind != KIND_HOST:
			continue
		if m.host.empty():
			var host = _match_host(m.id, m.name, idx)
			if host != null:
				_apply_host(m, host)
		if m.name == "":
			m.name = m.id

	# 5. Bluetooth: sólo pareados Y al alcance (conectado o con señal), con ícono por tipo.
	if typeof(bt_devices) == TYPE_ARRAY:
		var seen_bt = {}
		for d in bt_devices:
			if typeof(d) != TYPE_DICTIONARY:
				continue
			if not bool(d.get("paired", false)) or not bt_in_range(d):
				continue
			var addr = String(d.get("address", "")).strip_edges()
			if addr == "" or seen_bt.has(addr):
				continue
			seen_bt[addr] = true
			var b = _new_member(addr, KIND_BT)
			b.name = _bt_name(d, addr)
			b.bt_kind = bt_kind(String(d.get("icon", "")))
			b.connected = bool(d.get("connected", false))
			b.rssi = int(d.get("rssi", 0))
			b.online = b.connected
			by_key["b:" + addr] = b
			order.append("b:" + addr)

	# Recolectar y deduplicar por nombre visible (hosts sin host vivo).
	var deduped = []
	var by_name = {}
	for key in order:
		var m = by_key[key]
		var nk = _norm(m.name)
		if m.kind == KIND_HOST and nk != "":
			var prev = by_name.get(nk, null)
			if prev != null and (prev.host.empty() or m.host.empty()):
				_merge_into(prev, m)
				continue
			by_name[nk] = m
		deduped.append(m)

	# Migración v1: si quedaron una ficha nominal y un único HID opaco en el mismo
	# lado, son las dos identidades históricas de la misma pantalla. Sólo se fusiona
	# cuando la asociación es inequívoca; nunca se adivina entre dos equipos.
	for i in range(deduped.size() - 1, -1, -1):
		var alias = deduped[i]
		if _opaque_hid(String(alias.get("id", ""))) or String(alias.get("direction", "")) == "":
			continue
		var matches = []
		for j in range(deduped.size()):
			if i != j and _opaque_hid(String(deduped[j].get("id", ""))) \
					and String(deduped[j].get("direction", "")) == String(alias.direction):
				matches.append(j)
		if matches.size() == 1:
			_merge_into(deduped[matches[0]], alias)
			deduped.remove(i)

	_sort_members(deduped)
	return deduped


# Un Bluetooth está "al alcance" si está conectado o el adaptador lo ve ahora (RSSI
# distinto de 0, o `seen` explícito). Los sólo conocidos/pareados que no responden no.
static func bt_in_range(d):
	if typeof(d) != TYPE_DICTIONARY:
		return false
	return bool(d.get("connected", false)) or int(d.get("rssi", 0)) != 0 \
		or bool(d.get("seen", false))


# Ángulos (grados, horario en pantalla) guardados por la vista Grupo, para el diagrama
# de "Compartiendo": {hid: grados}. Sólo equipos con lado; sin `along` va al centro del lado.
static func placements(directions, half = null):
	var out = {}
	if typeof(directions) != TYPE_DICTIONARY:
		return out
	var h = _default_ring() if half == null else Vector2(half)
	for k in directions.keys():
		var e = directions[k]
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d = String(e.get("direction", "")).strip_edges()
		if not DIR_RANK.has(d):
			continue
		var a = _along(e.get("along", -1.0))
		out[String(k)] = SL.angle_from_placement(d, 0.5 if a < 0.0 else a, h)
	return out


# Añade el hid al Grupo (entrada propuesta, sin ubicar) si no existe. Copia pura.
static func add_member(directions, hid):
	var out = directions.duplicate(true) if typeof(directions) == TYPE_DICTIONARY else {}
	var id = String(hid).strip_edges()
	if id == "":
		return out
	if not out.has(id):
		out[id] = {"direction": "", "confirm": "proposed", "mode": "", "link": "", "updated": 0}
	return out


# Quita el hid del Grupo. Copia pura; el token y la pantalla los limpia el shell.
static func remove_member(directions, hid):
	var out = directions.duplicate(true) if typeof(directions) == TYPE_DICTIONARY else {}
	out.erase(String(hid).strip_edges())
	return out


# Plan de lo que el shell debe borrar al "Quitar del grupo".
static func removal_plan(hid, name):
	return {"directions": String(hid), "token": "cli:" + String(hid), "screen": String(name)}


# --- Layout de la vista Grupo (puro) -----------------------------------------
# Medidas de la vista Grupo: el ícono central es más grande que en el Vecindario
# y los miembros van "pegados" a su lado correspondiente. Todo determinista, sin
# I/O: recibe las fichas de members() y devuelve posiciones listas para dibujar.
const CENTER_SIZE = 100.0
const NODE_SIZE = 64.0
const BT_SIZE = 24.0
const GAP = 12.0
const LABEL_TAIL = 16.0
const ARC_SAG = 16.0
const STEP_H = NODE_SIZE + GAP
const STEP_V = (NODE_SIZE * 0.5 + LABEL_TAIL) * 2.0 + GAP
const SIDE_OFFSET = CENTER_SIZE * 0.5 + GAP + NODE_SIZE * 0.5
const UNPLACED_RADIUS = SIDE_OFFSET + (NODE_SIZE * 0.5 + LABEL_TAIL) * 2.0 + GAP


# Anillo (rectángulo) alrededor del equipo local donde se ubican los pares: semiejes
# proporcionales a SIDE_OFFSET, recortados a la vista. Es el rectángulo de referencia
# de SL.placement_from_angle / angle_from_placement.
const RING_FACTOR = Vector2(1.9, 1.3)
# Distancia mínima entre centros de dos pares sobre el anillo (ficha + rótulo).
const MIN_SEP = STEP_V


static func _default_ring():
	return Vector2(SIDE_OFFSET * RING_FACTOR.x, SIDE_OFFSET * RING_FACTOR.y)


# Semiejes del anillo para esta vista: no sale del área útil (entre las barras).
static func ring_half(vp, bar):
	var d = _default_ring()
	var max_x = float(vp.x) * 0.5 - NODE_SIZE * 0.5 - 8.0
	var max_y = float(vp.y) * 0.5 - float(bar) - (NODE_SIZE * 0.5 + LABEL_TAIL) - 8.0
	return Vector2(max(40.0, min(d.x, max_x)), max(40.0, min(d.y, max_y)))


# Posición de las fichas del Grupo. Devuelve:
#   center, center_size: ancla central (coincide con el ícono del shell, vp*0.5)
#   side_offset: distancia de un miembro con dirección al centro (lado N/S, centrado)
#   ring: semiejes del anillo donde caen los pares ubicados
#   nodes: [{...ficha..., center, pos, size, direction, angle, dimmed, member}]
#   unplaced: [ids sin dirección]
#   unplaced_label: posición del rótulo "Sin ubicar"
#   bt: [{...ficha..., center, pos, size}]
# Cada par con dirección va sobre el anillo en su ángulo (lado + `along`; sin `along`,
# al centro de su lado); si dos chocan se separan por ángulo. Los sin ubicar van en un
# arco inferior y los Bluetooth al alcance en un anillo exterior repartido en 360°,
# eligiendo el giro que más los aleja de los pares. Una pasada final separa lo móvil
# (sin ubicar y BT) sin mover lo ubicado.
static func group_layout(members, vp, bar):
	var center = Vector2(vp) * 0.5
	var half = ring_half(vp, bar)
	var out = {
		"center": center, "center_size": CENTER_SIZE, "side_offset": SIDE_OFFSET,
		"ring": half, "nodes": [], "unplaced": [], "unplaced_label": Vector2.ZERO, "bt": [],
	}
	if typeof(members) != TYPE_ARRAY:
		return out
	var placed = []
	var unplaced = []
	var bt = []
	for m in members:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		if String(m.get("kind", KIND_HOST)) == KIND_BT:
			bt.append(m)
			continue
		var d = String(m.get("direction", "")).strip_edges()
		if DIR_RANK.has(d):
			placed.append(m)
		else:
			unplaced.append(m)
	var nodes = []
	var angles = []
	for m in placed:
		var al = _along(m.get("along", -1.0))
		angles.append(SL.angle_from_placement(String(m.direction), 0.5 if al < 0.0 else al, half))
	_spread_angles(angles, half)
	for i in range(placed.size()):
		var n = _place(placed[i], center + SL.edge_point(angles[i], half), NODE_SIZE)
		n["angle"] = float(angles[i])
		nodes.append(n)
	# "Sin ubicar": arco inferior (se reparten a lo ancho con una leve curva).
	var ucnt = unplaced.size()
	var base_y = center.y + max(UNPLACED_RADIUS, half.y + (NODE_SIZE * 0.5 + LABEL_TAIL) * 2.0 + GAP)
	for i in range(ucnt):
		var off = float(i) - float(ucnt - 1) * 0.5
		var t = 0.0 if ucnt <= 1 else (float(i) / float(ucnt - 1)) * 2.0 - 1.0
		var c2 = Vector2(center.x + off * STEP_H, base_y - ARC_SAG * (1.0 - t * t))
		nodes.append(_place(unplaced[i], c2, NODE_SIZE))
		out.unplaced.append(String(unplaced[i].get("id", "")))
	if ucnt > 0:
		out.unplaced_label = Vector2(center.x - 80.0,
			base_y - NODE_SIZE * 0.5 - LABEL_TAIL - ARC_SAG - 20.0)
	# Bluetooth al alcance: anillo exterior, parejo en ángulo y girado hacia los huecos.
	var bt_half = half + Vector2(NODE_SIZE * 0.5 + LABEL_TAIL + BT_SIZE, NODE_SIZE * 0.5 + LABEL_TAIL + BT_SIZE)
	var bt_base = _bt_base_angle(angles, bt.size())
	for i in range(bt.size()):
		var ang = bt_base + 360.0 * float(i) / float(bt.size())
		out.bt.append(_place(bt[i], center + SL.edge_point(ang, bt_half), BT_SIZE))
	out.nodes = nodes
	_settle(out, vp, bar)
	return out


# Separa por ángulo los pares ubicados cuyos centros quedan a menos de MIN_SEP sobre el
# anillo (acotado y determinista). Modifica `angles` (grados 0..360).
static func _spread_angles(angles, half):
	var n = angles.size()
	if n < 2:
		return
	for _it in range(64):
		var order = []
		for i in range(n):
			order.append(i)
		order.sort_custom(_AngleSorter.new(angles), "less")
		var moved = false
		for k in range(n):
			var i = order[k]
			var j = order[(k + 1) % n]
			var pa = SL.edge_point(angles[i], half)
			var pb = SL.edge_point(angles[j], half)
			var dist = pa.distance_to(pb)
			if dist >= MIN_SEP - 0.5:
				continue
			var push = rad2deg((MIN_SEP - dist) / max(1.0, (pa.length() + pb.length()) * 0.5)) * 0.5
			angles[i] = fposmod(angles[i] - push, 360.0)
			angles[j] = fposmod(angles[j] + push, 360.0)
			moved = true
		if not moved:
			break


class _AngleSorter:
	var a
	func _init(angles):
		a = angles
	func less(i, j):
		return a[i] < a[j]


# Giro (grados) del anillo de Bluetooth que más lo aleja de los ángulos de los pares.
static func _bt_base_angle(host_angles, count):
	if count <= 0 or host_angles.empty():
		return 45.0
	var best = 45.0
	var best_d = -1.0
	for step in range(72):
		var base = float(step) * 5.0
		var worst = 360.0
		for i in range(count):
			var ang = base + 360.0 * float(i) / float(count)
			for h in host_angles:
				var d = abs(fposmod(ang - h + 180.0, 360.0) - 180.0)
				worst = min(worst, d)
		if worst > best_d + 0.001:
			best_d = worst
			best = base
	return best


# Ficha de layout: copia de la ficha del modelo + geometría y estado visual.
static func _place(m, c, size):
	return {
		"id": String(m.get("id", "")),
		"name": String(m.get("name", "")),
		"online": bool(m.get("online", false)),
		"direction": String(m.get("direction", "")),
		"kind": String(m.get("kind", KIND_HOST)),
		"bt_kind": String(m.get("bt_kind", "")),
		"along": float(m.get("along", -1.0)),
		"rssi": int(m.get("rssi", 0)),
		"connected": bool(m.get("connected", false)),
		"dimmed": not bool(m.get("online", false)),
		"center": Vector2(c),
		"pos": Vector2(c) - Vector2(size, size) * 0.5,
		"size": float(size),
		"member": m,
	}


# Reasienta lo móvil (sin ubicar y BT) para que ninguna cápsula se solape, sin
# mover a los ubicados ni salir de la vista. Acotado y determinista.
static func _settle(out, vp, bar):
	var pts = []
	var half_w = []
	var half_h = []
	var pinned = []
	for n in out.nodes:
		pts.append(Vector2(n.center))
		half_w.append(NODE_SIZE * 0.5)
		half_h.append(NODE_SIZE * 0.5 + LABEL_TAIL)
		pinned.append(String(n.direction) != "")
	for b in out.bt:
		pts.append(Vector2(b.center))
		half_w.append(BT_SIZE * 0.5)
		half_h.append(BT_SIZE * 0.5)
		pinned.append(false)
	var guard = 0
	while guard < 96:
		_separate_pinned(pts, half_w, half_h, pinned, GAP)
		_clamp_movable(pts, half_w, half_h, pinned, vp, bar)
		if not _overlap(pts, half_w, half_h, GAP):
			break
		guard += 1
	var idx = 0
	for n in out.nodes:
		n.center = pts[idx]
		n.pos = pts[idx] - Vector2(n.size, n.size) * 0.5
		idx += 1
	for b in out.bt:
		b.center = pts[idx]
		b.pos = pts[idx] - Vector2(b.size, b.size) * 0.5
		idx += 1


static func _separate_pinned(p, half_w, half_h, pinned, gap):
	var n = p.size()
	for i in range(n):
		for j in range(i + 1, n):
			if pinned[i] and pinned[j]:
				continue
			var d = p[j] - p[i]
			var dist = d.length()
			var dir
			if dist < 0.0001:
				dir = Vector2(1.0, 0.0).rotated(float(i * 7 + j) * 0.7)
				dist = 0.0
			else:
				dir = d / dist
			var need = (float(half_w[i]) + float(half_w[j]) + float(gap)) * abs(dir.x) \
				+ (float(half_h[i]) + float(half_h[j]) + float(gap)) * abs(dir.y)
			if dist >= need:
				continue
			var push = need - dist
			if pinned[i]:
				p[j] += dir * push
			elif pinned[j]:
				p[i] -= dir * push
			else:
				p[i] -= dir * (push * 0.5)
				p[j] += dir * (push * 0.5)


static func _clamp_movable(p, half_w, half_h, pinned, vp, bar):
	for i in range(p.size()):
		if pinned[i]:
			continue
		var min_x = float(half_w[i])
		var max_x = max(min_x, float(vp.x) - float(half_w[i]))
		var min_y = float(bar) + float(half_h[i])
		var max_y = max(min_y, float(vp.y) - float(bar) - float(half_h[i]))
		p[i] = Vector2(clamp(p[i].x, min_x, max_x), clamp(p[i].y, min_y, max_y))


static func _overlap(p, half_w, half_h, gap):
	for i in range(p.size()):
		for j in range(i + 1, p.size()):
			if abs(p[j].x - p[i].x) < float(half_w[i]) + float(half_w[j]) + float(gap) \
					and abs(p[j].y - p[i].y) < float(half_h[i]) + float(half_h[j]) + float(gap):
				return true
	return false


# Conectores de la vista Grupo (N9): uno por par con relación activa, del borde del
# ícono central al borde del par. `peers` es la lista de shared_block.radial (key = hid,
# peer_name, direction "out"=el local controla/extiende | "in" | "both", state
# starting|active|error, screen/input). Devuelve [{id, a, b, mid, screen, input,
# direction, state}]. Puro; los pares sin relación no tienen conector.
static func links(layout, peers):
	var out = []
	if typeof(layout) != TYPE_DICTIONARY or typeof(peers) != TYPE_ARRAY or peers.empty():
		return out
	var center = Vector2(layout.get("center", Vector2.ZERO))
	var csize = float(layout.get("center_size", CENTER_SIZE))
	for n in layout.get("nodes", []):
		if String(n.get("kind", KIND_HOST)) != KIND_HOST:
			continue
		var p = _link_peer(n, peers)
		if p == null:
			continue
		var c = Vector2(n.center)
		var d = c - center
		var dist = d.length()
		var r = float(n.get("size", NODE_SIZE)) * 0.5
		if dist <= csize * 0.5 + r + 4.0:
			continue
		var dir = d / dist
		var a = center + dir * (csize * 0.5)
		var b = c - dir * r
		out.append({"id": String(n.id), "a": a, "b": b, "mid": (a + b) * 0.5,
			"screen": bool(p.get("screen", false)), "input": bool(p.get("input", false)),
			"direction": String(p.get("direction", "none")),
			"state": String(p.get("state", "active"))})
	return out


static func _link_peer(node, peers):
	var id = String(node.get("id", ""))
	var nm = _norm(node.get("name", ""))
	for p in peers:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		if (id != "" and String(p.get("key", "")) == id) \
				or (nm != "" and _norm(p.get("peer_name", "")) == nm):
			return p
	return null


# Tipo de ícono de un dispositivo Bluetooth a partir del campo Icon de bluetoothctl.
static func bt_kind(icon):
	var k = String(icon).strip_edges().to_lower()
	if k.begins_with("audio"):
		return "audio"
	if k.begins_with("input"):
		return "input"
	if k.begins_with("phone"):
		return "phone"
	if k.begins_with("computer"):
		return "computer"
	return "other"


# --- Interno ------------------------------------------------------------------

static func _new_member(id, kind):
	return {
		"id": String(id),
		"name": "",
		"online": false,
		"direction": "",
		"along": -1.0,
		"kind": String(kind) if String(kind) != "" else KIND_HOST,
		"bt_kind": "",
		"rssi": 0,
		"connected": false,
		"host": {},
	}


static func _index_hosts(live_hosts):
	var by_hid = {}
	var by_name = {}
	if typeof(live_hosts) == TYPE_ARRAY:
		for h in live_hosts:
			if typeof(h) != TYPE_DICTIONARY:
				continue
			var hid = _host_hid(h)
			if hid != "" and not by_hid.has(hid):
				by_hid[hid] = h
			var nm = _norm(_host_name(h))
			if nm != "" and not by_name.has(nm):
				by_name[nm] = h
	return {"by_hid": by_hid, "by_name": by_name}


static func _match_host(hid, name, idx):
	var key = String(hid).strip_edges()
	if key != "" and idx.by_hid.has(key):
		return idx.by_hid[key]
	var nk = _norm(name)
	if nk != "" and idx.by_name.has(nk):
		return idx.by_name[nk]
	return null


static func _apply_host(m, host):
	if typeof(host) != TYPE_DICTIONARY:
		return
	m.online = true
	m.host = host
	m.kind = KIND_HOST
	var nm = _host_name(host)
	if nm != "":
		m.name = nm


static func _merge_into(target, src):
	# La persistencia antigua podía guardar la misma máquina como hostname y como
	# HID. Al fusionarlas, la identidad opaca estable debe ganar.
	if _opaque_hid(String(src.get("id", ""))) and not _opaque_hid(String(target.get("id", ""))):
		target.id = src.id
	target.online = target.online or src.online
	if target.host.empty() and not src.host.empty():
		target.host = src.host
	if src.name != "" and (target.name == "" or target.name == target.id):
		target.name = src.name
	if target.direction == "" and src.direction != "":
		target.direction = src.direction
		target.along = src.along


static func _opaque_hid(value):
	var s = String(value).strip_edges().to_lower()
	if s.length() < 16:
		return false
	for i in range(s.length()):
		if "0123456789abcdef".find(s[i]) < 0:
			return false
	return true


static func _host_hid(h):
	if typeof(h) != TYPE_DICTIONARY:
		return ""
	var hid = String(h.get("hid", "")).strip_edges()
	if hid != "":
		return hid
	return String(h.get("id", "")).strip_edges()


static func _host_name(h):
	if typeof(h) != TYPE_DICTIONARY:
		return ""
	var nm = String(h.get("label", "")).strip_edges()
	if nm != "":
		return nm
	return _host_hid(h)


static func _screen_name(s):
	var nm = String(s.get("label", "")).strip_edges()
	if nm != "":
		return nm
	nm = String(s.get("peer", "")).strip_edges()
	if nm != "":
		return nm
	return String(s.get("id", "")).strip_edges()


static func _bt_name(d, addr):
	var nm = String(d.get("name", "")).strip_edges()
	return nm if nm != "" else String(addr)


# Posición 0..1 a lo largo del lado, o -1 si falta/está fuera de rango.
static func _along(v):
	var t = typeof(v)
	if (t == TYPE_REAL or t == TYPE_INT) and float(v) >= 0.0 and float(v) <= 1.0:
		return float(v)
	return -1.0


static func _norm(s):
	return String(s).strip_edges().to_lower()


static func _rank(m):
	if String(m.get("kind", "")) == KIND_BT:
		return 5
	var d = String(m.get("direction", ""))
	if DIR_RANK.has(d):
		return int(DIR_RANK[d])
	return 4


static func _member_less(a, b):
	var ra = _rank(a)
	var rb = _rank(b)
	if ra != rb:
		return ra < rb
	var la = _norm(a.get("name", ""))
	var lb = _norm(b.get("name", ""))
	if la != lb:
		return la < lb
	return String(a.get("id", "")) < String(b.get("id", ""))


static func _sort_members(arr):
	var i = 1
	while i < arr.size():
		var cur = arr[i]
		var j = i - 1
		while j >= 0 and _member_less(cur, arr[j]):
			arr[j + 1] = arr[j]
			j -= 1
		arr[j + 1] = cur
		i += 1
