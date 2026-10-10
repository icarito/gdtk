# Sesión 2026-10-10 — Notificaciones v2

Rework del sistema de notificaciones (SPEC-notificaciones-2). Todo implementado,
sincronizado a `~/gdtk` y activado con recarga transaccional en bastion (mismo PID
124811, ventanas intactas). Sin commit.

## Observaciones del usuario
1. El dockapp no usaba el ícono de la aplicación.
2. No se veía el texto de la notificación (ni con hover).
3. Las notificaciones no caducaban nunca.
4. No persistían entre recargas del shell.
5. La atención de ventanas (frame que salte / ventana que resalte) no se percibía.

## Diagnóstico (verificado)
- **Daemon no corría**: `push` fallaba con `ServiceUnknown`; el shell caía al historial
  en memoria del worker → pérdida entre recargas y sin íconos externos.
- **Ícono del dockapp**: se resolvía a un *nombre* y `_load_png_file` esperaba un *path*.
- **Texto**: el dockapp sólo pintaba una línea; el tooltip no se veía en las barras.
- **Caducidad**: `expire_timeout=-1` se convertía en `0` = nunca; sin TTL de historial.
- **Atención**: el feedback sólo aparecía si la ventana estaba visible; sin bounce.

## Cambios
- **`session/gdtk-notify`**: store persistente en `$XDG_STATE_HOME/gdtk/notifications.json`
  (migra el viejo de tmpfs); `expire_timeout` fiel a la spec (`-1`→default por urgencia
  4/5/8 s, `0`→nunca, `>0`→ms); interfaces `Push` (JSON interno, preserva
  `target_window`/`resident`), `Read`, `ReadAll`; rearma timers al arrancar; pidfile;
  log de inicio/fin.
- **`shell/notify.gd`**: fallback persistente del worker sincronizado con el store (no
  lo clobbea); TTL de historial; `mark_read`/`mark_all_read`; `bounce_alpha`; `status`;
  detección del daemon por pidfile + `/proc/<pid>/stat` (zombis = muerto); ojo:
  `File.get_as_text()` no sirve en procfs, usar `get_line()`.
- **`shell/shell.gd`**: `_notify_supervise` relanza el daemon vía `setsid --fork`
  (desacoplado, sin zombis), cooldown 15 s; sincroniza los ajustes nuevos.
- **`shell/applet_notif.gd`**: ícono resuelto a path (`shell.resolve_notify_icon`), salto
  del aviso nuevo, expone `hovered`/`hover_rect`.
- **`shell/notifications_panel.gd`**: tarjeta de hover con ícono + app + summary + body
  multilínea + hora (para bloques y para el dockapp), bounce del bloque, `mark_read` al
  activar. Ojo: `WINDOW_TOP_LAYER = 33554432` es const local, no está en ImGuiCanvas.
- **`shell/frame.gd`**: franja pulsante+bounce en la barra superior cuando hay atención
  (visible aunque la ventana esté minimizada o en otra actividad/workspace); setea
  `applet_mods["notificaciones"].hovered`.
- **`shell/tiles_ui.gd` / `window_deco.gd`**: bounce del contorno de atención.
- **`settings/`**: `NOTIFICATIONS_DEFAULT` + normalización (`iconos`, `hover_card`,
  `bounce`, `toast_ms_low/normal/critical`, `history_ttl_ms`), página actualizada.

## Validado e2e en bastion
- Daemon arriba + supervisado (deja de relanzar cuando `daemon_ok`).
- `push` con ícono/cuerpo; `list`; **expira** según `expires_ms`; `read` baja `unread`;
  **persiste tras `reload_shell`**; store en `~/.local/state/gdtk/notifications.json`.
- Sin errores de script nuevos tras la recarga final.

## Pendiente / no hecho
- Sin probar con puntero real: tarjeta de hover y bounce (requieren interacción).
- Marcado de `read` al abrir la tarjeta de hover del dockapp (hoy sólo al activar bloque).
- Íconos SVG de apps: `Image.load` no rasteriza SVG; si el tema sólo trae SVG, cae a la
  campana (limitación preexistente).

