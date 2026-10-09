# Estudio — Multimonitor (span) sin perder rendimiento

## Contexto

- Modelo actual (`SPEC-rendimiento-compositor.md`): sway anfitrión → ventana fullscreen de Godot
  (`ImGuiCanvas`, `shell/shell.gd`) → compositor embebido **headless sin CRTC**. Los frames de las apps
  pasan por textura de Godot → escena del shell (`view`, TextureRects en `shell.tscn`) → sway compone.
- Caminos ingenuos descartados: crear `HEADLESS-*` en sway sólo extiende el escritorio exterior
  (`SPEC-embedded-multi-output.md` §1); varias ventanas nativas no existen en Godot 3/FRT.
- Decisión ya tomada y spikeada (`SPEC-physical-multi-monitor.md`, 2026-10-04): **una sola ventana
  borderless que cubre el rectángulo envolvente** de todos los monitores («span»), sin cambios de motor.
  Primary en (0,0) reordenando salidas con `swaymsg`; monitores extra = escritorio extendido sin Frame.
- Ya implementado: API multi-output del módulo (`modules/wayland/wl_server.c:996+`, `output_add/
  configure/remove`, `set_toplevel_output`, señales `output_added/removed/toplevel_output_changed`),
  modelo puro `shell/output_layout.gd` + `tests/output_layout_test.gd` y `tests/embedded_outputs_test.gd`
  (Fase B). `session/gdtk-outputs` elige salida principal hoy. **Falta**: wiring del span en `shell.gd`,
  hotplug y la parte de rendimiento.
- Presupuesto de rendimiento actual (P1/P2 hechos): present-only (`shell.gd:1551` `_present_commit`:
  `view.update()` + `send_frame_callbacks()`, sin rearmar ImGui), frame callbacks atados a la
  presentación, explicit sync. Contadores `present {light, full}` en RPC `state`.

## Análisis de rendimiento: dónde crece y dónde no

**No crece con span** (costo por widget/ventana, no por píxel):
- Rearme ImGui: inmediato y por widget, y la UI vive sólo en la primary (contrato 1) → igual.
- Ventanas: un TextureRect por capa de toplevel, textura dmabuf/shm actualizada in-place; una ventana en
  la secundaria cuesta lo mismo que en la primary. El camino P1 present-only no cambia.
- Escena: mismo número de nodos; sólo cambian posiciones.

**Crece (marginal, proporcional al área del 2° monitor, sólo mientras se presenta):**
1. **Ancho de banda de present**: una sola swapchain = envolvente (1920×1080 → 3840×1080): cada present
   escribe/lee 2× píxeles. En reposo no importa (low_processor_usage_mode + `update_hz=4`); con video sí.
2. **Composición de sway**: Godot no emite `wl_surface_damage_buffer` → wlroots asume daño completo →
   **ambas** salidas recomponen en cada present aunque sólo cambiara una. Peor caso: video en cualquier
   monitor duplica el compose.
3. **Reloj de frames**: una superficie en dos salidas se pacing por los frame callbacks (refresh de la
   primary); un monitor de 75/144 Hz corre al ritmo de la primary. Riesgo de jitter con refresh cercanos.
4. Costo menor: clear/fill del fondo de la secundaria por frame completo.

**No cambia lo estructural**: direct scanout sigue imposible (headless sin CRTC, P4). El span no agrava
la arquitectura de dos compositores en serie.

**Mitigaciones (sólo si la medición lo exige)**: M1 = parche FRT que emita daño de superficie antes del
swap (compose parcial por salida); M2 = frame_done por salida (ventanas de secundaria idle ya casi gratis
gracias a present-only); M3 = opt-out `GDTK_SPAN=0`. Multi-ventana nativa del engine queda descartada para
v1 (SPEC-embedded §10).

## Plan de tareas (ordenado)

1. **Fase 0 — Medir antes de construir (gate)**: extender el harness headless aislado (2 salidas sway,
   `tests/` + `XDG_RUNTIME_DIR` propio) y correr el shell en geometría 1× vs envolvente 2× (sólo resize
   de ventana, sin lógica span) con commits tipo video (Gears). Medir: CPU%, `present light/full`, fps,
   CPU del proceso sway. **Gate**: si el delta en hardware cupid-class (Haswell) supera ~15% con video,
   agendar M1 (parche de daño en FRT) antes de activar span por defecto.
2. **Modelo puro** (`shell/output_layout.gd`): `bounding_rect()`, reordenado span (primary en 0,0, resto a
   la derecha), diff de hotplug (agregadas/quitadas/geometría), retorno de ventanas al desenchufar.
   Extender `tests/output_layout_test.gd`.
3. **Auditoría `_screen_size()`**: migrar los usos de `get_viewport_rect()` (shell.gd:41, frame.gd:2,
   layers.gd, system_osd.gd, window_deco.gd, neighborhood_ui.gd:2) clasificando cada sitio: tamaño de
   **pantalla** (primary) vs **escritorio** (envolvente). Introducir `shell._screen_size()` y
   `shell._desktop_rect()`; con una sola salida no cambia nada (guarda de regresión en tests).
4. **Wiring span en el shell**: worker de hotplug (sondeo `swaymsg -t get_outputs -r` con Threads one-shot,
   patrón `_sway_exec_poll`, nunca en render); aplicar reglas sway (floating/border none/pos 0 0/resize);
   crear/quitar outputs embebidos con `compositor.add_output/remove_output`; cruce y asignación de
   ventanas vía `output_layout.cross` + `set_toplevel_output`; opt-in/out `GDTK_SPAN`.
5. **Métricas por salida**: HUD/RPC `state`: área envolvente, fps, `present {light,full}` y compose por
   salida; documentar pacing con refresh mixto.
6. **Validación**: e2e sólo en instancia aislada (sway headless 2 salidas, nunca la sesión viva), luego
   hardware real (scripts → sync a `~/gdtk` + reload transaccional; v1 no toca engine).

## Verificación

- `tests/output_layout_test.gd` extendido (envolvente, primary, hotplug, retorno); `verify_all` verde.
- Checklist `SPEC-physical-multi-monitor.md`: entrar/salir de span, desenchufar devuelve ventanas,
  `GDTK_SPAN=0` = comportamiento actual, Frame/OSD jamás en secundaria, popups en la salida de su raíz.
- Rendimiento: tabla de la Fase 0 + contadores por salida; camino light intacto (`full=0` con video y UI
  quieta); sin growth de memoria/fds en 10 min.

## Riesgos

- Daño completo por present duplica compose (mitigación M1, diferida salvo gate).
- Refresh mixto: secundaria corre al ritmo de la primary (aceptado v1; escalas distintas fuera de alcance).
- `shell.gd` es enorme: toda la lógica nueva va en `output_layout.gd`/módulos, no en `shell.gd`
  (`SPEC-embedded` §17).
- La sesión viva (bastion) no se toca para probar: instancias aisladas, conforme a `SPEC-isolated-development.md`.

## Fuera de alcance

- Extensión remota gvd (Fases C/D de `SPEC-embedded-multi-output.md`): broker y captura, flujo aparte.
- Frame por monitor, escala/altura distinta por salida, grilla libre (v2 del spec).
- Multi-ventana nativa del engine / direct scanout (P4 arquitectural).
