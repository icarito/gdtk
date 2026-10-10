# HANDOFF — Performance en tengu (idle) y camino de render

Medición 2026-10-10 en **tengu.local** (Core 2 Duo L9400 @1.86 GHz, 2 núcleos,
Intel **GM45** GMA 4500, 1280x800, Mesa 26.2.3). Objetivo: cuantificar la huella
en reposo de gdtk vs XFCE en el **mismo hardware** y responder si el render es
directo o hay cuellos, más evaluar "otro proceso para los dockapps".

Leer antes: `SPEC-rendimiento-compositor.md`, `HANDOFF-scanout-directo.md`,
`render-parity-gnome.md` (F0 en bastion), `bench/session_footprint.sh`.

## 1. Método y hook numérico (bloqueante)

Script `bench/session_footprint.sh` (huella de la sesión **activa** en seat0):
PSS de la sesión, `memory.current` del scope, servicios de usuario aparte, CPU en
reposo (% de **un** core, delta de `usage_usec` del cgroup + Xorg externo) y
ctxsw/s. Comparar con `--compare a.json b.json`.

**Bug corregido** (este corte): en seat0 pueden coexistir la sesión víctima y una
`State=closing`; el script tomaba la primera listada y medía una sesión muerta.
Ahora elige la sesión `State=active`.

## 2. Resultados (mismo hardware, sesión asentada, nada abierto)

| métrica | XFCE (session-32) | gdtk-sway (session-41) |
|---|---:|---:|
| CPU reposo (% de 1 core, scope) | **0.46** | **~14** |
| CPU reposo de la shell (godot, todos los hilos) | — | **~6.6–8.3** |
| vueltas del loop en reposo | — | **5–8/s** |
| CPU con actividad reciente ("busy") | — | **~12–17** (loop 60/s) |
| ctxsw/s | 31.5 | 82.2 |
| PSS sesión | 461.3 MB (27 procs) | 291.5 MB (18 procs) |
| `scope memory.current` | 305.5 MB | 208.1 MB |
| servicios de usuario | 87.0 MB | 98.6 MB |
| MemAvailable | 4715 MB | 4794 MB |

Nota: la huella XFCE incluye apps del usuario (`deskflow` 32 MB, `blueman`,
`nm-applet`); en gdtk corren `deskflow-core`, `avahi`, etc.

**Corrección al primer dato**: el "17.28%" se tomó en fase **busy** (la shell
despierta 3 s por cualquier RPC, §3.1) — no era reposo puro. En reposo real (sin
tocar el RPC): `scope` ≈ **14%**, godot ≈ **8.3%**, loop ≈ 8.4/s; **con el fix de
§3.1** baja a godot ≈ **6.6%**, loop ≈ 5.5/s. En fase busy el loop va a **60/s**.

Reconciliación: `cpu.stat usage_usec` del scope supera la suma de hilos de los
procesos en ~5–9 puntos, sin forks (`pids.events max 0`) ni subcgroups, con
`system_usec` ≈ 39% del total → tiempo de kernel (ioctl EGL/DRM/Wayland) atribuido
al cgroup. Cerrarlo pide `strace`/`perf` (no instalados) o `pidstat -t`.

## 3. ¿Render directo o cuellos? (respuesta)

**No hay render directo en uso real; hay composición doble y el shell no reposa.**

- **dmabuf sí, apps por GPU**: `compositor.dmabuf=on`, `explicit_sync=on`. Las
  apps van por dmabuf/zero-copy al compositor embebido (no shm/software).
- **Scanout directo (P4) no engancha**: `scanout=off`,
  `reason="sin commit del root (aun)"` (o `"otra ventana visible"` en bastion).
  El shell es **cliente fullscreen de sway** y el compositor embebido es wlroots
  **headless sin CRTC** → cada frame pasa por la textura de Godot y la escena del
  shell, y sway lo compone de nuevo. Igual que el F0 de bastion: P4 sólo cubre
  un xdg fullscreen en la salida principal sin overlays.
