# SPEC — Paso 6: control remoto del shell (JSON-RPC + puente MCP)

Objetivo: que un agente (Claude Code en otra máquina, vía ssh) pueda **ver y manejar** el shell en
marcha: estado, abrir actividades, lanzar apps, capturar pantalla, hacer clic y teclear. Idea tomada
de gpty (JSON-RPC + MCP), sin su código. Mínimo que funcione. Leer antes: `shell/shell.gd`,
`shell/shell.tscn`, `modules/wayland/wayland_compositor.h`, `session/*`, `deploy.sh`.

## Reglas (igual que antes)

- Repo `/run/media/icarito/DATA/icarito/Proyectos/gdtk`. **No hace falta recompilar el motor** (todo es
  GDScript + Python). No tocar el árbol de Godot ni el fork. `git add` por nombre (hay un archivo ajeno
  sin trackear en `shell/`). Sin push. No investigar la config de zsh del usuario.

## 1. Servidor en el shell: `shell/remote.gd` (Node hijo de la raíz en `shell.tscn`, nombre "Remote")

- `TCP_Server.listen(port, "127.0.0.1")`, `port` = env `GDTK_CONTROL_PORT` o 7777. **Sólo localhost**:
  el acceso remoto es por ssh.
- **Token**: al arrancar generar 32 hex aleatorios (`Crypto.new().generate_random_bytes(16).hex_encode()`),
  escribirlo en `$XDG_RUNTIME_DIR/gdtk-control.token` (ese dir es 0700 del usuario; si la env falta,
  no abrir el servidor y loguear por qué). Borrarlo al salir (`NOTIFICATION_WM_QUIT_REQUEST`/`_exit_tree`).
- Protocolo: **JSON-RPC 2.0, un objeto por línea** (`\n`), sobre cada conexión aceptada en `_process`
  (varias conexiones a la vez está bien; buffer por conexión hasta `\n`). La primera llamada debe ser
  `auth {token}`; cualquier otra antes → error `-32001 "unauthorized"` y cerrar.
- Métodos (params en objeto; errores JSON-RPC estándar):
  - `auth {token}` → `true`
  - `state` → `{"view": "home"|<nombre actividad>, "viewport": [w,h], "wayland_socket": s,
     "windows": [{"id", "title", "activity"}], "activities": [<nombres>]}`
  - `open {name}` → abre la actividad como si se tocara en el anillo (reusar `_activate`/`_open_by_name`)
  - `home` → vuelve al home (como "Inicio")
  - `launch {cmd, args?: []}` → `compositor.launch`; agrega en caliente una actividad wayland
    `{"name": cmd, "wayland": [cmd]}` si no existe (aparece en el anillo) y la abre. Devuelve `pid`.
  - `close_window {id}` → `compositor.close(id)`
  - `screenshot {max_width?: 1280}` → `{"png_base64": ...}`: `get_viewport().get_texture().get_data()`,
    `flip_y()`, reescalar si es más ancho que `max_width`, `save_png_to_buffer()`, `Marshalls.raw_to_base64`.
  - `click {x, y, button?: 1, double?: false}` → mover + press + release vía `Input.parse_input_event`
    (`InputEventMouseMotion` y `InputEventMouseButton` con `position` y `global_position`), así pasa por
    ImGui y por la vista wayland exactamente como un clic real.
  - `move {x, y}` → sólo motion.
  - `scroll {x, y, dy}` → wheel up/down (`BUTTON_WHEEL_UP/DOWN`, press+release, |dy| veces).
  - `type {text}` → por cada carácter un `InputEventKey` press+release con `unicode` y `scancode`/
    `physical_scancode` (`OS.find_scancode_from_string` para letras/dígitos/espacio; `\n` → Enter),
    vía `Input.parse_input_event`. Mayúsculas: shift en `shift` del evento.
  - `key {combo}` → p.ej. `"Enter"`, `"Escape"`, `"ctrl+c"`, `"alt+Tab"`: modificadores + tecla con
    `OS.find_scancode_from_string`; press+release.
  - `quit` → `get_tree().quit()`
  - No agregar nada que ejecute código arbitrario (nada de eval).
