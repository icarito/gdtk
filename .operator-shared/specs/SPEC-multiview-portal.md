# SPEC — Servidor multiview del Vecindario y su salida por portal (ScreenCast)

Estado: propuesta implementable. Extiende `SPEC-screen-share-compass.md` (gvd,
direcciones, sesiones) y `SPEC-embedded-multi-output.md` (broker de captura
interno); no reemplaza el flujo Wi-Fi, el modelo DNS-SD ni el contrato de
`SPEC-architecture.md`.

## 0. Decisión de alcance

Un equipo del Grupo **hospeda** una vista que recibe la pantalla de varios
miembros a la vez, la compone en tiles y la publica como **feed** por el
**portal ScreenCast** para que cualquier cliente local la capture. No hay trabajo
específico de OBS: el portal es la API y OBS (u otro cliente) es sólo un
consumidor posible.

Dos niveles, explícitos:

- **N0 — salida por el portal existente (sin motor).** El multiview se dibuja en
  gdtk; el `ScreenCast` ya está enrutado a `xdg-desktop-portal-wlr` y, como el
  shell es fullscreen sobre sway, **xdpw ya captura todo el escritorio gdtk**. El
  feed por portal existe hoy sin tocar el motor. Es el MVP.
- **N1 — fuente propia "multiview" (motor).** Backend `ScreenCast` nativo en
  `modules/wayland` que exporta **sólo** la vista compuesta como nodo PipeWire y
  la ofrece como fuente elegible. Es la vía limpia para no capturar el Frame y
  el resto del escritorio, pero exige recompilar y un corte controlado.

El feature del servidor (anuncio, recepción de N flujos, composición, seguir el
puntero) es el cuerpo de esta SPEC; N0/N1 son su salida.

## Estado de implementación (2026-10-12)

- **Hecho y verificado (sin motor):**
  - **F1** modelo puro `shell/multiview_model.gd` (+ `tests/multiview_model_test.gd`).
  - **F2** TXT `mv`/`mv_slots`/`mv_base` en `shell/neighborhood_publish.gd`,
    `neighborhood_publish_plan.gd`, `neighborhood_hosts.gd` (+ tests).
  - **F0** honestidad de emisión y plan de recepción por slot en
    `shell/gvd_launch.gd` (`multiview_recv_plans`, `emitter_send_kind`) y claves en
    `shell/gvd_session.gd`.
  - **F3** ciclo de vida + protocolo peer + RPC en `shell/shell.gd`
    (`multiview_start/stop`, `_peer_mv_slot/_peer_mv_stop`), `shell/peer_link.gd`
    (`mv_slot`/`mv_stop`), `shell/peer_control.gd`, `shell/remote.gd`
    (método `multiview`). Verificado con parse check y tests; sin FAIL nuevos.
  - **Dueño del puntero** (base del "seguir el puntero" y del radar):
    `shell/pointer_owner.gd` + `shell/pointer_owner()` en `shell/shell.gd`, y
    `focus.peer` en `shell/frame.gd` (el radar resalta el equipo correcto).
