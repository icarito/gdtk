# SPEC — Scanout directo: sacar el contenido de apps del camino de Godot (P4)

Estado: propuesta / a planificar. Complementa `SPEC-rendimiento-compositor.md`
(P1/P2/P3 hechos), `SPEC-compositor.md`, `SPEC-dmabuf.md` y
`SPEC-embedded-multi-output.md`. No implementa todavía: fija el diseño, las fases y
las incógnitas que hay que resolver antes de tocar el motor.

## 1. Problema

La sesión tiene **dos compositores en serie** y el contenido de cada app pasa por
Godot:

```text
app ──dmabuf──> wlroots EMBEBIDO (headless, SIN CRTC)
                    │ EGLImage → ImageTexture
                    ▼
   sway ──scanout── <── shell (Godot/GLES2) redibuja escena + ventanas
```

- El compositor embebido es **headless** (`SPEC-compositor.md` dec. 3): no tiene
  output/CRTC, así que **no puede hacer direct scanout**. Todo frame de app pasa por
  la textura de Godot y por la escena del shell antes de que sway componga.
- Con P1 el shell ya **no rearma ImGui** por commit (`present light`), pero sigue
  haciendo una pasada de GPU por frame para componer la ventana dentro de su escena.
- GNOME/Mutter, en cambio, manda el buffer de la ventana fullscreen **directo a un
  plano de hardware** (direct scanout) y no toca su UI. Esa es la brecha que queda.

Evidencia de partida (cupid, 2026-10-05): Firefox en dmabuf con `present
{light:170, full:1}`; aun así cada frame de Firefox atraviesa Godot. Medir/partir el
costo GPU del frame del shell es el primer paso (F0).

## 2. Objetivos

1. Para la **ventana activa** que sea fullscreen o axis-aligned sin efectos, que su
   contenido llegue a la pantalla **sin** pasar por la escena de Godot (ni por su
   textura), eliminando una composición y el trabajo por-frame en el hilo principal.
2. Mantener intactos el Frame, Hogar, OSD, input, foco, Deskflow y portal para el
   caso normal (ventanas flotantes/tiled con UI).
3. Degradación segura: si algo no aplica (transformación, escala, efectos, popups),
   se vuelve al camino actual sin que el usuario lo note.
4. No romper `SPEC-embedded-multi-output.md` (el modelo de outputs debe poder usar
   el mismo camino de presentación).

## 3. No objetivos

- Reescribir el WM ni quitar el Frame.
- Quitar sway en el primer corte (eso es la opción C, §5).
- Multi-monitor, captura/streaming (van en `SPEC-embedded-multi-output.md`).
- Hacer scanout directo de ventanas con transformaciones/escala/sombra/animación.

## 4. Estado actual y anclajes

- `WaylandCompositor` corre **en el proceso y el hilo de Godot**; su EGL es el
  contexto de Godot (`eglGetCurrentDisplay`, `wl_server.c:setup_dmabuf`).
- Import dmabuf→EGLImage→texture: `wl_server_bind_dmabuf`
  (`modules/wayland/wl_server.c:3146`). Las texturas se exponen por
  `WaylandCompositor::get_layers(id)` (`modules/wayland/wayland_compositor.cpp:913`),
  con `texture`, `rect`, `key`.
- El shell mapea capas a `TextureRect` en `_fill_nodes` (`shell/shell.gd:2479`) y
  posiciona en `_update_tile` (`:2616`); los commits se presentan con
  `_present_commit` (P1, `:1548`).
- Frame callbacks en la presentación (`end_frame`); sync explícita
  (linux-drm-syncobj-v1, P2).
- El shell es un cliente **fullscreen de sway** (`session/sway.conf`:
  `for_window [title=".*"] fullscreen enable`).
- `SPEC-embedded-multi-output.md` §8 ya prevé "exportar el render target por dmabuf
  y evitar copia" para la captura; este spec aplica la misma idea a la presentación.

## 5. Opciones

### A — "App mode" sin tocar la composición (bajo riesgo, ganancia acotada)

Cuando la ventana enfocada es fullscreen/axis-aligned, el shell **oculta el Frame y
los overlays** y presenta sólo la textura de la app (present-only, ya iniciado en
P1). Baja el costo de la UI y del redibujo, pero **sigue** habiendo una pasada por
Godot. Sirve de escalón y de red de seguridad.

### B — Puente dmabuf zero-copy hacia sway (recomendado)

El shell deja de dibujar el contenido de la app y **le entrega el dmabuf de la app a
sway** para que lo presente/escaneé. Idea: la superficie de Godot (que tiene el
Frame/OSD opacos) se vuelve **transparente en el rect de la app**; por debajo (o en
paralelo) se adjunta el dmabuf de la app a una superficie hija de la ventana en
sway. sway compone: dmabuf de la app (posible plano de hardware) + UI de Godot
encima con el hueco transparente. El input lo sigue recibiendo la superficie de
Godot; el shell lo reenvía al cliente del compositor embebido.

Elimina la pasada por Godot para el contenido de la app y el rebind por frame.
Requiere resolver (§6): pasar el fd del dmabuf de un compositor a otro, sync
adquirir/liberar entre ambos, y **crear una superficie/subsuperficie de la ventana
de Godot en sway** (la incógnita crítica).

### C — gdtk como compositor DRM (quitar sway) (alto costo, descartado por ahora)

