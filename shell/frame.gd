extends Node

# El Frame (como en Sugar): franja superpuesta arriba con Inicio, todo lo que
# corre (actividades internas con instancia viva y toplevels wayland sin padre,
# los haya lanzado el shell o no) y el reloj. No ocupa espacio: la app usa toda
# la pantalla y el Frame se dibuja encima (ViewLayer va en layer -1, bajo ImGui).
#
# Se muestra con F6, tocando Super sola (como GNOME/Sugar) o dejando el mouse
# HOT_MS en la esquina superior izquierda o contra el borde superior; en el Home
# está siempre. Se oculta al elegir algo, con Esc, con F6/Super o al sacar el
# mouse (si entró en él después de mostrarse).
# Super+F6 abre y cierra el HUD de debug (ya no hay widget mini ni F1).
#
# Super: la pulsación se retiene; si se suelta sin otra tecla ni clic entre medio
# alterna el Frame y la app no ve nada. Si llega otra tecla (Super+L...), la
# pulsación retenida se reenvía antes a la app y el combo le llega entero. FRT la
# entrega como scancode KEY_META (keysym) con physical KEY_SUPER_L/R.
#
# Borde: y <= EDGE en cualquier x (Deskflow entrando/saliendo por arriba, o chocar
# el borde). HOT_MS evita disparos al pasar hacia pestañas/menús pegados arriba, y
# un clic mientras espera la desarma hasta salir del borde (clic en una pestaña).
#
# Alt+Tab / Alt+Shift+Tab ciclan entre lo abierto sin mostrar el Frame. Se eligió
# Alt+Tab (no Ctrl+Tab, que usan las apps para pestañas): bajo cage en DRM llega
# al shell; sólo en cage anidado lo roba el escritorio anfitrión (probar con el
# control remoto: `key alt+Tab`).

const FRAME_H = 48.0
const CORNER = 4.0
const EDGE = 1.0
const HOT_MS = 250
# Entrada/salida del Frame deslizándose desde arriba (ease-out).
const SLIDE_MS = 130
const SUPER_KEYS = [KEY_META, KEY_SUPER_L, KEY_SUPER_R]
const ITEM_W = 200.0
const CLOSE_W = 28.0
const MIN_W = 26.0
const PAD = 8.0
const DRAG_PX = 8.0
# Insignia de identidad (persona): figura XO + nombre, fija a la derecha de Inicio.
const ID_BADGE_ICON = 28.0
const ID_BADGE_GAP = 6.0
const ID_BADGE_PAD = 4.0
# Applets del borde inferior (SPEC-sugar-frame-applets.md): cada control es un bloque
# cuadrado fijo, reordenable y ocultable. Lista corta de ids estables; sin arquitectura
# genérica de providers.
const APPLETS = [
	{"id": "cpu", "name": "CPU", "short": "CPU"},
	{"id": "memoria", "name": "Memoria", "short": "MEM"},
	{"id": "swap", "name": "Swap", "short": "SWP"},
	{"id": "reloj", "name": "Reloj", "short": "REL"},
	{"id": "deskflow", "name": "Deskflow", "short": "DFW"},
	{"id": "bluetooth", "name": "Bluetooth", "short": "BT"},
	{"id": "teclado", "name": "Teclado", "short": "TEC"},
]
const APPLET_DEFAULT = ["cpu", "memoria", "swap", "reloj", "deskflow", "bluetooth", "teclado"]
const APPLET = 44.0
const APPLET_PAD = 4.0
const ADD_W = 28.0
const DESKFLOW = "Deskflow"
const DESKFLOW_MS = 1000

onready var shell = get_parent()

var visible = false
var entered = false
# 0: armada; >0: ms en que el mouse llegó a la esquina; -1: desarmada hasta salir.
var corner_since = 0
var swallowed = {}
var hot_timer = false
# Pulsación de Super retenida mientras no se sepa si es un toque solo.
var super_press = null
# Deslizamiento: último estado dibujado (visible u Home) y cuándo cambió.
var shown = false
var slide_since = 0
# Layout del último frame dibujado (para el control remoto / tests).
var sysmon = Host.sc("res://sysmon.gd").new()
var bluetooth = Host.sc("res://applet_bluetooth.gd").new()
var keyboard = Host.sc("res://applet_keyboard.gd").new()
var items_layout = []
var drawn = false
# Teclado y drag: selección en el Frame, ventana "levantada" (tileo sin mouse),
# y arrastre con mouse (soltar sobre otra ventana tilea; soltar fuera deshace).
var sel = -1
var lifted = null
var dragging = null
var win_drag = null       # Super+arrastre de una ventana hacia el Frame (reordenar/tilear)
var drag_candidate = null
var drag_from = Vector2.ZERO
var mouse_down = false
var mouse_pos = Vector2.ZERO
var slide_instant = false  # aparecer sin animación (Alt+Tab)
var show_until = 0         # ms hasta el que el Frame no se auto-oculta (Alt+Tab)
# Applets del borde inferior: orden visible persistido (no es items_layout, que sigue
# siendo sólo de ventanas para el control remoto). `applets_future` conserva ids
# desconocidos del archivo para una versión futura.
var applets_visible = []
var applets_future = []
var applets_raw = {}
var applets_saved_bottom = []
var applets_dirty = false
var applets_layout = []    # rects del último dibujo de los applets
var applets_drawn = false
var applet_picker_want = false
var applet_picker_open = false
var applet_action_want = ""
var applet_press = null    # id del applet pulsado (aún sin arrastrar)
var applet_drag = null     # id del applet que se está arrastrando (reordenar)
var applet_from = Vector2.ZERO
var deskflow_on = false
var deskflow_ms = -DESKFLOW_MS


func _ready():
	_load_applets()


# Ruta del archivo de applets: $XDG_CONFIG_HOME/gdtk/frame-applets.json
# (~/.config/gdtk/frame-applets.json por defecto), junto a keyboard.
func _applets_path():
	var base = OS.get_environment("XDG_CONFIG_HOME")
	if base == "":
		base = OS.get_environment("HOME") + "/.config"
	return base + "/gdtk/frame-applets.json"


