# SPEC — Paso 9: teclado físico real en FRT (guion, Ctrl+letra, AltGr) para el compositor

Síntoma (X200, sesión X11, distribución `es`): en alacritty (dentro del compositor embebido) no
llegan el guion ni los atajos con Ctrl.

Causa (verificada leyendo el código):
- `platform/frt/frt_godot.cc:377-378`: `set_scancode(code); set_physical_scancode(code); // TODO` —
  `code` sale del **keysym** de SDL vía la tabla de `sdl2_godot_map.h` (87 entradas, sin `SDLK_MINUS`
  ni puntuación de otras distribuciones) → el guion llega con código 0 y `WaylandCompositor::key`
  lo descarta. No hay physical_scancode real.
- `sdl2_adapter.h` (`key_event`/`text_event`): para teclas que "requieren unicode" retiene el evento
  hasta el `SDL_TEXTINPUT`; con Ctrl apretado SDL no genera texto → el evento de la `c` de Ctrl+C no
  sale nunca.
- `modules/wayland/wayland_compositor.cpp` (`_scancode_to_evdev`) traduce `physical_scancode` → evdev
  y le faltan teclas (grave, F1–F12, Insert, PgUp/PgDn, CapsLock, teclado numérico, 102nd `<>`,
  AltGr, Ctrl/Shift derechos, Super).

## Rutas y reglas

- gdtk: `/run/media/icarito/DATA/icarito/Proyectos/gdtk` (commits aquí, `git add` por nombre; hay un
  archivo ajeno sin trackear en `shell/`).
- Fork: `/home/icarito/Proyectos/godot3-box3d/godot-box3d-3` (del usuario; ver su `AGENTS.md`). Se
  permite commit local en una rama nueva `feat/frt-physical-scancode`. **Sin push.**
- Árbol del motor: `/home/icarito/Proyectos/godot3-box3d/godot`; `platform/frt` es un checkout
  pineado **ya parcheado** con `patches/frt/*.patch` del fork. El cambio se hace editando
  `platform/frt` en el árbol y se guarda como **parche nuevo** en el fork:
  `patches/frt/zzzzz_sdl_physical_scancode.patch` (orden alfabético = se aplica último), generado con
  `git -C platform/frt diff` **sólo de tus cambios** (hacer `git -C platform/frt stash`/comparar
  contra el estado previo si hace falta: el parche debe aplicar sobre el checkout con los parches
  anteriores ya aplicados, que es como lo usa `scripts/build.sh` del fork). No correr `scripts/build.sh`.
  **Base para el diff**: copia de los archivos de `platform/frt` ANTES de tus cambios en
  `/run/media/icarito/DATA/icarito/Proyectos/gdtk/.frt-baseline/` (frt_godot.cc, sdl2_adapter.h,
  sdl2_godot_map.h, frt.h, platform_config.h, detect.py). Generar el parche con
  `diff -u` de cada archivo base vs. el editado, con rutas `a/<archivo>` y `b/<archivo>` (formato que
  aplica `git apply`/`patch -p1` desde `platform/frt`), y comprobarlo con
  `git -C <copia temporal de platform/frt con la base> apply --check`.
- No usar `pkill -f`/`pgrep -f` con patrones presentes en tu propia línea de comando.
- Build (sólo binarios con sufijo gdtk):
  ```sh
  cd /home/icarito/Proyectos/godot3-box3d/godot
  scons -j8 platform=frt arch=x86_64 target=release_debug tools=yes frt_desktop_gl=yes production=yes lto=none use_static_cpp=no progress=no extra_suffix=gdtk custom_modules=/home/icarito/Proyectos/godot3-box3d/godot-box3d-3,/run/media/icarito/DATA/icarito/Proyectos/gdtk/modules
  ```

## 1. FRT: physical_scancode real

- Pasar el `SDL_Scancode` (`key.keysym.scancode`) junto al keysym hasta `handle_key_event`
  (cambiar la firma de `EventHandler::handle_key_event` en `frt.h` o equivalente y sus llamadas).
- `set_physical_scancode(map_key_sdl2_scancode(scancode))`: tabla nueva en `sdl2_godot_map.h`
  **posicional (teclado US)**: letras `SDL_SCANCODE_A..Z` → `KEY_A..Z`, dígitos, `MINUS`, `EQUALS`,
  `LEFTBRACKET`, `RIGHTBRACKET`, `BACKSLASH`, `NONUSHASH`→`KEY_BACKSLASH`, `SEMICOLON`, `APOSTROPHE`,
  `GRAVE`→`KEY_QUOTELEFT`, `COMMA`, `PERIOD`, `SLASH`, `RETURN`, `ESCAPE`, `BACKSPACE`, `TAB`,
  `SPACE`, `CAPSLOCK`, F1–F12, `PRINTSCREEN`, `SCROLLLOCK`, `PAUSE`, `INSERT`, `HOME`, `PAGEUP`,
  `DELETE`, `END`, `PAGEDOWN`, flechas, keypad (`KP_0..9`, `KP_PERIOD`, `KP_DIVIDE`, `KP_MULTIPLY`,
  `KP_MINUS`, `KP_PLUS`, `KP_ENTER`), `NUMLOCKCLEAR`, `LCTRL/RCTRL`→`KEY_CONTROL`,
  `LSHIFT/RSHIFT`→`KEY_SHIFT`, `LALT`→`KEY_ALT`, `LGUI`→`KEY_SUPER_L`, `RGUI`→`KEY_SUPER_R`,
  `APPLICATION`→`KEY_MENU`.
  Teclas sin constante propia en Godot 3 (hay que poder distinguirlas en el compositor):
  `RALT` (AltGr) → `KEY_HYPER_R`, `NONUSBACKSLASH` (tecla `<>` de teclados ISO) → `KEY_HYPER_L`.
  Documentar esa convención en un comentario en ambos lados (FRT y compositor).
