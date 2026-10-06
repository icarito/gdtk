# Shared Partition Catalog

## Tree

- `operator.md`
  - Description: Operator Instructions for this partition.
  - Read If: Auto-injected.
- `catalog.md`
  - Description: This catalog.
  - Read If: Auto-injected.
- `README.md`
  - Description: Public explainer of Operator Memory for repo readers.
  - Read If: Never needed for project work.

### `specs/` - Contratos del sistema (Pasos de construcción + diseño Sugar). Nombres citados por el código; no renombrar.

- `SPEC-architecture.md`
  - Description: Mapa de capas/procesos, contratos transversales (hilo de render, modelos puros, Host.sc, ciclo de vida de procesos) y tabla «dónde va cada cosa».
  - Read If: Antes de agregar cualquier funcionalidad nueva, o si no sabés en qué archivo va algo.
- `SPEC-session-continuity.md`
  - Description: Contratos de recarga transaccional, heartbeat, promoción de contenido y límite entre rollback de scripts y runtime.
  - Read If: Tocando `Host`, `main.gd`, supervisor, version store, recuperación o continuidad de ventanas.
- `SPEC-isolated-development.md`
  - Description: Lanzador anidado con runtime/XDG/puertos/store aislados para iterar sin afectar la sesión viva.
  - Read If: Creando herramientas de prueba visual, instancias anidadas o tests e2e del shell.
- `SPEC-power-governor.md`
  - Description: Control seguro y verificable del governor con helper mínimo, acción PolicyKit dedicada y provisión explícita.
  - Read If: Tocando el DockApp de energía, `sysmon.gd`, governors, pkexec o reglas de privilegios.
- `MOCKUP-sugar-frame.svg`
  - Description: Mockup del Frame Sugar (bordes y bloques).
  - Read If: Diseño visual del Frame.

- `SPEC.md`
  - Description: POC del módulo `imgui` para Godot 3.6 (paso 1-2).
  - Read If: Tocando `modules/imgui` o su API base.
- `SPEC-shell.md`
  - Description: Paso 3: shell tipo Sugar (FRT/SDL2, Wayland nativo).
  - Read If: Arranque/estructura del shell, `run_shell.sh`.
- `SPEC-compositor.md`, `SPEC-dmabuf.md`, `SPEC-popups.md`
  - Description: Pasos 4, 5, 7: compositor Wayland anidado, zero-copy dmabuf, popups/subsurfaces vía wlroots.
  - Read If: Tocando `modules/wayland` (compositor, buffers, popups).
- `SPEC-control.md`
  - Description: Paso 6: control remoto JSON-RPC del shell + puente MCP.
  - Read If: Tocando `shell/remote.gd`, `mcp/` o RPCs nuevos.
- `SPEC-windows.md`
  - Description: Paso 8: diálogos y ventanas sin actividad (parent, app_id).
  - Read If: Ventanas toplevel sin actividad, diálogos.
- `SPEC-keys.md`
  - Description: Paso 9: teclado físico real en FRT (guion, Ctrl+letra, AltGr).
  - Read If: Mapeo de teclas FRT/SDL2 → compositor.
- `SPEC-imgui-api.md`
  - Description: Paso 10: API ImGui + ImPlot/ImPlot3D + menú radial.
  - Read If: Extendiendo la API GDScript de ImGui.
- `SPEC-hud.md`, `SPEC-hud-remote.md`
  - Description: Paso 11/11b: HUD de debug, contadores, benchmark y perfilado remoto.
  - Read If: Métricas, HUD, `gdtk_metrics`, rendimiento.
- `SPEC-ime.md`
  - Description: IME y teclado en pantalla (K14); requiere recompilar el motor.
  - Read If: Entrada de texto compuesta, OSK.
- `SPEC-hybrid-windows.md`, `SPEC-wm-mode.md`
  - Description: Gestión de ventanas por ventana (flotante + mosaico) y modo WindowMaker (K13). El modo es por ventana, no global.
  - Read If: Tiling, flotantes, decoraciones, exposé, modo ventanas.
- `SPEC-ui-rework-2026-10.md`
  - Description: Rediseño Vecindario/Configuración/ventanas: vocabulario de UI, decisiones 2026-10-01 (Extender ≠ Controlar), K16-K19 (pin/autohide de barras).
  - Read If: Cualquier UI de Vecindario, Configuración, Frame pin/autohide; vocabulario para usuarios.