func _applet_def(id):
	for a in APPLETS:
		if a.id == id:
			return a
	return null


func _applet_known(id):
	return _applet_def(id) != null


# Carga sólo el orden visible de `bottom`; archivo ausente o corrupto -> defaults.
# Ids desconocidos se guardan aparte y se reescriben intactos.
func _load_applets():
	applets_visible = APPLET_DEFAULT.duplicate()
	applets_future = []
	applets_raw = {}
	applets_saved_bottom = APPLET_DEFAULT.duplicate()
	var f = File.new()
	if f.open(_applets_path(), File.READ) == OK:
		var txt = f.get_as_text()
		f.close()
		var res = JSON.parse(txt)
		if res.error == OK and typeof(res.result) == TYPE_DICTIONARY:
			applets_raw = res.result
			var bottom = applets_raw.get("bottom", null)
			if typeof(bottom) == TYPE_ARRAY:
				var seen = {}
				applets_visible = []
				var saved = []
				for v in bottom:
					if typeof(v) != TYPE_STRING:
						continue
					if _applet_known(v):
						if not seen.has(v):
							seen[v] = true
							applets_visible.append(v)
					else:
						applets_future.append(v)
					saved.append(v)
				applets_saved_bottom = saved
	applets_dirty = false


func _same_list(a, b):
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true


# Escritura atómica y sólo si el orden visible (con ids futuros) cambió. Sin cambios
# reales no toca el archivo.
func _save_applets():
	var bottom = applets_visible.duplicate()
	for id in applets_future:
		bottom.append(id)
	if _same_list(bottom, applets_saved_bottom):
		applets_dirty = false
		return
	var path = _applets_path()
	var dir = Directory.new()
	dir.make_dir_recursive(path.get_base_dir())
	applets_raw["bottom"] = bottom
	var tmp = path + ".tmp"
	var w = File.new()
	if w.open(tmp, File.WRITE) != OK:
		printerr("frame: no se pudo escribir ", tmp)
		return
	w.store_string(JSON.print(applets_raw))
	w.close()
	if dir.rename(tmp, path) != OK:
		printerr("frame: no se pudo renombrar ", tmp, " a ", path)
		return
	applets_saved_bottom = bottom
	applets_dirty = false


func _applet_set_visible(id, v):
	if v:
		if not applets_visible.has(id):
			applets_visible.append(id)
			if id == "bluetooth":
				bluetooth.refresh(true)
			elif id == "teclado":
				keyboard.refresh(true)
	elif applets_visible.has(id):
		applets_visible.erase(id)
	applets_dirty = true
	_save_applets()
	shell.request_redraw()


func _applet_move(id, dir):
	var i = applets_visible.find(id)
	if i < 0:
		return
	var j = i + dir
	if j < 0 or j >= applets_visible.size():
		return
	applets_visible.remove(i)
	applets_visible.insert(j, id)
	applets_dirty = true
	_save_applets()
	shell.request_redraw()


func _deskflow_activity():
	for act in shell.ACTIVITIES:
		if act.name == DESKFLOW:
			return act
	return null


# Primaria del applet: Deskflow prende/apaga reusando _toggle_service; el resto no
# tiene acción en este corte (el tooltip muestra el nombre completo).
func _applet_primary(id):
	if id == DESKFLOW:
		var act = _deskflow_activity()
		if act != null:
			_refresh_deskflow(true)
			shell._toggle_service(act)
			deskflow_on = shell._service_running(DESKFLOW)
			deskflow_ms = OS.get_ticks_msec()
			shell.request_redraw()
	elif id == "bluetooth":
		# Se registra como actividad dinámica para que Blueman use el compositor
		# embebido y su ventana participe en el mismo espacio que las demás.
		var i = shell._activity_named("Bluetooth")
		if i < 0:
			shell.ACTIVITIES.append({"name": "Bluetooth", "wayland": ["blueman-manager"], "dynamic": true})
			i = shell.ACTIVITIES.size() - 1
		shell._activate(i)
		if shell.pending_wayland == "" and not shell.wayland_ids.has("Bluetooth") and shell.ACTIVITIES[i].get("dynamic", false):
			shell.ACTIVITIES.remove(i)
	elif id == "teclado":
		applet_action_want = "teclado"
		shell.request_redraw()


func _refresh_deskflow(force := false):
	var now = OS.get_ticks_msec()
	if not force and now - deskflow_ms < DESKFLOW_MS:
		return
	deskflow_ms = now
	# Una recarga antigua del shell puede perder el PID aunque Deskflow siga vivo.
	# Reincorporarlo evita mostrar «no» y lanzar un segundo cliente al pulsar.
	if not shell._service_running(DESKFLOW):
		var act = _deskflow_activity()
		if act != null:
			var out = []
			var cmd = act.service.replace("~/", OS.get_environment("HOME") + "/")
			if OS.execute("pgrep", ["-u", OS.get_environment("USER"), "-f", "-x", cmd], true, out) == 0 and out.size() > 0:
				var pid = int(String(out[0]).strip_edges().split("\n")[0])
				if pid > 0:
					shell.service_pids[DESKFLOW] = pid
	deskflow_on = shell._service_running(DESKFLOW)


# Estado y valor textual de cada applet. Sin medición no se estima: "sin dato".
func _applet_state(id):
	match id:
		"cpu":
			return "activo" if sysmon.has_cpu else "sin_dato"
		"memoria":
			return "activo" if sysmon.has_ram else "sin_dato"
		"swap":
			return "activo" if sysmon.has_swap else "sin_dato"
		"reloj":
			return "activo"
		"deskflow":
			return "activo" if deskflow_on else "apagado"
		"bluetooth":
			return bluetooth.state
		"teclado":
			return keyboard.state
	return "sin_dato"