- El `scancode` (lógico) queda como está (keysym), para no cambiar el comportamiento de juegos.
- Ctrl/Super: en `key_event`, si `KMOD_CTRL` o `KMOD_GUI` están activos, **no** esperar el text event:
  emitir el evento de tecla ya (unicode 0). AltGr (`KMOD_RALT` sin Ctrl) sí sigue esperando el texto
  (produce `@`, `#`, etc.).

## 2. Compositor: tabla evdev completa

`_scancode_to_evdev` en `modules/wayland/wayland_compositor.cpp` con todas las teclas de la tabla de
arriba (códigos de `linux/input-event-codes.h`): agregar `KEY_QUOTELEFT`→`KEY_GRAVE`(41), F1–F12,
`KEY_CAPSLOCK`(58), `KEY_INSERT`(110), `KEY_PAGEUP`(104), `KEY_PAGEDOWN`(109), `KEY_PRINT`(99),
`KEY_SCROLLLOCK`(70), `KEY_PAUSE`(119), `KEY_NUMLOCK`(69), keypad (`KEY_KP_0..9`, `KP_PERIOD` 83,
`KP_DIVIDE` 98, `KP_MULTIPLY` 55, `KP_SUBTRACT` 74, `KP_ADD` 78, `KP_ENTER` 96),
`KEY_SUPER_L`(125), `KEY_SUPER_R`(126), `KEY_MENU`(127), `KEY_HYPER_R`→`KEY_RIGHTALT`(100),
`KEY_HYPER_L`→`KEY_102ND`(86). `KP_ENTER` debe ir a 96, no a Enter. Verificar que el keymap xkb del
compositor (distribución de `XKB_DEFAULT_*`) resuelve AltGr (`es`: AltGr+2 = `@`).

## Verificación (obligatoria)

Inyección real por XTest, sin xdotool: script `tests/xtest_keys.py` (Python + `ctypes` sobre
`libX11.so.6` y `libXtst.so.6`: `XOpenDisplay`, `XKeysymToKeycode`, `XTestFakeKeyEvent`, `XFlush`)
que teclea una secuencia de keysyms con modificadores.

1. `Xvfb :97 -screen 0 1280x800x24` + `setxkbmap -display :97 es`; shell con
   `DISPLAY=:97 XKB_DEFAULT_LAYOUT=es GDTK_CONTROL_PORT=7797 session/gdtk-session-x11` (en background).
   Abrir Terminal con el control remoto (puerto 7797) y, con `xtest_keys.py` sobre `:97`, teclear
   `echo a-b_c@d` (el `@` con AltGr+2 en `es`) + Enter → `screenshot` `keys-term.png`: debe verse la
   línea impresa `a-b_c@d`.
2. Teclear `sleep 30` + Enter, luego **Ctrl+C** → `screenshot` `keys-ctrlc.png`: debe verse `^C` y el
   prompt de vuelta.
3. En el Chat (ImGui) teclear `hola-mundo` → `screenshot` `keys-chat.png`: el guion aparece (el
   texto de ImGui usa `unicode`, que no debe romperse).
4. `./run_compositor.sh`, `./run_shell.sh`, `tests/control_test.sh` siguen pasando.
Leer todos los PNG y describirlos.

**Aislamiento del control remoto**: si `GDTK_CONTROL_PORT` está definido, `shell/remote.gd` y
`mcp/gdtk_mcp.py` deben usar el token `$XDG_RUNTIME_DIR/gdtk-control-<port>.token` (sin puerto:
el nombre actual). Así una prueba en otro puerto no pisa el token de una sesión real.

## Entregable

- Fork: commit en la rama `feat/frt-physical-scancode` con el parche nuevo, mensaje
  `feat(frt): physical_scancode real desde el scancode SDL; Ctrl+letra sin esperar texto`.
  Sin push.
- gdtk: commit `fix(keys): tabla evdev completa (AltGr, 102nd, F-keys, keypad) + test XTest; token por puerto`
  terminado en `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`.
- Reporte breve: qué muestran los PNG, desvíos, errores literales. No modificar README.md ni SPEC*.md.
