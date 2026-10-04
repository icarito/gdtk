extends SceneTree

# Prueba pura de los slots/huecos de la barra del Frame: grilla regular de celdas
# (origen + paso entero), orden con huecos persistentes y drop/save/load. Reproduce
# el bug reportado "el bloque se pega a la izquierda en vez de caer en la celda N".
# No instancia el shell ni el compositor.
# Correr:
#   /home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk \
#     --no-window --path shell -s $PWD/tests/frame_slots_test.gd

# Stub mínimo del shell: `_place_pin`/`_bar_set` sólo piden un frame y anotan actividad.
class ShellStub:
	var last_activity = 0
	const LAYOUT_MS = 180
	var UI_FONT_PX = 12.0
	var UI_FONT_FILE = "/nonexistent/font.ttf"
	var appearance = null
	var script_instances = {}
	var minimized = {}
	var compositor = StubCompositor.new()
	var apps = StubApps.new()
	func request_redraw():
		pass
	func _ease_out(k):
		return k
	func _units():
		return []
	func _activity_icon_of(app):
		return null
	func _activity_named(n):
		return -1


# Grilla fija de las apps del anillo (para `_pinned_app`).
class StubApps:
	var scanned = true
	var apps = []
	func scan():
		pass


# Compositor vacío: `running()` no debe devolver ventanas en el test de cableado.
class StubCompositor:
	func get_ids():
		return []
	func get_parent_id(id):
		return 0


# UI mínima (no-op) para poder ejecutar `_draw_bar_blocks` de verdad en headless y
# comprobar en qué x queda cada token. Sólo implementa lo que usa el camino de
# pines/applets; las posiciones las devuelve `get_cursor_screen_pos`.
class StubUi:
	const COL_BUTTON = 0
	const COL_BUTTON_HOVERED = 1
	const COL_BUTTON_ACTIVE = 2
	const STYLE_VAR_FRAME_ROUNDING = 3
	var cur = Vector2.ZERO
	var scale = 1.0
	func set_cursor_pos(p):
		cur = p
	func get_cursor_screen_pos():
		return cur
	func get_imgui_scale():
		return scale
	func imgui_draw_rect_filled(r, c, x):
		pass
	func imgui_draw_circle(c, r, col, seg, w):
		pass
	func imgui_draw_circle_filled(c, r, col, seg):
		pass
	func imgui_draw_polyline(pts, col, w):
		pass
	func set_tooltip(s):
		pass
	func begin_tooltip():
		pass
	func end_tooltip():
		pass
	func push_style_color(a, b):
		pass
	func push_style_var_float(a, b):
		pass
	func push_style_var_vec2(a, b):
		pass
	func pop_style_var():
		pass
	func pop_style_color(n):
		pass
	func button(a, b):
		return false
	func is_item_active():
		return false
	func is_item_hovered():
		return false
	func has_method(n):
		return n == "calc_text_size"
	func calc_text_size(s):
		return Vector2(String(s).length() * 7.0, 12.0)
	func text_colored(c, t):
		pass
	func text(t):
		pass
	func text_disabled(t):
		pass
	func image(a, b, c = null):
		pass
	func add_font(a, b, c):
		return -1
	func push_font(i):
		pass
	func pop_font():
		pass

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _layout(entries, side):
	var out = []
	for e in entries:
		var tok = e.get("tok", "")
		var kind = e.get("kind", "g")
		var x = e.get("x", 0.0)
		var w = e.get("w", side)
		out.append({"kind": kind, "id": e.get("id", ""), "tok": tok,
			"x": x, "y": 0.0, "w": w, "h": side, "rect": Rect2(x, 0.0, w, side)})
	return out


# Entrada del layout real (bar_layout) para un token, o null.
func _entry(f, zone, tok):
	for it in f.bar_layout.get(zone, []):
		if it.tok == tok:
			return it
	return null


# x a la que se dibuja `tok` según el orden y los anchos del layout (mismo avance que
# `_draw_bar_blocks`: huecos = una celda, bloques = su ancho real).
func _drawn_x(order, layout, tok, origin, cell, side):
	var pad = cell - side
	var x = origin
	for t in order:
		if t == tok:
			return x
		if t == "" or t == "w:windows":
			# Hueco y DockApp de ventanas: una celda (el tramo va encima de los huecos).
			x += side + pad
		else:
			var w = side
			for it in layout:
				if it.tok == t:
					w = float(it.w)
					break
			x += w + pad
	return x


