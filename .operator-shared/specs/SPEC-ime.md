# SPEC — IME y teclado en pantalla (K14)

Estado: **parche entregado, sin desplegar**. Sólo se agrega el relay al módulo
Wayland; recompilar el motor es tarea de `deploy.sh`/scons y queda pendiente por
la regla "NO desplegar" de K14.

## Qué es IME aquí

IME = componente que convierte teclas en texto complejo: composición de
chino/japonés/coreano, teclas muertas avanzadas, emoji, predicción y teclados en
pantalla (X200 Tablet). En Wayland se implementa con dos protocolos:

- `text-input-v3` — el cliente (campo de texto) pide insumo de texto.
- `input-method-v2` — el motor IME (fcitx5, ibus, squeekboard/maliit) ofrece texto.

Para es_PE las teclas muertas de XKB ya bastan; el IME importa para CJK, emoji y
tablet.

## Cambios

Todos en `modules/wayland/wl_server.c` (C, wlroots 0.20, `WLR_USE_UNSTABLE` ya
definido por `SCsub`). No se cambió la API pública (`wl_server.h`): no hace falta
tocar el lado Godot para el relay mínimo.

1. **Globals nuevos** en `wl_server_create`:
   - `wlr_text_input_manager_v3_create(display)` — anuncia `text-input-v3`.
   - `wlr_input_method_manager_v2_create(display)` — anuncia `input-method-v2`.
   Si alguno falla se loguea y el resto del servidor sigue igual (el IME es
   opcional, no tumba la sesión).

2. **Relay mínimo** (struct `text_input_relay` + handlers):
   - `new_text_input`: registra `enable/commit/disable/destroy` por text-input.
   - `enable`: activa el motor (`wlr_input_method_v2_send_activate`) y le manda
     `surrounding_text`/`content_type` + `done` si el cliente los soporta.
   - `commit`: reenvía el estado actualizado al motor (refinar candidato).
   - `disable`/`destroy`: desactiva el motor y libera el nodo.
   - `new_input_method`: acepta **un** motor IME; un segundo recibe
     `send_unavailable`. Registra `commit`, `grab_keyboard`, `destroy`.
   - `input_method commit`: reenvía `preedit_string`, `commit_string` y
     `delete_surrounding_text` al text-input enfocado, luego `done`.
   - `grab_keyboard`: entrega el keymap y modificadores del teclado virtual
     (`s->keyboard`) al grab del motor.

3. **Foco**: `toplevel_apply_focus` llama a `text_input_relay_set_focus(s,
   surface)`. Como text-input-v3 es por cliente, entra en los text-input del
   mismo cliente que la surface enfocada y sale (`send_leave`) del resto.

4. **Teclado durante grab**: `wl_server_key` detecta `s->keyboard_grab` y reenvía
   tecla + modificadores al grab (`wlr_input_method_keyboard_grab_v2_send_key`)
   en vez del seat; así el motor ve la composición y decide qué commitear.

5. **Teardown**: en `wl_server_destroy` se quitan los listeners de managers y, tras
   `wl_display_destroy_clients`, una red de seguridad libera text-inputs, input
   method y grab restantes.

## Compilación (verificación hecha)

Compila limpio contra wlroots 0.20.2 sin tocar el resto del árbol:

```sh
gcc -fsyntax-only -DWLR_USE_UNSTABLE \
  $(pkg-config --cflags wlroots-0.20 libeis-1.0 libsystemd) \
  -I modules/wayland modules/wayland/wl_server.c
# rc=0

gcc -c -o /tmp/wl_server_ime.o -DWLR_USE_UNSTABLE \
  $(pkg-config --cflags wlroots-0.20 libeis-1.0 libsystemd) \
  -I modules/wayland modules/wayland/wl_server.c
# rc=0, sin warnings
```

Recompilar el motor real (sin desplegar): `deploy.sh` / scons del fork, que ya
usa `pkg-config wlroots-0.20`.

## Prueba manual (opcional, con hardware)

No hay test C del módulo en el repo; la verificación entregada es de compilación.
Prueba sugerida en un VT de gdtk (requiere motor IME instalado):

1. Lanzar un motor `input-method-v2`: `fcitx5` (o `ibus-daemon -drx`) con el
   backend Wayland apuntando a la sesión gdtk (`WAYLAND_DISPLAY` del shell).
2. Abrir un cliente GTK/Qt con campo de texto (p. ej. `gtk3-demo` o el editor de
   gdtk) y probar:
   - es_PE latam: teclas muertas (`´` + vocal) ya las resuelve XKB.
   - CJK: activar fcitx5 y componer; verificar que aparece el **preedit** y luego
     el **commit** en el campo.
   - Emoji: seleccionar desde el motor y confirmar que se inserta.
3. Teclado en pantalla (X200/tablet): un motor con `input-method-v2` (p. ej.
   squeekboard) debe tomar el grab; al tipear debe llegar el caracter.
4. Cortar el motor (`fcitx5 -e`/matar el proceso) no debe tumbar el shell ni dejar
   el teclado del cliente trabado: el text-input queda simplemente inactivo.

## Limitaciones conocidas (fase siguiente)

- No se relaya `input-popup-surface-v2` (posición del popup de candidatos):
  `new_popup_surface` no se escucha. En motores que dibujan popups propios puede
  verse descolocado; fcitx5 suele componer en su propia ventana.
- Un único motor IME a la vez (el segundo recibe `unavailable`).
- No se cubre `text-input-v1` (legacy) ni X11 IME (`XIM`), que va por Xwayland.