func _applet_value(id):
	match id:
		"cpu":
			return "%d%%" % int(round(sysmon.cpu_now())) if sysmon.has_cpu else "sin dato"
		"memoria":
			return "%d%%" % int(round(sysmon.ram)) if sysmon.has_ram else "sin dato"
		"swap":
			return "%d%%" % int(round(sysmon.swap)) if sysmon.has_swap else "sin dato"
		"reloj":
			var t = OS.get_time()
			return "%02d:%02d" % [t.hour, t.minute]
		"deskflow":
			return "sí" if deskflow_on else "no"
		"bluetooth":
			return bluetooth.value
		"teclado":
			return keyboard.value
	return ""


func _applet_pct(id):
	match id:
		"cpu":
			return clamp(sysmon.cpu_now() / 100.0, 0.0, 1.0) if sysmon.has_cpu else -1.0
		"memoria":
			return clamp(sysmon.ram / 100.0, 0.0, 1.0) if sysmon.has_ram else -1.0
		"swap":
			return clamp(sysmon.swap / 100.0, 0.0, 1.0) if sysmon.has_swap else -1.0
	return -1.0


func set_visible(v):
	visible = v
	entered = false
	corner_since = -1
	if v:
		show_until = 0  # mostrado a mano: sin auto-ocultado de Alt+Tab
		_refresh_deskflow(true)
	else:
		sel = -1
		lifted = null
		applet_press = null
		applet_drag = null
	# Desde _input (tecla tragada, ImGui no la ve) nadie más pide el frame que lo muestra.
	shell.request_redraw()
	shell.last_activity = OS.get_ticks_msec()


# Lo que corre: internas (por instancia viva) primero, con su nombre; después las
# ventanas visibles en el orden de las pantallas de shell._units() (las de una
# pantalla partida quedan juntas y comparten `screen`); al final las minimizadas y
# las que aún no entraron a la franja, atenuadas y sin número de pantalla. `title`
# y `key` no cambian: el número de pantalla es un campo aparte.
func running():
	var out = []
	for name in shell.script_instances.keys():
		out.append({"key": "s:" + name, "name": name, "title": name, "id": -1,
			"minimized": false, "screen": 0})
	var order = []
	var by_id = {}
	for id in shell.compositor.get_ids():
		if shell.compositor.get_parent_id(id) > 0:
			continue
		var name = shell._activity_for_window(id)
		var title = shell.compositor.get_title(id)
		if title == "":
			title = name if name != "" else "Ventana " + str(id)
		by_id[id] = {"key": "w:" + str(id), "name": name, "title": title, "id": id,
			"minimized": shell.minimized.has(id), "screen": 0}
		order.append(id)
	var screen = 0
	for unit in shell._units():
		screen += 1
		for id in unit:
			if by_id.has(id):
				by_id[id]["screen"] = screen
				out.append(by_id[id])
				by_id.erase(id)
	for id in order:
		if by_id.has(id):
			out.append(by_id[id])
	return out


func _is_current(item):
	if item.id >= 0:
		return item.id == shell._current_wayland_id()
	return shell.current_activity != null and shell.current_activity.name == item.name


# Rect en pantalla del ítem de una ventana (para anclar animaciones de min/cerrar).
func item_rect(id):
	for it in items_layout:
		if it.id == id:
			return Rect2(it.x, it.y, it.hit_w, 28.0)
	return null


func switch_to(item, keep_frame := false):
	if not keep_frame:
		set_visible(false)
	if item.id >= 0 and shell.minimized.has(item.id):
		# Restaurar una minimizada (el Frame la lista en gris).
		shell._restore_window(item.id)
	elif item.id < 0 or item.name != "":
		shell._open_by_name(item.name)
	else:
		# Toplevel que todavía no tiene actividad dinámica: se la crea ya.
		shell.unmanaged.erase(item.id)
		shell._open_unmanaged_window(item.id)


func close(item):
	if item.id >= 0:
		# Cierre educado (xdg_toplevel.close): la app puede preguntar antes de irse.
		shell.compositor.close(item.id)
	else:
		shell._close_script_activity(item.name)


func cycle(step):
	var items = running()
	if items.empty():
		return
	var at = -1
	for i in range(items.size()):
		if _is_current(items[i]):
			at = i
	if at < 0:
		at = 0 if step > 0 else items.size()
	else:
		at = posmod(at + step, items.size())
	# Alt+Tab: cambio casi instantáneo y con el Frame a la vista durante la transición.
	slide_instant = true
	sel = at
	shell.instant_switch = true
	switch_to(items[at], true)
	set_visible(true)
	show_until = OS.get_ticks_msec() + 1200  # se auto-oculta al terminar la gracia
	shell.last_activity = OS.get_ticks_msec()
	shell.request_redraw()


# Monitor del sistema: muestrea con el Frame a la vista (Home o abierto a pedido) y pide
# un frame por muestra (>= 1 Hz) para que la gráfica y los diales avancen.
func _process(_delta):
	if shell.fullscreen_id >= 0:
		return
	var home = shell.current_activity == null
	if visible or home:
		var changed = sysmon.tick()
		if changed:
			# El estado de Deskflow lanza un proceso (kill -0): a lo sumo 1/s.
			_refresh_deskflow(false)
		if applets_visible.has("bluetooth"):
			changed = bluetooth.refresh() or changed
		if applets_visible.has("teclado"):
			changed = keyboard.refresh() or changed
		if changed:
			shell.request_redraw()


# Super dejó de ser un toque solo: la app recibe la pulsación retenida.
func _super_used():
	if super_press != null and shell._current_wayland_id() >= 0:
		shell.compositor.key(super_press)
	super_press = null


