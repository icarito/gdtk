# Plan — Sistema centralizado de notificaciones (bus + dockapp + overlay + urgencia + foco)

Repositorio: `/run/media/icarito/DATA/icarito/Proyectos/gdtk` (Godot 3 GDScript + un
helper de sesión Python; **sin cambios de motor**, sin commit, sin deploy salvo sync +
recarga).

## Objetivo

Un **bus de notificaciones** único y central que reciba eventos de tres fuentes y los
presente de forma no intrusiva:

1. **Externas** (apps del compositor embebido): `org.freedesktop.Notifications` por un
   daemon propio.
2. **Internas del shell**: petición de foco (`xdg-activation`), urgencia de dockapps,
   mensajes del propio shell y comandos del control remoto.
3. Presentación: un **dockapp de notificaciones** que siempre muestra la última, una
   **columna overlay** de bloques por evento (scrolleable, hover expande) en el borde
   izquierdo, y **urgencia** que pinta el bloque del Frame (p. ej. térmico en rojo).

Reglas duras que respeta: el hilo de render nunca hace I/O; lo puro va en
`extends Reference` testeable; el shell duerme sin cambios (`request_redraw`); nada de
secretos en argv/logs/estado; no romper el contrato de applets (`guides/dockapp.md`).

## Hechos verificados

- **No hay daemon de notificaciones corriendo.** `session/autostart.sh:90` lanza `mako`,
  pero `which mako` → *not found*: hoy `org.freedesktop.Notifications` no lo posee nadie
  y las notificaciones de apps no aparecen.
- **`xdg-activation` ya llega al shell**: `modules/wayland/wl_server.c:2013` maneja
  `request_activate` y `wayland_compositor.cpp:424` emite `toplevel_activate`;
  `shell.gd:1234` lo conecta. Hoy `_on_toplevel_activate` (`shell.gd:10757`) **roba el
  foco** (`_open_by_name` + `compositor.focus`): es el comportamiento a cambiar.
- **Patrón a reusar**: portapapeles = helper de sesión (`session/gdtk-clipboard`) +
  applet con worker/snapshot (`shell/applet_clipboard.gd`) + popup de historial
  (`frame.gd:3618`). El Frame ya soporta applets con `span`, menú contextual por applet
  (`frame.gd:1567`, `frame.gd:3509`) y persistencia en `frame-applets.json`
  (`frame.gd:890`).
- **Runtime disponible**: Python 3.14 con `gi` (PyGObject 3.58), `dbus`, `dbus_fast`,
  `pydbus`, `Gio`; además `gdbus`, `busctl`, `dbus-send`, `notify-send`. Un daemon
  D-Bus propio es viable.
- **Watcher de archivos**: existe `GdtkFileWatch` (módulo inotify) usado por
  `shell/apps.gd:84`; sirve para avisar cambios del store sin sondeo.
- El Frame hoy sólo tiene borde **superior** e **inferior** (no hay franja izquierda).
- El OSD (`shell/system_osd.gd`) tiene `show_message(text, icon)` efímero e independiente
  del worker, útil como referencia de placa, pero **no** se usa como toast (el bloque es
  el toast).
- Iconos: `shell._load_np_icon`, `shell._load_sugar_svg`, `shell._load_png_file` y
  `shell.apps.resolve_icon(name)` (apps.gd:426) resuelven íconos por nombre/ruta.

## Decisiones tomadas (con el usuario)

| Decisión | Resultado |
|---|---|
| Origen | **D-Bus + internos**: daemon propio + bus interno que también genera activación, urgencia y RPC |
| Forma de la lista | **Dockapp + columna overlay** en el borde izquierdo (no franja real del Frame; no reserva espacio) |
| Petición de foco | **Destacar + avisar, sin robar foco**: pulso de borde + bloque del Frame; notificación con acción «ir» que sí enfoca |
| Urgencia | **API central con TTL**: `raise_urgency(fuente, severidad, ttl, texto)`; renueva sin duplicar; auto-expira |
| Aviso efímero | **El bloque ES el toast**: al llegar, un bloque en el overlay hace fade in/out; hover revela el texto; sin hover, ícono de la app |
| Visibilidad de la columna | **Toggle + modo**: oculta por defecto; se despliega al pulsar el dockapp; «modo» la deja abierta con pendientes; Esc/clic fuera cierra |
| Submenú del dockapp | **Ancho (span) + columna + modo + limpiar historial + silenciar (no molestar)** + acceso a Configuración |

