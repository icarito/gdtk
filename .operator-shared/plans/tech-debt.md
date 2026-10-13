# Deuda técnica

Registro vivo. Cada ítem: síntoma observado → costo → salida propuesta. Borrar el ítem
al resolverlo (el historial queda en git). Prioridad: **A** confunde a agentes o rompe
cosas; **B** frena trabajo; **C** higiene.

## A — Estructura

- **`shell.gd` es un objeto dios (≈9300 líneas).** Hogar, ventanas, Vecindario,
  servicios, Deskflow, gvd, portal, gestos y drag-and-drop en un solo archivo; los
  modelos puros ya se extrajeron, el cableado no. Los agentes editan en conflicto y no
  encuentran dónde va algo. Salida: extraer por área a nodos hijos cargados con
  `Host.sc` (como `frame.gd`, `neighborhood_ui.gd`), empezando por servicios/Deskflow y
  gvd. Un área por cambio, con `parse_check` + tests del área.
- **`frame.gd` (≈4200 líneas) mezcla barras, pines, DockApp de ventanas, Compartiendo y
  applets.** Los applets incorporados (`recursos`, `termico`, `reloj`) siguen como casos
  especiales en `_applet_state/_applet_value/_draw_applet`. Desde 2026-10-04 los
  applets con módulo pasan por `applet_mods` (`guides/dockapp.md`). Salida: mover los
  incorporados a módulos con el mismo contrato cuando se toquen.
## A — Portapapeles y entrada

- **Portapapeles partido en dos.** Las apps viven en el compositor embebido y el shell
  en sway; no hay puente de selección. Copiar en una app interna no llega a clientes de
  sway ni a `OS.get_clipboard()`. Probable (sin verificar): Deskflow, lanzado con el
  entorno del shell, comparte el portapapeles de sway y no el de las apps. Salida: un
  puente con `ext-data-control` en ambos lados (ya está en el embebido) o lanzar
  Deskflow contra el socket embebido; verificar primero.
- **El historial del portapapeles necesita el motor recompilado** (`ext-data-control-v1`
  en `wl_server.c`, 2026-10-04). Con un binario viejo el applet queda `no_disponible`.
- **X11↔Wayland: causa raíz hallada y fija (2026-10-10).** El socket del compositor
  embebido es `wayland-0` (`wayland-1` es sway; medir con el equivocado da un falso
  «no fluye»). El puente sí funciona: con una ventana X11 enfocada, copiar/pegar cruza
  en ambas direcciones. **La falla real: el Xwayland perezoso se apaga al quedarse sin
  clientes X y, al relanzarse, crea una XWM nueva SIN asiento**; sin asiento wlroots
  descarta TODOS los eventos de selección (`not handling selection events: no seat
  assigned to xwayland`) y el puente muere en ambas direcciones hasta reiniciar el
  shell. Fix: re-fijar `wlr_xwayland_set_seat` en cada evento `ready` de Xwayland
  (`modules/wayland/wl_server.c`, `handle_xwayland_ready`). Matiz de wlroots: sólo
  cruza mientras haya una superficie X11 enfocada (puerta de seguridad; se cumple al
  copiar/pegar en la propia app X11). Diagnóstico reproducible con `GDTK_WLR_DEBUG=1`
  (sube el log de wlroots a DEBUG vía env; sin la variable no cambia nada). Verificado
  e2e en instancia anidada: tras forzar el restart lazy, X→W y W→X funcionan y no hay
  líneas `no seat`.

## B — Rendimiento

- **El shell reconstruye toda la UI ImGui por cada commit de ventana visible.** Un commit
  visible pide frame completo (`shell.gd:1496`) y ImGui rearma Frame/Hogar/ventanas (GDScript)
  aunque sólo cambió el contenido de una ventana: CPU alta y techo de FPS con video. Salida:
  *present-only* (marcar el canvas sucio sin rearmar ImGui), P1 de
  `SPEC-rendimiento-compositor.md`. (Frame callbacks atados a la presentación: resuelto 2026-10-05.)
- **Import dmabuf sin explicit sync** (`wl_server_bind_dmabuf`, `SPEC-dmabuf.md` §5): con sync
  implícita el import puede bloquear el hilo principal bajo carga. Salida: `linux-drm-syncobj`.
  **RESUELTO 2026-10-05** (`linux-drm-syncobj-v1` anunciado; espera GPU del acquire y release
  con el buffer; fallback a implicit sync; `GDTK_NO_EXPLICIT_SYNC` para desactivar).
- **Warning de subsurfaces de Firefox (cliente, no compositor).** `Couldn't map window ... as
  subsurface` es bookkeeping de GTK3 al mostrar hijos con el toplevel sin mapear
  (`nsSigHandlers.cpp`); no rompe el render. El compositor no puede arreglarlo. Lo mitigado
  2026-10-05: el ruido propio del shell (`[cursor]`/`[osd-key]`/arrastre) ahora sólo con
  `GDTK_DEBUG_INPUT=1`.
