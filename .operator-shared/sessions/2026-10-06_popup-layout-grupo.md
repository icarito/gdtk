# Sesión 2026-10-06 — Popup de layout en Grupo (revisión con countdown)

## Objetivo

Al mover un equipo en la vista **Grupo** debe levantarse un popup con la vista de
distribución (como Pantallas), con countdown de 10 s para **Aceptar** (default,
también al vencer, clic afuera o Esc), **Editar en Pantallas** o **Revertir** el
layout propuesto. Pedido posterior: poder **arrastrar y redimensionar** las
pantallas ahí mismo, sin ir a Configuración, y que el snap "pegue contra la
pantalla solapada" en vez de llevársela lejos.

## Estado

- Implementado y activo en bastion (scripts sincronizados + recarga transaccional).
- Verificación: tests unitarios verdes; la verificación visual E2E queda del lado
  del usuario (el gesto del popup es difícil de automatizar).
- `Deskflow` con reinicio debounced y vigía con enfriamiento (ver abajo).

## Arquitectura

- `shell/layout_confirm.gd` (puro): ventana de revisión — baseline de la racha,
  countdown rearmable, `tick` (vence = aceptar), `accept`/`revert`/`dismissed`.
- `shell/screen_layout.gd` (puro, compartido con Pantallas):
  - `mini_map_transform` / `mm_pos` / `mm_rect` (px↔mm, transform congelada al
    agarrar para que el bbox no reacomode el resto);
  - `mini_map`, `mini_map_pick`, `mini_map_pick_near` (margen 12 px),
    `mini_map_edge` (zona de borde ≤6 px);
  - `resize_edge` (aspecto fijo, borde opuesto clavado, centro del eje libre;
    50..3000 mm);
  - `snap(...)`: **preferencia por la pantalla solapada** — primera pasada sólo
    con las pantallas que el rect soltado solapa; si no, pasada completa por costo.
- `shell/shell.gd`:
  - popup-hud como **ventana regular ImGui** (`WINDOW_NO_MOVE|NO_RESIZE|
    NO_DECORATION|NO_BACKGROUND`), posición clavada al abrir;
  - gesto por **eventos reales** en `_input` (press/motion/release), con el rect
    del hud bloqueando al mapa de Grupo (que si no se queda con el gesto);
  - **redraw continuo** mientras el hud vive (sin él, el loop de ImGui se duerme,
    los eventos no se despachan y el drag muere);
  - la **local** arrastra el plano completo (contactos preservados, sin snap);
    las demás se imantan al soltar; release escribe + sincroniza + aplica Deskflow
    y rearma el countdown.

## Trampas encontradas (leer antes de tocar)

1. **Preload cacheado en recarga transaccional**: `const X = preload(...)` sigue
   sirviendo la versión vieja tras un reload; modelos que cambian junto al shell
   van con `Host.sc("res://...")` (si no, `Nonexistent function`).
2. **El mapa de Grupo (`Control` con `MOUSE_FILTER_STOP` + drag propio) secuestra
   press y motion**: un popup que no bloquee su rect antes de la fase GUI pierde
   el gesto y el drag "no hace nada".
3. **El loop de ImGui se duerme si nadie pide redraw**: con el gesto por eventos
   hace falta `request_redraw()` continuo mientras el hud está abierto.
4. **Firmas**: `_layout_drag_follow` espera `Rect2`; pasarle un `Vector2` revienta
   con `Invalid get index 'size'` y el follow muere en cada motion.
5. **Deskflow**: cada escritura de layout reiniciaba el server (corta el teclado
   en plena escritura y deja teclas pegadas en el cliente). Ahora el reinicio va
   con **debounce 2,5 s**; `set_capture_ranges` sólo al cambiar el acomodo.
6. **Vigía de Deskflow**: soltaba la captura en bucle cuando el server volvía al
   local sin soltarla (flapping de captura). Ahora exige 3 chequeos y enfría 6 s
   tras soltar.

## Pendientes

- Verificación visual del popup (arrastre/resize) por el usuario; screenshot RPC
  disponible para inspección.
- Tecla pegada residual en el cliente: mitigado por debounce; el reset de
  dispositivos EIS del cliente queda como trabajo aparte si reaparece.

## Unificación con Pantallas (2026-10-06, posterior)

El popup quedó **idéntico** a Configuración > Pantallas usando el mismo modelo:

- Asas de **borde y esquina** (`screen_layout.mini_map_handle`, px con tope de
  1/3 del lado) → `handle` "" (mover), e/w/n/s o esquina (es/en/ws/wn).
- **Mover** con imán en vivo (`live_snap`, per-eje bordes/filas/columnas/centros)
  mientras se arrastra; la local sigue arrastrando el plano completo.
- **Redimensionar** con `resize_live` (antes `resize_edge`): aspecto de la
  resolución, snap de extremos para no dejar contactos al 1%/99%, y **no solapa**
  (si el cursor solapa, se mantiene el último rect válido; al soltar revierte al
  rect previo con `fits`).
- **Soltar**: si ya quedó tocando (`has_contact`) se respeta; si no, `snap`.
- **Guías** del imán dibujadas en el mini-mapa (`mm_pt`) y resaltado del asa bajo
  el puntero (hover) / tomada (drag).
- `resize_edge` queda como helper público (tests); el popup ya no lo usa.
- Tests: `tests/layout_confirm_test.gd` suma las asas y `mm_pt` (55 checks);
  `tests/screen_layout_test.gd` cubre `resize_live`/`live_snap` (65 checks).