- **F5 (motor) implementado, desplegado y verificado end-to-end:** backend nativo
  `org.freedesktop.impl.portal.ScreenCast` con exportador PipeWire.
  - `modules/wayland/screencast.{c,h}`: productor PipeWire (`pw_thread_loop` +
    `pw_stream` `PW_DIRECTION_OUTPUT`; un productor aparece como
    `Stream/Output/Video`, formato `RGBA8`). Clave: el `node_id` se lee recién
    tras el bound con el servidor (roundtrip, acotado); leerlo inmediato tras
    `connect` devuelve `SPA_ID_INVALID` y el cliente no puede engancharse.
  - `modules/wayland/eis_server.c`: métodos reales `CreateSession`/
    `SelectSources`/`Start` (results `streams` = `a(ua{sv})` con `position`,
    `size`, `source_type=1`, `pipewire-serial`) y propiedades
    `AvailableSourceTypes = MONITOR|VIRTUAL (1|4)`, `AvailableCursorModes = 1`.
  - `modules/wayland/remote_input.{h,cpp}`: bindings `screencast_active()` y
    `screencast_push(w,h,PoolByteArray)` (valida tamaño; no bloquea).
  - `modules/wayland/SCsub`: linkea `libpipewire-0.3`.
  - `shell/shell.gd`: alimentador a ~15 fps que empuja el viewport RGBA8 mientras
    hay fuente activa (inactivo si el binario no expone los métodos).
  - `session/gdtk-portals.conf`: `org.freedesktop.impl.portal.ScreenCast=gdtk`.
  - **Desplegado y activo** en bastion, tengu.local y cupid (motor reinstalado +
    shell reiniciado; portal `active`). Verificado con un cliente real por
    `org.freedesktop.portal.ScreenCast`: `CreateSession`/`SelectSources`/`Start`
    = 0; `Start.results.streams` trae un `node_id` real; el nodo `gdtk-multiview`
    aparece al `Start` y desaparece al `Close`; y `gst-launch-1.0 pipewiresrc
    path=<node_id>` recibió frames (3×1920×1080 RGB).
  - Caveats: `pipewire-serial` = node id (token de restore no estable); sin
    indicador visible en pantalla durante la captura; `screencast_new` bloquea el
    hilo del shell de forma acotada (~ms típicos) en el `Start`.
- **F4 (Vista del grupo) implementado y desplegado:** vista compuesta en el shell.
  - `tools/gvd/gvd.py`: `recv --title <texto>` (título por instancia).
  - `shell/gvd_launch.gd`: `local_recv_argv(..., title)` y `multiview_recv_plans`
    con título `"Vista del grupo — <label>"` por slot.
  - `shell/multiview_model.gd`: `TITLE_PREFIX`/`title_label`/`match_hid`/`unknown_label`.
  - `shell/shell.gd`: mapeo ventana↔`hid` por título, `_multiview_arrange`
    (convierte receptores tiled a flotantes anclados a la pantalla visible y los
    fija en la grilla), `_multiview_restore` (restaura modo/ancla/rect al cerrar),
    `_multiview_draw` (resalta el tile del dueño del puntero) y
    `multiview_set_follow(off|focus)`.
  - `shell/remote.gd`: reenvía `follow`; `mcp/gdtk_mcp.py`: tool `gdtk_multiview`.
  - `_peer_mv_slot` acepta que un peer en Wayland (gdtk sobre sway) mande su
    escritorio completo por captura wlr-screencopy (antes sólo GNOME/wlroots).
  - Verificado: parse check 34/34 ok, tests puros ok, `verify_all` sin FAIL nuevos.
    **Pendiente de validación visual** en sesión viva (composición, restaurado y
    resaltado). Abrir/cerrar: RPC `multiview {on, peers, follow}` o tool MCP
    `gdtk_multiview`.
