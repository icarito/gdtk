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

var cpu = []          # % de CPU por muestra, la más nueva al final
var ram = 0.0         # % de RAM en uso (MemTotal - MemAvailable)
var swap = 0.0        # % de swap en uso (SwapTotal - SwapFree)
var has_cpu = false   # hubo al menos una muestra de /proc/stat
var has_ram = false   # /proc/meminfo trajo MemTotal
var has_swap = false  # hay swap configurada (SwapTotal > 0)
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
	return true


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
