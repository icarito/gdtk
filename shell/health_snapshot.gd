extends Reference

# Snapshot puro del heartbeat semántico (SPEC-session-continuity C2).
# Construye el diccionario que host.gd escribe de forma atómica y decide cada
# cuánto toca hacerlo. No hace I/O ni toca nodos: sólo deriva datos del estado
# del shell, sin secretos. El path sale del XDG_RUNTIME_DIR heredado, de modo
# que en GDTK_ISOLATED=1 el latido va al runtime temporal (no se desactiva).

const DEFAULT_INTERVAL_MS := 1000
const MIN_INTERVAL_MS := 50
const DEFAULT_GENERATION := 0
const DEFAULT_RELOAD := "idle"
const SUBDIR := "gdtk"
const FILENAME := "health.json"

# GDTK_HEALTH_INTERVAL son segundos (default 1, objetivo 1 Hz). Un valor vacío,
# inválido o <= 0 cae al default; el mínimo evita un bucle de escritura.
func interval_ms(raw = ""):
	var text = String(raw).strip_edges()
	if text == "" or not text.is_valid_float():
		return DEFAULT_INTERVAL_MS
	var secs = float(text)
	if secs <= 0.0:
		return DEFAULT_INTERVAL_MS
	var ms = int(round(secs * 1000.0))
	return ms if ms >= MIN_INTERVAL_MS else MIN_INTERVAL_MS


# Decide si el tick actual corresponde a una escritura. La primera vez (sin
# marca previa) escribe ya; después respeta el intervalo. Sólo el tick del hilo
# principal llama a esto, así un cuelgue deja de avanzar el archivo.
func should_write(last_ms, now_ms, interval):
	if last_ms <= 0:
		return true
	if now_ms < last_ms:
		return true
	return now_ms - last_ms >= interval


# Extrae generation/reload de Host.reload_status con defaults seguros durante el
# arranque (dict vacío o campos ausentes). `reload` es el `state` del handoff;
# `generation`, su contador. Nunca lanza ni inventa estado.
func fields(reload_status):
	var generation = DEFAULT_GENERATION
	var reload = DEFAULT_RELOAD
	if typeof(reload_status) == TYPE_DICTIONARY:
		if reload_status.has("generation"):
			var g = reload_status["generation"]
			if typeof(g) == TYPE_INT or typeof(g) == TYPE_REAL:
				generation = int(g)
		var state = ""
		if reload_status.has("reload"):
			state = reload_status["reload"]
		elif reload_status.has("state"):
			state = reload_status["state"]
		if typeof(state) == TYPE_STRING and String(state) != "":
			reload = String(state)
	return {"generation": generation, "reload": reload}


# Snapshot completo del contrato C2. Sin secretos: sólo estos cinco campos.
func build(pid, reload_status, sequence, monotonic_ms):
	var f = fields(reload_status)
	return {
		"pid": int(pid),
		"generation": int(f.generation),
		"sequence": int(sequence),
		"monotonic_ms": int(monotonic_ms),
		"reload": String(f.reload),
	}


func encode(snapshot):
	return JSON.print(snapshot) + "\n"


# Directorio/archivo del heartbeat dentro del XDG_RUNTIME_DIR heredado.
func health_dir(runtime_dir):
	return String(runtime_dir).plus_file(SUBDIR)


func health_path(runtime_dir):
	return health_dir(runtime_dir).plus_file(FILENAME)
