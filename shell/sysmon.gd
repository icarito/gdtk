extends Reference

# Widget del Frame: % de RAM y gráfica de CPU del sistema (no del shell), de /proc.
# Sólo se muestrea mientras el Frame está visible (frame.gd llama a tick); sin Frame, nada.

const PERIOD_MS = 1000
const HISTORY = 40
const W = 150.0

var cpu = []          # % de CPU por muestra, la más nueva al final
var ram = 0.0         # % de RAM en uso (MemTotal - MemAvailable)
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
	return true


# Dibuja en la posición actual del cursor de ImGui: "RAM 42%" y la gráfica de CPU al lado.
func draw(ui, pos, h):
	ui.set_cursor_pos(pos + Vector2(0.0, 5.0))
	ui.text("RAM %d%%" % int(round(ram)))
	var gx = 64.0
	var gw = W - gx
	ui.set_cursor_pos(pos + Vector2(gx, 0.0))
	var o = ui.get_cursor_screen_pos()
	ui.imgui_draw_rect_filled(Rect2(o, Vector2(gw, h)), Color(1, 1, 1, 0.06), 3.0)
	if cpu.size() > 1:
		var pts = PoolVector2Array()
		for i in range(cpu.size()):
			var x = o.x + gw * float(i + HISTORY - cpu.size()) / float(HISTORY - 1)
			pts.append(Vector2(x, o.y + h - h * clamp(cpu[i], 0.0, 100.0) / 100.0))
		ui.imgui_draw_polyline(pts, Color(0.35, 0.8, 1.0, 0.9), 1.5)
	if cpu.size() > 0:
		ui.set_cursor_pos(pos + Vector2(gx + 4.0, 5.0))
		ui.text_disabled("CPU %d%%" % int(round(cpu[cpu.size() - 1])))
