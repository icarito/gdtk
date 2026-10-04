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

## C — Higiene

- `README.md` describe el plan original (cage, XMPP, «Fase 2/3») y no el shell actual;
  remitir a `specs/SPEC-architecture.md`.
- `shell/activities/` está vacío.
- `shell/design_check.gd` es un script `extends SceneTree` (un test) dentro de `shell/`
  y sin cabecera; va en `tests/`.
- `.frt-baseline/` e `icarito-none/` en la raíz (ignorados); capturas y logs de Kilo
  viejos movidos a `.attic/` (ignorado) el 2026-10-04.