- **El shell SÍ entra en reposo, pero cada redibujo es caro**: con el Escritorio
  vacío (`view=home`, `tiles=[]`, `commits=0`, `present.light=full=0`), en reposo
  real el loop va a **~5–8 vueltas/s** (`busy=false`, `sleep_usec=250000`). El
  costo es **por frame**: `[FRT_PERF] render=10.95 ms` (GL, no GDScript) → a 8/s
  ~8% de un core; en fase **busy** sube a 60/s (~17%). `[IMGUI]` (armado GDScript)
  es aparte: 4.76–5.82 ms por build. Con `~/.gdtk-frt-perf` y `~/.gdtk-imgui-time`:

  ```
  [FRT_PERF] frame=16.72ms idle=5.75 phys=0.011 steps=0.167 render=10.95 sync=0.002 fps=59.8
  [IMGUI]    avg=4.76ms | setup=0.05 home=0.86 tiles=0.05 deco=0.00 frame=3.75 tail=0.06
  [FRAME]    avg=3.77ms | shared=0.13 top=2.49 applets=1.01 tail=0.14 || tilesTop=0.47 bb=1.89 win=0.00
  ```

  OJO al medir: el `fps` de `[FRT_PERF]`/`Engine.get_frames_per_second()` **no** es
  la tasa del loop (`frame_time` excluye el sleep). Usar `loop.*` del RPC `state`.

- **Godot corre GLES2, no GLES3**: `shell.log` línea 3:
  `OpenGL ES 2.0 Renderer: Mesa Mobile Intel GM45 Express Chipset (CTG)` +
  referencias a `rasterizer_gles2.cpp`, pese a que el launcher fuerza
  `--video-driver GLES3` / `GDTK_VIDEO_DRIVER=GLES3`. El GM45 es GLES2-only y
  **Godot cae al rasterizer GLES2**, que el F0 de bastion marcó como el camino
  caro (GLES2 ~23–25% vs GLES3 9–15% en el mismo contenido).

### 3.1 Fix RPC (hecho este corte)

`shell/remote.gd` ponía `last_activity` + `request_redraw` para **cualquier**
método, así que un poll de `state` despertaba la shell 3 s a 60 fps: era la causa
de la "fase busy" que medí primero (y explicaría un `state`-poll en producción
quemando CPU). Ahora los lectores puros (`state`/`peers`/`hud_snapshot`) **no**
la despiertan; los interactivos sí (latencia intacta). Medido en tengu: con
polling de `state`, godot pasó de ~12–17% a **6.6%**.

**Cuellos, por impacto:**
1. **Costo por redibujo ≈ 11 ms** (GLES2/GM45): el dominante. El loop en reposo
   ya es bajo (5–8/s); abaratar el frame (overdraw, canvas items) y/o bajar a 4/s
   es donde está el retorno.
2. **Fase busy a 60/s**: cualquier input/RPC interactivo mantiene 60 fps por 3 s
   (`IDLE_MS`). Es lo que da latencia baja; ya no lo disparan los lectores.
3. **Rebuild de ImGui + barra superior**: `[IMGUI]` 4.76–5.82 ms (`frame.draw`
   3.75, `top` 2.49, `bb` 1.89). anchors: `shell/frame.gd`, `_imgui_frame`
   `shell/shell.gd:1897`.
4. **GLES2 forzado→fallback**: sin GLES3 no hay `[FRT_GPU]`; todo el render cae
   en el rasterizer GLES2 sobre crocus. anchors: `session/gdtk-session-sway:28-31`.
5. **Composición doble + sin KMS** (arquitectural): igual que
   `render-parity-gnome.md` §3.

## 4. "¿Otro proceso para los dockapps?" — evaluación

Bajo retorno como está planteado. Los **applets miden ~1.01 ms** de los
~3.77 ms del Frame y de los ~4.76 ms de ImGui; el costo real está en
`render` (10.95 ms/frame) y en **redibujar 60 fps una escena estática**, no en
el trabajo de los dockapps. Sacarlos a otro proceso no baja ese render y agrega
IPC/sincronización y una segunda conexión Wayland.