- **Rediseño OFFLINE (2026-10-12, tras bloquear el escritorio 2 veces):** la composición
  ya NO mueve ventanas reales al escritorio. `gvd recv --sink shmout --shm-out <path>`
  publica frames RGBA en un archivo shm (contrato `GVDSHM1`) **sin abrir ventana**;
  `shell/multiview_canvas.gd` los lee y compone una grilla (`MULTIVIEW.tile_rects`, con
  letterbox por tile) en un `Viewport` **fuera de pantalla**, y F5 empuja ESE texture
  —no `get_viewport()`— cuando `multiview_on`. Así el feed es un mosaico limpio (no
  espeja el escritorio, no incluye la ventana del cliente, sin toplevels que roben foco
  ni readback del escritorio). Cambios: `tools/gvd/gvd.py` (sink `shmout`, `--shm-out`,
  `--shm-fps`, `ShmWriter`), `shell/neighborhood_actions.gd` (sink+opts), `shell/gvd_launch.gd`
  (`multiview_offscreen_plans`), `shell/multiview_canvas.gd` (nuevo), `shell/shell.gd`
  (arranque/parada + feeder). Verificado: e2e loopback de gvd (frames RGBA fluyen por el
  archivo), parse check y tests puros (`multiview_canvas_test`, `gvd_launch_test`,
  `neighborhood_actions_test`) sin FAIL nuevos.
  **Activación:** `reload_shell` sólo recompila `shell.gd`; los módulos preloaded
  (`gvd_launch.gd`, `neighborhood_actions.gd`) **quedan cacheados y requieren reinicio
  del shell** (o próximo login) para tomar los planes `shmout`. Hasta entonces `multiview`
  falla honesto con "requiere reiniciar el shell".
  **Validado e2e (2026-10-12, tras reinicio del shell):** con un peer wayland (cupid) el
  portal (ScreenCast gdtk) sirvió el **mosaico compuesto a 1920×1080** (`pipewiresrc
  path=<node>` entregó 3 frames RGB, `mean 23.7 var 450.7`); el escritorio quedó **limpio
  y responsivo** (sin ventanas de receptor; fps ~62). Detalle crítico: `screencast_push_rgba`
  (C) **descarta el frame si el tamaño no coincide** con la geometría del stream
  (`OS.get_window_size()`, difundida por `RemoteInput::_notification` → `eis_server_set_size`),
  así que el canvas se crea EXACTAMENTE al tamaño de la ventana (los receptores sí decodifican
  chico, tope `MULTIVIEW_TILE_CAP`). Pendiente menor: el resaltado de "seguir el puntero"
  (F4 follow) no se dibuja aún en el canvas offscreen; y un peer X11 (`XDG_SESSION_TYPE=x11`,
  p. ej. tengu hoy) no puede emitir escritorio completo y su tile queda degradado (honesto).

### Activación de F5 (corte controlado, `SPEC-session-continuity.md`)

1. Build e instalar el binario del motor (mismo `deploy.sh`/build; para bastion:
   scons + `objcopy --remove-section .note.gnu.property` + copiar a
   `~/gdtk/bin/godot-gdtk`), con el trabajo guardado.
2. Cambiar `org.freedesktop.impl.portal.ScreenCast=gdtk` en
   `session/gdtk-portals.conf` y reinstalar el portal del usuario (`portal.sh`).
   Antes de eso, mantener `wlr` (comportamiento actual N0).
3. Verificar: `pw-cli ls Node` muestra el nodo `gdtk-multiview`
   (`Stream/Output/Video`); un
   cliente portal (`gdbus`/libportal) obtiene fd por `OpenPipeWireRemote` y
   recibe frames. Si falla, volver el routing a `wlr`.

## 1. Hechos verificados en el repo (base de diseño)

| Hecho | Dónde |
|---|---|
| Discovery mDNS por servicio, agrupado por `hid`; el rol receptor ya anuncia `_gdtk-gvd._udp` con `role=recv`, `state=capable|ready`, puerto 5600 | `shell/shell.gd:6067-6071`, `shell/neighborhood_publish.gd` |
| `gvd recv` es **un stream por proceso y por puerto** (video `--port`, cursor `--port+1`); un monitor por proceso en `send` | `tools/gvd/README.md:130-131,156`, `tools/gvd/gvd.py:1771` |
| El shell ya orquesta receptores rastreados por equipo (clave `gvdrecv:<hid>`, PIDs, threads) sin duplicar el ciclo de vida | `shell/gvd_launch.gd:200-248`, `shell/shell.gd:301-306`, `:8694-8720` |
| El shell ya compone: mosaico de ventanas y **exposé** (tiles, z-order, foco) | `shell/expose_layout.gd`, `shell/shell.gd:470-479` |
| Captura de una ventana a frames: `get_layers(wid)` → Viewport offscreen → contrato `shm` → `gvd send --capture shm` | `shell/window_cast.gd:1-17,55-240` |
| Captura del viewport completo (para pantallazos): `get_viewport().get_texture().get_data()` | `shell/remote.gd:571` |
| `ScreenCast` del portal está **enrutado a `wlr` (xdpw)**, no a gdtk; el shell es fullscreen sobre sway, así que xdpw captura todo el escritorio gdtk | `session/gdtk-portals.conf:19`, `session/portal.sh:31-43` |
| El backend `ScreenCast` de gdtk está **vacío** (todo pedido `m_unsupported`), sólo existe para que libportal lea la versión | `modules/wayland/eis_server.c:1042-1061,1296` |
| El motor ya linkea `libeis`/`libsystemd`/wlroots, **no** libpipewire | `modules/wayland/SCsub:44-51` |
| Uso previo de libpipewire en el repo (helper C) | `tools/gvd/gvd-cursor.c` |
| El estado de captura de input es consultable (`is_capturing()`), y el shell sabe por qué borde/host cruzó el puntero (barreras EIS + links Deskflow del compás) | `shell/shell.gd:13154-13157,8559`, `modules/wayland/eis_server.c`, `shell/screen_layout.gd` (`link_ranges`) |
| gdtk **no** puede emitir su escritorio completo todavía: `--capture gdtk` está planificado pero no implementado en gvd; sólo emite ventana (`shm`) o, en un sway convencional, un output `--capture wlr --output` | `shell/gvd_launch.gd:56-84,140-176`, `tools/gvd/gvd.py:1755-1763`, `SPEC-embedded-multi-output.md:§8,§13` |

