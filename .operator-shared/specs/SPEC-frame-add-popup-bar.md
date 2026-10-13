# SPEC-frame-add-popup-bar.md

Fecha: 2026-10-13 · alcance: `shell/frame.gd` (Frame/barras), tests `tests/frame_menu_test.gd`

# Alta de bloques del Frame en la barra que los pidió

## Problema

El selector genérico de Controles (popup `##applets_add`, clic derecho sobre un slot
vacío de cualquier barra) era el único menú que DA DE ALTA bloques al Frame (los
dockapps: Volumen, Notificaciones, Vista del grupo, Térmico, etc.). Su colocación
involuntaria siempre caía a la barra INFERIOR: `_applet_set_visible` llamaba
`_place_new_token(..., "dock")` con la zona fija. Abrir el selector desde la barra
superior y fijar un dockapp lo mandaba a la inferior: sorpresa y reacomodo manual.

## Contrato

1. **Una sola función de ubicación de slot nuevo**: `_place_new_token(tok, span,
   zone, cell)` (`shell/frame.gd`). Todo alta de bloque nuevo pasa por ahí; cada
   caller fija SU zona explícita o la recomendada por su origen:
   - Alta por MENÚ (selector de Controles, `##applets_add`): la zona es la de la
     BARRA cuyo slot vacío abrió el popup ⇒ se registra `applet_picker_zone` con
     `_zone_at(pos)` en el momento de pedirlo y se aplica al colocar
     (`picker_zone(applet_picker_zone)`).
   - Alta por ARRastre/drop (celdas desde x del puntero, `_place_token(zone, tok,
     x)`): coloca donde se soltó —fuera de alcance de esta spec—.
   - Bloque "Compartiendo" (`_sync_shared_token`): reaparece donde su pref guardado;
     primera vez, barra superior. No es alta por menú.
   - DockApp de ventanas (`w:windows`, `_ensure_window_token`): alta AUTOMÁTICA
     (nada invocado por menú) ⇒ default actual: barra superior.
2. **Honestidad con barra llena**: si la barra invocadora no tiene lugar, NO se
   coloca y el estado no cambia (como hoy); repetir el alta desde la otra barra.
   NUNCA falla silenciosamente a la barra contraria: la colocación es predecible.
3. **Origen desconocido**: `applet_picker_zone` vacío/basura (alta programática,
   compatibilidad) cae a "dock" con `F.picker_zone(recorded)` (puro, testado en
   `frame_menu_test.gd`) — el default histórico queda intacto.
4. El popup refresca la zona en CADA pedido (si se abrió sin válido, el próximo alta
   usa la última barra invocadora, nunca una zona vieja).

## No objetivos

- No cambia el drop de pines/applets ni el reacomodo manual.
- No cambia la migración/carga de `applets.json` (`order`/anclas).
- No promueve applets ocultos ni reordena bloques existentes.

## Verificación

- `tests/frame_menu_test.gd`: `picker_zone` barra invocadora/fallback.
- Manual: clic derecho sobre slot vacío de la barra SUPERIOR ⇒ el dockapp fijado
  aparece ahí; ídem desde la inferior.
