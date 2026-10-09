extends Reference

# Estado observado del protocolo Deskflow. `jump` también cambia de pantalla;
# una reconexión invalida la caída anterior. Sin evidencia, estado desconocido.
static func observe(log_text, local_name):
	var dest = ""
	var gone = false
	var event = ""
	var connection = "unknown"
	for line in String(log_text).split("\n"):
		if line.find("connected to server") >= 0:
			connection = "connected"
		elif line.find("disconnected from server") >= 0 or line.find("connection failed") >= 0 \
				or line.find("failed to connect") >= 0 or line.find("server is dead") >= 0 \
				or line.find("connecting to '") >= 0:
			connection = "disconnected"
		var sw = line.find("switch from \"")
		if sw < 0:
			sw = line.find("jump from \"")
		if sw >= 0:
			var to = line.find("\" to \"", sw)
			var end = line.find("\"", to + 6) if to >= 0 else -1
			if end > to + 6:
				dest = line.substr(to + 6, end - (to + 6))
				gone = false
				event = line
			continue
		if dest == "" or dest == String(local_name):
			continue
		if line.find("client \"" + dest + "\"") < 0:
			continue
		if line.find("has connected") >= 0:
			gone = false
			event = line
		elif line.find("disconnected") >= 0 or line.find("timed out") >= 0 or line.find("is dead") >= 0:
			gone = true
			event = line
	return {"destination": dest, "gone": gone, "event": event, "connection": connection}


static func stuck_on(log_text, local_name):
	var state = observe(log_text, local_name)
	return state.destination if state.gone else ""


static func server_local(log_text, local_name):
	var dest = observe(log_text, local_name).destination
	return dest != "" and dest == String(local_name)


# mDNS puede cambiar de orden, interfaz o desaparecer un scan. No cortar una
# conexión sana para sustituir su dirección; sólo reparar tras caída confirmada.
static func should_retarget(current, candidate, connection):
	return String(current) != "" and String(candidate) != "" \
		and String(current) != String(candidate) and String(connection) == "disconnected"
