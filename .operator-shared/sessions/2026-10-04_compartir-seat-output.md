# 2026-10-04 · Compartir teclado/mouse, dockapp y ventana-como-app-remota

## Hecho (sin commit; sync a ~/gdtk + reload transaccional)
- `shell.gd` `_group_input_set`: ya no sale temprano si el equipo no está en `host_directions`
  (el dockapp corta por nombre) y recalcula «algún input encendido» desde el layout de pantallas;
  `_screen_share_set` apagando no crea fichas. Antes «Detener» no apagaba Deskflow.
- `frame.gd` `_draw_shared_face`: burbuja clara de contraste para la inicial (también en «both»);
  flecha de puntero (`_draw_shared_pointer`) en el equipo que tiene el foco (centro = este equipo).
- `menu_style.gd` `chrome`: primer ítem con x = PAD_X (antes 0, sin margen).

## Pendiente
- Ventana exportada = output headless exclusivo + segundo wl_seat. `wl_server.c` hoy tiene un único
  `s->seat`. Revisión de factibilidad delegada: `briefs/S1-seat-output-review.txt` (log
  `/tmp/kilo-gdtk/S1-seat-output.jsonl`). Riesgo a validar: soporte real de varios wl_seat en
  toolkits (GTK/Firefox/Qt). Luego: spec nueva (no apéndice de SPEC-sugar-group-2026-10).
- «Extender pantalla»: la fila existe en el menú del Grupo (`neighborhood_ui.gd:416`); falta saber
  dónde la echa de menos el usuario.

## Loop nocturno: ventana compartida transparente y de baja latencia (tengu → cupid)
Decisión del usuario: sin segundo seat; la ventana compartida es una app normal en el receptor y el
input vuelve por el canal peer sobre el wid. Banco e2e: `tools/e2e/winlat/` (`run.sh` = sync a
tengu/cupid + abre `stamp_app.py` + comparte + `sampler.py`; `recv_probe.py` mide captura→decodificado
sin pantalla). RPC nuevos en `remote.gd`: `peers`, `share_window`, `unshare_window`. Nunca bastion.

Mediciones (tengu Core2 L9400 → cupid i5-4300U, Wi-Fi):
- RTT de red 5–54 ms (media 16–32), muy variable.
- Floor del método (screenshot de una ventana LOCAL en cupid): p50 120 ms (el screenshot cuesta ~230 ms).
- Estampa→decodificado en cupid (appsink, sin pantalla): p50 150, min 104, p90 189 ms.
- Estampa→pantalla de cupid (screenshot): p50 ~715 ms → ~600 reales: ~450 ms se pierden después del
  decode (glimagesink = sink `auto`; waylandsink aborta en el compositor embebido) o en el render del
  shell de cupid (≈9 fps dibujados a 2160×1440 con la ventana activa).
- Cambios ya aplicados: cadencia 20→30 (`WINDOW_CAST_FPS` en shell.gd) y sondeo de 2 ms en
  `gvd.py shm_capture` (antes dormía un periodo entero). Efecto pequeño (p50 763→704).
- Entrada: cada lote = conexión TCP nueva + sondeo de 5 ms + un solo lote en vuelo + compuerta de 16 ms
  (`shell.gd _window_input_poll`, `peer_call.gd request_status`) y el token rota por respuesta.

Hipótesis siguientes (en orden): H2 etapa de pantalla (sink gl y frecuencia de redibujado del shell
receptor; probar `max-lateness`/`qos`, `render` al llegar el commit); H3 entrada por canal TCP
persistente sin respuesta por lote; H4 etapa de captura en el emisor (readback + tick).

## Plan de la noche (despertar cada 30 min)
Dueños de archivos (disjuntos): **I** entrada = `peer_call/peer_control/peer_link.gd` + bloque `_window_input_*` de
`shell.gd` (Kilo, brief `briefs/I1-input-stream.txt`); **C** captura = `window_cast.gd` (+ `gvd.py shm_capture`);
**D** pantalla/receptor = `gvd.py recv`, sink, redibujado del shell receptor (lead mide, delega luego).
- T0 (21:00): I1 lanzado. Lead mide D (qué cuesta glimagesink y el redibujado de cupid).
- T1 (21:30): integrar I1, e2e de entrada (`stamp_app` registra teclas; falta `input_probe`), medir. Lanzar C1.
- T2 (22:00): C1 integrado, medir captura→file; D1 según medición.
- T3–T5 (22:30–23:30): iterar el cuello de botella dominante; cada vuelta = una hipótesis + e2e + nota aquí.
- T6+ : bajar bitrate/preset según CPU de tengu, 60 fps si la CPU alcanza, jitter-ms 30→10; cierre con resumen.
Reglas: sin commit/deploy; probar sólo en tengu/cupid; si un cambio empeora la mediana, revertirlo.