- `SPEC-sugar-journal-neighborhood.md`, `SPEC-sugar-neighborhood-host-actions.md`
  - Description: Dirección de producto Diario/Vecindario; hosts descubiertos y acciones compartidas (Wi-Fi ≠ presencia, host ≠ persona).
  - Read If: Vecindario, mDNS, acciones por host, Diario.
- `SPEC-sugar-senal-wifi.md`
  - Description: Vecindario: señal Wi-Fi que comparte Internet (perfil `Hotspot`, WPA, `ipv4.method shared`) y asociarse a APs con clave por popup ImGui; modelo puro `neighborhood_hotspot.gd`, estado en el worker y experimento STA+AP.
  - Read If: Señal Wi-Fi del Vecindario, `neighborhood_hotspot.gd`, popup de clave, hotspot/AP.
- `SPEC-screen-share-compass.md`
  - Description: Brújula de pantalla compartida: direcciones N/S/E/O, gvd (extender) vs Deskflow (controlar), receptor 1:1 sin escalar.
  - Read If: gvd, Deskflow, layout de pantallas entre hosts.
- `SPEC-embedded-multi-output.md`
  - Description: Salidas múltiples dentro del compositor embebido: Frame sólo en la principal, workspaces/ventanas por output, captura offscreen para gvd y base común para multi-monitor físico.
  - Read If: Implementando gdtk como emisor, salidas virtuales, captura gvd, cruce de ventanas entre pantallas o soporte multi-monitor.
- `SPEC-physical-multi-monitor.md`
  - Description: Monitores físicos adicionales: una ventana Godot flotante que cubre todos los monitores («span»), principal en (0,0), `_screen_size()`, hotplug por sway.
  - Read If: Segundo monitor físico, `session/gdtk-outputs`, `shell/output_layout.gd`, cualquier uso de `get_viewport_rect()`.
- `SPEC-rendimiento-compositor.md`
  - Description: Rendimiento del compositor embebido y del shell: por qué GNOME gana por construcción (damage tracking, vblank, direct scanout), frame callbacks atados a la presentación (hecho), y plan present-only / explicit sync / scanout.
  - Read If: FPS bajo o CPU alta, frame pacing, frame callbacks, dmabuf/shm, o antes de tocar el camino de presentación de ventanas.
- `SPEC-scanout-directo.md`
  - Description: P4: sacar el contenido de la ventana activa del camino de Godot. Opciones A (app mode), B (puente dmabuf zero-copy hacia sway) y C (quitar sway); incógnita crítica: crear una subsuperficie de la ventana FRT en sway.
  - Read If: Se retoma P4, el costo de la pasada de Godot por frame, o scanout/direct scanout y presentación de la ventana activa.
- `SPEC-sugar-frame-blocks.md`, `SPEC-sugar-frame-applets.md`
  - Description: Frame de bloques cuadrados Sugar/NeXT y applets (estados, fuentes, registro `applet_mods`, Portapapeles).
  - Read If: Tocando `shell/frame.gd` o `shell/applet_*.gd`.
- `SPEC-sugar-group-2026-10.md`
  - Description: Grupo (zoom Sugar), Vecindario sin solapes, Hogar por orientación, dockapp Compartiendo (G1-G5), portapapeles y enviar audio/ventanas.
  - Read If: Vista Grupo, dockapp Compartiendo, briefs `.operator-shared/briefs/G*.txt`.
- `SPEC-sugar-home-visual.md`, `SPEC-sugar-resource-ring.md`, `SPEC-sugar-spatial.md`
  - Description: Hogar: identidad visual, anillo de recursos, orientación espacial del shell.
  - Read If: Vista Hogar, anillo, navegación espacial entre vistas.
- `SPEC-blackboard-2026-09-30.md`
  - Description: Pizarra de ideas Vecindario/Hogar/Frame (2026-09-30), previa a las specs Sugar.
  - Read If: Rastreando el origen de una decisión de diseño Sugar.

### `guides/` - Cómo hacer cosas recurrentes (tutoriales verificados)

- `session-continuity.md`
  - Description: Recarga transaccional vs corte controlado, sync, heartbeat/rollback y provisión del governor.
  - Read If: Iterando, aplicando cambios, recuperando una caída o antes de reiniciar la sesión.