Consecuencia honesta: **"todo el grupo manda su pantalla" sólo se cumple hoy con
miembros GNOME/sway.** Un miembro gdtk aporta una ventana (o nada, hasta la Fase
D de `SPEC-embedded-multi-output.md`).

## 2. Objetivo

1. Un miembro del Grupo (el "host multiview") se anuncia como capaz de recibir N
   pantallas y hospedarlas.
2. Los demás miembros pueden mandarle su pantalla (o una ventana, según su
   capacidad real) con una acción explícita.
3. El host compone los flujos en tiles y los muestra.
4. La vista compuesta se publica como **feed por el portal ScreenCast**; cualquier
   cliente local la captura sin código específico de OBS.
5. Opcional: un modo "seguir el puntero" resalta/cambia el tile de la máquina
   donde está el puntero (estado de Deskflow/InputCapture).

## 3. No objetivos

- Un camino específico de OBS (ni plugin, ni Media Source atado a OBS).
- Cifrado o autenticación del stream H.264: sigue siendo LAN de confianza/VPN.
- Reenvío de input por el feed: gvd **no** devuelve input. El puntero entre
  equipos es Deskflow; el feed es sólo video.
- Espejo (mirror) de una salida real. Sólo extensión/mosaico de lo que el emisor
  comparte.
- Reemplazar exposé/Grupo: el multiview es una actividad/vista más.
- ScreenCast nativo en el **primer** corte (es N1, Fase F5).

## 4. Arquitectura

```text
miembros que envían                         host multiview (gdtk)
┌──────────────┐   gvd send pantalla  ┌───────────────────────────────────────────┐
│ GNOME "A"    │ ── H.264 :5700 ─────▶│ gvd recv :5700 → slot 0                     │
├──────────────┤                      │ gvd recv :5702 → slot 1    ┌────────────┐   │
│ gdtk "B"     │ ─(ventana, hoy)─────▶│ gvd recv :5704 → slot 2    │ composición│   │
├──────────────┤                      │ …                          │ (tiles)    │   │
│ GNOME "C"    │ ── H.264 :5704 ─────▶│ disposición = compás/Grupo └─────┬──────┘   │
└──────────────┘                      └───────────────────────────────│──────────┘
        ▲                                                              ▼
        └── Deskflow: puntero real cruza N/S/E/O (ya existe)   portal ScreenCast
                                                               (N0: xdpw sobre sway;
                                                                N1: backend gdtk)
```

Contratos que no se negocian:

- **El hilo de render nunca espera** (`SPEC-architecture.md` §1): discovery,
  `gvd`, ssh/canal peer, procesos y lectura de disco van a workers con snapshot;
  el dibujo sólo copia.
- **Lógica pura aparte**: el reparto de slots, el layout de tiles y la decisión de
  "tile activo" viven en `extends Reference`, no en `shell.gd`.