El compositor embebido pasa a ser el compositor de sesión con outputs reales
(direct scanout nativo). Máxima ganancia, pero hay que asumir input, touchpad
(gestos), outputs/hotplug, portal ScreenCast, Xwayland y Deskflow que hoy aporta
sway. No se encara salvo que B resulte insuficiente y haya apetito de asumir la
sesión.

**Recomendación:** A como escalón inmediato; B por fases con feature flag; C sólo si
B no alcanza.

## 6. Diseño de B (fase F2)

Contrato mínimo entre el compositor embebido y el shell:

```text
wayland_compositor.scanout_candidate(toplevel_id) -> {
  "ok": bool, "reason": str,
  "dmabuf": {fd, modifier, width, height, stride, format},
  "acquire": {timeline_fd, point}, "release": {timeline_fd, point},
  "rect": Rect2  # en coords del viewport del shell
}
```

Pasos:
1. Sólo candidatos: toplevel fullscreen/axis-aligned, formato importable por sway,
   sin transformaciones activas. Si no, `ok=false` con motivo.
2. El shell obtiene (o crea) una **superficie en sway** para el dmabuf. Decisión
   abierta §7: subsuperficie de la ventana de Godot vs. toplevel/layer-surface
   aparte.
3. Adjuntar el dmabuf con `zwp_linux_dmabuf_v1` de sway y commit; sync explícita
   (`linux-drm-syncobj-v1`) si sway la soporta, si no implícita.
4. Marcar la región de la app como **transparente** en la superficie de Godot
   (hueco) y excluirla del draw de la escena. El shell sigue dibujando Frame/OSD.
5. Input: la superficie de Godot recibe el input (región opaca); el shell lo traduce
   a coords del compositor embebido y lo reenvía por el seat interno. La superficie
   del dmabuf se crea con `input_region` vacía.
6. Al cambiar buffer/rect/resize o al perder el candidato: re-adjuntar o **volver al
   camino actual** (dibujar la textura en Godot).

## 7. Incógnitas críticas (resolver antes de F2)

1. **¿FRT/SDL exponen la `wl_surface` de su ventana** para crear una `wl_subsurface`
   del lado cliente? Si no, hay que hacerlo en el engine (`platform/frt`) o usar una
   superficie separada. **Es el bloqueante principal de B.**
2. ¿El dmabuf de un cliente del compositor embebido se puede re-exportar/duplicar el
   fd y adjuntar a sway sin copia? (esperado que sí: es el mismo `wl_drm`/dmabuf).
3. ¿Sway 0.20 acepta `linux-drm-syncobj-v1` y dmabuf de origen ajeno? (si no,
   implícita).
4. Orden z y transparencia: ¿sway compone correctamente UI de Godot sobre el dmabuf?
5. Captura de pantalla: el portal ScreenCast (xdpw sobre sway) captura el **output**
   de sway, que incluye las subsuperficies; confirmar que Meet/Zoom siguen viendo la
   app cuando va por B.

## 8. Fases

- **F0 — medir (bajo riesgo).** Instrumentar GPU/frame del shell y por-ventana
  (`[FRT_GPU]`, HUD, RPC). Sin esto no se puede afirmar la ganancia de B.
- **F1 — app mode.** Frame oculto + present-only para la ventana fullscreen; medir
  CPU/GPU. Red de seguridad y comparación.
- **F2 — PoC del puente dmabuf** para una ventana axis-aligned, input en el shell,
  en instancia aislada. Requiere resolver §7.1.
- **F3 — generalizar**: popups/diálogos, resize, fullscreen, degradación.
- **F4 (opcional) — evaluar C** (compositor DRM).

## 9. Riesgos y mitigaciones

- **No poder crear la subsuperficie** → F2 bloqueado; mitigación: superficie
  separada de sway + layer-shell, o dejar B y quedarse en A.
- **Input/foco entre dos compositores** → empezar display-only (input 100% en el
  shell).
- **Sync entre compositores** (tearing/stalls) → reusar P2; medición y fallback a
  implícita.
- **Transparencia mal soportada** → verificación temprana en F1/F2.
- **Regresión** → feature flag (`GDTK_SCANOUT_DIRECT`), fallback automático al
  camino actual ante cualquier error.

## 10. Verificación

- Instancia aislada (no la sesión viva; `SPEC-session-continuity.md`).
- Medir fps/CPU/GPU antes/después: video fullscreen, HUD, RPC `state`.
- Comprobar: sin tearing, input/foco correctos, resize, popups, Frame/OSD encima,
  pantalla compartida por el portal sigue viendo la app.
- Rollback: flag off → camino P1; el binario previo si hace falta.

## 11. Archivos previstos

- `modules/wayland/`: export del dmabuf+sync del surface activo; API Godot.
- `platform/frt` (engine): acceso a la `wl_surface` / creación de subsuperficie
  (posible cambio de motor — corte controlado).
- `shell/`: modo app, hueco transparente, forwarding de input, flag.
- `tests/`: candidato/degradación (puro) + e2e aislado.

## 12. Criterios de aceptación

- Con el flag activo, una ventana fullscreen de video se presenta sin pasar por la
  textura del shell, sin tearing y con input/foco correctos.
- Con el flag inactivo (o no candidato) el comportamiento es idéntico al de P1.
- Frame/OSD/popups y el portal ScreenCast siguen correctos.
- Métricas documentan la reducción de GPU/CPU del shell en el caso fullscreen.
