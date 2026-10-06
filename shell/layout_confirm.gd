extends Reference

# Modelo PURO de la ventana de revisión del layout (SPEC-sugar-group-2026-10,
# popup de Distribución en Grupo). Al mover un equipo el layout YA se aplicó; el
# popup deja una cola de 10 s en la que se puede Aceptar (default: botón, clic
# afuera, Esc o countdown vencido), Editar (Configuración > Pantallas) o
# Revertir (vuelve el layout previo). Sin I/O, sin procesos y sin relojes: el
# shell aporta `now` en ms y ejecuta las acciones.

const DEFAULT_TIMEOUT_MS = 10000.0

var open = false
var baseline = {}        # layout previo (dicts de screen_layout) para Revertir
var deadline_ms = 0.0    # vence el countdown: Aceptar

# Nueva (o re-)propuesta. Si la revisión ya estaba abierta, la línea base SIEMPRE
# es la primera de la racha — Revertir deshace el acomodo completo — y el
# countdown se rearma para el nuevo acomodo.
func propose(baseline_layout, now_ms, timeout_ms = DEFAULT_TIMEOUT_MS):
	if not open:
		baseline = baseline_layout
	deadline_ms = float(now_ms) + max(1.0, float(timeout_ms))
	open = true
	return self


func remaining_ms(now_ms):
	if not open:
		return 0.0
	return max(0.0, deadline_ms - float(now_ms))


func seconds_left(now_ms):
	if not open:
		return 0
	return int(ceil(remaining_ms(now_ms) / 1000.0))


# Cada frame mientras la revisión vive. "accept" cuando el countdown vence
# (default aceptar); "" en cualquier otro caso.
func tick(now_ms):
	if not open:
		return ""
	if float(now_ms) >= deadline_ms:
		open = false
		return "accept"
	return ""


func accept():
	return _close("accept")


func revert():
	return _close("revert")


# Clic afuera o cierre por el compositor de popups: sin decisión explícita.
func dismissed():
	return _close("accept")


func _close(action):
	var had = open
	open = false
	return action if had else ""