func _input(event):
	# Mouse: además del borde/esquina, sigue el arrastre de ítems para tilear.
	if event is InputEventMouseMotion:
		mouse_pos = event.position
		# Arrastre de un applet del borde inferior: reordena, nunca mueve ventanas.
		if mouse_down and applet_press != null and applet_drag == null \
				and mouse_pos.distance_to(applet_from) > DRAG_PX:
			applet_drag = applet_press
		if applet_drag != null:
			shell.request_redraw()
		if mouse_down and dragging == null and drag_candidate != null \
				and mouse_pos.distance_to(drag_from) > DRAG_PX:
			dragging = drag_candidate
		if dragging != null:
			shell.request_redraw()
		if win_drag != null:
			shell.request_redraw()
		return
	if event is InputEventMouseButton:
		mouse_pos = event.position
		# Rueda: con Super, o sobre la barra del Frame visible, avanza entre workspaces
		# de la franja. La SUELTA de la rueda se ignora (si cayera al final del bloque
		# llamaría a _super_used y limpiaría super_press, cortando el paneo).
		if event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN:
			if not event.pressed:
				return
			# En exposé la rueda desplaza la tira (no cambia la selección).
			if shell.expose:
				shell._expose_scroll_by((240.0 if event.button_index == BUTTON_WHEEL_DOWN else -240.0))
				get_tree().set_input_as_handled()
				return
			if super_press != null:
				shell._pan_by((-1.0 if event.button_index == BUTTON_WHEEL_UP else 1.0))
				shell.request_redraw()
				get_tree().set_input_as_handled()
				return
			if visible and mouse_pos.y <= FRAME_H:
				shell._focus_dir(-1 if event.button_index == BUTTON_WHEEL_UP else 1)
				shell.request_redraw()
				get_tree().set_input_as_handled()
				return
			return
		if event.button_index == BUTTON_RIGHT:
			# Bluetooth ofrece radio/dispositivos; los demás, composición del Frame.
			var right_applet = _applet_at(mouse_pos)
			if event.pressed and not applet_picker_open and right_applet != null:
				if right_applet == "bluetooth":
					applet_action_want = "bluetooth"
				else:
					applet_picker_want = true
				shell.request_redraw()
				get_tree().set_input_as_handled()
				return
		if event.button_index == BUTTON_LEFT:
			mouse_down = event.pressed
			if event.pressed:
				# Super+arrastre sobre una ventana: la mueve al Frame (reordenar/tilear).
				if super_press != null and mouse_pos.y > FRAME_H and shell.focused_tile >= 0:
					win_drag = {"id": shell.focused_tile}
					shell.window_dragging = true
					set_visible(true)
					get_tree().set_input_as_handled()
					return
				# Clic en un applet: selecciona y arma el posible arrastre de orden.
				var hit_applet = _applet_at(mouse_pos)
				if hit_applet != null and not applet_picker_open:
					applet_press = hit_applet
					applet_from = mouse_pos
					applet_drag = null
					var at = applets_visible.find(hit_applet)
					if at >= 0:
						sel = running().size() + at
					shell.request_redraw()
					get_tree().set_input_as_handled()
					return
				drag_candidate = _item_at(mouse_pos)
				drag_from = mouse_pos
				dragging = null
			else:
				if applet_drag != null:
					_finish_applet_drag()
				elif applet_press != null:
					_applet_primary(applet_press)
				applet_press = null
				applet_drag = null
				if win_drag != null:
					_finish_win_drag()
				elif dragging != null:
					_finish_drag()
				dragging = null
				drag_candidate = null
		_super_used()
		if corner_since > 0:
			corner_since = -1
		return
	if not (event is InputEventKey):
		return
	var code = event.scancode
	# Esc cancela el arrastre de un applet (conserva el orden) antes de ocultar el Frame.
	if event.pressed and code == KEY_ESCAPE and applet_drag != null:
		applet_drag = null
		applet_press = null
		shell.request_redraw()
		_gulp(code)
		return
	# Exposé abierto: navegar y elegir (Esc cierra).
	if shell.expose:
		if not event.pressed:
			return
		if code == KEY_ESCAPE:
			shell._toggle_expose(false)
		elif code == KEY_LEFT:
			shell._expose_move(-1)
		elif code == KEY_RIGHT:
			shell._expose_move(1)
		elif code == KEY_ENTER or code == KEY_KP_ENTER or code == KEY_SPACE:
			shell._expose_commit()
		else:
			return
		_gulp(code)
		return
	if SUPER_KEYS.has(code) or SUPER_KEYS.has(event.physical_scancode):
		if event.pressed:
			super_press = event
		elif super_press != null:
			super_press = null
			if shell.pan_active:
				shell._snap_pan()  # cae a la pantalla más cercana
			elif win_drag == null:
				set_visible(not visible)
		else:
			return  # Suelta tras un combo: va a la app.
		get_tree().set_input_as_handled()
		return
	if event.pressed and super_press != null:
		# Super+tecla: atajos del shell (no llegan a la app).
		if code == KEY_F6:
			super_press = null
			DebugHud.toggle()
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_W:
			super_press = null
			shell._toggle_expose(true)
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_M:
			super_press = null
			shell._minimize_window(shell.focused_tile)
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_LEFT or code == KEY_RIGHT:
			# Super+←/→: tiling a la mitad izquierda/derecha.
			super_press = null
			shell._snap_tile(-1 if code == KEY_LEFT else 1)
			shell.request_redraw()
			_gulp(code)
			return
		if code == KEY_T:
			super_press = null
			if event.shift:
				shell._untile_window(shell.focused_tile)
			else:
				shell._tile_with_next()
			shell.request_redraw()
			_gulp(code)
			return
	if event.pressed:
		_super_used()
	if not event.pressed:
		# La suelta de una tecla que nos comimos tampoco va a la app.
		if swallowed.has(code):
			swallowed.erase(code)
			get_tree().set_input_as_handled()
		return
	# Frame a la vista: flechas mueven la selección y Enter/Espacio/m/Delete operan.
	if visible and _frame_key(code, event):
		return
	var home = shell.current_activity == null
	if code == KEY_F6:
		if not event.echo:
			set_visible(not visible)
	elif code == KEY_ESCAPE and visible and not home:
		set_visible(false)
	elif code == KEY_TAB and event.alt:
		cycle(-1 if event.shift else 1)
	elif event.control and event.alt and not event.shift and _arrow_dir(code) != 0:
		# Ctrl+Alt+flecha: cambiar de pantalla (desliza; arriba/abajo mueve la franja).
		shell._focus_dir(_arrow_dir(code))
	elif event.control and event.alt and event.shift and _arrow_dir(code) != 0:
		# Ctrl+Alt+Shift+flecha: intercambiar la pantalla enfocada con la vecina.
		shell._swap_dir(_arrow_dir(code))
	elif event.alt and not event.control and code == KEY_F11:
		# Alt+F11: pantalla completa de la ventana enfocada.
		shell._toggle_fullscreen()
	elif event.alt and not event.control and code == KEY_F10:
		# Alt+F10: maximizar (ocupar todo el workspace).
		shell._maximize_window(shell.focused_tile)
	else:
		return
	_gulp(code)


