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
	# Desde 5 (lado derecho) el centro queda a la izquierda -> 4.
	var col2 = B.to_cells([anchor("x", 5), anchor("y", 5)], 10)
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

	OS.exit_code = 1 if failed > 0 else 0
	quit()