Detalles fijados: el dockapp se llama `notificaciones` (short `NOTIF`), span por defecto
**2** y elegible **2/3** (override persistido). Sin secretos: sólo resumen/cuerpo de la
notificación, cap de historial, efímero en `$XDG_RUNTIME_DIR`.

## Arquitectura y flujo de datos

```
app externa ──D-Bus──▶ session/gdtk-notify serve   (daemon Python+gi, dueño de
                        │  org.freedesktop.Notifications; escritor único)
                        ▼ escribe atómico
        $XDG_RUNTIME_DIR/gdtk/notifications.json          shell/notify.gd (worker)
                        │                                        │ Lee el store (1s + inotify),
                        │  command dir / CLI                     │ publica snapshot inmutable
                        ▼                                        ▼
   session/gdtk-notify push|dismiss|clear|invoke ◀── worker ── notify.gd UI thread:
   (internos: activación, urgencia, RPC)                          atención, urgencia, silencio,
                                                                  panel/modo, revisión
                                                                 │
                    ┌────────────────────────────────────────────┼───────────────────────────┐
                    ▼                        ▼                    ▼                            ▼
        applet_notif.gd (dockapp)   notifications_panel.gd   frame._draw_applet         window_deco/tiles_ui
        última + historial          bloques scroll/hover     urgencia (pulso/accento)   atención (pulso borde)
```

- **Escritor único**: sólo el daemon escribe `notifications.json`. Los eventos internos
  del shell se **encolan** (mutex) y el worker los ejecuta vía
  `session/gdtk-notify push …` (proceso fuera del hilo de render).
- **Ojo**: si el daemon no corre, `notify.gd` degrada a modo local (historial en memoria
  desde los pushes internos) sin romper el shell.

### Modelo de registro (una entrada del store)

```json
{
  "id": 42,
  "source": "dbus | activacion | urgencia | rpc | shell",
  "app": "Firefox",
  "app_id": "firefox",
  "icon": "firefox",
  "summary": "Descarga terminada",
  "body": "informe.pdf",
  "urgency": "low | normal | critical",
  "actions": [{"key": "default", "label": "Abrir"}],
  "target_window": 0,
  "created_ms": 1791515748397,
  "expires_ms": 0,
  "read": false
}
```

`notifications.json` = `{"revision": <int>, "items": [ …más nuevo primero… ]}`.
Cap configurable (`history_max`, por defecto 100). `expires_ms == 0` = no expira (queda
en historial); la urgencia se evalúa por su `expires_ms` contra el reloj de UI.

## Tareas (por fases, orden de implementación)

### Fase 1 — Bus interno + dockapp (usable y verificable sin daemon)

1. **`shell/notify.gd`** (`extends Reference`, dueño del bus):
   - Worker (Thread+Mutex, patrón `applet_clipboard.gd`) que lee
     `$XDG_RUNTIME_DIR/gdtk/notifications.json` a 1 s (y con `GdtkFileWatch` si la clase
     existe) y publica un snapshot inmutable `{revision, items, latest}`.
   - Estado de UI (hilo principal): `attention` (id→{hasta_ms}), `urgency`
     (fuente→{severidad, hasta_ms, texto}), `silenced`, `panel_open`, `panel_mode`,
     `revision`. `poll()` avanza relojes y devuelve `true` mientras haya animación
     pendiente (transitorio/urgencia/atención) para pedir frames.
   - API pública: `latest()`, `items()`, `push_internal(record)` (encola),
     `dismiss(id)`, `dismiss_all()`, `request_attention(window_id, texto)`,
     `clear_attention(id)`, `raise_urgency(fuente, severidad, ttl_ms, texto)`,
     `urgency_for(fuente)`, `attention_ids()`, `set_silenced(bool)`, `silenced()`.
   - Helper puro estático (`selftest()` como `neighborhood.gd`): orden por llegada,
     recorte al cap, merge por `replaces_id`/renovación de urgencia, expiración.