- **Vocabulario de producto**: la UI nunca dice `gvd`/`deskflow`/`hid`.

## 5. Anuncio del rol (mDNS)

Se reutiliza `_gdtk-gvd._udp` y `neighborhood_publish.gd`. Se añaden claves
**opcionales, informativas y sin secretos**; ausentes equivalen a no-hospedar:

```text
mv=1            # este equipo puede hospedar un multiview
mv_slots=4      # tiles simultáneos admitidos (informativo, acota la UI)
mv_base=5700    # puerto base de recepción de video; el cursor va en +1
```

Reglas:

- total del TXT < 200 bytes, cada entrada < 255 (ya vigente).
- Si el host no tiene `gvd` o no puede hospedar, **no** anuncia `mv`.
- El TXT no lleva puertos de peers, direcciones ni identidades de terceros.

## 6. Modelo puro — `shell/multiview_model.gd`

`extends Reference`, sin I/O ni nodos, con `tests/multiview_model_test.gd`.

```gdscript
# Reparto determinista de slots/puertos por hid. base + 2*i evita que el cursor
# (port+1) choque con el video del slot siguiente.
static func assign_slots(peers, base = 5700, max_slots = 4) -> Dictionary
#   -> { "<hid>": {"slot": i, "port": base + 2*i, "cursor_port": base + 2*i + 1} }

# Cuadrícula de tiles para `count` flujos en un viewport dado (sin solapes,
# bounding box >= 80% del área útil, como G3/exposé).
static func tile_rects(count, viewport, gutter = 8) -> Array   # [Rect2, ...]

# Disposición cardinal desde el compás/Grupo (N/S/E/O) cuando existe; si no,
# cuadrícula. Devuelve el índice de tile -> hid.
static func place_by_direction(slots, directions) -> Dictionary

# Tile "activo" según la máquina dueña del puntero. `pointer_hid == ""` ->
# sin_foco (devuelve -1).
static func active_slot(pointer_hid, slots) -> int

# Máquina de estados por ruta de recepción.
static func transition(state, event) -> String
#   states: idle|joining|live|degraded|leaving|stopped|failed
#   events: join|ready|drop|resume|leave|stopped|fail|reset
```

Validaciones puras: `hid` sólo átomos seguros; `count` acotado por `mv_slots`;
puertos dentro de un rango permitido; una sola ruta por `hid`.

## 7. Composición

Dos consumidores de la misma fuente de tiles:

- **Pantalla (UI):** una actividad/vista del shell. Para el MVP basta reutilizar el
  patrón de mosaico ya existente (tiles + z-order + foco de exposé,
  `shell/expose_layout.gd`): cada tile es un receptor. El Frame/Hogar/Grupo/Vecindario
  no se pintan **dentro** de un tile.
- **Feed (portal):** ver §9. Para N1 se compone en un `OutputContext` offscreen
  (misma maqueta que `SPEC-embedded-multi-output.md` §6), con fondo, tiles y
  cursor local compuesto; el Frame queda fuera por construcción.

Backpressure y daño (hereda `SPEC-embedded-multi-output.md` §8/§11): si el
consumidor del feed va atrasado se descartan frames intermedios y se conserva el
más nuevo; nunca se bloquea el hilo de render.

## 8. Seguir el puntero

El puntero real **ya** cruza equipos por Deskflow; gdtk conoce el estado de
captura y por qué borde/host cruzó (`shell/shell.gd:13154-13157`,
`screen_layout.link_ranges`, barreras EIS). El multiview lo usa sólo para
**presentar**:

- **Dueño del puntero** = host del link activo de Deskflow (el borde que se está
  cruzando). Sin Deskflow o sin captura activa: sin dueño.
- Modos:
  - `off`: cuadrícula estática.
  - `focus`: el tile del dueño se resalta (borde/acento del equipo); el resto se
    atenúa.
  - `carousel`: sólo el tile del dueño a pantalla completa; los demás en una tira
    lateral.
- El cambio de modo es una acción local explícita y revocable; **nunca** cambia el
  contenido que se envía a otros.