### Bastion como anfitrión (pedido del usuario, 21:10)
- bastion = i7-1185G7, 8 hilos, `vah264enc` disponible (gvd `--encoder auto` ya lo elige): es el emisor típico y
  tiene CPU de sobra → los parámetros (fps, calidad, jitter) deben escalar con la CPU del emisor, no fijarse
  para tengu (Core2). Pendiente: perfil por emisor (p. ej. 60 fps + `balanced` con VA; 30 fps con x264).
- bastion sólo tomó el soft reload de `shell.gd`/scripts; su `Host`/`main.gd` son viejos, así que NO carga
  `remote.gd`/`peer_control.gd` nuevos (sin RPC `share_window`, sin `window_input_stream`) hasta el próximo
  login. Por eso I1 debe caer al método `window_input` viejo cuando el otro extremo no lo soporta.
- Para medir bastion→cupid sin esos RPC: gestos reales de arrastre por el RPC viejo (`move`/`mouse_button`),
  sólo cuando bastion esté inactivo (delta de `state.input.motion` = 0 durante ~15 s), y cerrando después la
  ventana de prueba. Se hace en una vuelta nocturna, no mientras el usuario trabaja.

### Regla de la noche (21:15, usuario)
Bastion queda INTACTO esta noche (el usuario ve una película): ni rsync a `~/gdtk`, ni reload, ni RPC, ni gestos,
ni tests que lo usen. Desde bastion sólo se coordina: editar el repo, correr Kilo, y operar tengu/cupid por ssh.
Las pruebas con bastion como emisor quedan para cuando el usuario lo pida.

## Resultado de la noche (22:00–23:00, tengu → cupid)
- **La medición inflaba la latencia ~2.5×**: `sampler.py` con pausa 0.15 s hacía screenshots (~230 ms, frenan el
  shell) casi seguidos y el cliente quedaba esperando al shell. Con pausa 1.5 s (ahora el default y el de `run.sh`):
  estampa→pantalla p50 ≈ 280 ms (incluye ~115 ms de piso del método), 22/25 muestras entre 244 y 324 ms; 2–3 de 25
  son outliers de 0.5–1.7 s (sin causa aún: Wi-Fi/keyframe). La etapa visual NO tiene el cuello de 450 ms que se creía.
- Probado sin efecto y descartado: `avdec_h264 max-threads=1`, `vblank_mode=0` en glimagesink.
- **Bug real de I1**: `PEER_CALL.open` no existe en GDScript 3 (choca con `GDScript.open`) → renombrado a
  `connect_peer`; ningún lote de entrada salía por el stream. Además la recarga transaccional conserva los `preload`
  cacheados, por eso `shell.gd` ahora carga `PEER_CALL` con `Host.sc`.
- **Entrada** (`tools/e2e/winlat/input_probe.sh`, cupid `key` → `stamp_app` en tengu): 15/15 llegan, p50 104 ms,
  p90 114 ms. Esto va por el método viejo `window_input`: tengu tiene `peer_control.gd`/`peer_link.gd` viejos (los carga
  `Host` al login) y `peer_link` cacheado en cupid no tiene `encode_window_stream`. El stream persistente sólo se
  puede validar tras reiniciar el shell de ambos (el reinicio remoto fue denegado en esta sesión: lo decide el usuario).
- Lección: NO usar `git checkout <archivo>` para deshacer un experimento en un árbol con cambios sin commit (se
  perdió `gvd.py` y se recuperó de la copia sincronizada en cupid).
- Tests: arreglados `frame_slots_test` (stub sin `_load_np_icon`) y `neighborhood_ui_test` (`GROUP` sin `Host`).
