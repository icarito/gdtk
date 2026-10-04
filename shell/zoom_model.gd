extends Reference

# G1 — Modelo puro del zoom Sugar de 3 niveles.
#
# Hogar(0) -> Grupo(1) -> Vecindario(2). El nivel se anima como un float continuo
# `level_f` (0..2); el ícono central del equipo es el ancla visible: se achica al
# alejarse (1.0 -> 0.6 -> 0.35) y cada capa entra/sale con su propia escala/alfa.
#
# Sin estado, sin I/O, sin nodos: sólo matemática (SPEC-sugar-group-2026-10, G1).

const HOME = 0
const GROUP = 1
const NEIGHBORHOOD = 2

# Escalas del ícono central por nivel.
const CENTER_HOME = 1.0
const CENTER_GROUP = 0.6
const CENTER_NEIGHBORHOOD = 0.35
# Escala de la capa entrante (viene "desde afuera") y de la saliente (se encoge).
const LAYER_IN_SCALE = 1.4
const LAYER_OUT_SCALE = 0.72


# Ease-out cúbico (sin overshoot), el mismo lenguaje que el anillo del Hogar.
static func ease_out(t):
	t = clamp(float(t), 0.0, 1.0)
	return 1.0 - pow(1.0 - t, 3.0)


# Escala del ícono central para un nivel animado continuo.
static func center_icon_scale(level_f):
	level_f = clamp(float(level_f), 0.0, 2.0)
	if level_f <= 1.0:
		return lerp(CENTER_HOME, CENTER_GROUP, ease_out(level_f))
	return lerp(CENTER_GROUP, CENTER_NEIGHBORHOOD, ease_out(level_f - 1.0))


# Rect del ícono central, centrado en vp/2, con `base_size` como lado de referencia
# (el mismo tamaño del ícono a nivel Hogar).
static func center_icon_rect(level_f, vp, base_size):
	var s = float(base_size) * center_icon_scale(level_f)
	var size = Vector2(s, s)
	var center = Vector2(vp) * 0.5
	return Rect2(center - size * 0.5, size)


# Transformación de una capa dado el nivel animado. Devuelve {"scale", "alpha"}:
# - alpha 1 en su propio nivel y 0 a distancia >= 1;
# - las capas por debajo del nivel actual (salientes al alejarse) se encogen hacia
#   LAYER_OUT_SCALE; las que están por encima (entrantes) vienen desde LAYER_IN_SCALE
#   hacia 1.0.
static func layer_transform(layer_level, level_f):
	var level = float(layer_level)
	var d = clamp(float(level_f), 0.0, 2.0) - level
	var alpha = clamp(1.0 - abs(d), 0.0, 1.0)
	var scale = 1.0
	if d >= 0.0:
		scale = lerp(1.0, LAYER_OUT_SCALE, ease_out(clamp(d, 0.0, 1.0)))
	else:
		scale = lerp(LAYER_IN_SCALE, 1.0, ease_out(clamp(1.0 + d, 0.0, 1.0)))
	return {"scale": scale, "alpha": alpha}


# Siguiente nivel al mover la rueda/pinch: acercar (+1) o alejar (-1), tope 0..2.
static func step(level, delta):
	return int(clamp(float(level) + float(delta), 0.0, 2.0))