- **Arquitectural: el compositor embebido no tiene CRTC ⇒ sin direct scanout** (`SPEC-compositor.md`
  dec. 3): la ventana activa no puede ir a un plano de hardware, siempre pasa por la textura de
  Godot y la escena del shell. Salida: compositor en hilo/proceso propio o scanout directo (P4).
  **RESUELTO 2026-10-05** (`3b1ad32` puente dmabuf, `ddabd66` activo por defecto, `b67fe49`
  pausa con overlays). Pendiente: sync explícito a sway (hoy implicit sync), Xwayland y salidas
  secundarias, y medir GPU/frame (F0) antes de generalizar.

## B — Pruebas y herramientas

- **`AGENTS.md` lista 7 tests de ≈60.** El runner real es `tools/verify_all.sh` (aislado
  de la sesión). Salida: que `AGENTS.md` remita al runner (hecho) y a correr sólo los
  tests del área.
- **Crash al salir (rc 134/139) con todos los checks en ok**, intermitente, en el binario
  dev y en el instalado (`tests/parse_check.gd` sale 139 también en HEAD).
- **Tests que cargan `shell.gd` cuelgan con el binario dev** (no trae `RemoteInput`),
  p. ej. `tests/ring_frame_test.gd`; `verify_all.sh` lo marca como conocido. Salida:
  que esos tests no instancien `shell.gd` o que corran con el binario instalado.
- **`-s` con el binario instalado carga los autoloads:** `Host` levanta un compositor,
  `RemoteInput` pide el nombre D-Bus del portal (sin reemplazar: falla limpio) y
  `Remote` intenta :7777. No hay lanzador de instancia anidada aislada (lo pide
  `AGENTS.md`). Salida: un flag/env que apague `Remote`/`RemoteInput` en tests.
- **Dos `WaylandCompositor` en un mismo proceso fallan intermitente** (el segundo a
  veces no anuncia globals). Sólo afecta tests; sugiere estado global en `wl_server.c`.
- **`deploy.sh` copia los scripts de `session/` uno por uno.** Olvidar uno rompe el host
  remoto en silencio. Salida: `rsync` del directorio con exclusiones.

## B.2 — Activas (2026-10-06)

- **Crash de Firefox (UAF de escala/monitores en el hilo Renderer).**
  El diagnóstico anterior de EGL/Gallium queda corregido por el desensamblado
  del 2026-10-07: `ScreenHelperGTK::GetGTKMonitorFractionalScaleFactor()` accede
  a un Screen liberado desde `WaylandSurface::GetScale()`. Sigue ocurriendo
  después de los fixes de frame callbacks/ids muertos del 2026-10-06.
  Mitigación opt-in: launcher `session/gdtk-firefox` por Xwayland; falta validar
  reuniones prolongadas y aislar la carrera nativa. Evidencia, límites y operación
  en `guides/firefox-crashes.md`. Mantener separada la familia de reportes por
  pérdida del compositor; ni ella ni el spam GTK prueban la causa del UAF.
- **El supervisor marcó el shell «hung» a las 14:57 (pid 1962160) y no hizo
  nada más hasta el reinicio pedido 15:38.** Coincide con los crashes de
  Firefox de la tarde (shell vivo pero sin dibujar = sin frame_done para
  nadie; Firefox muere por su frame clock cuando la ventana pasa oculta→visible).
  Investigar por qué el shell se cuelga sin morir (probable bloqueo en el loop
  de ImGui/`_process`) y decidir si el supervisor debe relanzar en ese caso
  (para scripts siempre es recargable; con engine abierto, no).

## B.3 — Activas (2026-10-09)

- **Diálogos que «quedan detrás» de ventanas tiled/maximizadas (reportado, sin
  reproducir).** Los child toplevels se dibujan en `dialog_view`, hermana de `view` y
  agregada después (`shell.gd:1275`, `shell.gd:1346-1350`), así que por orden de hijos
  de `view_layer` deberían ir siempre encima. Sospecha: no son child toplevels sino
  **popups/subsurfaces** (`xdg_popup`, combos, tooltips, o diálogos que el cliente pinta
  como subsurface) que se dibujan como capas **dentro del nodo de la ventana**
  (`compositor.get_layers` → `_fill_nodes`, `shell.gd:4352`, `shell.gd:2740`) y una
  ventana tiled/maximizada encima las tapa. Alternativa: `tiles_ui` está **encima** de
  `dialog_view` (`shell.gd:1360`). Falta reproducir (¿qué app? ¿About/selector real o
  menú/combo?) para decidir si el fix es en el z-order del compositor o en
  `dialog_view`. Salida: reproducir con app+pasos, luego promover popups/subsurfaces al
  apilado de ventanas (o subir `dialog_view` sobre `tiles_ui` si es lo segundo).

## C — Higiene

- `shell/activities/` está vacío.
- `.frt-baseline/` e `icarito-none/` en la raíz (ignorados); capturas y logs de Kilo
  viejos movidos a `.attic/` (ignorado) el 2026-10-04.
