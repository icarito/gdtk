extends Reference

# Widgets del Frame: gráfica de CPU y diales de RAM/swap del sistema (no del shell), de /proc.
# Sólo se muestrea mientras el Frame está visible (frame.gd llama a tick); sin Frame, nada.
# Nota: los anillos se dibujan con polilíneas cerradas (no imgui_draw_circle): en el GPU
# viejo de tengu AddCircle dejaba de rasterizar todos los rellenos del Frame.

const PERIOD_MS = 1000
const HISTORY = 40
const CPU_W = 96.0      # ancho de la gráfica de CPU
const R = 12.0          # radio de los diales
const GAUGE_W = 74.0    # dial + etiqueta
const W = CPU_W + GAUGE_W * 2.0 + 10.0
# Governor de CPU: se lee siempre; se escribe sólo por acción explícita del usuario.
const GOV_PATH = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
const GOV_AVAIL = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"
const Gov = preload("res://governor_control.gd")
const APPLY_TIMEOUT_MS = 8000  # ventana para que sysfs refleje el cambio antes de error

var cpu = []          # % de CPU por muestra, la más nueva al final
var ram = 0.0         # % de RAM en uso (MemTotal - MemAvailable)
var swap = 0.0        # % de swap en uso (SwapTotal - SwapFree)
var has_cpu = false   # hubo al menos una muestra de /proc/stat
var has_ram = false   # /proc/meminfo trajo MemTotal
var has_swap = false  # hay swap configurada (SwapTotal > 0)
var temp_c = -1.0     # temperatura de CPU en °C (-1 = sin dato)
var has_temp = false  # se leyó alguna zona térmica
var temp_label = ""   # zona elegida (informativa; no se muestra como jerga)
var governor = ""     # governor de cpu0 (schedutil, performance, …)
var has_governor = false
var governor_initial = ""  # governor al arrancar la sesión ("predeterminado")
var governor_state = "idle"    # máquina de estados visible (governor_control.gd)
var governor_reason = ""       # diagnóstico corto del último cambio (sin secretos)
var governor_requested = ""    # governor pedido mientras se espera verificación
var governor_deadline_ms = 0   # límite de la ventana applying
var battery_pct = -1.0     # carga de la batería principal (-1 = sin batería)
var battery_status = ""    # Charging / Discharging / Full / Not charging
var has_battery = false
var last_ms = -PERIOD_MS
var prev_total = 0
var prev_idle = 0


# Devuelve true si tomó una muestra nueva (hay algo que redibujar).
func tick():
	var now = OS.get_ticks_msec()
	if now - last_ms < PERIOD_MS:
		return false
	last_ms = now
	var f = File.new()
	if f.open("/proc/stat", File.READ) == OK:
		var v = f.get_line().split(" ", false)  # cpu user nice system idle iowait irq softirq steal
		f.close()
		var total = 0
		for i in range(1, min(v.size(), 9)):
			total += int(v[i])
		var idle = int(v[4]) + int(v[5])
		if prev_total > 0 and total > prev_total:
			cpu.append(100.0 * (1.0 - float(idle - prev_idle) / float(total - prev_total)))
			has_cpu = true
			if cpu.size() > HISTORY:
				cpu.pop_front()
		prev_total = total
		prev_idle = idle
	if f.open("/proc/meminfo", File.READ) == OK:
		var info = {}
		while not f.eof_reached():
			var kv = f.get_line().split(":")
			if kv.size() == 2:
				info[kv[0]] = int(kv[1])
		f.close()
		if info.get("MemTotal", 0) > 0:
			ram = 100.0 * (1.0 - float(info.get("MemAvailable", 0)) / float(info.MemTotal))
			has_ram = true
		if info.get("SwapTotal", 0) > 0:
			swap = 100.0 * (1.0 - float(info.get("SwapFree", 0)) / float(info.SwapTotal))
			has_swap = true
		else:
			swap = 0.0
			has_swap = false
	_sample_thermal()
	_sample_battery()
	return true


