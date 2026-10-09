extends SceneTree

# Bus de notificaciones: modelo puro (orden, cap, replaces_id, expiración, store) y
# selftest embebido. No instancia el worker ni toca $XDG_RUNTIME_DIR.
# Correr: godot --no-window --path shell -s $PWD/tests/notify_model_test.gd

var fails = 0


func check(cond, msg):
	if cond:
		print("ok ", msg)
	else:
		fails += 1
		printerr("FAIL ", msg)


func _init():
	var N = load("res://notify.gd")
	check(N != null, "notify.gd carga")
	if N == null:
		OS.exit_code = 1
		quit()
		return

	# Orden más nuevo primero + cap.
	var a = N.apply_push([], {"id": 1, "summary": "uno"}, 2)
	a = N.apply_push(a, {"id": 2, "summary": "dos"}, 2)
	a = N.apply_push(a, {"id": 3, "summary": "tres"}, 2)
	check(a.size() == 2 and int(a[0].id) == 3 and int(a[1].id) == 2, "orden y cap")

	# replaces_id reemplaza y sube al frente conservando el id.
	var r = N.apply_push(a, {"replaces_id": 2, "summary": "dos nuevo"}, 2)
	check(int(r[0].id) == 2 and r[0].summary == "dos nuevo", "replaces_id reemplaza")

	# Id autogenerado.
	var n = N.apply_push([], {"summary": "sin id"}, 5)
	check(int(n[0].id) == 1, "id autogenerado")
	check(int(N.apply_push(n, {"summary": "otro"}, 5)[0].id) == 2, "id siguiente")

	# dismiss.
	check(N.apply_dismiss([{"id": 1}, {"id": 2}], 1).size() == 1, "dismiss")

	# expiración.
	var items = [{"id": 1, "expires_ms": 0}, {"id": 2, "expires_ms": 1500}]
	check(N.prune_expired(items, 1000).size() == 2, "sin vencer")
	check(N.prune_expired(items, 1600).size() == 1, "vence por expires_ms")

	# store round-trip + corrupto.
	var doc = N.parse_store(N.serialize_store(7, items))
	check(int(doc.revision) == 7 and doc.items.size() == 2, "store round-trip")
	check(N.parse_store("basura").items.empty(), "store corrupto")

	# urgencia inválida normalizada.
	check(N.normalize_record({"urgency": "URGENTE"}).urgency == "normal", "urgencia inválida")

	# atención y urgencia expiran (puro).
	var att = {5: {"hasta_ms": 2000, "texto": "x"}}
	check(N.prune_attention(att, 1000).size() == 1, "atención vigente")
	check(N.prune_attention(att, 3000).empty(), "atención vencida")
	var urg = {"termico": {"severidad": "critical", "hasta_ms": 2000, "texto": "t"}}
	check(not N.urgency_for_(urg, "termico", 1000).empty(), "urgencia vigente")
	check(N.urgency_for_(urg, "termico", 3000).empty(), "urgencia vencida")

	# selftest embebido del módulo (debe pasar sin excepciones).
	N.selftest()
	check(true, "notify selftest")

	OS.exit_code = 1 if fails > 0 else 0
	quit()
