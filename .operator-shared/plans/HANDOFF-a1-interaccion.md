# HANDOFF — Track A1: costo de interacción (optimizar dibujo de la shell)

Estado: **en curso**. Retomar en sesión nueva. Este doc es autosuficiente.

## Objetivo
Bajar el CPU de la shell bajo interacción (mouse) sin KMS. Contexto global:
`plans/render-parity-gnome.md` (Track A) y `sessions/2026-10-05_rendimiento-compositor.md`.

## Diagnóstico (hecho)
El costo de interacción = **armar ImGui** en cada frame de actividad:
`motion → ImGuiCanvas arma ImGui a input_hz (60) → _imgui_frame (GDScript)`.
Medido: `_imgui_frame` ~**7,5 ms/build**, invocado **24/s idle** y **48/s con motion**
→ ~18% / ~36% de un core.

Desglose de `_imgui_frame` (tiled): `frame.draw` **88%**, `tiles` 10%, resto ~0.
En **fullscreen** `frame.draw` early-returnea (`frame.gd:4117`) → por eso el video fullscreen
es barato (~5%). El ritmo de build lo decide `ImGuiCanvas::_notification`
(`godot-box3d-3-gdtk/imgui/imgui_canvas.cpp:655`): `update_hz`(4) + `input_hz`(60 con input
reciente ≤250 ms) + `requested_redraw`.

## Optimizaciones YA entregadas (por reload, sin reinicio)
| qué | efecto | commit |
|---|---|---|
| `_shared_snapshot` memoizado (versión Vecindario + 500 ms) | `frame.draw` 6,6→**3,95 ms** | `9814b47` |
| `_text_w` memoizado (evita `calc_text_size` en el while de `_truncate_w`) | `_draw_windows` 1,88→**1,01 ms** | `50f5536` |

## Lo que FALTA (hotspot actual)
Dentro de `frame.draw` (≈4,0–4,3 ms):
- **`_draw_bar_blocks` = ~1,95 ms** ← principal, no bajó con `_text_w` (su costo es íconos/layout).
- tiles Vecindario/Grupo/Hogar = ~0,5 ms.
- `_sync_shared_token`/`_draw_windows` ya optimizados (~0,3–0,6 / ~1,0).

### Próximos pasos sugeridos
1. **Sub-perfilar `_draw_bar_blocks`** (`shell/frame.gd:1263`) por token: separar la iteración/
   layout de las llamadas de dibujo (`_draw_app_tile`, `_draw_window_tile`, `_draw_shared_tile`).
2. Candidato probable: **memoizar `_item_icon`** (`frame.gd:2036`) con TTL corto
   (lookups `window_peer_icon`/`_window_icon`/`_sugar_icon_for` por tesela en cada build).
   **Validar que sea el costo antes de tocar.**
3. Si aparece costo en el módulo `imgui` (`godot-box3d-3-gdtk/imgui/`), eso **sí** requiere
   recompilar (`deploy.sh`) y **reiniciar**; avisar.

## Cómo medir (reproducible)
- **Probe**: `bench/f0_probe.sh <label> <seg>` (CPU sesión/shell, dmabuf/shm, GPU freq).
  Motion determinista por RPC `move {"x","y"}` (~60 Hz). Ver abajo gotcha de RPC.
- **Flags** (van en `~`):
  - `~/.gdtk-frt-perf` → el motor emite `[FRT_PERF]`/`[FRT_GPU]` (ms/frame; OJO: el `fps` del
    profiler es **1/tiempo-de-trabajo**, no la tasa del loop — `frame_time` excluye el sleep).
  - `~/.gdtk-imgui-time` → la shell emite `[IMGUI]` (total + setup/home/tiles/deco/frame/tail)
    y `[FRAME]` (shared/top/applets/tail || tilesTop/bb/win), promedio cada 120 builds.
- **Aplicar cambios de script**: `rsync shell/... → ~/gdtk/shell/`, preflight
  (`GDTK_GODOT=~/gdtk/bin/godot-gdtk ~/gdtk/session/gdtk-preflight ~/gdtk`), y **soft reload**
  por RPC `reload_shell` (permitido en bastion). NO requiere reinicio.
- **GOTCHA**: `reload_shell` **tumba el listener RPC ~20 s**; esperar y reintentar (nos costó
  varias corridas). Las mediciones en vivo tienen **mucha varianza** → medir en instancia
  **aislada/quieta** (molde: `bench/span_bench.sh`) cuando se pueda.

## Entorno / hosts
- repo `~/Proyectos/gdtk`; instalación `~/gdtk` (binario con clases nativas). Tests dev:
  binario `godot3-box3d/godot-dev/...gdtk`.
- Deploy: `./deploy.sh icarito@<host>` (bastion=localhost, cupid.local, tengu-2.local).
- Motor FRT: `platform/frt` (repo anidado, WIP sin commitear). Módulo imgui: `godot-box3d-3-gdtk/imgui`.
- Sesión de bastion ya corriendo GLES3; `scanout_reason` en RPC para P4/A3.

## Archivos que tocan esto
- `shell/shell.gd`: `_imgui_frame` (1687), `_present_commit` (1632), instrumentación `[IMGUI]`.
- `shell/frame.gd`: `draw` (4112), `_draw_bar_blocks` (1263), `_draw_windows` (3965),
  `_item_icon` (2036), `_text_w` (2125), `_shared_snapshot`/`_sync_shared_token` (441/1564).
- `modules/imgui/imgui_canvas.cpp` (fork): decisión de armar ImGui en `_notification`.
- `bench/f0_probe.sh`; plan `plans/render-parity-gnome.md`.

## Commits de referencia
`e7898cd` (GLES3 default) · `122bcee` (supervisor safe-mode) · `c1b594e` (cursor fullscreen) ·
`03beaff`/`63daa4a` (scanout_reason A3) · `4799718`/`fd13826`/`e43f494` (instrumentación) ·
`9814b47`/`50f5536` (A1 perf) · docs del plan (`b88a698`, `a650d23`, `3788a4b`).

## Arranque sugerido
1. `git log --oneline -15` y leer `plans/render-parity-gnome.md` (Track A).
2. Recrear flags de medición; confirmar sesión GLES3 en bastion.
3. Sub-perfilar `_draw_bar_blocks` y atacar `_item_icon` (o el costo real que aparezca).