Lo que sí separa trabajo es **B1 de `render-parity-gnome.md`**: desacoplar el
**compositor embebido** a su hilo/proceso para no serializar import de dmabuf +
render con el hilo de Godot. Los dockapps son la parte barata; el cuello es el
loop de presentación.

## 5. Recomendaciones (por [costo → beneficio])

1. **Hecho: gate de RPC por solo-lectura** (§3.1). Los lectores puros no despiertan
   el loop; los interactivos sí. Beneficio inmediato y verificable en tengu.
2. **Abartar el costo por redibujo (~11 ms, el cuello real)**: cachear por tesela
   `_draw_bar_blocks` (1.89 ms) y `frame.draw` (3.75 ms) del build ImGui, y
   evaluar overdraw/canvas items del pase GL. Precedente: `_shared_snapshot`,
   `_text_w` memoizados.
3. **Bajar el piso de reposo a 4/s**: hoy ~5–8/s (update_hz del módulo + requests
   periódicos de applets/health/notify). Ver qué pide esos frames extra.
4. **Revisar GLES3 vs GLES2 en tengu**: documentar/forzar el fallback a GLES2
   (hoy el launcher pide GLES3 y Godot baja solo) para no medir con supuestos
   falsos.
5. **Cerrar el hueco de atribución de CPU** (~5–9%, kernel-time): `strace -c`/`perf`
   en un host que los tenga, o `pidstat -t`.
6. **Track B (arquitectural)**: B1 desacoplar el compositor; B2 KMS real sólo con
   F0 a favor (ver `render-parity-gnome.md`). No arrancar sin números de GPU.

## 6. Reproducir

```sh
# huella (sesión activa en seat0); copiar el script corregido al host
scp bench/session_footprint.sh icarito@tengu.local:/tmp/
ssh icarito@tengu.local 'sh /tmp/session_footprint.sh 45'
# comparar dos corridas
sh bench/session_footprint.sh --compare a.json b.json
# estado de render (compositor/present/engine)
ssh icarito@tengu.local 'python3 /tmp/ctl.py state'   # + .result.compositor/.present/.engine
# reposo del loop: .result.loop = {busy, sleep_usec, low_mode, fps}
# OJO: no pollear con métodos interactivos (despiertan la shell); state es lectura pura.
# A/B del reposo: exportar GDTK_FORCE_IDLE=1 en el entorno de la sesión (hook del shell).
# perfil por frame (requiere ~/.gdtk-frt-perf y ~/.gdtk-imgui-time)
grep -aE "FRT_PERF|IMGUI|FRAME" ~/.local/state/gdtk/shell.log | tail
```

JSONs crudos: `~/gdtk-bench/xfce-20261010-000735.json`,
`~/gdtk-bench/gdtk-sway-20261010-001213.json` (en tengu).

## 7. Caveats

- Una sola corrida por escritorio; varianza de interacción no medida.
- XFCE traía apps del usuario de más; gdtk traía `deskflow-core`/`avahi`. No es
  1:1 estricto, pero la brecha (37×) es mucho mayor que el ruido.
- El "idle" de gdtk se midió con el Escritorio visible (barra del Frame); no se
  midió con la barra oculta.
- En este corte cambié `bench/session_footprint.sh` (selección de sesión activa).
  No commiteado.

## 8. Bastion — video fullscreen (2026-10-10, medición en vivo)

Escenario real: Firefox **fullscreen** (id 13) con Alacritty/Nautilus tiled detrás
(i7-1185G7 / Iris Xe). Medido ~8 s con la shell recargada:

| métrica | valor |
|---|---:|
| loop / drawn | 63/s / 47/s |
| commits/s | 57.8 (todas dmabuf, shm=0) |
| present/s | light 45.2, full 0 |
| `scanout` | **off** — `"otra ventana visible"` |
| CPU godot | **~7.6%** (firefox ~9.7%) |
| `[IMGUI]` | ~0.5 ms (`frame` 0.03, `tiles` 0.3) |