2. **`shell/applet_notif.gd`** (`extends Reference`, dockapp; contrato de
   `guides/dockapp.md`): `state/value/detail` desde el snapshot del bus (`refresh()` copia
   y devuelve `true` si cambió); `draw()` = ícono de app + resumen recortado (o «sin
   notificaciones»); `detail` = resumen completo para tooltip. **No** crea worker propio:
   `stop()` no-op (el bus vive en el shell). Se le asigna `notif = shell.notify` en
   `frame._ready()`.
3. **Registro en `frame.gd`**: alta en `APPLETS` (`{"id":"notificaciones","name":
   "Notificaciones","short":"NOTIF","span":2}`), instancia en `applet_mods`, y
   `applet_menu("notificaciones") → "notificaciones"` (submenú propio, ver Fase 4).
   **No** agregar a `APPLET_DEFAULT`.
4. **RPC mínimo `remote.gd`**: método `"notify"` con `{action: push|list|dismiss|clear|
   silence|attention}` para tests e2e (mismo estilo que `"media"`).

### Fase 2 — Daemon D-Bus (apps externas)

5. **`session/gdtk-notify`** (Python 3 + `gi`/`Gio`, POSIX-friendly):
   - `serve`: posee `org.freedesktop.Notifications` en el bus de sesión
     (`Gio.bus_own_name`), implementa `Notify`, `CloseNotification`, `GetCapabilities`,
     `GetServerInformation` y emite `NotificationClosed`/`ActionInvoked`. Honra
     `replaces_id`, hints (`urgency`, `desktop-entry`, `category`, `resident`) y
     `expire_timeout`. Escribe `notifications.json` atómico (tmp+rename), cap.
   - Cliente: `push` (eventos internos del shell), `dismiss <id>`, `clear`, `invoke
     <id> <action>`, `list`, `selftest` (sin bus: valida parseo/serialización/cap y
     sale 0). Secretos nunca por argv (el cuerpo va por archivo/stdin).
   - Idempotente por lock (`flock`) como `gdtk-clipboard`; log en
     `$XDG_RUNTIME_DIR/gdtk-notify.log`.
6. **`session/autostart.sh`**: reemplazar `start_mako` por `start_notify` (lanza
   `gdtk-notify serve`, pidfile en `$run_dir/gdtk-notify.pid`, `running` para no
   duplicar). Mantener la forma POSIX y el logging de `say`.
7. **`deploy.sh`**: sumar `$GDTK/session/gdtk-notify` a la lista de `rsync` de `session/`
   (línea 48). Actualizar **`session/DEPS.md`**: `python3` + `PyGObject`/`Gio` y
   `gdtk-notify` en vez de `mako`.

### Fase 3 — Ingesta interna (foco y urgencia)

8. **Foco sin robo** (`shell.gd`):
   - `_on_toplevel_activate(id)` deja de enfocar: llama
     `notify.request_attention(root, texto)` (y `push_internal` de tipo `activacion` con
     `target_window`), más `request_redraw()`. No abre actividad ni cambia `focused_tile`.
   - `_focus_tile(id)` llama `notify.clear_attention(id)` y no cambia el resto.
   - Limpieza: al cerrar la ventana, en `_on_toplevel_removed`, y por timeout (~10 s,
     configurable).
9. **Pulso de «destacar»**:
   - `shell/window_deco.gd`: en `_draw()` del caso flotante, si `id` está en
     `shell.notify.attention_ids()`, dibujar un contorno pulsante (acento del shell,
     `0.5+0.5*sin(ms)`) alrededor de `fr`. `_imgui_frame` ya refresca los `deco_nodes`.
   - `shell/tiles_ui.gd` (`_draw`): mismo pulso sobre el rect de cada ventana tileada
     en atención (usa `shell.tile_nodes`/`_node_footprint`).
   - Bloque del Frame: en `_draw_windows`/tile de ventana, marca de atención (pulso).
10. **Urgencia de dockapps**:
    - API en `notify.raise_urgency(...)` (Fase 1). El Frame la consume: en
      `frame._draw_applet` de `termico`, evaluar `sysmon.temp_c` (y governor) y llamar
      `raise_urgency("termico", "critical", 3*60*1000, "Temperatura alta")` cuando
      corresponda; `urgency_for("termico")` tiñe la placa de rojo y pulsa mientras dura.
    - Al mostrar/renovar urgencia, `push_internal` de tipo `urgencia` (una vez por
      episodio, no por frame).
    - Interruptor global `urgencia` (Configuración) y `silenced`.

