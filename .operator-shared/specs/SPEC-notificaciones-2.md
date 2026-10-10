# SPEC — Notificaciones v2 (diagnóstico + diseño)

Estado: **implementado** (2026-10-10) en scripts + daemon; reemplaza al primer corte
(`SPEC-notificaciones.md`) en los puntos que toca. Pendiente de recarga/verificación en
sesión viva. Requiere reiniciar `gdtk-notify` (el shell lo supervisa).

Alcance del rework pedido (2026-10-10):
1. El dockapp no usa el ícono de la aplicación.
2. No se ve el texto de la notificación (ni con hover).
3. Las notificaciones no caducan nunca.
4. No persisten entre reloads del shell.
5. La atención de ventanas (frame salta / ventana resalta) no se percibe.

---

## 1. Diagnóstico (causas raíz, verificadas en bastion 2026-10-10)

### 1.1 El daemon no corre (raíz de 1, 3 y 4)
- `ps` no muestra `gdtk-notify serve`. El store `$XDG_RUNTIME_DIR/gdtk/notifications.json`
  quedó `{"revision":43,"items":[]}` y `$XDG_RUNTIME_DIR/gdtk-notify.log` repite
  `push: ...ServiceUnknown: The name is not activatable`: `org.freedesktop.Notifications`
  **no tiene dueño**.
- Sin daemon, `shell/notify.gd:_work` (≈línea 496) cae al historial `local` **en memoria
  del thread del worker**. Ese `local` muere con el thread → **pérdida entre reloads**
  (observación 4). Y ninguna app externa puede notificar → **no hay íconos externos**
  (contribuye a observación 1).
- `session/autostart.sh:95-102` arranca `serve` una vez; si muere, nadie lo relanza.

### 1.2 Ícono del dockapp (observación 1)
- `shell/applet_notif.gd:36-42` guarda `icon_path = resolve_icon_name(icon, app_id)`,
  que devuelve un **nombre** (`"firefox"`, `"org.mozilla.firefox"`), no un path.
- `draw()` lo pasa a `shell._load_png_file()` (`shell/shell.gd:5139`), que espera un
  **path**: `Image.load("firefox")` falla → cae siempre a la campana genérica
  (`applet_notif.gd:66-69`).
- En cambio `notifications_panel._icon` (`notifications_panel.gd:266-277`) sí resuelve
  con `shell.apps.resolve_icon()` (`shell/apps.gd:431`). La lógica está duplicada y sólo
  una copia es correcta.
- Para externas, el estándar recomienda resolver el ícono vía `desktop-entry` hint →
  `.desktop` → `Icon=`. Hoy el daemon pone `app_id` desde `desktop-entry`
  (`session/gdtk-notify:289`) pero nadie encadena hasta el `Icon=`.

### 1.3 Texto nunca visible (observación 2)
- Dockapp: sólo se dibuja `value` = resumen truncado a una línea
  (`applet_notif.gd:76-82`). `detail`/`tooltip()` (`applet_notif.gd:121-130`) se calcula
  pero **no se renderiza en ningún lado**; el Frame no tiene tooltip propio.
- Columna: el hover sólo resalta el bloque (`notifications_panel.gd:143-178`); no
  expande ni muestra `body`.

### 1.4 Nunca caducan (observación 3)
- `session/gdtk-notify:296`: `expires_ms = int(expire) if int(expire) > 0 else 0`.
  `expire_timeout == -1` (el default de casi toda app) se convierte en `0` = **nunca**.
  La spec freedesktop dice: `-1` = default del servidor, `0` = nunca.
- El modelo no tiene TTL de historial: con `expires_ms == 0` una entrada sólo sale por
  el cap (`history_max`). Internas (`request_attention` `notify.gd:160`, `raise_urgency`,
  `rpc push` sin `expires_ms`) tampoco expiran.
- `read` nunca pasa a `true` (`notify.gd:343`), así que el badge de no leídas es siempre
  `== total`.

### 1.5 Atención de ventanas no se percibe (observación 5)
- El motor **sí** emite `toplevel_activate`
  (`modules/wayland/wl_server.c:2015` → `modules/wayland/wayland_compositor.cpp:425`);
  el shell conecta (`shell/shell.gd:1271`) y llama `notify.request_attention`
  (`shell/shell.gd:11011-11020`). La cadena llega.