- Casos: dueño sin tile (no comparte) → se mantiene el último tile válido y se
  marca "sin foco"; varios links → gana el de la captura activa; se desactiva el
  auto-follow al abrir un menú/arrastre (igual que el guard de arrastre de
  `_capture_remote_input_event`).

No confundir esto con input: el feed no inyecta nada en los tiles.

## 9. Salida por portal (ScreenCast)

### N0 — portal existente (MVP, sin motor)

El multiview se dibuja en gdtk. `session/gdtk-portals.conf:19` enruta
`org.freedesktop.impl.portal.ScreenCast=wlr`; xdpw captura la única salida de sway,
que es el shell fullscreen, así que **ya exporta el escritorio gdtk completo**. Un
cliente local (Meet/Zoom/`ffmpeg`/OBS…) que pida ScreenCast obtiene la vista.

- Ventaja: cero código de motor; el feed por portal **ya funciona**.
- Límite aceptado: la fuente es "monitor" (todo el escritorio gdtk, con Frame y
  overlays), no un "multiview" con nombre; el cliente recorta si quiere.
- Consentimiento: lo maneja xdpw (`chooser_type=none` hoy, `session/portal.sh:40-42`).

Este es el camino recomendado para el primer corte y ya responde a "aparece como
feed/portal" sin OBS.

### N1 — backend ScreenCast nativo de gdtk (motor, posterior)

Para ofrecer **sólo** la vista compuesta como fuente elegible:

1. Implementar de verdad `org.freedesktop.impl.portal.ScreenCast` en
   `modules/wayland` (hoy `m_unsupported`, `eis_server.c:1042-1061`), registrado
   en `:1296`. Firmas exactas (interface v6):
   - `CreateSession(o handle, o session_handle, s app_id, a{sv} options)` →
     `(u response, a{sv} results)`, `results=[session_id]`.
   - `SelectSources(o, o, s, a{sv})` → `(u, a{sv})`; opciones `types` (bitmask:
     `1` MONITOR, `2` WINDOW, `4` VIRTUAL), `multiple`, `cursor_mode`.
   - `Start(o, o, s, s parent_window, a{sv})` → `(u, a{sv})`; `results["streams"]`
     es `a(ua{sv})`: node id + props `position`, `size`, `source_type`,
     `mapping_id`, `pipewire-serial`.
   - Propiedades `AvailableSourceTypes`, `AvailableCursorModes` (empezar por `1`
     Hidden), `version`.
2. El backend conecta al PipeWire del usuario y exporta un nodo
   `media.class=Stream/Output/Video` (productor) con los frames del `OutputContext` del multiview
   (productor = broker de captura de `SPEC-embedded-multi-output.md` §8). El
   frontend entrega el fd al cliente con
   `org.freedesktop.portal.ScreenCast.OpenPipeWireRemote`.
3. Añadir `libpipewire-0.3` a `modules/wayland/SCsub` (hoy no está); referencia de
   uso: `tools/gvd/gvd-cursor.c`.
4. Consentimiento: el backend decide `response` 0/1/2. MVP: permitir con un
   **indicador visible en pantalla** (como InputCapture), nunca captura silenciosa.
5. Routing: cambiar `org.freedesktop.impl.portal.ScreenCast=gdtk` en
   `session/gdtk-portals.conf` (afecta también Meet/Zoom: implementar además la
   fuente `MONITOR` = salida principal para no perder el comportamiento N0) y
   revisar `session/portal.sh` (reinicio del portal y `control de xdpw`).

N1 es una **fase de motor**: recompilar y activar sólo en un corte controlado
(`SPEC-session-continuity.md`). No se implementa dentro del primer corte.

## 10. Ciclo de vida y puertos

Inicio transaccional del host multiview:

1. Reservar `mv_slots` slots (sin pisar otros `gvd recv` del usuario).
2. Para cada miembro que comparte: lanzar `gvd recv --port <slot.port>` rastreado
   (`_launch_tracked`), con `--cursor none` (el cursor es local) y `--jitter-ms`
   holgado de Wi-Fi.
