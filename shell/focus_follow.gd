extends Reference

# Lazy focus follows mouse (Feature Tiles). Decisión PURA de a quién enfocar
# cuando el puntero se mueve sobre la vista de ventanas.
#
# "Lazy" = la política sólo se evalúa con movimiento real del puntero
# (InputEventMouseMotion): una ventana que aparece bajo un cursor quieto no roba
# el foco por sí sola. El shell ejecuta el efecto (compositor.focus / _focus_tile);
# acá sólo vive la decisión, sin compositor ni shell, para poder testearla.
#
# Reglas:
#  - Sin ventana bajo el puntero: no cambia nada.
#  - Con un diálogo transitorio debajo: se enfoca el diálogo si no es el ya
#    enfocado; no se toca el tile de fondo.
#  - Misma ventana ya enfocada: no cambia nada (no se reenfoca sola); salvo que se
#    venga de un diálogo, caso en que se devuelve el foco al tile raíz.
#  - Ventana minimizada: pasar el mouse no la restaura.

# Devuelve {"target": id, "dialog": id_o_0}. `target` < 0 = no cambiar el foco.
static func decide(focused_tile, focused_dialog, hit_id, hit_dialog = 0, hit_minimized = false):
	var id = int(hit_id)
	if id < 0:
		return {"target": -1, "dialog": 0}
	var dlg = int(hit_dialog)
	if dlg > 0:
		if dlg == int(focused_dialog):
			return {"target": -1, "dialog": 0}
		return {"target": id, "dialog": dlg}
	if bool(hit_minimized):
		return {"target": -1, "dialog": 0}
	if id == int(focused_tile):
		# Volver al tile raíz tras estar sobre un diálogo cierra ese estado.
		if int(focused_dialog) != 0:
			return {"target": id, "dialog": 0}
		return {"target": -1, "dialog": 0}
	return {"target": id, "dialog": 0}


# Dwell del foco por hover: el cambio sólo se aplica si el puntero permaneció
# HOVER_DWELL_MS sobre el mismo objetivo. `pend` es el estado previo ({} al inicio);
# devuelve {"key", "since", "ready"} para pasar como `pend` en la próxima llamada.
const HOVER_DWELL_MS = 250


static func dwell(pend, key, now_ms):
	var since = int(pend.since) if pend.has("since") and pend.key == key else int(now_ms)
	return {"key": key, "since": since, "ready": int(now_ms) - since >= HOVER_DWELL_MS}