- Pero el feedback es **sólo** un contorno pulsante: tesela (`shell/tiles_ui.gd:74-82`) o
  ventana (`shell/window_deco.gd:96-98, 168-173`), y **sólo si la ventana está visible**
  (`shell.view.visible`; `window_deco` hace `return` temprano en exposé, línea 82). Si la
  ventana está **minimizada o en otra actividad/workspace**, no hay tesela → no se ve nada.
- Nunca hay "salto" (bounce): ni la tesela, ni el dockapp, ni el título de la actividad.
- Un pedido de atención de un cliente que no emite xdg-activation (o que el motor no
  reenvía) no se registra.

---

## 2. Diseño

### Principios
- El estándar freedesktop es el contrato externo (`Notify`, `CloseNotification`, hints,
  `expire_timeout`).
- Hilo de render **sin I/O** (regla dura de `SPEC-architecture.md`).
- Atención pasiva: **no roba foco**; enfocar es una acción explícita.
- La **presentación** (toast/bloque) es efímera; el **historial** persiste y **envejece**.

### 2.1 Daemon y persistencia (arregla 1, 4)
- **Store persistente** en `$XDG_STATE_HOME/gdtk/notifications.json`
  (fallback `~/.local/state/gdtk/`). tmpfs se reserva a lo efímero. Migración: si existe
  el viejo `$XDG_RUNTIME_DIR/gdtk/notifications.json`, se importa una vez.
- **Escritor único efectivo**: el daemon si corre; si no, el worker de `notify.gd` escribe
  el mismo archivo (atómico tmp+rename). El invariante pasa a ser "nunca dos escritores a
  la vez", garantizado con `flock` sobre `<store>.lock`. Así, reloads y caída del daemon
  no pierden historial.
- **Arranque robusto**: `serve` loguea "daemon iniciado" y el motivo de salida; el
  supervisor del shell (tick, como Deskflow) relanza `gdtk-notify` si murió. Nuevo RPC
  `notify {"action":"status"}` → `{daemon: up|down, store, items, unread}` para diagnóstico.

### 2.2 Expiración: toast vs historial (arregla 3)
- `expire_timeout` (spec): `>0` ms; `-1` = default del servidor por urgencia; `0` = nunca
  (residente). El store guarda `expires_ms` como **instante absoluto** cuando aplica, `0`
  cuando es "nunca".
- Defaults cuando `-1` (config): low 4 s, normal 5 s, critical 8 s. Con hint
  `resident=true`, o `critical` con acciones, `0` (permanece hasta descarte).
- **Historial con edad**: nuevo `history_ttl_ms` (config, por defecto 0 = sólo cap). El
  daemon y el worker prunan por `created_ms` además de por `expires_ms` y `history_max`.
- Internas: `request_attention` registra con `expires_ms = now + ATTENTION_MS`;
  `raise_urgency` ya usa TTL; `rpc push` sin `expires_ms` usa el default por urgencia.

### 2.3 Íconos (arregla 1)
- `applet_notif.refresh` usa `shell.apps.resolve_icon(icon_or_app_id)` (path real), igual
  que la columna.
- Nuevo helper compartido `notify_icon(shell, record)` (dockapp, columna y tarjeta de
  hover) con la cadena: `desktop-entry` → `Icon=` del `.desktop` → `app_icon` →
  `apps.resolve_icon`. Cachear por `app_id`/`icon` (reusar caché de `_load_png_file`,
  `shell.gd:5139`).

### 2.4 Presentación: hover + bounce (arregla 2 y parte de 5)
- **Dockapp**: al hover, tarjeta sobre el Frame con ícono + `app` + `summary` + `body`
  (multilínea, envuelto ~320 px) + hora + acciones. Sin hover, la línea actual.
- **Columna**: al hover, el bloque se ensancha a tarjeta con `summary` + `body` +
  acciones (reemplaza el sólo-resaltar actual).
- **Bounce**: animación "salto" (translate/escala con easing, ~2 rebotes) sobre la tesela
  en atención, el dockapp y el bloque nuevo. Reloj en `notify` (`bounce_alpha(id)`),
  dibujo en el hilo de render, se detiene al terminar (no romper ahorro energético).
- **`read`**: se marca al abrir la tarjeta, al enfocar la ventana, o con "marcar leídas".
  Badges leen `unread`.