3. Avisar al miembro por el canal peer autorizado qué `--port` usar para su
   `send` (no por mDNS): reutilizar `shell/peer_control.gd` / el handshake de
   `SPEC-sugar-group-no-ssh.md`. Un peer gdtk recibe además si puede mandar
   pantalla o sólo ventana.
4. Confirmar primer frame por tile y publicar `live`; si no llega, `degraded` con
   reintento acotado.

Detención (misma que el ciclo de vida del Grupo): cortar cada `recv`, avisar
`share_stop` al emisor, liberar slots y volver a `stopped`. Caída de red o de un
emisor → `degraded` y recuperación con backoff, sin rearmar el resto.

Reglas:

- **Un flujo por proceso/puerto** (`tools/gvd/README.md:156`); el host tiene N
  procesos, no uno.
- No duplicar el ciclo de vida: reusar `_launch_tracked`, `gvd_session_pids`,
  `_stop_gvd_session`.
- Ningún `OS.execute` con captura en el hilo de render; el estado de slots se
  publica como snapshot con TTL.

## 11. Seguridad y consentimiento

- mDNS descubre; no autoriza. Mandar pantalla es **acción explícita** por miembro.
- El stream H.264 no cifra ni autentica: sólo LAN de confianza / mesh / VPN.
- TXT sin secretos; el reparto de puertos viaja por el canal peer autenticado, no
  por mDNS.
- Toda sesión viva se ve y se corta desde el mismo host (dockapp Compartiendo /
  menú del equipo).
- N1: el portal no captura en silencio; indicador visible y acción de corte.

## 12. Errores y recuperación

| Error | Detección | Recuperación |
|---|---|---|
| peer sin capacidad de envío | TXT/peer | no ofrecer "compartir a la vista"; explicar |
| peer gdtk sin emisor de escritorio | backend/`caps` | ofrecer sólo "compartir ventana" |
| slots llenos | modelo | lista de espera o rechazo honesto |
| puerto ocupado | bind de `recv` | reasignar slot; no pisar sesiones existentes |
| sin frames en un tile | timeout | `degraded`, reintento con backoff; el resto sigue |
| emisor cae | fin de `recv` | liberar slot; aviso; rearmar si vuelve |
| sin avahi | `detect_avahi` | Vecindario degradado; el multiview local sigue |
| N1: PipeWire no corre | conexión | portal responde error 2; no prometer feed |

## 13. Fases y delegación (Kilo)

Reglas de `AGENTS.md`: un `kilo run` por vez, `--agent code` para cambios
acotados y `--agent ask` para mapeo, `-m kilo/deepseek/deepseek-v4.1-flash`,
write set explícito, sin commit, sin deploy, sin revertir cambios ajenos.

- **F0 — honestidad.** `shell/gvd_launch.gd`/`gvd_session.gd`: exponer si un peer
  puede mandar pantalla o sólo ventana; no prometer escritorio desde gdtk.
- **F1 — modelo puro.** `shell/multiview_model.gd` + `tests/multiview_model_test.gd`
  (§6). Sin I/O.
- **F2 — anuncio.** `shell/neighborhood_publish.gd` (+ `neighborhood_hosts.gd`
  parseo) para `mv`/`mv_slots`/`mv_base`; test del TXT.
- **F3 — orquestación.** `shell/shell.gd` + `shell/gvd_launch.gd` +
  `shell/peer_control.gd`: N `recv` por slot, reparto por canal peer, ciclo de
  vida y snapshot. Sin bloquear el frame.
- **F4 — vista y follow.** Actividad/vista de tiles + `focus`/`carousel` desde el
  estado de InputCapture/Deskflow (§8). Lógica de decisión en el modelo puro.
