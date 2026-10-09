# SPEC — Pantallazos (selector ventana / pantalla / selección)

Estado: implementado (2026-10-08). Código: `shell/screenshot_model.gd` (puro),
`shell/screenshot_ui.gd` (overlay), cableado en `shell/shell.gd`, RPC en
`shell/remote.gd`, copia al portapapeles en `session/gdtk-screenshot`.

## Objetivo

Ofrecer, estilo GNOME, un pantallazo que permita elegir **una ventana**, **toda la
pantalla** o **una selección** rectangular, y que al confirmar **guarde el PNG a disco
y lo copie al portapapeles** del compositor embebido (pegable dentro de las apps).

## Disparadores (teclas)

| Tecla | Acción |
| --- | --- |
| `PrintScreen` | Abre el selector (modo por defecto: Selección) |
| `Shift+PrintScreen` | Selector en modo Selección |
| `Alt+PrintScreen` | Selector en modo Ventana |
| `Ctrl+PrintScreen` | Captura directa de toda la pantalla (guarda y copia, sin overlay) |

`Esc` cierra el selector; `Enter` confirma el modo activo. Mientras el selector está
abierto se queda con **todo** el input (`shell._input`, antes de cualquier reenvío).

## Congelado del marco

Al abrir, el shell saca la foto del viewport compuesto (`_grab_viewport_image`) **antes**
de que se dibuje el overlay; el recorte se hace sobre esa `Image` congelada, así el
resultado **no** incluye el dim ni la barra. En HiDPI la textura puede ser mayor que el
Viewport: `screenshot_model.scale_for`/`crop_rect` mapean y recortan en píxeles de imagen.

## Overlay (`screenshot_ui.gd`)

Ventana ImGui fullscreen con `ImGuiWindowFlags_NoMouseInputs` (no roba hover/clics);
el mouse se maneja a mano, igual que `system_osd.gd`. Dibuja: dim, resaltado de la
ventana bajo el cursor o la selección, barra superior con botones
(`Ventana`, `Pantalla`, `Selección`, `Cancelar`) y una ayuda. Contrato del módulo:
`begin/is_active/cancel/handle_input/draw/rpc_action`.

Geometría pura y testeable en `screenshot_model.gd`: normalización del arrastre,
recorte a píxeles de imagen, layout/hit-test de la barra y nombre del archivo.

## Guardado y portapapeles

Al confirmar, `shell._screenshot_done(image, kind)` escribe
`$XDG_PICTURES_DIR/Pantallazos/Pantallazo[-region|-ventana]-<fecha>.png` en un `Thread`
(no bloquea el frame) y luego copia el PNG al portapapeles embebido con
`session/gdtk-screenshot copy <socket> <archivo>` (`wl-copy --type image/png`). El socket
del compositor embebido lo aporta `frame.clipboard.wayland_display`. Como la copia pasa
por el portapapeles embebido, el applet Portapapeles la registra como entrada de imagen.

## Control remoto / automatización

- `screenshot {"ui": true, "mode": "region|window|screen"}` → abre el selector.
- `screenshot {"action": "screen"}` → captura directa de toda la pantalla (guarda y copia).
- `screenshot {"action": "window", "id": N}` → captura esa ventana/diálogo.
- `screenshot {"action": "region", "region": [x, y, w, h]}` → captura esa región (coords de UI).
- `screenshot {"action": "cancel"}` → cierra el selector.
- Sin `ui`/`action`: comportamiento histórico (PNG base64 del escritorio, `max_width`).

CLI: `session/gdtk-screenshot ui [modo]`.

## Límites

- Captura el **viewport compuesto** (lo que se ve), no la superficie a resolución nativa
  de una ventana tapada; una ventana parcialmente ocluida se recorta tal cual se ve.
- Sin selector de monitor: "Pantalla" es la pantalla principal (`_desktop_rect`/viewport).
- El guardado/copiado usa `Thread`; un solo guardado en vuelo (`_shot_thread`).