# Temperatura de CPU y governor. Prefiere las zonas térmicas de paquete/CPU; si no
# hay, usa la más caliente de cualquier zona. Lee archivos chicos de sysfs a 1 Hz
# (mismo periodo que el resto del muestreo); nunca desde _draw.
func _sample_thermal():
	governor = ""
	has_governor = false
	var f = File.new()
	if f.open(GOV_PATH, File.READ) == OK:
		governor = f.get_line().strip_edges()
		f.close()
		has_governor = governor != ""
		if governor_initial == "":
			governor_initial = governor  # "predeterminado" de la sesión
	# El muestreo, no la UI, resuelve el cambio pedido: verified si sysfs ya lo
	# refleja; error si venció la ventana sin lograrlo.
	if governor_state == Gov.STATE_APPLYING:
		governor_state = Gov.observe_result(governor_state, governor_requested, governor, OS.get_ticks_msec(), governor_deadline_ms)
		if governor_state == Gov.STATE_VERIFIED:
			governor_requested = ""
			governor_reason = ""
		elif governor_state == Gov.STATE_ERROR:
			governor_reason = "timeout"
	var cpu_t = -1.0
	var any_t = -1.0
	var cpu_label = ""
	var d = Directory.new()
	if d.open("/sys/class/thermal") == OK:
		d.list_dir_begin(true, true)
		var n = d.get_next()
		while n != "":
			if n.begins_with("thermal_zone"):
				var base = "/sys/class/thermal/" + n
				var t = _read_float(base + "/temp")
				if t > 0.0:
					if t > 1000.0:
						t = t / 1000.0  # mili-grados a °C
					var typ = _read_text(base + "/type").to_lower()
					if typ.find("pkg") >= 0 or typ.find("cpu") >= 0 or typ.find("x86") >= 0:
						if t > cpu_t:
							cpu_t = t
							cpu_label = typ
					if t > any_t:
						any_t = t
			n = d.get_next()
		d.list_dir_end()
	temp_c = cpu_t if cpu_t >= 0.0 else any_t
	temp_label = cpu_label
	has_temp = temp_c >= 0.0


# Lee una línea de sysfs. sysfs reporta tamaño 0, así que get_as_text() devuelve "";
# get_line() sí trae el valor (temp/type/governor).
func _read_text(path):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var s = f.get_line().strip_edges()
	f.close()
	return s


func _read_float(path):
	var s = _read_text(path)
	return float(s) if s != "" else -1.0


# Batería principal: capacidad (%) y estado (Charging/Discharging/Full/…). Sin
# batería, todo queda en -1/"" y los widgets no la muestran.
func _sample_battery():
	has_battery = false
	battery_pct = -1.0
	battery_status = ""
	var d = Directory.new()
	if d.open("/sys/class/power_supply") != OK:
		return
	d.list_dir_begin(true, true)
	var n = d.get_next()
	while n != "":
		var base = "/sys/class/power_supply/" + n
		if _read_text(base + "/type").to_lower() == "battery":
			var cap = _read_float(base + "/capacity")
			if cap >= 0.0:
				battery_pct = cap
				battery_status = _read_text(base + "/status")
				has_battery = true
				break
		n = d.get_next()
	d.list_dir_end()


func battery_charging():
	var s = battery_status.to_lower()
	return s == "charging" or s == "full"


# Governor "predeterminado": el que estaba activo al arrancar la sesión; si no se
# pudo capturar, el primero que ofrezca el kernel.
func governor_default():
	if governor_initial != "":
		return governor_initial
	var g = governors()
	return g[0] if not g.empty() else ""


# Governors que ofrece el equipo (lista del kernel, en orden). Sin caché: se lee
# sólo cuando el usuario interactúa, no en cada tick.
func governors():
	var s = _read_text(GOV_AVAIL)
	if s == "":
		return []
	var out = []
	for g in s.split(" ", false):
		if String(g) != "":
			out.append(String(g))
	return out