**El shell NO es el cuello en bastion** (godot < firefox) y el armado ImGui es
despreciable en fullscreen (`frame.visible=False` → `frame.draw`≈0). El cuello es
**presentación**:

1. **Scanout no engancha por la ventana fullscreen**: `scanout_candidate`
   (`modules/wayland/wl_server.c:454`) evalúa `scanout_has_visible_sibling`
   (:484) **antes** que `t->tl->current.fullscreen` (:488). Una ventana fullscreen
   que **tapa todo** nunca hace scanout si hay cualquier otra ventana visible en
   la salida principal → el video paga una **composición extra** (Godot + sway).
2. **Coalescing de presents**: 57.8 commits/s pero sólo 45.2 present/s (~22% no
   presentado) → judder potencial. El loop (63/s) hace *phase-slip* contra el
   vblank (ver comentario `shell.gd:1760-1763`; `LOW_SLEEP_VIDEO_USEC=2000`).

### Optimizaciones recomendadas (bastion, por retorno)

1. **Reordenar `scanout_candidate`: chequear fullscreen antes que el sibling**
   (o ignorar siblings detrás de un fullscreen opaco). Es una ventana fullscreen
   la que manda en la salida; el sibling no puede estar delante. Habilitaría el
   scanout directo del video (unredirect fullscreen ≈ Mutter). Cambio chico en
   `modules/wayland/wl_server.c` (motor → recompilar + corte controlado).
   **IMPLEMENTADO + validado + DESPLEGADO/ACTIVO (2026-10-10)**: harness aislado
   (nuevo→`scanout=on`, viejo→`"otra ventana visible"`) y **hardware real en
   bastion** con `GDTK_SCANOUT_DIRECT=1` (2 ventanas, fullscreen + sibling detrás
   → `scanout=on/reason="on"`). Instalado y activado por corte controlado
   (`restart_shell` → supervisor relauncha) en bastion, tengu y cupid.
   Rollback bastion: `~/gdtk/bin/godot-gdtk.prev`.
   **Corte controlado: las apps NO sobreviven** (son clientes del compositor
   embebido en el proceso del shell): en los 3 hosts las ventanas se perdieron y
   el shell volvió con su Terminal. En bastion el **server tmux sobrevivió**
   (sesiones intactas; los clientes de terminal mueren, tmux no).
2. **Frame scheduling a vblank (A4)**: emitir `frame_done`/presentación al vblank
   de sway y por salida, no al loop de Godot, para presentar cada commit (hoy
   ~22% se coalesce).
3. **Xwayland fullscreen en el candidato (bloqueo REAL de la peli)**: medido en
   vivo (2026-10-10, diagnóstico por‑ventana) → Firefox (id 5, fullscreen)
   reporta `scanout={active:False, reason:"toplevel no mapeado"}`. Firefox corre
   por **Xwayland** (`MOZ_ENABLE_WAYLAND=0`, `DISPLAY=:0`, por la mitigación de
   `guides/firefox-crashes.md`) y `scanout_candidate` exige `t->tl != NULL`
   (xdg), que para Xwayland es NULL → se rechaza antes del fullscreen/sibling.
   **El reorden no ayuda a la peli**; el fix es aceptar Xwayland fullscreen
   (usar `t->xs` + estado fullscreen del surface X11). Como una ventana Xwayland
   es **un solo `wl_surface`** (sin subsurfaces), escanearía la ventana completa
   (video incluido). Viabilidad alta; es un cambio de motor como el anterior.
   **IMPLEMENTADO + build OK + validado en harness + DESPLEGADO/ACTIVO (2026-10-10)**:
   `scanout_candidate` generalizado para xdg (`t->tl`) y Xwayland (`t->xs`;
   `t->xs->fullscreen`, excluye `override_redirect`). Harness: X11 fullscreen
   (`glxgears`) + sibling xdg → `active:true/"on"` (antes `"toplevel no mapeado"`).
   Instalado + corte en bastion/tengu/cupid. Caveat: en Xwayland no hay
   `base->popups`, así que un menú X11 abierto no suspende el scanout del padre
   (taparía el menú); sólo engancha si el cliente X presenta dmabuf.
   Alternativa (no recomendada): Firefox nativo Wayland
   (`GDTK_FIREFOX_NATIVE_WAYLAND=1`), pero reabre el UAF de escala.
   Nota: A3 (subsurface) sólo aplicaría al Firefox nativo-Wayland, no a Xwayland.
   **CONFIRMADO EN VIVO (bastion, peli fullscreen, 2026-10-10)**: `firefox`
   `scanout={active:True, reason:"on"}` (6/6); antes `"toplevel no mapeado"`.
   CPU durante la peli tras el fix: godot ~7.0%, sway ~3.0% (antes godot ~8.5%,
   sway ~1.6%): se saca la pasada de composición de Godot para el video, aunque
   `sway` sigue componiendo la salida (la composición doble se reduce, no se
   elimina del todo — eso es B2/KMS).
