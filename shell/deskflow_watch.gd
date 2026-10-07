extends Reference

# Vigía del servidor Deskflow (puro): ¿el puntero quedó "en" un equipo que ya no está?
# Lee la cola del log del servidor: el último `switch from "A" to "B"` fija el destino;
# si después de eso aparece que B se desconectó / venció / murió, la captura local debe
# soltarse (Deskflow a veces no pide Release y el puntero quedaba atrapado).


# Devuelve el nombre del equipo destino caído, o "" si no hay nada que soltar.
static func stuck_on(log_text, local_name):
	var dest = ""
	var gone = false
	for line in String(log_text).split("\n"):
		var sw = line.find("switch from \"")
		if sw >= 0:
			var to = line.find("\" to \"", sw)
			if to >= 0:
				var end = line.find("\"", to + 6)
				if end > to + 6:
					dest = line.substr(to + 6, end - (to + 6))
					gone = false
			continue
		if dest == "" or dest == String(local_name):
			continue
		if line.find("client \"" + dest + "\"") >= 0 and (line.find("disconnected") >= 0 \
				or line.find("timed out") >= 0 or line.find("is dead") >= 0):
			gone = true
	if gone:
		return dest
	return ""


# ¿El servidor cree que el puntero está en la pantalla local? Sólo si el ÚLTIMO
# `switch from "A" to "B"` de la cola va al local. Sin ninguna línea `switch` en la
# ventana (p.ej. el log creció y el switch salió del tail mientras se escribe en el
# remoto) NO se concluye: antes se asumía local y eso soltaba la captura en pleno uso.
static func server_local(log_text, local_name):
	var dest = ""
	for line in String(log_text).split("\n"):
		var sw = line.find("switch from \"")
		if sw < 0:
			continue
		var to = line.find("\" to \"", sw)
		var end = line.find("\"", to + 6) if to >= 0 else -1
		if end > to + 6:
			dest = line.substr(to + 6, end - (to + 6))
	return dest != "" and dest == String(local_name)