### Fase 4 — Columna overlay de bloques + submenú

11. **`shell/notifications_panel.gd`** (`extends Reference`, dibujo ImGui; llamar desde
    `shell._imgui_frame` cerca de `system_osd.draw`):
    - Columna en el borde izquierdo (ancho ≈ 2 celdas, alto útil entre barras del
      Frame). Bloques por evento, orden de llegada, **scrolleables** (rueda/gesto;
      reusar `scroll_gesture.gd`/acumulador como `frame.vol_pan`).
    - **Hover expande** el bloque para mostrar el cuerpo completo; sin hover, ícono de la
      app (+ resumen de una línea). Clic = acción (`invoke`/foco si `target_window`;
      `default` si el registro trae acciones); botón central/«×» = descartar.
    - **Transitorio (el «toast»)**: si la columna está cerrada y no `silenced`, un bloque
      nuevo entra con fade in, permanece ~4 s y sale con fade out; el hover pausa/expande.
      `notify.poll()` devuelve `true` mientras anima.
    - `panel_open`, `panel_mode` y `silenced` los expone `notify.gd`.
12. **Submenú del dockapp** en `frame._draw_frame_popups` (`##applet_notificaciones`):
    - Ancho: span **2** / **3** vía `_applet_set_span(id, n)` nuevo en `frame.gd`
      (override persistido en `applets_raw["span"][id]`; `_applet_span` lo consulta
      primero; si está visible, reubica el token y guarda).
    - Abrir/cerrar columna; «modo siempre abierta»; «Limpiar historial»
      (`notify.dismiss_all()` vía worker); «Silenciar» (toggle `notify.set_silenced`);
      acceso a Configuración.
13. **Salida a Configuración**: `settings_bridge.launch_argv()` + selección de página
    (patrón existente para abrir la app de Configuración).

### Fase 5 — Configuración, RPC completo, tests y doc

14. **`settings/pages/notifications.gd`** (hereda `page.gd`) + claves en
    `settings/settings_model.gd` (`notifications`: `enabled`, `toast_transitorio`,
    `atencion_foco`, `urgencia`, `history_max`, `columna_modo`, `silencio`) y lectura en
    `shell/settings_bridge.gd` (`func notifications()` con defaults sanos). Página
    registrada en la app `settings/` como las demás.
15. **RPC**: completar `remote.gd` `"notify"` (`push` con `summary/body/icon/urgency`,
    `list`, `dismiss`, `clear`, `silence`, `attention`) y documentar en la tabla de
    `SPEC-control.md`.
16. **Tests** (regla `tests/<x>_test.gd`, `extends SceneTree`, `check()`, `OS.exit_code`):
    - `tests/notify_model_test.gd`: orden, cap, expiración de urgencia, atención,
      `replaces_id`, silencio, `selftest()` puro.
    - `tests/applet_notif_test.gd`: resumen/label, rutas, «más nuevo», estado vacío.
    - Extender `tests/frame_menu_test.gd`: `applet_menu("notificaciones")`, span override
      y persistencia; `tests/parse_check.gd`: sumar `notify.gd`, `applet_notif.gd`,
      `notifications_panel.gd`.
    - `session/gdtk-notify selftest` como test de sesión (sin bus).
17. **Doc**: fila del applet en `SPEC-sugar-frame-applets.md`; nota del bus y del daemon
    en `.operator-shared/specs/` (nueva `SPEC-notificaciones.md`) enlazada desde
    `catalog.md` y `SPEC-architecture.md` (tabla «Dónde va cada cosa nueva»).

## Integraciones por archivo