4. Vigilar que un poll de estado no despierte la shell (fix §3.1) en bastion.
5. Largo plazo: **B1/B2** (`render-parity-gnome.md`).
6. **Diagnóstico de scanout por‑ventana (INSTALADO Y ACTIVO, corte 2026-10-10)**: `state.compositor.windows[].scanout = {active, reason}` vía
   `WaylandCompositor.scanout_of(id)`. Motor: campo `toplevel.scanout_reason` +
   getter `wl_server_scanout_of` (`wl_server.c`/`.h`), binding en
   `wayland_compositor.cpp`/`.h`, y `shell/remote.gd`. Elimina la contradicción
   global `scanout="on"` vs `scanout_reason="otra ventana visible"`. Validado en
   harness aislado: fullscreen `active=true/reason="on"`; hermana
   `active=false/"otra ventana visible"`. **Corte aplicado en bastion, tengu y cupid**
   (mismo binario md5 `9f8733…`; incluye `imgui_canvas.cpp` del 04:36). En vivo en
   bastion, la ventana de video aparece con `scanout={active:false, reason:"suspendido
   (overlay del shell)"}`: el diagnóstico funciona; ese overlay (Frame/barra) es lo que
   impide el scanout en ese caso.

## 9. Issue B — causa raíz hallada y CORREGIDA (2026-10-10)

**Síntoma**: el shell armaba ImGui y redibujaba la barra del Frame en **cada vuelta del
loop** (≈4/s en reposo), aunque `update_hz=1` (§3.2). El piso de 1 Hz era inútil porque
algo pedía `request_redraw()` por vuelta. Ese era "B": redibujo continuo en reposo.

**Causa raíz**: `shell/applet_clipboard.gd:refresh()` comparaba
`... or items != s_items ...`, donde `items` es un **duplicado** de `s_items`
(`s_items.duplicate(true)`). En **Godot 3 `Dictionary` (y `Array` de `Dictionary`) se
comparan por REFERENCIA, no por contenido**: `duplicate(true) != original` es **siempre
true**. Resultado: el applet Portapapeles reportaba `changed=true` en cada `refresh()`,
y `frame._process` (`frame.gd:2682-2687`) pedía un frame cada vuelta mientras los applets
estuvieran a la vista. El contenido de los dos arrays era idéntico (misma cantidad,
mismos dicts); sólo difería la identidad.

**Cómo se encontró** (instrumentación temporal, ya removida):
1. Nuevo diagnóstico permanente `state.imgui = {update_hz, input_hz, builds}` donde
   `builds` es `shell.frame_count` (cada `_imgui_frame` armado). Dos lecturas dan
   armados/s. En reposo `builds/s` seguía **= loop/s** (4.1) en vez de `update_hz` (1).
2. Contador por sitio + sombra temporal de `request_redraw()` → aisló
   `applet:portapapeles` (62 llamadas/15 s) como la única fuente por vuelta.

