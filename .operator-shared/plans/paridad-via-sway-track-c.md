# Plan — Track C: paridad vía sway (gdtk como shell, no como compositor)

Estado: **propuesta de arquitectura**. Nace de la pregunta del 2026-10-10:
«¿las ventanas flotantes las podemos gestionar vía sway? eso resolvería la paridad
con GNOME». Leer antes: `plans/render-parity-gnome.md` (Track A/B y F0),
`SPEC-compositor.md`, `SPEC-architecture.md`.

## 1. La respuesta corta

- **Flotantes vía sway, parcialmente, NO se puede.** Cada toplevel vive en el
  compositor al que la app se conectó (wayland-0, el embebido). Sway solo ve UNA
  ventana (la del shell) y no puede adoptar superficies de otro compositor.
  No existe «migrar las flotantes» como medida chica.
- **Sí existe el cambio completo (Track C)**: las apps pasan a ser clientes directos
  de sway; gdtk deja de ser compositor y queda como shell de UI (Layer-shell:
  Frame/franja, Hogar, exposé, dockapps, columna de notificaciones) + gran parte del
  control del WM vía IPC de sway.

## 2. Lo que gana Track C vs seguir anidados

1. **Paridad de presentación gratis**: vblank/por-salida, damage parcial, plano de
   cursor KMS, MPO, scanout por ventana: son features maduras de sway/wlroots.
   Los ítems A4, M1, A5, P4 y el fix del `put_data` dejan de ser trabajo de gdtk.
2. **Puente X11↔Wayland gratis** (el de sway funciona). El fix del módulo C que
   motivó auditarlo el 2026-10-10 se anula: Firefox/XWayland pasa a ser cliente de
   sway y su portapapeles se comparte solo.
3. **Multi-monitor, escalado fractional, VRR, KMS**: nativos.
4. Un menos: se jubila toda la deuda de composición doble (app→textura→escena).

## 3. Lo que se reescribe (el costo real)

- **El corazón de la shell**: franja de workspaces, Hogar/anillo, exposé, tiler
  híbrido K13, chrome de flotantes, zone-reservations: re-implementados contra el
  modelo de sway (workspaces/containers/IPC) o como dibujos de panel sobre vista de
  sway vía `screencopy` para miniaturas.
- **Input & captura**: el stack Deskflow/EIS/portal (`org.freedesktop.impl.portal
  .desktop.gdtk`) hoy vive EN el compositor; migrar a sway = pointer-constraints de
  sway, gráfico de origen remoto propio, portales revisados.
- XWayland pasa a ser el de sway ( ownership fuera del módulo), dialogs/dnd/screencast
  igual por sway. El valor propio del fork (`modules/wayland`) queda en gran parte
  jubilado o reutilizado como librería del shell.

## 4. Comparación honesta con lo que ya está en el plan

| | Track A (nested exprimido) | Track B (backend DRM propio) | Track C (sway-native) |
|---|---|---|---|
| Riesgo | acotado | alto (reescribe presentación en C) | alto (reescribe la shell en GDScript) |
| Paridad límite | cercana, no total | real | real |
| Trabajo dominante | GDScript + algo de C | C del engine | GDScript + IPC de sway |
| Bridge X11/clipboard | nosotros lo escribimos | idem (XWM propio) | **gratis (sway)** |
| Depende de F0 | sí (gate) | sí | menos, pero manda igual |

## 5. Orden recomendado

1. **F0** (bloqueante del plan): medir gdtk vs GNOME en los 4 escenarios.
2. **Track A**: A4 (frame scheduling) + M1 (damage) — ya avanzados a medio día.
3. **Track C** solo si al terminar A la meta de uso diario no se alcanza, **o**
   antes, si la decisión es estratégica: paridad total + jubilar el compositor
   embebido. La decisión es del usuario; el costo estimado es el capítulo 3.

## 6. Conexión con pendientes del día

- Puente X11↔Wayland roto (`xclip`/`xclip` medido, 21:10): en Track C se resuelve
  gratis; en Track A/B se arregla en el módulo C.
- UAF de Firefox (WaylandSurface/ScreenHelperGTK): **no cambia** con Track C (es bug
  de Firefox); la mitigación X11 sigue siendo la medida práctica.
- Estabilidad posicional del appicon (20:19) es trabajo de shell que NO desaparece
  con Track C, solo cambia de backend de layout.