- `dockapp.md`
  - Description: Tutorial de dockapp/applet del Frame: contrato del módulo, registro en `applet_mods`, worker, scripts de `session/`, tests; ejemplo Portapapeles.
  - Read If: Crear o modificar un applet/dockapp del Frame, o cualquier módulo con worker.

### `briefs/` - Briefs de delegación a Kilo (`G*.txt`, `W*.txt`); sirven de modelo para nuevos

### `sessions/` - Bitácoras de sesiones `/polish` (`YYYY-MM-DD_<tema>.md`): estado, hechos, decisiones, próximos pasos

- `2026-10-03_grupo.md`, `2026-10-04_grupo-gestos.md`
  - Description: Polish de Grupo, Vecindario, Hogar, dockapp Compartiendo y cadena vertical.
  - Read If: Retomando trabajo de Grupo/Vecindario/gestos.
- `2026-10-03_ventanas.md`
  - Description: Polish de ventanas (exposé, arrastre, tamaño live).
  - Read If: Retomando trabajo de ventanas.
- `2026-10-04_portapapeles-grupo.md`
  - Description: Portapapeles sin ext-data-control en el binario; «Extender» ausente en Grupo.
  - Read If: Retomando el applet Portapapeles o el menú de Grupo.
- `2026-10-04_enviar-audio-ventana.md`
  - Description: Grupo: compartir ventanas por gvd y audio por equipo, arrastrando en Grupo; e2e tengu ↔ cupid y pendientes.
  - Read If: Retomando envío de audio/ventanas o el canal peer.
- `2026-10-04_cuelgue-cursor.md`
  - Description: Diagnóstico del cuelgue del shell en bastion (resuelto f26c8a4).
  - Read If: El shell se cuelga o el cursor se congela.
- `2026-10-05_rendimiento-compositor.md`
  - Description: Research de rendimiento (Meet FPS bajo/CPU alta) + acciones cortas entregadas: frame_done a la presentación, diagnóstico dmabuf; binario rebuild+instalado y validado headless.
  - Read If: Retomando el rendimiento del compositor/shell, o el plan present-only/explicit-sync.

### `plans/` - Planes vigentes

- `tech-debt.md`
  - Description: Registro priorizado de deuda técnica (objetos dios, código muerto, portapapeles partido, tests no aislados, deploy).
  - Read If: Planificando refactors, algo «raro» en tests/deploy, o antes de agrandar `shell.gd`/`frame.gd`.
- `bastion-migration.md`
  - Description: Veredicto y bloqueantes para migrar bastion de GNOME a gdtk.
  - Read If: Priorizando trabajo, o sesión diaria / funciones de GNOME faltantes.
- `HANDOFF-scanout-directo.md`
  - Description: Handoff de P4 (scanout directo): estado, primer paso (medir y resolver si FRT/SDL exponen la wl_surface), anclajes, comandos, gotchas y decisiones.
  - Read If: Se retoma P4 con contexto fresco.
- `render-parity-gnome.md`
  - Description: Plan para acercar el rendering de gdtk a GNOME/Mutter (meta: sesión diaria): F0 medición bloqueante, Track A sin KMS (damage, cursor del host, cobertura P4, multi-output) y Track B KMS real.
  - Read If: Se prioriza rendimiento/paridad de rendering o se decide entre exprimir el anidado y tomar DRM/KMS.
- `HANDOFF-a1-interaccion.md`
  - Description: Handoff de Track A1 (costo de interacción): diagnóstico del armado de ImGui, optimizaciones entregadas (_shared_snapshot, _text_w), hotspot pendiente (_draw_bar_blocks/_item_icon), cómo medir (probe, flags, RPC) y gotchas (reload tumba RPC ~20 s).
  - Read If: Se retoma la optimización del CPU de la shell bajo interacción en sesión nueva.
- `HANDOFF-senal-wifi.md`
  - Description: Handoff de la Señal Wi-Fi (AP que comparte Internet + asociarse a APs): bloqueante real (falta el cableado en shell.gd), capacidad HW por host (AX201/MT7601U/cupid/tengu), topología viable (cupid=AP) y riesgo de perder SSH por radio única.
  - Read If: Se retoma la feature de señal Wi-Fi o hay que probar/terminar el AP+clientes.