func _gulp(code):
	swallowed[code] = true
	get_tree().set_input_as_handled()


# Teclado con el Frame a la vista: flechas eligen ítem (ventanas y después applets),
# Enter cambia/restaura o dispara la primaria del applet, Espacio levanta y suelta
# (tilear), Ctrl+←/→ reordena el applet elegido y Esc cancela. La celda "+" abre el
# selector de applets. Devuelve true si lo consumió.
func _frame_key(code, event):
	if shell.apps_view:
		return false  # buscando apps en el Home: el teclado es del buscador
	var items = running()
	var n_app = applets_visible.size()
	var total = items.size() + n_app + 1  # + la celda "+" del selector
	if total <= 1:
		return false
	var over_app = shell.current_activity != null
	if code == KEY_ESCAPE:
		if lifted != null:
			lifted = null
		else:
			set_visible(false)
		shell.request_redraw()
		_gulp(code)
		return true
	if sel < 0 or sel >= total:
		sel = -1
		for i in range(items.size()):
			if _is_current(items[i]):
				sel = i
		if sel < 0:
			sel = 0
	if not event.control and not event.alt and code == KEY_LEFT:
		sel = posmod(sel - 1, total)
	elif not event.control and not event.alt and code == KEY_RIGHT:
		sel = posmod(sel + 1, total)
	elif sel < items.size():
		# Ventana: comportamiento de siempre (cambiar, tilear, minimizar, cerrar).
		if code == KEY_ENTER or code == KEY_KP_ENTER:
			var it = items[sel]
			lifted = null
			switch_to(it)
		elif code == KEY_SPACE and over_app:
			var it = items[sel]
			if lifted == null:
				if it.id >= 0 and not it.minimized:
					lifted = it
			elif lifted.id == it.id:
				lifted = null
			else:
				if it.id >= 0:
					shell._tile_drop(lifted.id, it.id)
				lifted = null
		elif code == KEY_M and over_app:
			if items[sel].id >= 0:
				shell._minimize_window(items[sel].id)
		elif code == KEY_DELETE:
			close(items[sel])
		else:
			return false
	elif sel < items.size() + n_app:
		# Applet: Ctrl+←/→ lo mueve en el orden; Delete lo quita; Enter lo acciona.
		var id = applets_visible[sel - items.size()]
		if event.control and code == KEY_LEFT:
			_applet_move(id, -1)
		elif event.control and code == KEY_RIGHT:
			_applet_move(id, 1)
		elif code == KEY_ENTER or code == KEY_KP_ENTER or code == KEY_SPACE:
			_applet_primary(id)
		elif code == KEY_DELETE:
			_applet_set_visible(id, false)
		else:
			return false
	else:
		# Celda "+": abre el selector de applets (fijar/quitar).
		if code == KEY_ENTER or code == KEY_KP_ENTER or code == KEY_SPACE:
			applet_picker_want = true
		else:
			return false
	shell.request_redraw()
	_gulp(code)
	return true


# Ítem cuyo rect (incluye los botones de minimizar/cerrar) contiene el punto.
func _item_at(pos):
	for it in items_layout:
		if pos.x >= it.x and pos.x < it.x + it.hit_w and pos.y >= it.y and pos.y < it.y + 28.0:
			return it
	return null


# Id del applet bajo el punto (rects del último dibujo del borde inferior).
func _applet_at(pos):
	if not applets_drawn:
		return null
	for it in applets_layout:
		if pos.x >= it.x and pos.x < it.x + it.w and pos.y >= it.y and pos.y < it.y + it.w:
			return it.id
	return null


# Índice de destino al soltar un applet arrastrado, según la x del mouse: la primera
# celda cuyo centro queda a la derecha, o el final.
func _applet_drop_index(x, dragged):
	var n = applets_layout.size()
	var idx = n
	for i in range(n):
		var it = applets_layout[i]
		if it.id == dragged:
			continue
		if x < it.x + it.w * 0.5:
			idx = i
			break
	return idx


func _finish_applet_drag():
	var id = applet_drag
	applet_drag = null
	applet_press = null
	if id == null:
		return
	# Fuera de la franja inferior, cancelar sin alterar la composición.
	var bottom = get_viewport().size.y - FRAME_H
	if mouse_pos.y < bottom or mouse_pos.y >= bottom + FRAME_H:
		shell.request_redraw()
		return
	var to = _applet_drop_index(mouse_pos.x, id)
	var from = applets_visible.find(id)
	if from >= 0:
		applets_visible.remove(from)
		if to > from:
			to -= 1
		to = int(clamp(to, 0, applets_visible.size()))
		applets_visible.insert(to, id)
		applets_dirty = true
		_save_applets()
	shell.request_redraw()


# Suelta del arrastre: sobre otra ventana tilea; fuera, la vuelve a pantalla completa.
func _finish_drag():
	var target = _item_at(mouse_pos)
	if target != null and target.id >= 0 and not target.minimized and target.id != dragging.id:
		shell._tile_drop(dragging.id, target.id)
	else:
		shell._untile_window(dragging.id)
	shell.request_redraw()


# Super+arrastre: si se suelta sobre la barra del Frame, mueve la ventana a ese lugar
# (reordena la franja); si no, cancela.
func _finish_win_drag():
	var dragged = win_drag.id
	win_drag = null
	shell.window_dragging = false
	if mouse_pos.y <= FRAME_H:
		var t = _frame_insert_target(mouse_pos.x)
		if t != null:
			shell._move_window_to(dragged, t.id, t.before)
	shell.request_redraw()