# Aplica un governor. Valida token y lista del kernel y, si sysfs no es escribible
# directo, delega en el helper root vía pkexec --disable-internal-agent (sin agente
# textual y sin bloquear el frame). No afirma éxito: marca `applying` y el muestreo
# normal resuelve verified/error. Devuelve true si el pedido quedó en curso.
func set_governor(gov):
	var name = String(gov).strip_edges()
	var avail = governors()
	var v = Gov.validate_request(name, avail)
	if not v.ok:
		governor_state = v.state
		governor_reason = v.reason
		governor_requested = ""
		return false
	var f = File.new()
	if f.open(GOV_PATH, File.WRITE) == OK:
		f.store_line(name)
		f.close()
		_mark_applying(name)
		return true
	# Sin permiso directo: helper instalado + action polkit. pkexec no valida
	# argumentos; el modelo ya validó el token y el helper los revalida.
	var plan = Gov.plan_apply(name, avail,
		File.new().file_exists(Gov.HELPER_PATH),
		File.new().file_exists(Gov.POLICY_PATH),
		File.new().file_exists(Gov.PKEXEC_PATH))
	if plan.state != Gov.STATE_APPLYING:
		governor_state = plan.state
		governor_reason = plan.reason
		governor_requested = ""
		return false
	OS.execute(plan.program, plan.argv, false)
	_mark_applying(name)
	return true


func _mark_applying(name):
	governor_state = Gov.STATE_APPLYING
	governor_requested = String(name)
	governor_reason = ""
	governor_deadline_ms = OS.get_ticks_msec() + APPLY_TIMEOUT_MS


func _cpu_now():
	return cpu[cpu.size() - 1] if cpu.size() > 0 else 0.0


# Valor de CPU actual (público para los applets del Frame).
func cpu_now():
	return _cpu_now()


# Gráfica de CPU + diales de MEM y SWP, a partir de la posición (coords de la ventana ImGui).
func draw(ui, pos, h):
	_cpu_graph(ui, pos, h)
	_gauge(ui, Vector2(pos.x + CPU_W, pos.y), h, ram, Color(0.5, 0.9, 0.45, 0.95), "MEM")
	_gauge(ui, Vector2(pos.x + CPU_W + GAUGE_W, pos.y), h, swap, Color(0.95, 0.7, 0.3, 0.95), "SWP")


# Historial de CPU: dos textos primero (como el original), después fondo y línea.
func _cpu_graph(ui, pos, h):
	ui.set_cursor_pos(pos + Vector2(4.0, 0.0))
	ui.text_disabled("CPU")
	ui.set_cursor_pos(pos + Vector2(4.0, 14.0))
	ui.text("%d%%" % int(round(_cpu_now())))
	ui.set_cursor_pos(pos)
	var o = ui.get_cursor_screen_pos()
	ui.imgui_draw_rect_filled(Rect2(o, Vector2(CPU_W, h)), Color(1, 1, 1, 0.06), 3.0)
	if cpu.size() > 1:
		var pts = PoolVector2Array()
		for i in range(cpu.size()):
			var x = o.x + CPU_W * float(i + HISTORY - cpu.size()) / float(HISTORY - 1)
			pts.append(Vector2(x, o.y + h - h * clamp(cpu[i], 0.0, 100.0) / 100.0))
		ui.imgui_draw_polyline(pts, Color(0.35, 0.8, 1.0, 0.95), 1.5)


# Un dial: anillo de fondo (polilínea cerrada), arco proporcional al % y etiqueta + valor.
func _gauge(ui, pos, h, pct, color, label):
	var f = clamp(pct / 100.0, 0.0, 1.0)
	ui.set_cursor_pos(pos)
	var o = ui.get_cursor_screen_pos()
	var center = o + Vector2(R, h * 0.5)
	var ring = PoolVector2Array()
	for i in range(33):
		var a = TAU * float(i) / 32.0
		ring.append(center + Vector2(cos(a), sin(a)) * R)
	ui.imgui_draw_polyline(ring, Color(1, 1, 1, 0.14), 2.0, true)
	if f > 0.003:
		var seg = int(max(2.0, ceil(64.0 * f)))
		var pts = PoolVector2Array()
		for i in range(seg + 1):
			var a = -PI * 0.5 + TAU * f * float(i) / float(seg)
			pts.append(center + Vector2(cos(a), sin(a)) * R)
		ui.imgui_draw_polyline(pts, color, 2.5)
	ui.set_cursor_pos(pos + Vector2(R * 2.0 + 6.0, 1.0))
	ui.text_disabled(label)
	ui.set_cursor_pos(pos + Vector2(R * 2.0 + 6.0, 15.0))
	ui.text("%d%%" % int(round(pct)))
