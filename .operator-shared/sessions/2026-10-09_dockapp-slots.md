# Sesión 2026-10-09 — Slots de dockapps consistentes

Pedido (/polish): la ubicación de los slots de los dockapps en la barra del Frame es
poco consistente. Regla deseada: **mitad izquierda** preserva el slot relativo a la
distancia desde el primer slot izquierdo; **idem por la derecha**. Si colapsan
(portrait / monitor más chico) van a buscar el próximo slot libre, con **un solo
algoritmo**. Aclaración posterior: **nunca** deben quedar dos bloques en el mismo slot.

## Diagnóstico (anclado)

- `bar_slots.to_saved` decidía el lado por `i >= total/2` con el `n` **vigente**, y
  `frame._sync_anchor` re-deriva el ancla desde las celdas vivas en cada guardado. Al
  colapsar, un bloque de la derecha que caía cerca de la izquierda se re-guardaba
  **izquierdo** y al volver a landscape no retomaba su distancia al borde (drift).
- Dos buscadores de hueco distintos: `frame.nearest_free` (empate→derecha; drops) y
  `bar_slots._nearest_free` (empate→centro; colisiones del ancla). De ahí el
  "poco consistente" y el "un solo algoritmo".
- `bar_slots.to_cells` era ancho-ciego: no reservaba el `span`, así un bloque ancho
  podía telescopar al de al lado.

## Decisiones (confirmadas por el usuario)

1. El **lado** (izq/der) se fija al soltar por el **centro de la barra** y es
   **estable**: no se reclasifica al rotar; sólo cambia si el usuario vuelve a mover.
2. En colapso cada bloque busca **hacia adentro de su lado** (izq→derecha, der→
   izquierda) con el mismo algoritmo y desempate que los drops.
3. **Invariante**: un bloque por slot (se reserva el `span`).

## Implementado

- `shell/bar_slots.gd`:
  - `nearest_free(cells, target, span, max_cells, prefer=1)` — **único** buscador de
    slot libre (`prefer` elige orden/desempate). Reemplaza a `_nearest_free`.
  - `to_saved(cells, n, prev_anchor=[])` — conserva el **signo** (`at`) o sea el lado,
    del ancla previa; sólo lo asigna por centro si el token es nuevo.
  - `to_cells(saved, n, spans={})` — usa `nearest_free` con `prefer` = lado del bloque
    (hacia adentro) y **reserva el `span`** para no superponer.
- `shell/frame.gd`:
  - `const BAR_SLOTS = preload("res://bar_slots.gd")`; `nearest_free` (static) delega.
  - `_sync_anchor` pasa el ancla previa (lado estable).
  - `_anchor_set_side` fija el lado del bloque soltado; llamado desde
    `_place_token_cell` y `_applet_move`.
  - `_resolve_order` arma `spans` y los pasa a `to_cells`.
- Tests: `tests/bar_slots_test.gd` (lado estable, prefer, no-solape por span), y
  `tests/parse_check.gd` suma `bar_slots.gd`.

## Verificación

- `bar_slots_test` rc=0 sin FAIL; `frame_next_slot_test`, `frame_slots_test`,
  `frame_grid_test`, `frame_menu_test`, `frame_strip_test`, `frame_hidden_mouse_test`,
  `wm_drag_test` rc=0 sin FAIL.
- `parse_check.gd` con `~/gdtk/bin/godot-gdtk`: `ok res://frame.gd` (y el resto).
- Pre-existentes, no relacionados: `expose_drag_wiring_test` 1 FAIL (match de texto en
  `shell.gd`), `ring_frame_test` cuelga por clases nativas (dev binary).
- Sync a `~/gdtk` hecho (md5 igual). **No** hubo reload/deploy ni commit.

## Pendiente / cómo probar

Requiere **recargar el shell** (no se hizo: sesión con VS Code/Kilo abiertos). En
landscape vs portrait, con 1 y con 2 monitores:

- Un bloque en la mitad derecha sigue pegado a la derecha al pasar a portrait y al
  volver (no se corre al medio ni a la izquierda).
- Al agregar/soltar, el bloque queda del lado del centro donde se soltó y ahí se queda.
- Con la barra achicada no aparecen dos bloques en la misma celda.
- Bajar de un `n` grande a uno chico y volver: los bloques retoman su distancia al
  borde del lado que les toca.