# Ítem del Frame bajo una x (coords de pantalla): dónde insertar al soltar, y si va
# antes o después de ese ítem. Ignora actividades de script (id < 0).
func _frame_insert_target(x):
	var last = null
	for it in items_layout:
		if it.id < 0:
			continue
		last = it
		if x >= it.x and x <= it.x + it.hit_w:
			return {"id": it.id, "before": x < it.x + it.w * 0.5}
	if last != null:
		return {"id": last.id, "before": false}
	return null


func _arrow_dir(code):
	if code == KEY_LEFT:
		return -1
	if code == KEY_RIGHT:
		return 1
	if code == KEY_UP:
		return -2
	if code == KEY_DOWN:
		return 2
	return 0


# Borde inferior retráctil: bloques cuadrados de applets + la celda "+" que abre el
# selector para fijar/quitar. `off` es el mismo deslizamiento que la barra superior.
func _draw_applets(ui, vp, off, mouse):
	applets_layout = []
	applet_picker_open = false
	var by = vp.y - FRAME_H - off
	ui.set_next_window_pos(Vector2(0.0, by), true)
	ui.set_next_window_size(Vector2(vp.x, FRAME_H), true)
	var flags = ui.WINDOW_NO_DECORATION | ui.WINDOW_NO_MOVE | ui.WINDOW_NO_SAVED_SETTINGS | ui.WINDOW_NO_SCROLLBAR
	if not ui.begin("##frame_bottom", flags):
		ui.end()
		return
	var n = applets_visible.size()
	var step = APPLET + APPLET_PAD
	var total_w = n * step + ADD_W + APPLET_PAD
	var x = max(PAD, vp.x - PAD - total_w)
	var y = (FRAME_H - APPLET) * 0.5
	var n_items = running().size()
	for i in range(n):
		var id = applets_visible[i]
		var pos = Vector2(x + i * step, y)
		ui.set_cursor_pos(pos)
		var o = ui.get_cursor_screen_pos()
		applets_layout.append({"id": id, "x": o.x, "y": o.y, "w": APPLET})
		_draw_applet(ui, id, pos, o, visible and (n_items + i) == sel and applet_drag == null, mouse)
	# Celda "+": abre la lista de controles (fijar/quitar), pulsable con mouse o teclado.
	var add_x = x + n * step
	ui.set_cursor_pos(Vector2(add_x, y))
	var add_scr = ui.get_cursor_screen_pos()
	if ui.button("+##applets_add", Vector2(ADD_W, APPLET)) or applet_picker_want:
		applet_picker_want = false
		ui.open_popup("##applets_add")
	if visible and sel == n_items + n:
		_draw_outline(ui, Rect2(add_scr, Vector2(ADD_W, APPLET)), Color(1.0, 0.85, 0.35, 0.95))
	if ui.begin_popup("##applets_add"):
		applet_picker_open = true
		ui.text_disabled("Controles del Frame")
		for a in APPLETS:
			if ui.menu_item(a.name, "", applets_visible.has(a.id)):
				_applet_set_visible(a.id, not applets_visible.has(a.id))
		ui.end_popup()
	if applet_action_want != "":
		ui.open_popup("##applet_" + applet_action_want)
		applet_action_want = ""
	if ui.begin_popup("##applet_bluetooth"):
		ui.text_disabled("Bluetooth")
		if ui.menu_item("Dispositivos…"):
			_applet_primary("bluetooth")
		if bluetooth.state == "activo" or bluetooth.state == "apagado":
			if ui.menu_item("Apagar radio" if bluetooth.state == "activo" else "Encender radio"):
				bluetooth.toggle_power()
				shell.request_redraw()
		ui.text_disabled(bluetooth.detail)
		ui.end_popup()
	if ui.begin_popup("##applet_teclado"):
		ui.text_disabled("Distribución · próxima sesión")
		for layout in ["es", "latam", "us"]:
			if ui.menu_item({"es":"Español (ES)", "latam":"Latinoamericano (LAT)", "us":"Inglés (US)"}[layout]):
				keyboard.choose(layout)
				shell.request_redraw()
		ui.text_disabled(keyboard.detail)
		ui.end_popup()
	# Marca vertical del destino mientras se arrastra un applet (Esc cancela).
	if applet_drag != null:
		var to = _applet_drop_index(mouse.x, applet_drag)
		var mx = applets_layout[to].x if to < applets_layout.size() else add_scr.x
		ui.imgui_draw_rect_filled(Rect2(mx - 1.0, add_scr.y, 2.0, APPLET), Color(1.0, 0.85, 0.35, 0.95), 0.0)
	ui.end()
	applets_drawn = true


# Un applet: relleno y contorno según estado, etiqueta y valor textuales (nunca sólo
# color) y barra proporcional cuando hay medición. Tooltip con el nombre completo.
func _draw_applet(ui, id, pos, scr, is_sel, mouse):
	var a = _applet_def(id)
	if a == null:
		return
	var state = _applet_state(id)
	ui.set_cursor_pos(pos)
	var rect = Rect2(scr, Vector2(APPLET, APPLET))
	var fill = Color(1, 1, 1, 0.10)
	var line = Color(1, 1, 1, 0.22)
	if state == "activo":
		fill = Color(0.35, 0.75, 1.0, 0.26)
		line = Color(0.55, 0.85, 1.0, 0.9)
	elif state == "apagado":
		fill = Color(1, 1, 1, 0.05)
	elif state == "sin_dato":
		fill = Color(1, 1, 1, 0.03)
		line = Color(1, 1, 1, 0.28)
	elif state == "cambiando":
		line = Color(1.0, 0.85, 0.35, 0.95)
	elif state == "error" or state == "no_disponible":
		line = Color(0.95, 0.55, 0.3, 0.9)
	if is_sel:
		line = Color(1.0, 0.85, 0.35, 0.95)
	ui.imgui_draw_rect_filled(rect, fill, 3.0)
	_draw_outline(ui, rect, line)
	var pct = _applet_pct(id)
	if pct >= 0.0:
		var b = Rect2(rect.position + Vector2(3.0, rect.size.y - 5.0), Vector2((rect.size.x - 6.0) * pct, 3.0))
		ui.imgui_draw_rect_filled(b, Color(0.35, 0.8, 1.0, 0.9), 1.0)
	ui.set_cursor_pos(pos + Vector2(4.0, 3.0))
	ui.text_disabled(a.short)
	ui.set_cursor_pos(pos + Vector2(4.0, 22.0))
	ui.text(_applet_value(id))
	if mouse.x >= rect.position.x and mouse.x < rect.end.x and mouse.y >= rect.position.y and mouse.y < rect.end.y:
		ui.begin_tooltip()
		ui.text(a.name)
		ui.text_disabled("estado: " + state)
		if id == "bluetooth":
			ui.text(bluetooth.detail)
		elif id == "teclado":
			ui.text(keyboard.detail)
		ui.end_tooltip()


