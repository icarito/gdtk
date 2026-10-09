extends SceneTree

# Autoprueba del modelo puro de anclaje de bloques de barra (shell/bar_slots.gd).
# No instancia el Frame ni el shell: sólo arrays/ints.
#   /home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk \
#     --no-window --path shell -s $PWD/tests/bar_slots_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


# Celdas con tokens en los índices dados: lista de `n` celdas.
func cells_at(n, ats):
	var out = []
	for _i in range(n):
		out.append("")
	for k in ats.keys():
		out[int(k)] = ats[k]
	return out


# Ancla {"tok","at"} para un token.
func anchor(tok, at):
	return {"tok": tok, "at": at}


func _init():
	var B = load("res://bar_slots.gd")
	check("bar_slots.gd carga", B != null)

	# --- to_saved: mitades y omisión de huecos --------------------------------
	# n=10: mitad izquierda = celdas 0..4; derecha = 5..9 (offsets -5..-1).
	var cells = cells_at(10, {0: "a", 2: "b", 9: "c"})
	var saved = B.to_saved(cells, 10)
	check("to_saved omite huecos", saved.size() == 3)
	check("to_saved izquierda cuenta desde la izquierda",
		saved[0].tok == "a" and saved[0].at == 0 and saved[1].tok == "b" and saved[1].at == 2)
	check("to_saved ultima celda = -1", saved[2].tok == "c" and saved[2].at == -1)

	# Span: celdas repetidas del mismo token se guardan una sola vez.
	var span = cells_at(8, {0: "a", 1: "a", 3: "b"})
	var span_saved = B.to_saved(span, 8)
	check("to_saved colapsa el span", span_saved.size() == 2 \
		and span_saved[0].tok == "a" and span_saved[1].tok == "b" and span_saved[1].at == 3)

	# Derecha: un bloque en la mitad derecha se guarda como offset negativo.
	var right = B.to_saved(cells_at(8, {0: "a", 5: "d"}), 8)
	check("to_saved mitad derecha = offset desde el borde",
		right[1].tok == "d" and right[1].at == -3)

	# --- roundtrip mismo n -----------------------------------------------------
	check("roundtrip mismo n", B.to_cells(saved, 10) == cells)

	# --- bloque en N-1 pegado a la DERECHA con n mayor y menor -----------------
	var bigger = B.to_cells(saved, 16)
	check("n mayor: a y b quedan a la izquierda",
		bigger[0] == "a" and bigger[2] == "b")
	check("n mayor: c vuelve a la ultima celda", bigger[15] == "c")
	var smaller = B.to_cells(saved, 8)
	check("n menor: c vuelve a la ultima celda", smaller[7] == "c")
	check("n menor: la izquierda no se mueve", smaller[0] == "a" and smaller[2] == "b")

	# Un bloque de la mitad derecha conserva su distancia al borde.
	var r_saved = B.to_saved(cells_at(10, {7: "e"}), 10)   # at = -3
	var r_big = B.to_cells(r_saved, 20)
	check("bloque de la derecha mantiene el offset del borde", r_big[17] == "e")

	# --- colisiones y fuera de rango -------------------------------------------
	# Dos bloques en la misma celda: el que choca va a la libre más cercana hacia el
	# centro. n=10, centro 4.5: desde 3 -> 4.
	var col = B.to_cells([anchor("x", 3), anchor("y", 3)], 10)
	check("colision corre al que choca hacia el centro",
		col[3] == "x" and col[4] == "y")
	# Desde el lado derecho (offset negativo) el choque se corre hacia la izquierda.
	var col2 = B.to_cells([anchor("x", 5), anchor("y", -5)], 10)
	check("colision del lado derecho va a la izquierda", col2[5] == "x" and col2[4] == "y")
	# Fuera de rango a la derecha: se corre hacia el centro si el borde está ocupado.
	var oor = B.to_cells([anchor("a", 9), anchor("z", 12)], 10)
	check("fuera de rango se corre a la libre mas cercana", oor[9] == "a" and oor[8] == "z")
	# Barra llena: no se pierde ningún bloque (se agrega al final).
	var full = B.to_cells([anchor("a", 0), anchor("b", 1), anchor("c", 2)], 2)
	check("barra llena no pierde el bloque", full.size() == 3 and full[2] == "c")

	# --- formato viejo (lista de tokens/"") = celdas desde la izquierda ----------
	var legacy = B.to_cells(["a", "", "b"], 5)
	check("formato viejo conserva las celdas", legacy == ["a", "", "b", "", ""])
	check("formato viejo con huecos a la izquierda", B.to_cells(["", "", "c"], 5) == ["", "", "c", "", ""])
	check("formato viejo fuera de rango se reubica", B.to_cells(["a", "", "b"], 2) == ["a", "b"])

	# --- casos límite -----------------------------------------------------------
	check("sin anclas = todas libres", B.to_cells([], 4) == ["", "", "", ""])
	check("n=0 no explota y conserva el bloque", B.to_cells([anchor("a", 0)], 0) == ["a"])

	# --- buscador ÚNICO de hueco (`nearest_free`) ------------------------------
	check("nearest_free usa el destino libre",
		B.nearest_free(["a", "", "", "b"], 1, 1, 4) == 1)
	check("nearest_free empate -> derecha (prefer +1)",
		B.nearest_free(["", "X", ""], 1, 1, 3, 1) == 2)
	check("nearest_free prefer -1 -> izquierda",
		B.nearest_free(["", "X", ""], 1, 1, 3, -1) == 0)
	check("nearest_free respeta el span (2 contiguas)",
		B.nearest_free(["X", "Y", "", "", "Z"], 1, 2, 5, 1) == 2)
	check("nearest_free barra llena = -1", B.nearest_free(["a", "b"], 0, 1, 2, 1) == -1)

	# --- lado ESTABLE: un colapso no reclasifica el ancla -----------------------
	# Bloque anclado a la derecha con offset grande (n=20 -> celda 12, at=-8).
	var big_right = B.to_saved(cells_at(20, {12: "c"}), 20)
	check("ancla derecha con offset grande", big_right[0].tok == "c" and big_right[0].at == -8)
	# Colapsa a n=6: no entra en su slot y queda del lado izquierdo de la barra.
	var collapsed = B.to_cells(big_right, 6)
	check("colapsa dentro de la barra", collapsed.has("c"))
	# Al re-guardar con n=6 el LADO se conserva (signo negativo) y al volver a n=20
	# retoma la mitad derecha en vez de quedar pegado a la izquierda.
	var re_saved = B.to_saved(collapsed, 6, big_right)
	check("el lado derecha se conserva al re-guardar", re_saved[0].tok == "c" and re_saved[0].at < 0)
	var restored = B.to_cells(re_saved, 20)
	check("al volver a n grande sigue en la mitad derecha", restored.find("c") >= 10)
	# Sin la ancla previa, el mismo colapso se reclasificaría como izquierda.
	var without = B.to_saved(collapsed, 6)
	check("sin prev se reclasifica (contraste)", without[0].at >= 0)

	# --- invariante: nunca dos bloques en el mismo slot -------------------------
	# Dos bloques de span 2 anclados en celdas contiguas: reservan su ancho y no se
	# superponen (el segundo corre al hueco libre).
	var spans2 = {"a": 2, "b": 2}
	var overlap = B.to_cells([anchor("a", 0), anchor("b", 1)], 8, spans2)
	var starts = {}
	var dup = false
	for i in range(overlap.size()):
		var t = String(overlap[i])
		if t == "":
			continue
		if starts.has(t) and int(starts[t]) > 1:
			dup = true
		if not starts.has(t):
			starts[t] = 0
		starts[t] = int(starts[t]) + 1
	check("span: no hay dos bloques solapados", int(starts.get("a", 0)) == 2 and int(starts.get("b", 0)) == 2 and not dup)
	# Colapso de muchos bloques angostos: cada celda ocupada una sola vez.
	var many = B.to_cells([anchor("a", 0), anchor("b", 0), anchor("c", 0), anchor("d", 0)], 3)
	var used = {}
	var clash = false
	for i in range(many.size()):
		var t = String(many[i])
		if t == "":
			continue
		if used.has(t):
			clash = true
		used[t] = true
	check("colapso: un bloque por slot en la barra", not clash)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