**Fix** (`shell/applet_clipboard.gd`): comparar por **firma de string** (sí es por
contenido): `or str(items) != str(s_items) or ...`.

**Verificación (bastion, vivo, reposo)**:
- Armados de ImGui: **4.1/s → 1.2/s** (el resto = piso `update_hz=1` + `sysmon.tick()`
  1/s del Frame). Loop sin cambios (4.05/s). `state.loop.busy=false`.
- CPU de godot en reposo: **~3.5%** de un core (Home, barra visible).
- Test de regresión: `tests/clipboard_refresh_test.gd` (asserta el gotcha de identidad de
  Godot 3 y que `refresh()` **no** reporta cambio en reposo, sí ante cambios reales).

**Nota sobre `update_hz`** (§3.2): bajarlo 4→1 es correcto, pero recién ahora tiene
efecto; antes el redraw por vuelta del applet lo anulaba.

**Observación en tengu (no es el mismo caso)**: con una terminal ([mosh] tmux)
commiteando ~19/s, el loop queda `busy=true` a **62 fps** y la CPU del shell ~**68%** de
un core (render de ~11 ms/frame en GM45/GLES2 a 60 fps: `render` domina, no GDScript).
Esa es la "fase busy" de §3.2 → **A4** (frame scheduling al vblank, no al loop de Godot)
es el trabajo pendiente de mayor retorno ahí.

**Deploy a tengu/cupid (HECHO 2026-10-10)**: se instaló el binario del corte
(md5 `9f8733…`, `objcopy --remove-section=.note.gnu.property`) en
`~/gdtk/bin/godot-gdtk` de tengu y cupid (backup en `.prev`) y se reinició la shell
de cada host (mismo binario en los tres). Nota de método: los `peer_control.gd`/
`peer_link.gd` con `preload` deben entrar juntos en la recarga; un snapshot completo
(`rsync -a --delete --exclude '.import' --exclude '*crash*' shell settings ~/gdtk/`) +
`reload_shell` para scripts, `restart_shell` sólo para motor.

## 10. Estado del árbol y suite (2026-10-10, turno siguiente)

- **Build del diagnóstico scanout**: terminado; no hay `scons` corriendo. Artefacto
  `godot-gdtk-slug/bin/godot.frt.opt.debug.x86_64.gdtklite` (04:37) **más nuevo** que
  `~/gdtk/bin/godot-gdtk` (04:09) → sigue **sin instalar** (necesita el corte controlado).
- **Suite headless** (`tools/verify_all.sh`, binario dev): verde salvo 4 fallas
  **preexistentes y ajenas a este cambio** (no las toca el fix de B):
  `frame_hidden_mouse_test` (harness rígido: `drop_mouse_interaction` ahora usa
  `_win_pick`, que el stub no declara — trabajo de frame sin commitear), `inotify_watch_test`
  y `scanout_overlay_test` (dependen de clases nativas/WIP), `expose_drag_wiring_test`.
  **`clipboard_refresh_test.gd` (nuevo) pasa (8/8)** y todos los tests del área tocada
  (`applet_*`, `frame_*`, `bar_slots`, `shared_block`) pasan.
- **Auditoría de la clase de bug de B** (comparar `Dictionary`/`Array` por contenido):
  barrido de `!=`/`==` contra `.get()`/`.duplicate()` en `shell/*.gd` → **no quedan más**
  casos de ese tipo que gateen redraw/refresh.
- **Por qué el busy sigue caro (análisis, no fix)**: en tengu, con una terminal
  commiteando ~19/s, el loop corre a 60 fps (`SLEEP_ACTIVE=16ms`, por latencia de input)
  y **re-presenta frames sin cambio** entre commits (~41 de cada 60 son redundantes);
  el costo real es el render (~11 ms/frame en GM45), no GDScript. Bajar el sleep del busy
  agrega latencia de tecleo, así que el fix correcto es **A4/damage (arquitectural)**,
  no un cambio de script. Confirma la prioridad de A4 para tengu.


