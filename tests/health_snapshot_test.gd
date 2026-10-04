extends SceneTree

# Prueba pura del productor de heartbeat (shell/health_snapshot.gd): construcción
# del snapshot, defaults seguros, rate-limit y path XDG. No escribe archivos, no
# instancia Host ni compositor, no toca la sesión real.
#   <binario dev> --no-window --path shell -s $PWD/tests/health_snapshot_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var Model = load("res://health_snapshot.gd")
	check("health_snapshot.gd compila", Model != null)
	if Model == null:
		OS.exit_code = 1
		quit()
		return

	var m = Model.new()

	# --- defaults seguros durante arranque -------------------------------
	var f = m.fields({})
	check("status vacío -> generation 0", int(f.generation) == 0)
	check("status vacío -> reload idle", String(f.reload) == "idle")
	f = m.fields(null)
	check("status null -> defaults", int(f.generation) == 0 and String(f.reload) == "idle")
	f = m.fields({"generation": 7, "state": "ready"})
	check("state ready -> generation 7", int(f.generation) == 7)
	check("state ready -> reload ready", String(f.reload) == "ready")
	f = m.fields({"generation": "x", "state": 3})
	check("tipos inválidos -> defaults",
		int(f.generation) == 0 and String(f.reload) == "idle")
	f = m.fields({"generation": 2, "state": ""})
	check("state vacío -> reload idle", int(f.generation) == 2 and String(f.reload) == "idle")

	# --- snapshot del contrato ------------------------------------------
	var snap = m.build(1234, {"generation": 7, "state": "ready"}, 91, 123456)
	check("snapshot: 5 campos exactos", snap.size() == 5)
	check("snapshot: pid", int(snap.pid) == 1234)
	check("snapshot: generation", int(snap.generation) == 7)
	check("snapshot: sequence", int(snap.sequence) == 91)
	check("snapshot: monotonic_ms", int(snap.monotonic_ms) == 123456)
	check("snapshot: reload", String(snap.reload) == "ready")
	check("snapshot: sin campos extra (sin secretos)",
		snap.has("pid") and snap.has("generation") and snap.has("sequence")
		and snap.has("monotonic_ms") and snap.has("reload"))

	# --- encode JSON reparseable ----------------------------------------
	var text = m.encode(snap)
	var parsed = JSON.parse(text)
	check("encode: JSON válido", parsed.error == OK)
	if parsed.error == OK:
		check("encode: pid reparsado", int(parsed.result.pid) == 1234)
		check("encode: termination newline", text.ends_with("\n"))

	# --- rate-limit / decisión de escritura -----------------------------
	check("primera vez escribe ya", m.should_write(0, 500, 1000))
	check("dentro del intervalo no escribe", not m.should_write(1000, 1500, 1000))
	check("justo en el intervalo escribe", m.should_write(1000, 2000, 1000))
	check("pasado el intervalo escribe", m.should_write(1000, 2500, 1000))
	check("reloj hacia atrás no cuelga", m.should_write(5000, 10, 1000))

	# --- intervalo desde entorno ----------------------------------------
	check("intervalo default vacío", int(m.interval_ms("")) == 1000)
	check("intervalo inválido -> default", int(m.interval_ms("nope")) == 1000)
	check("intervalo 0 -> default", int(m.interval_ms("0")) == 1000)
	check("intervalo 2s -> 2000ms", int(m.interval_ms("2")) == 2000)
	check("intervalo 0.5s -> 500ms", int(m.interval_ms("0.5")) == 500)
	check("intervalo mínimo respetado", int(m.interval_ms("0.001")) >= 50)

	# --- path dentro del XDG heredado -----------------------------------
	check("health_dir", String(m.health_dir("/tmp/iso")) == "/tmp/iso/gdtk")
	check("health_path",
		String(m.health_path("/tmp/iso")) == "/tmp/iso/gdtk/health.json")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
