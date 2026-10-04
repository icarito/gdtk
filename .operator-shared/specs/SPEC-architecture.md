# SPEC — Arquitectura de gdtk (mapa y reglas que cruzan todo)

Lectura obligada antes de agregar algo nuevo. Dice **dónde va cada cosa** y qué
contratos no se negocian. El detalle de cada área está en su spec (ver catálogo).

## Capas y procesos

```
GDM ─ gdtk.desktop ─ session/gdtk-session-sway ─ sway (compositor anfitrión)
                                                  └─ session/gdtk-supervisor (heartbeat, relanza, fallback last_good_content)
                                                      └─ godot-gdtk --path ~/gdtk/shell   ← UN proceso
                                                          ├─ autoload Host (host.gd): vive toda la corrida
                                                          │   ├─ WaylandCompositor  (modules/wayland, C: wlroots embebido)
                                                          │   │     └─ apps del usuario (alacritty, firefox, Xwayland…)
                                                          │   ├─ RemoteInput (EIS + backend del portal xdg)
                                                          │   └─ peer_control (canal LAN entre shells)
                                                          └─ main.tscn (main.gd): recambia shell.gd sin cerrar apps
                                                              └─ shell.gd (ImGuiCanvas): Hogar, actividades, ventanas,
                                                                  Vecindario, servicios, control remoto (remote.gd :7777)
                                                                  ├─ frame.gd       barras del Frame, pines, applets/dockapps
                                                                  ├─ neighborhood_ui.gd, tiles_ui.gd, layers.gd, …
                                                                  └─ modelos puros (extends Reference)
Configuración (settings/) = otro proyecto Godot, lanzado como ventana Wayland; habla con
el shell por archivos (~/.config/gdtk/settings.json) + settings_bridge.gd.
mcp/gdtk_mcp.py = puente MCP → JSON-RPC de remote.gd (SPEC-control.md).
```

- **Dos compositores, dos portapapeles.** Las apps viven en el compositor embebido
  (`WAYLAND_DISPLAY` propio, lo fija `WaylandCompositor.launch`); el shell mismo es
  cliente de sway. No hay puente de selección entre ambos (ver `plans/tech-debt.md`).
- **Motor ≠ scripts.** Cambios en `modules/` (o en el fork) exigen recompilar y un corte
  controlado; cambios en `.gd` se sincronizan a `~/gdtk` y entran al recargar el shell.
- **Recargar ≠ reiniciar.** La recarga transaccional compila/instancia un candidato y
  conserva el activo si falla; reiniciar el proceso destruye el compositor embebido y
  sus clientes. Operación detallada en `guides/session-continuity.md`.
- **Vivo ≠ sano.** `Host` publica un heartbeat semántico; el supervisor sólo promueve
  contenido si observa progreso del PID correcto y `reload=ready`. `last_good` no
  versiona ni certifica el binario.

## Contratos transversales

1. **El hilo de render nunca espera.** `_process`, `_imgui_frame`, `draw` y `refresh()` no
   hacen `OS.execute` con captura, ni leen `/proc`, `/sys` o archivos, ni consultan D-Bus.
   Todo eso va a un worker (`Thread` + `Mutex`) que publica un snapshot; la UI copia el
   snapshot. Patrón de referencia: `applet_keyboard.gd`, `applet_clipboard.gd`, el worker
   de servicios en `shell.gd`. Contrato completo en `SPEC-screen-share-compass.md` §14.
2. **El shell duerme.** Sin cambios no hay frame (`IDLE_MS`); quien cambie estado visible
   llama `shell.request_redraw()` (o devuelve `true` desde `refresh()` en un applet).
3. **Lógica pura aparte.** Parsers, layouts y decisiones van en `extends Reference` sin I/O
   ni nodos, con test en `tests/<nombre>_test.gd`. `shell.gd`/`frame.gd` sólo cablean.
4. **Recarga en caliente.** Los scripts que deben tomarse del disco al recargar se cargan
   con `Host.sc("res://x.gd")` (compila desde el texto). `preload` queda cacheado hasta
   reiniciar el proceso: sirve para modelos puros, no para lo que se itera en vivo.
5. **Ciclo de vida de procesos externos.** Servicios con botón: `ACTIVITIES[].service` +
   `_toggle_service`/`_service_running`/`service_pids` (no duplicar). Procesos auxiliares
   de un módulo (p. ej. el vigía del portapapeles) se desacoplan con `sh -c '… &'` (sin
   zombies) y son idempotentes por lock, para sobrevivir a una recarga del shell.
6. **Honestidad de estado.** Sin medición no se inventa valor: `sin_dato`,
   `no_disponible`, `error` (tabla de estados en `SPEC-sugar-frame-applets.md`).
7. **Sin secretos** en argumentos, logs, TXT DNS-SD, Diario ni historiales persistentes.

## Dónde va cada cosa nueva

| Quiero… | Va en | Guía/spec |
|---|---|---|
| un bloque en la barra del Frame (dockapp/applet) | `shell/applet_<x>.gd` + 2 líneas en `frame.gd` | `guides/dockapp.md` |
| una app que abre ventana | `ACTIVITIES` en `shell.gd` o un `.desktop` (lo lee `apps.gd`) | `SPEC-shell.md` |
| un servicio de fondo con botón | `ACTIVITIES[].service` | este doc §5 |
| una página de Configuración | `settings/pages/<x>.gd` (hereda `page.gd`) | `SPEC-ui-rework-2026-10.md` |
| un comando del control remoto/MCP | `shell/remote.gd` + `mcp/gdtk_mcp.py` | `SPEC-control.md` |
| un protocolo Wayland nuevo | `modules/wayland/wl_server.c` (recompilar) | `SPEC-compositor.md` |
| un script de sesión | `session/` **y** la lista de `deploy.sh` | `AGENTS.md` |

## Verificación

- Un test: `<binario dev> --no-window --path shell -s $PWD/tests/<x>_test.gd`.
- Todos: `tools/verify_all.sh` (aislado de la sesión viva; mira `ok/FAIL`, no sólo el rc).
- Parseo de scripts que usan clases nativas: `~/gdtk/bin/godot-gdtk … -s tests/parse_check.gd`.
- Ojo: `-s` con el binario instalado carga los autoloads (`Host` levanta un compositor y
  `Remote` intenta el puerto 7777). Para pruebas e2e del compositor, aislar con un
  `XDG_RUNTIME_DIR` propio y corto (el path del socket no puede pasar de 108 bytes).