### 2.5 Atención de ventanas (arregla 5)
- Mantener el contorno pulsante, pero **no depender de la visibilidad**: si el root está
  minimizado o en otra actividad/workspace, marcar:
  - el **título de la actividad** en el Frame (bounce + color),
  - el **dockapp de notificaciones** (bounce global),
  - (opcional) indicador en el ring/exposé de esa ventana.
- **Bounce de escala** en la tesela (además del contorno) para que "salte".
- Fuentes unificadas en `notify.request_attention(win, texto, {origen})`:
  xdg-activation (ya llega), notificaciones con `target_window`, urgencia de dockapps.
- Robustez: permitir que el daemon marque atención al recibir un `Notify` con
  `target_window`/hint, para clientes que no emiten xdg-activation.
- Limpieza: atención se limpia al enfocar (ya) o al abrir la tarjeta.

### 2.6 Ajustes (Configuración → Notificaciones)
- Nuevos: `toast_ms` (default por urgencia), `history_ttl_ms`, `bounce`, `hover_card`,
  `iconos`. Se suman a los actuales (`enabled`, `toast_transitorio`, `atencion_foco`,
  `urgencia`, `history_max`, `columna_modo`, `silencio`).
- `settings/settings_model.gd:115` `NOTIFICATIONS_DEFAULT` extendido;
  `settings_bridge.notifications()` propaga.

### 2.7 Contrato de la entrada (v2, compatible)
Se agregan campos opcionales: `resident`, `read_at_ms`, `category`. `expires_ms` pasa a
ser instante absoluto (ya lo era). No rompe entradas v1.

---

## 3. Archivos tocados (previsto)
- `session/gdtk-notify` (expire_timeout, store state, status, log).
- `shell/notify.gd` (store fallback persistente, TTL, atención, bounce clock, status).
- `shell/applet_notif.gd` (ícono resuelto, tarjeta hover, badge/read).
- `shell/notifications_panel.gd` (hover card, ícono helper, bounce).
- `shell/window_deco.gd`, `shell/tiles_ui.gd`, `shell/frame.gd` (bounce, atención
  multi-workspace, título de actividad).
- `settings/settings_model.gd`, `settings/pages/notifications.gd`,
  `shell/settings_bridge.gd` (settings nuevos).
- Tests: `tests/notify_model_test.gd`, `tests/applet_notif_test.gd`,
  `session/gdtk-notify selftest`.

## 4. Plan de pruebas
- Modelo: `-1/0/>0`, TTL de historial, `replaces_id`, cap, round-trip del store.
- Dockapp: ícono resuelto a path, tarjeta hover, `unread`/`read`.
- E2E: daemon caído → push interno → reload shell → el historial sigue; `notify {push}` →
  hover muestra body + ícono; activación de ventana **minimizada** → el Frame salta.

## 5. Riesgos y límites- Escribir en `$XDG_STATE_HOME` (fuera de tmpfs): evaluar ruido; atómico, con TTL/cap.
- El daemon depende de Python3/PyGObject; el fallback del worker debe ser de primera clase.
- `ActionInvoked` hacia la app original sigue limitado a su conexión D-Bus viva.
- Sin cambios de motor (xdg-activation ya emite).

## 6. Controles de audio universales (IMPLEMENTADO 2026-10-10)

Una tecla de volumen (subir/bajar/silencio) se aplica local y se **difunde a todos los
equipos del Grupo** por el canal peer; **viaja la acción, no el nivel** (cada host
conserva su propio volumen). Se reutilizan las teclas multimedia y el OSD existentes.

- Canal: método peer `media` (`peer_link.METHODS` + validador `media_action()`),
  despachado en `peer_control.gd` → `shell._peer_media()` (aplica local, no re-difunde).
- Emisor: `system_osd.media_action(action)` aplica local y llama a
  `shell._broadcast_media()` (destinos de `_group_targets()`); no difunde si la captura
  de Deskflow tiene el teclado.
- Sin peers: sólo local. Brillo: **no** universal (es por equipo).
- Toggle: Ajustes → **Sonido** («Aplicar el volumen y el silencio a todo el Grupo»,
  `audio.universal` en settings.json, default activo; `settings_model.audio()` +
  `settings_bridge.audio()` + `_apply_audio_settings()`). El applet **Volumen** anota en
  su tooltip «· se aplica a todo el Grupo» cuando está activo.
- Regresión: `tests/universal_audio_test.gd` (aplica/difunde, el par no rebota,
  validación, cableado y ajustes).

Nace como «universal mute» y se amplió a vol up/down.
