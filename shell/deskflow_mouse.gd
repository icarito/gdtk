extends Reference

# Multiplicador global de velocidad del puntero (puro). Deskflow 1.27 no tiene
# velocidad por cliente: sólo la env `DESKFLOW_MOUSE_ADJUSTMENT` que lee el proceso
# SERVIDOR. Acá se arma su texto clampeado a 0.1..10.0; 1.0 = sin cambio (se envía
# igual: es un valor válido y evita el ruido de log de un valor vacío).
#
# Va por Host.sc (no `const preload`) en el shell: un preload cacheado no tomaba el
# método nuevo en una recarga transaccional (mismo motivo que deskflow_presence.gd).


static func adjust_text(scale):
	var v = clamp(float(scale), 0.1, 10.0)
	var t = String(v)
	if t.find(".") < 0:
		t += ".0"
	return t


static func selftest():
	assert(adjust_text(1.5) == "1.5", "1.5")
	assert(adjust_text(1.0) == "1.0", "1.0")
	assert(adjust_text(0.01) == "0.1", "clampa bajo")
	assert(adjust_text(99.0) == "10.0", "clampa alto")
	assert(adjust_text("2.5") == "2.5", "texto numerico")
	assert(adjust_text("x") == "0.1", "basura cae al minimo del clamp")
	return true


func run_selftest():
	return selftest()
