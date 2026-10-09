# SPEC — Sistema centralizado de notificaciones (bus + daemon + dockapp + columna)

Estado: primer corte implementado (2026-10-09). Cubre el bus interno, el daemon
`org.freedesktop.Notifications`, el dockapp, la columna overlay, la urgencia y la
atención de foco sin robo. **Sin cambios de motor.**

## Idea

Un **bus único** recibe eventos de tres fuentes y los presenta sin interferir:

- **Externas**: apps del compositor embebido vía `org.freedesktop.Notifications`,
  servido por un daemon propio (`session/gdtk-notify serve`, Python 3 + Gio). No hay
  `mako` en los equipos.
- **Internas del shell**: pedidos de foco (`xdg-activation`), urgencia de dockapps,
  mensajes del shell y comandos del control remoto.
- **Presentación**: un **dockapp** (`notificaciones`, short `NOTIF`, span 2/3) que
  muestra la última, una **columna overlay** de bloques por evento (scrolleable,
  hover expande) en el borde izquierdo, y **urgencia** que pinta el bloque del Frame
  (p. ej. térmico en rojo).

## Separación de hilos (regla dura)

El hilo de render **nunca** hace I/O. `shell/notify.gd`:

- **worker** (Thread+Mutex, patrón `applet_clipboard.gd`): lee
  `$XDG_RUNTIME_DIR/gdtk/notifications.json` a 1 s (y con `GdtkFileWatch` si el motor
  lo trae), ejecuta los comandos encolados (`push`/`dismiss`/`clear`/`invoke`) vía
  `session/gdtk-notify` y publica un snapshot inmutable `{revision, items, latest}`.
- **hilo principal**: copia el snapshot en `poll()`, avanza los relojes de
  atención/urgencia/transitorio y devuelve `true` mientras haya animación pendiente
  (así el shell pide frames y vuelve a dormir). `poll()` se llama desde
  `shell._process`; el bus se crea **antes** del Frame y se detiene en `_exit_tree`.

Modelo puro y testeable (`tests/notify_model_test.gd`): orden por llegada, cap,
merge por `replaces_id`, expiración, parseo/serialización del store, y
`notify.selftest()`.

## Store (escritor único: el daemon)

`$XDG_RUNTIME_DIR/gdtk/notifications.json` = `{"revision": <int>, "items": [...]}`,
más nuevo primero, tope `history_max` (100 por defecto). Entrada:

```json
{
  "id": 42, "source": "dbus|activacion|urgencia|rpc|shell",
  "app": "Firefox", "app_id": "firefox", "icon": "firefox",
  "summary": "Descarga terminada", "body": "informe.pdf",
  "urgency": "low|normal|critical",
  "actions": [{"key": "default", "label": "Abrir"}],
  "target_window": 0, "created_ms": 1791515748397, "expires_ms": 0, "read": false
}
```

`expires_ms == 0` no expira (queda en el historial). El cuerpo viaja a los helpers
por **archivo**, nunca por argv; el store es efímero (tmpfs) y sin credenciales.

Si el daemon no corre, el worker degrada a un historial local en memoria con los
pushes internos, sin romper el shell.

## Daemon y cliente (`session/gdtk-notify`)

- `serve`: posee `org.freedesktop.Notifications` (`Gio.bus_own_name`), implementa
  `Notify`, `CloseNotification`, `GetCapabilities`, `GetServerInformation`, emite
  `NotificationClosed`/`ActionInvoked`, honra `replaces_id`, hints (`urgency`,
  `desktop-entry`, `x-gdtk-source`), `actions` y `expire_timeout`. Escribe atómico
  (tmp+rename). Idempotente por `flock`; log en `$XDG_RUNTIME_DIR/gdtk-notify.log`.
- Interfaz privada `org.gdtk.Notify` (`/org/gdtk/Notify`): `Clear`, `Invoke(u,s)`.
- Cliente: `push <archivo.json>`, `dismiss <id>`, `clear`, `invoke <id> <acción>`,
  `list`, `selftest` (sin bus, valida el modelo puro y sale 0).
- Arranque: `session/autostart.sh` → `start_notify` (reemplaza a `start_mako`);
  `deploy.sh` copia el helper; `session/DEPS.md` lista `python3`/PyGObject.

## Foco sin robo (`xdg-activation`)