func _draw_outline(ui, rect, color):
	var p = PoolVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	ui.imgui_draw_polyline(p, color, 2.0, true)


func _user_name():
	var user = OS.get_environment("USER")
	if user == "":
		user = OS.get_environment("LOGNAME")
	if user == "":
		user = "user"
	return user


func _identity_width(ui):
	return ID_BADGE_ICON + ID_BADGE_GAP + float(_user_name().length()) * 7.0 * ui.get_imgui_scale()


# Insignia fija de identidad en la barra superior: placa tenue, figura XO cacheada
# (rasterizada por el shell, ver identity_tex) y nombre de usuario. Sin acción por ahora.
func _draw_identity(ui, x, y):
	var user = _user_name()
	var w = _identity_width(ui)
	# Placa tenue: se dibuja en coords de pantalla (como los applets), así sigue
	# al Frame mientras desliza.
	ui.set_cursor_pos(Vector2(x - ID_BADGE_PAD, y - 2.0))
	ui.imgui_draw_rect_filled(Rect2(ui.get_cursor_screen_pos(), Vector2(w + ID_BADGE_PAD * 2.0, 32.0)), Color(1, 1, 1, 0.07), 6.0)
	var icon = shell.identity_tex()
	if icon != null:
		ui.set_cursor_pos(Vector2(x, y + (28.0 - ID_BADGE_ICON) * 0.5))
		ui.image(icon, Vector2(ID_BADGE_ICON, ID_BADGE_ICON))
	ui.set_cursor_pos(Vector2(x + ID_BADGE_ICON + ID_BADGE_GAP, y + 7.0))
	ui.text_colored(Color(0.90, 0.91, 0.94, 1.0), user)


# Llamado en cada imgui_frame del shell, después de la vista.
func draw(ui):
	# Otra vez tras dibujar la vista: lo que cambió en este frame (un clic que abre
	# una app, la primera textura) arranca el fundido ya, sin un frame a opacidad plena.
	transition()
	# En pantalla completa el Frame no existe (Alt+F11 vuelve).
	if shell.fullscreen_id >= 0:
		visible = false
		drawn = false
		items_layout = []
		applets_layout = []
		applets_drawn = false
		return
	var home = shell.current_activity == null
	var mouse = ui.get_mouse_pos()
	var now = OS.get_ticks_msec()
	var vp = ui.get_viewport_rect().size
	# MousePos es -FLT_MAX hasta el primer movimiento: eso no es la esquina.
	var hot = mouse.y >= 0.0 and (mouse.y <= EDGE or mouse.y >= vp.y - EDGE or (mouse.x >= 0.0 and mouse.x <= CORNER and mouse.y <= CORNER))
	if hot:
		if corner_since == 0:
			corner_since = now
		if corner_since > 0:
			var left = HOT_MS - (now - corner_since)
			if left <= 0:
				if not visible:
					set_visible(true)
					entered = true
			elif not hot_timer:
				# Sin input no hay frames: un timer pide el que vuelve a mirar al cumplirse HOT_MS.
				hot_timer = true
				get_tree().create_timer(left / 1000.0).connect("timeout", self, "_hot_wake")
	else:
		corner_since = 0
	if visible and not home:
		# La barra inferior cuenta como parte del Frame: el mouse ahí no lo auto-oculta.
		if mouse.y <= FRAME_H or mouse.y >= vp.y - FRAME_H:
			entered = true
		elif entered and mouse.y > FRAME_H + 16.0 and mouse.y < vp.y - FRAME_H \
				and dragging == null and lifted == null and win_drag == null \
				and applet_drag == null and applet_press == null and now > show_until:
			set_visible(false)
		elif show_until > 0 and now > show_until:
			# Frame mostrado por Alt+Tab: se oculta solo al terminar la gracia.
			set_visible(false)
			show_until = 0

	items_layout = []
	var off = _slide(visible or home, now)
	drawn = off > -FRAME_H
	if not drawn:
		applets_layout = []
		applets_drawn = false
		return

	ui.set_next_window_pos(Vector2(0.0, off), true)
	ui.set_next_window_size(Vector2(vp.x, FRAME_H), true)
	var flags = ui.WINDOW_NO_DECORATION | ui.WINDOW_NO_MOVE | ui.WINDOW_NO_SAVED_SETTINGS | ui.WINDOW_NO_SCROLLBAR
	var chosen = null
	var to_close = null
	var to_minimize = null
	if ui.begin("##frame", flags):
		var y = 10.0
		ui.set_cursor_pos(Vector2(PAD, y))
		if ui.button("Inicio", Vector2(90, 28)):
			set_visible(false)
			shell._go_home()

		# Insignia de identidad: figura XO + usuario, a la derecha de Inicio. Por ahora
		# no tiene acción (no captura input: sólo se dibuja).
		var badge_x = PAD + 90.0 + PAD
		_draw_identity(ui, badge_x, y)
		var badge_w = _identity_width(ui)

		var items = running()
		# La selección recorre las ventanas y después los applets (y la celda "+").
		var app_total = items.size() + applets_visible.size() + 1
		if sel < 0 or sel >= app_total:
			sel = -1
			for i in range(items.size()):
				if _is_current(items[i]):
					sel = i
			if sel < 0:
				sel = 0
		# Objetivo del arrastre/levantado, para resaltarlo al dibujar.
		var drop_id = -1
		if dragging != null:
			var t = _item_at(mouse_pos)
			if t != null and t.id >= 0 and t.id != dragging.id:
				drop_id = t.id
		elif lifted != null:
			drop_id = lifted.id

		var x = badge_x + badge_w + PAD * 2.0
		var w = ITEM_W
		if items.size() > 0:
			# ponytail: se achican para caber; con muchísimas no hay scroll.
			w = clamp((vp.x - PAD - x) / items.size() - CLOSE_W - MIN_W - PAD, 40.0, ITEM_W)
		var index = 0
		for item in items:
			var current = _is_current(item)
			var label = item.title
			# Número de pantalla compartido por las ventanas de una misma franja: las
			# minimizadas y las internas (screen 0) no lo llevan. No toca `title`.
			if item.screen > 0:
				label = str(item.screen) + " " + label
			var max_chars = int(w / 8.0)
			if label.length() > max_chars:
				label = label.substr(0, max_chars - 2) + ".."
			var is_sel = visible and index == sel and dragging == null
			var is_drop = (item.id >= 0 and item.id == drop_id)
			ui.set_cursor_pos(Vector2(x, y))
			if current:
				ui.push_style_color(ui.COL_BUTTON, Color(0.26, 0.59, 0.98, 0.9))
			elif is_drop:
				ui.push_style_color(ui.COL_BUTTON, Color(0.98, 0.65, 0.20, 0.95))
			elif is_sel:
				ui.push_style_color(ui.COL_BUTTON, Color(0.45, 0.45, 0.50, 0.95))
			elif item.minimized or (item.id >= 0 and item.screen == 0):
				ui.push_style_color(ui.COL_TEXT, Color(0.6, 0.6, 0.6, 1.0))
			if ui.button(label + "##" + item.key, Vector2(w, 28)):
				chosen = item
			if current or is_drop or is_sel or item.minimized or (item.id >= 0 and item.screen == 0):
				ui.pop_style_color()
			var min_x = x + w + 2.0
			var close_x = min_x + MIN_W
			ui.set_cursor_pos(Vector2(min_x, y))
			if ui.button("-##m" + item.key, Vector2(MIN_W - 2.0, 28)):
				to_minimize = item
			ui.set_cursor_pos(Vector2(close_x, y))
			if ui.button("x##c" + item.key, Vector2(CLOSE_W - 4.0, 28)):
				to_close = item
			items_layout.append({"title": item.title, "id": item.id, "current": current,
				"minimized": item.minimized, "screen": item.screen, "x": x, "y": y + off,
				"w": w, "min_x": min_x, "close_x": close_x,
				"hit_w": w + MIN_W + CLOSE_W - 2.0})
			x += w + MIN_W + CLOSE_W + PAD
			index += 1

		# El reloj y CPU/MEM/SWP viven como applets en el borde inferior.

		# Chip flotante mientras se arrastra, se levanta o se mueve una ventana con Super.
		var ghost = dragging if dragging != null else lifted
		var ghost_title = ghost.title if ghost != null else ""
		if win_drag != null:
			for it in items:
				if it.id == win_drag.id:
					ghost_title = it.title
					break
		if ghost_title != "":
			ui.begin_tooltip()
			ui.text(ghost_title)
			ui.end_tooltip()
	ui.end()

	_draw_applets(ui, vp, off, mouse)

	if chosen != null:
		switch_to(chosen)
	elif to_minimize != null:
		if to_minimize.id >= 0:
			if to_minimize.minimized:
				shell._restore_window(to_minimize.id)
			else:
				shell._minimize_window(to_minimize.id)
			shell.request_redraw()
	elif to_close != null:
		close(to_close)