| Archivo | Cambio |
|---|---|
| `shell/notify.gd` (nuevo) | Bus: worker store + snapshot, atención, urgencia, silencio, panel/modo |
| `shell/applet_notif.gd` (nuevo) | Dockapp: última + historial; sin worker propio |
| `shell/notifications_panel.gd` (nuevo) | Overlay izquierdo: bloques scroll, hover-expand, transitorio |
| `shell/frame.gd` | `APPLETS`, `applet_mods`, `applet_menu`, `_applet_span`/`_applet_set_span`, submenú, urgencia en `_draw_applet` |
| `shell/shell.gd` | `var notify`, arranque/parada, `poll()`, `draw` del panel, `_on_toplevel_activate`, `_focus_tile`, limpieza de atención |
| `shell/window_deco.gd`, `shell/tiles_ui.gd` | Pulso de atención (borde) |
| `shell/remote.gd` | RPC `notify` |
| `shell/settings_bridge.gd` | `notifications()` |
| `session/gdtk-notify` (nuevo) | Daemon D-Bus + cliente (`push/dismiss/clear/invoke/list/selftest`) |
| `session/autostart.sh`, `session/DEPS.md`, `deploy.sh` | Arranque, deps y copia del helper |
| `settings/pages/notifications.gd`, `settings/settings_model.gd` | Página y claves |

## Riesgos y límites

- **Sin D-Bus nativo en Godot**: toda acción del shell hacia el daemon va por CLI en el
  worker (nunca en el hilo de render). Si el binario dev no tiene `GdtkFileWatch`, el
  store se sondea a 1 s (latencia aceptable).
- **Acciones externas**: `ActionInvoked` a la app original requiere que su conexión D-Bus
  siga viva; en el primer corte se soporta `default` (abrir/foco) y se documenta el
  límite para acciones arbitrarias.
- **Robo de foco**: el cambio en `_on_toplevel_activate` altera un comportamiento
  existente; el pulso y el timeout deben cubrir el caso legítimo (clic en un enlace que
  abre el navegador) sin dejar la ventana «colgada» pidiendo atención.
- **No hay franja izquierda fija**: la columna es overlay; no reserva espacio ni toca la
  grilla del Frame ni la colocación de ventanas.
- **Capacidad de barra**: un dockapp de span 2/3 puede no entrar si la barra está llena
  (`_place_new_token` devuelve `false`); el submenú debe informarlo, no forzar.
- **Secretos**: el store es efímero y sin credenciales; el cuerpo de la notificación
  nunca va por argv ni al log.

## Validación

1. `tools/verify_all.sh` sobre lo tocado (mirar `ok/FAIL`, no sólo el rc; ruido conocido
   de autoloads). Tests `-s` individuales con el binario dev.
2. Parseo con el binario instalado: `~/gdtk/bin/godot-gdtk --no-window --path shell -s
   tests/parse_check.gd` (incluye los scripts nuevos).
3. e2e D-Bus: `session/gdtk-notify selftest`; con la sesión viva,
   `notify-send "hola" "cuerpo"` y comprobar que aparece en el dockapp y en la columna.
4. e2e sin tocar la sesión: RPC `notify push`, `notify list`, `notify dismiss`; y
   `media`/`state` siguen respondiendo.
5. Foco: RPC/xtest para disparar `xdg-activation` y verificar que **no cambia**
   `focused_tile`, que la ventana pulsa, que la notificación «pide atención» aparece y que
   pulsarla sí enfoca; sin atención residual tras el timeout.
6. Urgencia: forzar `sysmon.temp_c` alto (o RPC) y ver «termico» en rojo con pulso que se
   apaga al expirar el TTL, sin duplicar entradas.
7. Visual: 800×600 (Tengu) y 1280×720; columna scroll + hover-expand; fade in/out del
   bloque nuevo; span 2/3 desde el submenú y persistencia tras recargar el shell.

## Fuera de alcance / siguientes cortes

- Franja **izquierda real** del Frame (rejilla, reserva de espacio) — descartada en este
  corte.
- Réplica/«handoff» de notificaciones entre equipos del Vecindario.
- Acciones arbitrarias de apps externas más allá de `default`.
- Promoción de gdtk como emisor de pantalla (`gvd`), sin relación con este corte.

## Aplicación (recordatorio de repo)

- Editar y probar **sólo en el repo**; tras pasar tests, `rsync` de `shell`/`settings` a
  `~/gdtk` y **una** recarga transaccional del shell (ver `guides/session-continuity.md`).
- El helper `session/gdtk-notify` requiere copiarse a `~/gdtk/session/` y que el daemon
  arranque por autostart (o relanzarlo a mano para la prueba). No commit, no deploy, no
  revertir cambios ajenos.