- **F5 — portal nativo (motor).** HECHO, compilado, desplegado y verificado e2e
  (ver "Estado de
  implementación"): `modules/wayland/screencast.{c,h}`, `eis_server.c`,
  `remote_input.{h,cpp}`, `SCsub`, feed en `shell/shell.gd`. Falta el indicador
  visible y el routing del portal, que entran en el corte controlado.

F1–F4 son scripts recargables. F5 necesita motor y no entra en el primer corte.

## 14. Verificación

- Puros: `tests/multiview_model_test.gd` (slots/puertos deterministas, sin
  solapes, `active_slot`, transiciones). `tools/verify_all.sh`.
- Anuncio: test del TXT con y sin `mv`; ausencia de secretos.
- Parseo de `shell.gd`/`peer_control.gd` con `~/gdtk/bin/godot-gdtk … -s
  tests/parse_check.gd`.
- N0 e2e (sin motor): en instancia aislada, abrir la vista multiview y crear una
  sesión `ScreenCast` con un cliente portal (`gdbus`/libportal) apuntando a la
  salida; verificar frames del escritorio gdtk.
- N1 e2e (motor): `pw-cli ls Node` muestra el nodo `gdtk-multiview`; el cliente
  portal obtiene fd por `OpenPipeWireRemote`, conecta y recibe frames; indicador
  visible mientras dura la captura.
- Nunca se recarga la sesión principal para e2e; instancia aislada
  (`SPEC-isolated-development.md`).

## 15. Criterios de aceptación

- Un host puede anunciarse como multiview y hospedar N tiles rastreados, sin
  bloquear el hilo de render.
- Los miembros pueden compartir explícitamente su pantalla (GNOME/sway) o una
  ventana (gdtk), con la capacidad real reflejada en la UI.
- Cada sesión viva se ve y se corta desde el mismo host.
- La vista compuesta es capturable **por el portal** hoy (N0) sin código de OBS.
- El modo "seguir el puntero" cambia el tile activo según Deskflow/InputCapture y
  es revocable; no inyecta input.
- Sin avahi o sin peers, el multiview local sigue y el Vecindario degrada honesto.
- N1 (si se implementa) no captura en silencio y no obliga a perder el ScreenCast
  "monitor" existente.

## 16. Archivos previstos

- `shell/multiview_model.gd` (nuevo, puro) + `tests/multiview_model_test.gd`.
- `shell/neighborhood_publish.gd`, `shell/neighborhood_hosts.gd` (TXT `mv*`).
- `shell/gvd_launch.gd`, `shell/gvd_session.gd` (capacidad de envío honesta).
- `shell/shell.gd`, `shell/peer_control.gd` (orquestación por canal peer,
  snapshot, follow).
- `shell/expose_layout.gd` o un `shell/multiview_ui.gd` (vista de tiles).
- N1: `modules/wayland/eis_server.c` (o `screencast.c`), `modules/wayland/SCsub`,
  `session/gdtk-portals.conf`, `session/portal.sh`, broker de captura de
  `SPEC-embedded-multi-output.md`.
- `shell/remote.gd` (+ `mcp/`) para arrancar/cortar el multiview en pruebas.

## 17. Referencias

- `SPEC-screen-share-compass.md` (§1 dirección, §7 gvd, §8 flujos, §13 no-goals, §14 hilo de render)
- `SPEC-embedded-multi-output.md` (§6 OutputContext, §8 broker de captura, §13 caps)
- `SPEC-sugar-neighborhood-host-actions.md` (§Discovery gvd, reglas TXT)
- `SPEC-sugar-group-2026-10.md` (§Enviar audio y ventanas, dockapp Compartiendo)
- `SPEC-sugar-group-no-ssh.md`, `SPEC-control.md`, `SPEC-screenshot.md`
- `session/gdtk-portals.conf`, `session/portal.sh`
- `/usr/share/dbus-1/interfaces/org.freedesktop.portal.ScreenCast.xml` (frontend, v6)
- `/usr/share/dbus-1/interfaces/org.freedesktop.impl.portal.ScreenCast.xml` (backend, v6)
- `modules/wayland/eis_server.c:1042-1061,1296`, `modules/wayland/SCsub:44-51`
- `shell/window_cast.gd`, `shell/remote.gd:571`, `tools/gvd/README.md`, `tools/gvd/gvd.py`