func _init():
	var base = OS.get_user_data_dir() + "/frame_slots_test"
	Directory.new().make_dir_recursive(base)
	OS.set_environment("XDG_CONFIG_HOME", base)

	var F = load("res://frame.gd")
	check("frame.gd carga", F != null)
	if F == null:
		OS.exit_code = 1
		quit()
		return
	var f = F.new()
	f.shell = ShellStub.new()
	# El binario dev no trae Host: el inicializador `Host.sc(...)` de frame.gd falla y
	# deja en Nil los `var` posteriores. Sembrar los que tocan save/load/anim.
	f.applets_visible = []
	f.applets_future = []
	f.applets_raw = {}
	f.applets_saved_bottom = []
	f.bar_order_saved = {"top": [], "dock": []}
	f.pinned_top = []
	f.pinned_dock = []
	f.pinned_saved_top = []
	f.pinned_saved_dock = []
	f.bar_anim = {}
	f.bar_side = {"top": 0.0, "dock": 0.0}
	f.applets_layout = []
	f.window_block_x = {"top": 0.0, "dock": 0.0}

	# Grilla regular de la barra: paso entero `pitch` = lado del bloque + PAD. Se usa
	# en las dos barras; `side = pitch - PAD` es el lado cuadrado del bloque.
	var side = 80.0
	var cell = 80.0
	var grid = {"n": 20, "pitch": int(cell), "side": side, "margin": 0}
	f.bar_grid_state = {"top": grid, "dock": grid}
	f.window_span = {"top": 0, "dock": 0}
	f.window_region = {"top": Rect2(), "dock": Rect2()}
	f.window_scroll = {"top": 0.0, "dock": 0.0}
	# Origen de la barra superior tras la esquina reservada, Vecindario e Inicio.
	var x0 = 240.0

	# --- Helpers puros de la grilla ---------------------------------------------
	check("cell_from_x celda 0", f.cell_from_x(x0 + 0.5 * cell, x0, cell) == 0)
	check("cell_from_x celda 6", f.cell_from_x(x0 + 6.5 * cell, x0, cell) == 6)
	check("cell_from_x borde izquierdo celda 6", f.cell_from_x(x0 + 6.0 * cell, x0, cell) == 6)
	check("cell_from_x antes del origen = 0", f.cell_from_x(x0 - 10.0, x0, cell) == 0)
	check("cell_from_x sin celda conocida = 0", f.cell_from_x(x0 + 999.0, x0, 0.0) == 0)
	check("slot_x celda 6", f.slot_x(x0, 6, cell) == x0 + 6.0 * cell)
	check("bar_base_origin dock = 1 celda fija",
		f.bar_base_origin("dock", grid) == float(grid.margin) + 1.0 * float(grid.pitch))
	check("bar_base_origin top = 3 celdas fijas",
		f.bar_base_origin("top", grid) == float(grid.margin) + 3.0 * float(grid.pitch))

	var wide = _layout([{"tok": "w:windows", "kind": "w", "x": x0, "w": 160.0}], side)
	check("_token_cells hueco = 1", f._token_cells("", [], cell) == 1)
	check("_token_cells DockApp de ventanas = 1 celda aunque se dibuje ancho", f._token_cells("w:windows", wide, cell) == 1)
	check("_token_cells sin layout = 1", f._token_cells("p:x", [], cell) == 1)

	# --- CASO 1: barra vacía, soltar en la celda 6 => índice 6 -------------------
	f.bar_order = {"top": [], "dock": []}
	f.bar_cell = {"top": cell, "dock": cell}
	f.bar_origin = {"top": x0, "dock": 0.0}
	f.bar_layout = {"top": [], "dock": []}  # sin bloques dibujados
	var app = {"id": "foo.desktop", "name": "Foo"}
	f._place_pin(app, "top", x0 + 6.0 * cell + cell * 0.5)
	check("barra vacía: el pin cae en la celda 6",
		f.bar_order["top"] == ["", "", "", "", "", "", "p:foo.desktop"])
	check("barra vacía: x dibujada = x0 + 6*cell",
		f.slot_x(x0, f.bar_order["top"].find("p:foo.desktop"), cell) == x0 + 6.0 * cell)

	# Persiste: tras recargar, sigue en la celda 6 y con huecos a su izquierda.
	f._load_applets()
	check("tras _load_applets el pin sigue en la celda 6",
		f.bar_order["top"].find("p:foo.desktop") == 6)
	var gaps_ok = true
	for gi in range(6):
		if f.bar_order["top"][gi] != "":
			gaps_ok = false
	check("tras _load_applets los huecos persisten", gaps_ok)
	check("tras _load_applets hay un DockApp de ventanas detrás",
		f.bar_order["top"].count("w:windows") == 1 and f.bar_order["top"].find("w:windows") > 6)

	# --- CASO 2: dos bloques delante, la celda 6 sigue siendo la celda 6 --------
	f.bar_order = {"top": ["p:a", "p:b"], "dock": []}
	f.bar_cell = {"top": cell, "dock": cell}
	f.bar_origin = {"top": x0, "dock": 0.0}
	f.bar_layout = {"top": _layout([
		{"tok": "p:a", "kind": "p", "id": "a", "x": x0},
		{"tok": "p:b", "kind": "p", "id": "b", "x": x0 + cell}], side), "dock": []}
	var app2 = {"id": "bar.desktop", "name": "Bar"}
	f._place_pin(app2, "top", x0 + 6.0 * cell + cell * 0.5)
	check("con 2 bloques, el drop en la celda 6 abre 4 huecos",
		f.bar_order["top"] == ["p:a", "p:b", "", "", "", "", "p:bar.desktop"])

	# --- CASO 3: celda vacía a la IZQUIERDA de un bloque a la derecha -----------
	# El bug viejo (índice relativo a centros) compactaba el bloque al primer hueco.
	f.bar_order = {"top": ["p:a", "", "", "", "", "", "p:far"], "dock": []}
	f.bar_cell = {"top": cell, "dock": cell}
	f.bar_origin = {"top": x0, "dock": 0.0}
	f.bar_layout = {"top": _layout([
		{"tok": "p:a", "kind": "p", "id": "a", "x": x0},
		{"tok": "", "kind": "g", "x": x0 + cell},
		{"tok": "", "kind": "g", "x": x0 + 2.0 * cell},
		{"tok": "", "kind": "g", "x": x0 + 3.0 * cell},
		{"tok": "", "kind": "g", "x": x0 + 4.0 * cell},
		{"tok": "", "kind": "g", "x": x0 + 5.0 * cell},
		{"tok": "p:far", "kind": "p", "id": "far", "x": x0 + 6.0 * cell}], side), "dock": []}
	f._place_pin(app2, "top", x0 + 3.0 * cell + cell * 0.5)
	check("drop en celda vacía intermedia respeta la celda 3",
		f.bar_order["top"].find("p:bar.desktop") == 3)

	# --- CASO 4: hueco a la derecha del último bloque (bloque ancho delante) ----
	f.bar_order = {"top": ["w:windows"], "dock": []}
	f.bar_cell = {"top": cell, "dock": cell}
	f.bar_origin = {"top": x0, "dock": 0.0}
	f.bar_layout = {"top": _layout([{"tok": "w:windows", "kind": "w", "id": "windows", "x": x0, "w": 3.0 * cell}], side), "dock": []}
	f._place_pin(app2, "top", x0 + 8.0 * cell + cell * 0.5)
	check("tras el DockApp (tramo de 3 celdas), el pin se dibuja en la celda 8",
		_drawn_x(f.bar_order["top"], f.bar_layout["top"], "p:bar.desktop", x0, cell, side) == x0 + 8.0 * cell)

	# --- Semántica previa de tokens/huecos que se conserva ----------------------
	check("token hueco válido", f._maybe_order_token(""))
	check("token pin válido", f._maybe_order_token("p:x.desktop"))
	check("token ventanas válido", f._maybe_order_token("w:windows"))
	check("token basura inválido", not f._maybe_order_token("z:x"))
	f.bar_order = {"top": ["p:a", "p:b"], "dock": []}
	f._order_insert("top", "p:c", 4)
	check("insert lejos abre huecos", f.bar_order["top"] == ["p:a", "p:b", "", "", "p:c"])
	f.bar_order = {"top": ["p:a", "", "p:b"], "dock": []}
	f._order_insert("top", "p:c", 1)
	check("insert ocupa hueco", f.bar_order["top"] == ["p:a", "p:c", "p:b"])
	check("_order_with_gap clamp", f._order_with_gap(["a", "b", "c"], "a", 3) == ["b", "c", "a"])
	check("_order_with_slots deja la celda de origen vacía", f._order_with_slots(["a", "b", "c"], "a", 4) == ["", "b", "c", "", "a"])

	# --- SLOTS FIJOS: mover un bloque no corre a los de su derecha -----------------
	check("vacate deja hueco", F.seq_vacate(["a", "b", "c"], "a") == ["", "b", "c"])
	check("vacate recorta huecos finales", F.seq_vacate(["a", "b", "", "c"], "c") == ["a", "b"])
	check("vacate bloque ancho deja su ancho", F.seq_vacate(["w", "b"], "w", 3) == ["", "", "", "b"])
	# Mover el de la izquierda a un hueco lejano: b y c se quedan en sus celdas.
	check("mover a hueco no corre a nadie", F.seq_place(F.seq_vacate(["a", "b", "c"], "a"), "a", 5) == ["", "b", "c", "", "", "a"])
	check("ocupar hueco intermedio", F.seq_place(["a", "", "c"], "x", 1) == ["a", "x", "c"])
	# Soltar sobre un bloque ocupado: sólo el grupo contiguo se corre hasta el hueco.
	check("soltar sobre ocupado corre sólo al vecino", F.seq_place(["a", "b", "", "d"], "x", 1) == ["a", "x", "b", "d"])
	check("grupo contiguo se corre hasta el primer hueco", F.seq_place(["a", "b", "c", "", "e"], "x", 0) == ["x", "a", "b", "c", "e"])
	check("sin hueco a la derecha crece al final", F.seq_place(["a", "b"], "x", 1) == ["a", "x", "b"])
	f.bar_order = {"top": ["p:a", "p:b", "p:c"], "dock": []}
	f._order_remove("p:a")
	check("_order_remove deja la celda vacía", f.bar_order["top"] == ["", "p:b", "p:c"])

	# --- CABLEADO REAL: `_draw_bar_blocks` deja cada token en slot_x --------------
	# Ejecuta el dibujo de verdad (ui no-op) y comprueba las x del layout. Ésta es la
	# capa que fallaba: el modelo viejo empaquetaba los pines y `_pin_slot` sólo
	# contaba centros a la izquierda, así que un drop lejano caía en el índice 0.
	var ui = StubUi.new()
	f.applets_visible = ["reloj"]
	f.shell.apps.apps = [
		{"id": "foo.desktop", "name": "Foo"},
		{"id": "bar.desktop", "name": "Bar"}]

	# W1: barra superior vacía, pin soltado en la celda 6 => se dibuja en slot_x 6.
	f.bar_order = {"top": [], "dock": []}
	f.bar_origin = {"top": x0, "dock": f.bar_base_origin("dock", grid)}
	f.bar_cell = {"top": cell, "dock": cell}
	f.bar_layout = {"top": [], "dock": []}
	f._place_pin({"id": "foo.desktop", "name": "Foo"}, "top", x0 + 6.0 * cell + cell * 0.5)
	f.bar_anim = {}
	f._draw_bar_blocks(ui, "top", x0, 0.0, grid, Vector2(-999, -999))
	var e = _entry(f, "top", "p:foo.desktop")
	check("cableado: pin en celda 6 se dibuja en slot_x(6)",
		e != null and abs(e.x - f.slot_x(x0, 6, cell)) < 0.01)
	var gaps = 0
	for it in f.bar_layout["top"]:
		if it.kind == "g":
			gaps += 1
	check("cableado: 6 huecos a la izquierda visibles (no compacta)", gaps == 6)

	# W2: con p:foo en 6, soltar bar sobre la celda 6 (ocupada) va a la libre más
	# cercana (7, a la derecha); el bloque existente NO se mueve.
	f._place_pin({"id": "bar.desktop", "name": "Bar"}, "top", x0 + 6.0 * cell + cell * 0.5)
	f.bar_anim = {}
	f._draw_bar_blocks(ui, "top", x0, 0.0, grid, Vector2(-999, -999))
	e = _entry(f, "top", "p:bar.desktop")
	var e_foo = _entry(f, "top", "p:foo.desktop")
	check("cableado: drop sobre ocupado va a la celda libre más cercana (7)",
		e != null and abs(e.x - f.slot_x(x0, 7, cell)) < 0.01)
	check("cableado: el bloque existente no se mueve",
		e_foo != null and abs(e_foo.x - f.slot_x(x0, 6, cell)) < 0.01)

	# W3: barra inferior (otro origen): applet en la celda 4.
	var dock_x = f.bar_base_origin("dock", grid)
	f.bar_order = {"top": [], "dock": []}
	f.bar_origin = {"top": x0, "dock": dock_x}
	f.bar_cell = {"top": cell, "dock": cell}
	f.bar_layout = {"top": [], "dock": []}
	f._move_token("dock", "a:reloj", dock_x + 4.0 * cell + cell * 0.5)
	f.bar_anim = {}
	f._draw_bar_blocks(ui, "dock", dock_x, 0.0, grid, Vector2(-999, -999))
	e = _entry(f, "dock", "a:reloj")
	check("cableado: applet en dock celda 4 se dibuja en slot_x(4)",
		e != null and abs(e.x - f.slot_x(dock_x, 4, cell)) < 0.01 \
		and f.bar_order["dock"].find("a:reloj") == 4)

	# W4: DockApp de ventanas (clip vacío) reubicado en cualquier celda del dock.
	f.bar_order = {"top": [], "dock": []}
	f.bar_origin = {"top": x0, "dock": dock_x}
	f.bar_cell = {"top": cell, "dock": cell}
	f.bar_layout = {"top": [], "dock": []}
	f._move_token("dock", "w:windows", dock_x + 2.0 * cell + cell * 0.5)
	f.bar_anim = {}
	f._draw_bar_blocks(ui, "dock", dock_x, 0.0, grid, Vector2(-999, -999))
	e = _entry(f, "dock", "w:windows")
	check("cableado: DockApp de ventanas en dock celda 2",
		e != null and abs(e.x - f.slot_x(dock_x, 2, cell)) < 0.01)

	# W4b: el tramo del DockApp cubre los huecos siguientes SIN consumirlos: el
	# applet de su derecha queda en su celda (antes se corría tantas celdas como
	# midiera el tramo).
	f.bar_order = {"top": [], "dock": ["w:windows", "", "", "a:reloj"]}
	f.bar_anim = {}
	f._draw_bar_blocks(ui, "dock", dock_x, 0.0, grid, Vector2(-999, -999))
	e = _entry(f, "dock", "a:reloj")
	check("cableado: applet tras el tramo de ventanas sigue en su celda 3",
		e != null and abs(e.x - f.slot_x(dock_x, 3, cell)) < 0.01)
	check("cableado: el tramo de ventanas cubre sus 3 celdas", int(f.window_span.get("dock", 0)) == 3)

	# W5: sin dibujo previo (autohide): la grilla se reconstruye, no colapsa al 0.
	f.bar_cell = {"top": 0.0, "dock": 0.0}
	f.bar_origin = {"top": 0.0, "dock": 0.0}
	f.bar_grid_state = {"top": grid, "dock": grid}
	var fo = f.bar_base_origin("top", grid)
	check("fallback: celda 6 reconstruida sin último dibujo",
		f._slot_index("top", fo + 6.0 * cell + cell * 0.5, "p:x", []) == 6)

	# W6: persistencia con huecos intermedios Y finales intactos.
	f.bar_cell = {"top": cell, "dock": cell}
	f.bar_side = {"top": side, "dock": side}
	f.bar_order = {"top": ["p:foo.desktop", "", "", "", ""], "dock": []}
	f._sync_pins()
	f._save_applets()
	f._load_applets()
	var seq_top = f.bar_order["top"]
	check("persistencia: huecos intermedios y finales se conservan",
		seq_top.size() >= 5 and seq_top[0] == "p:foo.desktop" \
		and seq_top[1] == "" and seq_top[2] == "" and seq_top[3] == "" and seq_top[4] == "")

	# --- INVARIANTE: un bloque por celda, libre más cercana, nadie se mueve --------
	var big = {"n": 20, "pitch": int(cell), "side": side, "margin": 0}
	f.bar_grid_state = {"top": big, "dock": big}
	f.bar_cell = {"top": cell, "dock": cell}
	f.bar_origin = {"top": x0, "dock": 0.0}
	f.bar_layout = {"top": [], "dock": []}

	# Izquierda más cerca: hueco en 1, bloques en 2 y 3; drop en 2 -> va a 1.
	f.bar_order = {"top": ["p:a", "", "p:b", "p:d"], "dock": []}
	f._place_pin({"id": "c.desktop", "name": "C"}, "top", x0 + 2.0 * cell + cell * 0.5)
	check("ocupado: la libre más cercana a la izquierda",
		f.bar_order["top"].find("p:c.desktop") == 1)
	check("ocupado: el bloque de la celda destino no se mueve",
		f.bar_order["top"].find("p:b") == 2)
	check("ocupado: el bloque de la derecha no se mueve",
		f.bar_order["top"].find("p:d") == 3)

	# Empate: a y b en 0,1; drop sobre 1 -> libre más cercana 2 (derecha).
	f.bar_order = {"top": ["p:a", "p:b"], "dock": []}
	f._place_pin({"id": "c2.desktop", "name": "C2"}, "top", x0 + 1.0 * cell + cell * 0.5)
	check("empate de distancia va a la derecha",
		f.bar_order["top"].find("p:c2.desktop") == 2)

	# Applet de 2 celdas: busca 2 libres contiguas.
	f.bar_order = {"top": ["p:a", "p:b", "", "", "p:c"], "dock": []}
	var placed_wide = f._place_token_cell("top", "a:wide", 1, 2)
	check("applet de 2 celdas ocupa 2 libres contiguas",
		placed_wide and f.bar_order["top"].find("a:wide") == 2)
	check("applet de 2 celdas no se superpone al siguiente",
		f.bar_order["top"].find("p:c") == 3)

	# Barra llena: no se añade y nada cambia.
	var small = {"n": 8, "pitch": int(cell), "side": side, "margin": 0}  # top max = 4
	f.bar_grid_state = {"top": small, "dock": small}
	f.bar_cell = {"top": cell, "dock": cell}
	f.bar_origin = {"top": x0, "dock": 0.0}
	f.bar_layout = {"top": [], "dock": []}
	f.bar_order = {"top": ["p:a", "p:b", "p:c", "p:d"], "dock": []}
	var before = f.bar_order["top"].duplicate()
	f._place_pin({"id": "e.desktop", "name": "E"}, "top", x0 + 1.0 * cell + cell * 0.5)
	check("barra llena: no se añade y queda igual", f.bar_order["top"] == before)

	# Mover a una barra llena no borra el bloque de su barra original (se restaura).
	f.bar_grid_state = {"top": small, "dock": small}
	f.bar_order = {"top": ["p:keep.desktop"], "dock": ["p:a", "p:b", "p:c", "p:d", "p:e", "p:f"]}
	f._place_pin({"id": "keep.desktop", "name": "Keep"}, "dock", x0 + 1.0 * cell + cell * 0.5)
	check("mover a barra llena conserva el bloque original",
		f.bar_order["top"].has("p:keep.desktop") and not f.bar_order["dock"].has("p:keep.desktop"))

	# Datos fuera de rango: se normalizan sin superposición.
	f.bar_grid_state = {"top": small, "dock": small}
	f.bar_order = {"top": ["p:a", "", "p:b", "p:c", "p:d", "p:e"], "dock": []}
	f._normalize_order("top")
	check("normaliza: todo dentro del tope útil de la barra",
		f.bar_order["top"].size() <= 4)
	check("normaliza: reubica en la celda libre más cercana",
		f.bar_order["top"].find("p:d") == 1)
	check("normaliza: descarta lo que no cabe sin superponer",
		not f.bar_order["top"].has("p:e"))

	# Preview coincide exactamente con el drop.
	f.bar_grid_state = {"top": big, "dock": big}
	f.bar_cell = {"top": cell, "dock": cell}
	f.bar_origin = {"top": x0, "dock": 0.0}
	f.bar_layout = {"top": [], "dock": []}
	f.bar_order = {"top": ["p:a", "", "p:b", "p:d"], "dock": []}
	var mx = x0 + 2.0 * cell + cell * 0.5
	var preview = f._seq_with_drag("top", "p:c.desktop", mx, big, [], x0)
	f._place_pin({"id": "c.desktop", "name": "C"}, "top", mx)
	check("preview coincide con el drop", preview == f.bar_order["top"])

	# Helpers puros de celdas.
	check("nearest_free: el destino libre se usa",
		F.nearest_free(["a", "", "", "b"], 1, 1, 4) == 1)
	check("nearest_free: empate -> derecha",
		F.nearest_free(["", "X", "", ""], 1, 1, 4) == 2)
	check("nearest_free: izquierda más cerca",
		F.nearest_free(["", "X", "Y", "Z"], 3, 1, 4) == 0)
	check("nearest_free: span 2 contiguo",
		F.nearest_free(["X", "Y", "", "", "Z"], 1, 2, 5) == 2)
	check("nearest_free: barra llena = -1", F.nearest_free(["a", "b"], 0, 1, 2) == -1)
	check("seq_to_cells/cells_to_seq respetan el span",
		F.cells_to_seq(F.seq_to_cells(["a", "b", ""], {"a": 2})) == ["a", "b", ""])

	f.free()
	print("FRAME_SLOTS_TEST_" + ("OK" if failed == 0 else "FAIL"))
	OS.exit_code = 1 if failed > 0 else 0
	quit()
