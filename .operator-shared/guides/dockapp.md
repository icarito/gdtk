# Guía — Cómo hacer una dockapp (applet del Frame)

Una dockapp es un bloque cuadrado de la barra del Frame (estilo Window Maker) con un
estado y un valor: la persona la agrega con clic derecho → selector de controles, la
ordena arrastrando y queda guardada en `~/.config/gdtk/frame-applets.json`.
Reglas de producto y estados: `specs/SPEC-sugar-frame-applets.md`. Reglas generales:
`specs/SPEC-architecture.md`. Ejemplo completo y verificado: **Portapapeles**
(`shell/applet_clipboard.gd`), que se usa como hilo conductor.

## 1. El contrato (duck typing, sin clase base)

Un archivo `shell/applet_<x>.gd` que `extends Reference` y expone:

| miembro | qué es | quién lo usa |
|---|---|---|
| `var state` | `activo`, `listo`, `apagado`, `cambiando`, `sin_dato`, `no_disponible`, `error` | contorno y color de la tesela |
| `var value` | texto corto (cabe en ~40 px) | dibujo genérico / tu `draw` |
| `var detail` | texto largo; si no es `""` es el tooltip al pasar el mouse | Frame |
| `func refresh(force := false) -> bool` | copia el snapshot del worker; `true` si cambió algo (pide redibujo). Arranca el worker en la primera llamada | Frame, ~cada frame mientras la barra está a la vista |
| `func stop()` | detiene el worker (`wait_to_finish`) | Frame al salir del árbol |
| `func draw(frame, ui, scr, loc, w, h)` *(opcional)* | dibuja dentro de la placa; `scr` = coords de pantalla (draw list), `loc` = coords locales (`set_cursor_pos`). `frame` presta helpers: `_draw_shared_glyph`, `_push_label_font`, `_truncate_w`, `_text_w`, `NX_TEXT`, `NX_TEXT_DIM` | Frame |

Sin `draw`, el Frame pinta `short` arriba y `value` centrado.

**Regla dura:** `refresh()` y `draw()` corren en el hilo de render: nada de
`OS.execute`, lectura de archivos ni `/proc` ahí. Eso va en el worker.

## 2. Registrarla (dos líneas en `shell/frame.gd`)

```gdscript
const APPLETS = [
	...
	{"id": "portapapeles", "name": "Portapapeles", "short": "CLIP"},   # "span": 2 si ocupa 2 celdas
]
...
var clipboard = Host.sc("res://applet_clipboard.gd").new()   # Host.sc: se recarga en caliente
var applet_mods = {"teclado": keyboard, "portapapeles": clipboard}
```

Con eso el Frame ya: la ofrece en el selector, la guarda/ordena, la refresca sólo si
está visible y la barra a la vista (`applets_live`), la para al salir, muestra el
tooltip y llama a tu `draw`. El `id` es estable: queda escrito en la config del usuario.
No la agregues a `APPLET_DEFAULT` salvo pedido explícito (cambia el Frame de todos).

Si necesita algo del shell (como el socket del compositor), el Frame se lo asigna en
`_ready()`; el módulo no toca `shell`. Usar `Host.compositor`, no `shell.compositor`:
el `_ready` del Frame corre antes que los `onready` de `shell.gd`.

## 3. El worker (copiar la forma, no inventar otra)

```gdscript
var _mutex = Mutex.new()
var _thread = null
var _want_stop = false
var _snap = {"state": "sin_dato", "value": "", "detail": ""}

func refresh(_force := false):
	if _thread == null:
		_thread = Thread.new()
		_thread.start(self, "_work", _paths())   # datos resueltos en el hilo principal
	_mutex.lock(); var s = _snap; _mutex.unlock()
	var changed = state != s.state or value != s.value or detail != s.detail
	state = s.state; value = s.value; detail = s.detail
	return changed

func _work(p):
	while not _stopped():
		var snap = ...            # acá sí: OS.execute, File, Directory
		_mutex.lock(); _snap = snap; _mutex.unlock()
		# dormir en pasos de 100 ms mirando _stopped(), para que stop() no espere
```

- Período: ≥ 1 s para lecturas baratas; ≥ 5 s si lanza procesos (el X200 es lento).
- Fallo repetido → `no_disponible` con el motivo en `detail`, y dejar de reintentar.
- `OS.execute` en Godot 3 trae `output=[]` por defecto → usa popen y **espera EOF**:
  un hijo en segundo plano que herede stdout cuelga la llamada. Redirigir siempre
  (`</dev/null >>log 2>&1 &`). Para desacoplar un proceso largo: `sh -c '… &'`.

## 4. Datos que vienen de fuera: un script en `session/`

Si la fuente es un proceso de larga vida (un vigía), escribirlo como script POSIX en
`session/` e idempotente por `flock`, y que el applet sólo **lea** lo que ese script
deja. Portapapeles: `session/gdtk-clipboard watch <socket>` deja vivo
`wl-paste --watch` contra el compositor embebido (protocolo `ext-data-control-v1`,
habilitado en `modules/wayland/wl_server.c`); cada copia se guarda como un archivo en
`$XDG_RUNTIME_DIR/gdtk/clipboard` (0700, se borra al cerrar sesión, tope 50, descarta lo
marcado como sensible). Al agregar un script en `session/`, sumarlo a la lista de
`deploy.sh` (copia esos archivos uno por uno).

## 5. Test y verificación

1. Test de lo puro (`tests/applet_<x>_test.gd`, `extends SceneTree`, `check()`,
   `OS.exit_code`). Portapapeles: `summary()`, `newest()` y la ruta del script.
2. Parseo con el binario instalado: agregar el script a `tests/parse_check.gd`.
3. e2e sin tocar la sesión: `XDG_RUNTIME_DIR` propio y corto, compositor del autoload
   `Host` (uno solo por proceso: dos compositores en el mismo proceso fallan de forma
   intermitente), `wl-copy` hacia ese socket y leer el snapshot del applet.
4. Visual: sync a `~/gdtk`, agregar el bloque desde el selector y capturar. Si el
   applet necesita un protocolo nuevo del compositor, además recompilar e instalar el
   motor (`AGENTS.md` → Build y deploy).

## Checklist

- [ ] `shell/applet_<x>.gd` con `state/value/detail/refresh/stop` (+ `draw`)
- [ ] entrada en `APPLETS` + línea en `applet_mods`
- [ ] worker fuera del hilo de render; estados honestos
- [ ] scripts de `session/` también en `deploy.sh`
- [ ] test puro + `parse_check.gd`
- [ ] fila en la tabla de `SPEC-sugar-frame-applets.md`