`shell._on_toplevel_activate` ya **no** enfoca: llama
`notify.request_attention(root, texto)` (más un registro `activacion` con
`target_window`) y `request_redraw()`. No abre actividad ni cambia `focused_tile`.
La atención dura `ATTENTION_MS` (~10 s) y se limpia al cerrar la ventana, al
enfocarla a mano (`_focus_tile`) y por timeout. El pulso del borde lo dibujan
`window_deco.gd` (flotantes) y `tiles_ui.gd` (mosaico) con `notify.has_attention(id)`.
Pulsar la notificación (acción «ir» / `target_window`) sí enfoca.

## Urgencia

`notify.raise_urgency(fuente, severidad, ttl_ms, texto)` eleva o renueva con TTL; sólo
encola una notificación en el primer episodio (no por frame). `urgency_for(fuente)`
tiñe la placa (el Frame la consume en `termico` con `sysmon.temp_c > TEMP_ALERT_C`, **95 °C**:
el pulso rojo se reserva para calor extremo) y pulsa mientras dura; auto-expira. El dockapp
térmico también dibuja el **ventilador** (`sysmon.fan_rpm` de `/sys/class/hwmon`) girando a
velocidad proporcional a las rpm (color tenue, no distractivo; sin hwmon de fan → "vent. s/d").
Interruptores globales `enabled`,
`atencion_foco`, `urgencia` y `silencio` (Configuración) llegan por
`settings_bridge.notifications()`.

## Columna overlay y dockapp

- `shell/notifications_panel.gd` (ImGui, llamado desde `shell._imgui_frame`): cada aviso es un
  **bloque estilo dockapp** (bisel + placa LCD + ícono de la app + resumen DENTRO del bloque),
  apilado en el borde izquierdo. Son **transitorios y animados**: fade-in, ~5 s de sostenimiento y
  fade-out **en orden de aparición** (más viejos primero; escalonado en ráfagas); con la columna
  fijada (`panel_open`/`columna_modo`) no se desvanecen. Un clic sobre un bloque enfoca (si trae
  `target_window`) o dispara la acción `default`; clic derecho descarta.
- **Sin obstrucción**: la ventana ImGui usa `WINDOW_NO_MOUSE_INPUTS` y el puntero se resuelve a
  mano. El guard va en `shell._on_view_input` —el punto por donde el puntero llega al compositor,
  tanto en el Hogar como sobre una app— **antes** de reenviar al cliente; así un clic sobre un
  bloque (o en el hueco de la columna) se consume y NUNCA atraviesa a la app de abajo. Un clic
  fuera de la columna la cierra pero no se consume. (Antes el guard vivía en `_input`, por encima
  del View; clicks que no llegaban ahí atravesaban el bloque.)
- `shell/applet_notif.gd`: dockapp sin worker propio (`notif = shell.notify` en
  `frame._ready()`); `state/value/detail` desde el snapshot; ícono de la app + resumen.
  Submenú (clic derecho): ancho 2/3 (`_applet_set_span`, override persistido en
  `frame-applets.json` → `span[id]`), abrir/cerrar columna, modo, limpiar, silenciar
  y acceso a Configuración → Notificaciones.

## Configuración y RPC

- `settings/pages/notifications.gd` + claves en `settings_model.gd`
  (`enabled`, `toast_transitorio`, `atencion_foco`, `urgencia`, `history_max`,
  `columna_modo`, `silencio`); lectura en `settings_bridge.notifications()`.
- RPC `notify {action, …}` en `shell/remote.gd` (`push|list|dismiss|clear|silence|
  attention|panel|urgency`), documentado en `SPEC-control.md`.

## Límites

- Sin D-Bus nativo en Godot: las acciones del shell hacia el daemon van por CLI en el
  worker (nunca en el hilo de render).
- `ActionInvoked` a la app original requiere que su conexión D-Bus siga viva; el
  primer corte soporta `default` y documenta el límite.
- La columna es **overlay**: no reserva espacio ni toca la rejilla del Frame.
- Un dockapp de span 3 puede no caber en una barra llena; el submenú no fuerza.

## Referencias

- `shell/notify.gd`, `shell/applet_notif.gd`, `shell/notifications_panel.gd`,
  `session/gdtk-notify`, `session/autostart.sh`.
- `SPEC-sugar-frame-applets.md`, `guides/dockapp.md`, `SPEC-architecture.md`,
  `SPEC-control.md`.
