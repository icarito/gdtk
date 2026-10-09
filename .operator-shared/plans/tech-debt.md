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
- **`applet_bluetooth.gd` es código muerto.** El Frame lo instancia y lo para, pero no
  está en `APPLETS` y la migración de config descarta el id `bluetooth`. Salida:
  registrarlo en `applet_mods` (y `APPLETS`) o borrarlo.

## A — Portapapeles y entrada

- **Portapapeles partido en dos.** Las apps viven en el compositor embebido y el shell
  en sway; no hay puente de selección. Copiar en una app interna no llega a clientes de
  sway ni a `OS.get_clipboard()`. Probable (sin verificar): Deskflow, lanzado con el
  entorno del shell, comparte el portapapeles de sway y no el de las apps. Salida: un
  puente con `ext-data-control` en ambos lados (ya está en el embebido) o lanzar
  Deskflow contra el socket embebido; verificar primero.
- **El historial del portapapeles necesita el motor recompilado** (`ext-data-control-v1`
  en `wl_server.c`, 2026-10-04). Con un binario viejo el applet queda `no_disponible`.

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

## C — Higiene

- `README.md` describe el plan original (cage, XMPP, «Fase 2/3») y no el shell actual;
  remitir a `specs/SPEC-architecture.md`.
- `shell/activities/` está vacío.
- `shell/design_check.gd` es un script `extends SceneTree` (un test) dentro de `shell/`
  y sin cabecera; va en `tests/`.
- `.frt-baseline/` e `icarito-none/` en la raíz (ignorados); capturas y logs de Kilo
  viejos movidos a `.attic/` (ignorado) el 2026-10-04.
