extends Reference

# Modelo puro del estado de servicios del shell: parser de pgrep, filtro de pids
# ajenos y merge del snapshot cacheado. Sin I/O, Threads ni nodos.


static func parse_pgrep_pids(text):
	var pids = []
	for raw in String(text).split("\n", false):
		var line = raw.strip_edges()
		if line == "" or not line.is_valid_integer():
			continue
		var pid = int(line)
		if pid > 0:
			pids.append(pid)
	return pids


static func stray_deskflow_pids(measured, own_pids):
	var own = {}
	for p in own_pids:
		own[int(p)] = true
	var out = []
	for p in measured:
		var pid = int(p)
		if pid > 0 and not own.has(pid):
			out.append(pid)
	return out


static func merge_service_snapshot(observed, prev, now_ms, launch_until, stop_until):
	var snap = {}
	for name in observed:
		var measured = observed[name]
		var old = prev.get(name, null)
		var old_running = old != null and old.running
		var old_pids = old.pids if old != null else []
		var running = false
		var pids = []
		if not measured.empty():
			if now_ms < int(stop_until.get(name, 0)):
				running = false
				pids = []
			else:
				running = true
				pids = measured
		elif old_running and now_ms < int(launch_until.get(name, 0)):
			running = true
			pids = old_pids
		snap[name] = {"running": running, "pids": pids}
	return snap


static func snapshot_equal(a, b):
	if a.size() != b.size():
		return false
	for name in a:
		if not b.has(name):
			return false
		var ea = a[name]
		var eb = b[name]
		if bool(ea.running) != bool(eb.running) or ea.pids.size() != eb.pids.size():
			return false
		for i in range(ea.pids.size()):
			if int(ea.pids[i]) != int(eb.pids[i]):
				return false
	return true