## Segunda tanda (2026-10-10, tarde)- **Bloques sin margen**: la columna usa la MISMA grilla del Frame (`frame.bar_grid`,
  PAD=0 → bloque = pitch = side), alineada a `grid.margin`, apilada por `pitch` (pegada).
  Se compensa el recorte de 1 px del borde de la ventana ImGui con 1 px de relleno
  transparente (`edge = 1.0`) para que el bloque use toda su unidad. Se quitó el offset
  (4,4) y el `ROW_GAP` que dejaban aire.
- **Aviso al copiar**: `applet_clipboard` publica `take_copy_event()` cuando el worker ve
  una copia local NUEVA (no la primera lectura); `shell._clip_sync_poll` lo drena y hace
  `notify.push_internal` (App «Portapapeles», summary «Copiado», body = resumen,
  ícono `edit-copy`, `expires_ms` +4 s). Verificado: aparece el aviso «Copiado».
- **Elevación de la dockapp**: la dockapp de notificaciones se ELEVA ~7 px (salto) al
  llegar un aviso, para cualquier fuente (app, dockapp, urgencia, atención, RPC). Se
  aplica en `frame._draw_applet` (desplaza `pos`/`scr`); se quitó el `dy` interno del
  applet para no duplicar.
- **RAISE sobre ventanas (incl. fullscreen)**: «elevar» era *raise*, no el salto. La
  columna se dibujaba con Godot/ImGui, pero el scanout directo del fullscreen (P4)
  dejaba la ventana por encima. Se agregó la columna a `_scanout_overlay_active()`
  (si hay bloques visibles, se pausa el scanout) y `WINDOW_TOP_LAYER` a la ventana de
  la columna, así el aviso queda encima de la ventana a pantalla completa.
- **Fondo de la tarjeta de hover**: se veía sólo el texto. Causa: `imgui_draw_rect_filled`
  y `_bevel` usan coordenadas de **PANTALLA**, no locales de la ventana ImGui, así que
  el fondo se dibujaba en (0,0) de pantalla (recortado por el clip de la ventana) y
  sólo el texto (`set_cursor_pos`+`text_colored`, que sí son locales) aparecía. Se
  corrigió el fondo/borde de la tarjeta a coords de pantalla (`anchor`) y se agregó un
  relleno explícito al bloque de la columna. También se desactivó el tooltip de ImGui
  del dockapp de notificaciones (iba sin fondo) para no duplicar la tarjeta.
  Verificado por screenshot (muestra de píxeles `NX_BG` en la tarjeta).

## Sync/estado

- Sincronizado a `~/gdtk` y recargado en **bastion** (mismo PID 124811). Sin errores de
  script nuevos (655 totales, todos previos). Pendiente de commit.
- **Deploy a `tengu.local` y `cupid.local`** (2026-10-10): rsync de `shell`/`settings`
  con `--delete` + `session` sin `--delete` a `~/gdtk`, se mató el daemon viejo
  (`pkill gdtk-notify serve` + borrar pidfile) y se recargó el shell (RPC
  `reload_shell`). Verificado: `notify status` → `daemon:true`, y `push` de prueba
  aparece en `list` en ambos hosts.

## Feature pedido (pendiente de diseñar)

- **Controles de audio universales**: mute/unmute **y** volumen arriba/abajo aplicados a
  *todos* los equipos del Grupo (difusión), **sin sincronizar el nivel** (cada equipo
  mantiene su propio volumen; sólo viaja la acción). Accesible desde el shell con las
  teclas multimedia y OSD de estado. A definir: atajo, indicador/applet en el Frame,
  reutilizar `media`/`system_osd` + el canal peer del Grupo, y comportamiento cuando no
  hay peers. Anotado por pedido del usuario, 2026-10-10 (alcance inicial: mute global;
  ampliado a vol up/down universal).