func _hot_wake():
	hot_timer = false
	shell.request_redraw()


# Desplazamiento vertical del Frame: 0 quieto a la vista, -FRAME_H fuera. Mientras
# desliza pide frames y mantiene despierto el loop; al terminar deja de pedirlos.
func _slide(want, now):
	if want and slide_instant:
		slide_instant = false
		shown = true
		slide_since = now - SLIDE_MS
		return 0.0
	if want != shown:
		shown = want
		# Si cambia a mitad de camino, sigue desde donde está.
		var done = min(now - slide_since, SLIDE_MS)
		slide_since = now - (SLIDE_MS - done)
	var k = clamp(float(now - slide_since) / SLIDE_MS, 0.0, 1.0)
	if k < 1.0:
		shell.request_redraw()
		shell.last_activity = now
	var p = 1.0 - pow(1.0 - k, 3.0)
	if not shown:
		p = 1.0 - p
	return -FRAME_H * (1.0 - p)


# Cambio de vista (Home <-> app, anillo <-> grilla, entre apps): fundido de FADE_MS
# y, en la vista wayland, zoom leve desde el centro. Devuelve el alfa para ImGui.
# Sólo toca nodos mientras dura: en reposo no hay nada que redibujar.
const FADE_MS = 320
var view_key = ""
var fade_since = 0
var fading = false


func transition():
	var now = OS.get_ticks_msec()
	var key = "home:" + str(shell.apps_view)
	if shell.current_activity != null:
		if shell.current_activity.has("wayland") and shell.tile_mode:
			# En tiling todas las ventanas están a la vista: enfocar otra no re-funde todo.
			key = "tiles"
		else:
			# Una app nueva cambia de clave otra vez al llegar su primera textura.
			key = shell.current_activity.name + ":" + str(shell.tex_ready_frame >= 0)
	if key != view_key:
		view_key = key
		fade_since = now
		fading = true
	if not fading:
		return 1.0
	var k = clamp(float(now - fade_since) / FADE_MS, 0.0, 1.0)
	var a = 1.0 - pow(1.0 - k, 3.0)
	if k < 1.0:
		shell.request_redraw()
		shell.last_activity = now
	else:
		fading = false
	var v = shell.view
	v.rect_pivot_offset = v.rect_size * 0.5
	var z = lerp(0.94, 1.0, a)
	v.rect_scale = Vector2(z, z)
	# Las capas usan alfa premultiplicado: se escala también el color.
	v.modulate = Color(a, a, a, a)
	return a