- Encolar los eventos sintéticos de a uno por frame si hace falta para que ImGui los vea (ImGui procesa
  la cola de eventos por frame; un press+release en el mismo frame puede perderse: en ese caso
  press en un frame, release en el siguiente).

## 2. Puente MCP: `mcp/gdtk_mcp.py` (Python 3, **sólo stdlib**)

- Servidor MCP por **stdio** (JSON-RPC 2.0 por líneas): `initialize` (responder `protocolVersion`
  igual al que pide el cliente, `capabilities: {"tools": {}}`, `serverInfo: {"name": "gdtk"}`),
  `notifications/initialized` (sin respuesta), `tools/list`, `tools/call`, `ping`. Logs a stderr.
- Una tool por método del shell: `gdtk_state`, `gdtk_open`, `gdtk_home`, `gdtk_launch`,
  `gdtk_close_window`, `gdtk_screenshot`, `gdtk_click`, `gdtk_move`, `gdtk_scroll`, `gdtk_type`,
  `gdtk_key`, con `inputSchema` JSON Schema correcto y descripciones en inglés breves.
  (`quit` NO se expone.)
- Cada `tools/call`: conectar a `127.0.0.1:$GDTK_CONTROL_PORT|7777`, leer el token de
  `$XDG_RUNTIME_DIR/gdtk-control.token` (si `XDG_RUNTIME_DIR` no está: `/run/user/<uid>`), `auth`,
  llamar, cerrar. Timeout 10 s. Si el shell no corre → resultado con `isError: true` y texto claro.
- `gdtk_screenshot` devuelve contenido `{"type": "image", "data": <base64>, "mimeType": "image/png"}`;
  las demás, `{"type": "text", "text": <json>}`. Tras `click`/`type`/`key`/`open`/`launch`/`home`,
  esperar 300 ms antes de responder (para que un screenshot siguiente ya vea el efecto).
- Uso previsto desde la otra máquina:
  `claude mcp add gdtk -- ssh -T icarito@192.168.18.163 python3 gdtk/mcp/gdtk_mcp.py`

## 3. Deploy

`deploy.sh`: agregar `rsync -a "$GDTK/mcp" "$HOST:gdtk/"` junto a los otros rsync.

## Verificación (obligatoria)

`tests/control_test.sh` que:
1. Arranca el shell en cage anidado en background con el binario FRT
   (`GDTK_GODOT=/home/icarito/Proyectos/godot3-box3d/godot/bin/godot.frt.opt.tools.x86_64.gdtk`,
   `session/gdtk-session &`), espera a que exista el token (tope 30 s).
2. Habla con `mcp/gdtk_mcp.py` por stdio (desde un pequeño driver Python en `tests/`) y ejecuta:
   `initialize` → `tools/list` (≥ 11 tools) → `gdtk_state` (view=home) → `gdtk_open {"name":"Chat"}` →
   `gdtk_click` sobre el campo de texto del chat → `gdtk_type {"text":"hola mcp\n"}` → esperar 1.5 s →
   `gdtk_screenshot` (guardar PNG en `mcp-chat.png`) → `gdtk_home` → `gdtk_launch {"cmd":"es2gears_wayland"}`
   → esperar 3 s → `gdtk_state` (una ventana) → `gdtk_screenshot` (`mcp-gears.png`).
   Para el clic en el chat: coordenada aproximada del input (abajo del historial); ajustarla mirando el PNG.
3. Prueba negativa: conexión TCP directa con token incorrecto → error `-32001`.
4. Cierra el shell (`kill` del proceso cage) y verifica que el token se borró.
Leer los dos PNG y describirlos: `mcp-chat.png` debe mostrar `yo: hola mcp` (y luego la respuesta eco
`bot: hola mcp`); `mcp-gears.png` los engranajes.

Además `./run_shell.sh` y `./run_compositor.sh` siguen pasando.

## Entregable

- Commit `feat(control): JSON-RPC por TCP local con token + puente MCP stdio para manejar el shell`
  terminado en `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`.
- Reporte breve: resultado de cada paso del test, qué muestran los PNG, desvíos, errores literales.
  No modificar README.md ni los SPEC*.md.
