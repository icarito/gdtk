# SPEC — Monitores físicos adicionales (modo «span»)

Concreta la «Fase E» de `SPEC-embedded-multi-output.md` sin esperar varias ventanas nativas en Godot/FRT.

## Decisión
Una sola ventana de Godot **flotante, sin borde, que cubre el rectángulo envolvente de todos los monitores**
(spike 2026-10-04 en sway headless con 2 salidas: `--resolution WxH` sin `--fullscreen` + regla sway
`floating enable, border none, move absolute position 0 0, resize set W H` → ventana en (0,0) y viewport W×H;
**sin cambios de motor**). El viewport es el escritorio completo; el shell lo divide en salidas lógicas.

## Contrato
1. **Salida principal = origen.** El Frame, Hogar, Grupo, Vecindario, Exposé y el mosaico viven SÓLO en la
   principal. Para que sus coordenadas no cambien, la principal queda en (0,0): al entrar en span el anfitrión
   reordena las salidas con `swaymsg output <n> pos x y` (principal en 0,0, el resto a su derecha en orden).
   Principal: `GDTK_SHELL_OUTPUT`, si no la elegida por `session/gdtk-outputs` (externa > interna).
2. **Tamaño de pantalla ≠ tamaño del viewport.** Todo código de UI usa `shell._screen_size()` (tamaño de la
   principal; sin span = `get_viewport_rect().size`). `get_viewport_rect()` sólo sirve para el escritorio
   completo (p. ej. dónde puede flotar una ventana).
3. **Monitores extra = escritorio extendido.** Las ventanas flotantes pueden vivir/arrastrarse a las
   salidas secundarias; allí no hay Frame ni mosaico. Maximizar/pantalla completa usa el rect de la salida
   donde está la ventana (`add_output`/`set_toplevel_output` del compositor embebido, ya existentes).
4. **Hotplug.** Un worker (nunca el render) sondea `swaymsg -t get_outputs -r` y alimenta el modelo puro
   `shell/output_layout.gd`. Al cambiar el envolvente: `swaymsg '[app_id="godot-gdtk"] fullscreen disable,
   floating enable, border none, move absolute position 0 0, resize set W H'`. Con una sola salida activa se
   vuelve a fullscreen. Las ventanas que estaban en una salida retirada vuelven a la principal.
5. **Opt-out.** `GDTK_SPAN=0` mantiene el comportamiento actual (un monitor, fullscreen).
   Implementación 2026-10-05: el ajuste persistente vive en Configuración > Monitores
   (`settings.json` → `span {enabled, primary, order}`; `GDTK_SPAN=1/0` lo fuerza por
   encima). Por el **gate de la Fase 0** (medir el costo antes de activarlo) el ajuste
   arranca apagado por default; tras medir en hardware débil el default pasa a
   encendido. Ver `sessions/2026-10-05_multimonitor-span.md`,
   `settings/pages/monitors.gd` y `bench/span_bench.sh`.
6. Entrada: el puntero cruza solo (una sola superficie). Foco y teclado siguen siendo del shell.

## Verificación
Pura: `tests/output_layout_test.gd` (envolvente, principal, reordenado, hotplug). E2E: sway headless con 2
salidas aisladas (XDG propios, puertos 7790/7791, `GDTK_ISOLATED=1`) en tengu/cupid; jamás la sesión viva.

## Fuera de alcance (v2)
Frame por monitor, escalas distintas por salida, alturas distintas con zonas muertas, wl_output por salida
real hacia los clientes.
