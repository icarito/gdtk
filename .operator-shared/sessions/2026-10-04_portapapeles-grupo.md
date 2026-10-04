# Polish 2026-10-04 — Portapapeles y «Extender» en Grupo

## A. Portapapeles: «no disponible»
- Causa: `wlr_ext_data_control_manager_v1_create` está en `modules/wayland/wl_server.c:2175` pero
  **sin commitear y sin compilar**: el binario instalado (bastion y tengu) no tiene `ext_data_control`
  (`strings ~/gdtk/bin/godot-gdtk | grep ext_data_control` = 0).
- No falta instalar nada: wl-clipboard 2.3.0 (bastion y tengu) ya habla `ext_data_control_manager_v1`;
  wlroots 0.19 trae el header.
- HECHO: motor compilado e instalado en bastion, tengu y cupid (md5 a340d246…, con ext_data_control).
  Activa al reiniciar el shell. `tengu.local` no resolvía por mDNS: se desplegó por IP.

## B. Grupo: no aparece «Extender mi pantalla»
- El menú de interruptores (`neighborhood_ui.gd:_group_toggle_items` :403) sólo se abre para
  **miembros** del Grupo o pares con dirección confirmada/token (`_peer_member` :327).
- Clic derecho sobre un equipo NO miembro en Grupo → menú del Vecindario (`_open_menu`, :628) que
  sólo ofrece «Extender mi escritorio a él» si el host anuncia `gvd role=recv`
  (`neighborhood_actions.gd:207`); si no, sólo «Añadir a mi grupo».
- Soltar tras arrastrar en Grupo (`_apply_group_placement` :476) NO abre el popup de dos interruptores
  que pide SPEC-sugar-group G4.
- HECHO (pedido: «simplificá»): en Grupo todo equipo abre el mismo menú de dos interruptores con
  estado propio cada uno + Añadir/Quitar (SPEC-sugar-group G4 «Menú único»).

## C. Portapapeles compartido en el Grupo (sin configuración)
- HECHO: método peer `clip_set`; `applet_clipboard` encola copias locales (`take_outbox`) y aplica las
  recibidas (`receive` → `gdtk-clipboard set`); `shell._clip_sync_poll` reparte en un Thread.
  Contrato en SPEC-sugar-group «Portapapeles del Grupo». Test: `applet_clipboard_test` (anti-rebote).
- Sin probar e2e: requiere reiniciar el shell en ambos equipos (motor nuevo + scripts).
- Desplegado en los 3 hosts (sin commit).

## D. Deskflow: una sola entrada (el Grupo)
- HECHO: Deskflow salió de ACTIVITIES (anillo) a `SERVICES`; borrada `settings/pages/shared_control.gd`;
  Vecindario filtra `use_remote_input`/`serve_input_here`; el interruptor del Grupo y el «apagar» de
  Compartiendo van a `shell._group_input_set`; el receptor sigue con `_deskflow_follow`.
  Contrato: SPEC-sugar-group «Teclado y mouse: una sola entrada».
- Pendiente/deuda:
  - `_set_host_direction` (arrastre del Vecindario) y `propose_direction` reescriben la entrada y pierden
    `input`.
  - El servidor por equipo (`_run_deskflow_server`, `_run_deskflow_plan`) y los planes Deskflow de
    `neighborhood_actions` quedaron sin entrada desde la UI: borrar en una tanda aparte (tienen tests).
  - Migración: bastion tenía `share_here` desde Configuración sin `input` → el interruptor se ve
    Apagado hasta encenderlo una vez.

## E. Despliegue 12:20
- tengu y cupid reiniciados (flag `gdtk-restart` + kill del pid): motor nuevo, `wl-paste --watch` vivo.
- Fix: el vigía del portapapeles sólo arrancaba si el applet estaba en una barra; ahora lo arranca
  `shell._clip_sync_poll`.
- bastion: binario + scripts instalados; falta que el usuario reinicie su shell.

## F. Grupo/Vecindario no recibían clics (12:45)
- Causa (regresión de 3246ad1, «el Hogar se dibuja siempre»): la ventana ImGui `##home` cubre la
  pantalla también con zoom; ImGui quiere el mouse e `ImGuiCanvas::_input` marca el evento como
  manejado → `neighborhood_ui._gui_input` nunca llegaba (ni menú ni arrastre).
  Fix: con zoom, `##home` lleva `ImGuiWindowFlags_NoMouseInputs` salvo sobre el ícono central.
  Verificado en tengu: el menú de Grupo abre.
- Ojo al depurar: `_sync_capture_cursor` re-habilita `set_process_input` del shell cada frame (un
  `set_process_input(false)` por eval no tiene efecto).
- `remote.gd`: el motion por RPC ahora lleva `button_mask` (antes no se podía simular un arrastre).
- `peer_control.gd`: reintenta `listen` cada 5 s; tras reiniciar el shell el puerto 7788 seguía
  ocupado y el canal peer (portapapeles, avisos) quedaba muerto.
- Pendiente cosmético: el ícono central se dibuja encima del menú; «Apagado» se corta a la derecha.
- Arrastre en Grupo sin verificar e2e (en tengu entraban eventos de Deskflow desde bastion).

## G. Menú de Grupo congelaba y no hacía nada (13:00)
- Causa: `neighborhood_inbox.ssh_target` tomaba la primera dirección mDNS = IPv6 global de tengu;
  `_peer_call_result` le pegaba ".local" (`2804:…:e712.local`) → resolución bloqueante en el hilo de
  render (congelamiento) y falla; además PeerControl escucha sólo IPv4. Ningún aviso, gvd_recv ni
  clip_set llegaba.
- Fix: `ssh_target` prefiere IPv4 (test); ".local" sólo a nombres pelados, nunca a IPs; el emisor gvd
  usa el mismo destino que el canal peer; `_share_notify` va por `_peer_send_async` (Thread) y loguea
  `peer: <método> a <hid> falló`.
- Verificado: portapapeles tengu → bastion llega (historial de bastion). bastion → tengu y «Extender»
  requieren reiniciar el shell de bastion.
- tengu se anuncia como `tengu-2.local` (colisión de nombre avahi): por eso `tengu.local` no resolvía.
