extends SceneTree

# Prueba del plan de handoff (shell/reload_plan.gd) con un driver falso: verifica
# que un candidato inválido conserva el shell activo y que un swap válido lo
# reemplaza una sola vez, sin levantar el compositor ni tocar Host.
#   godot --no-window --path shell -s $PWD/tests/reload_plan_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


class FakeShell:
	extends Reference
	var revision = 0
	var attached = false
	var freed = false

	func _save_layout():
		revision += 1


class FakeDriver:
	extends Reference
	var calls = []
	var compiled = null
	var candidate = null
	var attach_ok = true
	var live = false
	var staged = []
	var detached = []
	var restored = []
	var disposed = []
	var attached_candidate = null
	var wired = null

	func _handoff_compile():
		calls.append("compile")
		return compiled

	func _handoff_construct(s):
		calls.append("construct")
		return candidate if s != null else null

	func _handoff_stage(active):
		calls.append("stage")
		staged.append(active)

	func _handoff_set_live(v):
		calls.append("live:" + str(v))
		live = v

	func _handoff_detach(active):
		calls.append("detach")
		detached.append(active)

	func _handoff_attach(c):
		calls.append("attach")
		if not attach_ok:
			return false
		attached_candidate = c
		return true

	func _handoff_wire(c):
		calls.append("wire")
		wired = c

	func _handoff_restore(active):
		calls.append("restore")
		restored.append(active)

	func _handoff_dispose(active):
		calls.append("dispose")
		disposed.append(active)


func _init():
	var Plan = load("res://reload_plan.gd")
	check("reload_plan.gd compila", Plan != null)
	if Plan == null:
		OS.exit_code = 1
		quit()
		return

	# --- falla la compilación: conserva el shell activo -------------------
	var plan = Plan.new()
	var d = FakeDriver.new()
	d.compiled = null
	var active = FakeShell.new()
	var ok = plan.run(d, active)
	check("compile falla -> run false", ok == false)
	check("compile falla -> estado failed", String(plan.status().state) == "failed")
	check("compile falla -> generation 1", int(plan.status().generation) == 1)
	check("compile falla -> error visible", String(plan.status().error) != "")
	check("compile falla -> live false", d.live == false)
	check("compile falla -> no toca el activo",
		not d.calls.has("stage") and not d.calls.has("detach")
		and not d.calls.has("attach") and not d.calls.has("dispose")
		and active.revision == 0 and not active.attached and not active.freed)

	# --- falla la instanciación: conserva el shell activo -----------------
	plan = Plan.new()
	d = FakeDriver.new()
	d.compiled = Reference.new()
	d.candidate = null
	active = FakeShell.new()
	ok = plan.run(d, active)
	check("construct falla -> run false", ok == false)
	check("construct falla -> estado failed", String(plan.status().state) == "failed")
	check("construct falla -> error visible", String(plan.status().error) != "")
	check("construct falla -> live false", d.live == false)
	check("construct falla -> no toca el activo",
		not d.calls.has("detach") and not d.calls.has("attach")
		and not d.calls.has("dispose") and not d.calls.has("wire")
		and active.revision == 0)

	# --- swap válido: reemplaza una sola vez y termina listo --------------
	plan = Plan.new()
	d = FakeDriver.new()
	d.compiled = Reference.new()
	var candidate = FakeShell.new()
	d.candidate = candidate
	active = FakeShell.new()
	ok = plan.run(d, active)
	check("swap válido -> run true", ok == true)
	check("swap válido -> estado ready", String(plan.status().state) == "ready")
	check("swap válido -> error vacío", String(plan.status().error) == "")
	check("swap válido -> live false al final", d.live == false)
	check("swap válido -> una sola vez",
		d.calls.count("detach") == 1 and d.calls.count("attach") == 1
		and d.calls.count("dispose") == 1 and d.calls.count("wire") == 1)
	check("swap válido -> orden stage<detach<attach<wire<dispose",
		d.calls.find("stage") < d.calls.find("detach")
		and d.calls.find("detach") < d.calls.find("attach")
		and d.calls.find("attach") < d.calls.find("wire")
		and d.calls.find("wire") < d.calls.find("dispose"))
	check("swap válido -> candidato agregado y cableado",
		d.attached_candidate == candidate and d.wired == candidate)
	check("swap válido -> activo liberado una sola vez", d.disposed == [active])
	check("swap válido -> no restaura el activo", not d.calls.has("restore"))

	# --- falla el attach tras retirar: restaura el activo -----------------
	plan = Plan.new()
	d = FakeDriver.new()
	d.compiled = Reference.new()
	d.candidate = FakeShell.new()
	d.attach_ok = false
	active = FakeShell.new()
	ok = plan.run(d, active)
	check("attach falla -> run false", ok == false)
	check("attach falla -> estado failed", String(plan.status().state) == "failed")
	check("attach falla -> restaura el activo", d.restored == [active])
	check("attach falla -> no libera el activo", d.disposed.empty())
	check("attach falla -> no cablea", not d.calls.has("wire"))
	check("attach falla -> live false", d.live == false)

	# --- generation incrementa en cada intento ----------------------------
	plan = Plan.new()
	d = FakeDriver.new()
	d.compiled = null
	plan.run(d, FakeShell.new())
	check("generation incrementa", int(plan.status().generation) == 1)
	d = FakeDriver.new()
	d.compiled = null
	plan.run(d, FakeShell.new())
	check("generation incrementa de nuevo", int(plan.status().generation) == 2)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
