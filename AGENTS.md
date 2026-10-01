# AGENTS.md — gdtk

## Proyecto

`gdtk` es un shell/toolkit sobre el fork Godot 3.6 `godot3-box3d`, con módulos
locales de ImGui, Wayland/FRT, portal de input remoto y utilidades de shell tipo
Sugar. El repo **no** es un proyecto Godot vanilla ni Godot 4.

## Motor y binarios

Usar siempre el fork Godot 3 del usuario, no `/usr/bin/godot`:

```sh
/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk
```

Para tests headless de GDScript puro también funciona el mismo binario con
`--no-window --path shell -s <test>`.

`/usr/bin/godot` puede ser Godot 4 y no sirve para este repo.

## Comandos de verificación

Tests pequeños de modelos/parsers:

```sh
/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk --no-window --path shell -s $PWD/tests/neighborhood_test.gd
/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk --no-window --path shell -s $PWD/tests/neighborhood_hosts_test.gd
/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk --no-window --path shell -s $PWD/tests/neighborhood_publish_test.gd
/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk --no-window --path shell -s $PWD/tests/neighborhood_actions_test.gd
```

Shell visual/anidado:

```sh
./run_shell.sh
tests/control_test.sh
```

Los tests pueden imprimir ruido previo conocido de autoloads/clases nativas
(`RemoteInput`, `host.gd`, `WaylandCompositor`) antes del runner. No lo confundas
con falla si el proceso termina en `exit 0` y las líneas `ok` del test aparecen.

## Build y deploy

`deploy.sh` compila y despliega con un árbol aislado del motor:

- `GODOT` default: `/home/icarito/Proyectos/godot3-box3d/godot-gdtk-slug`
- `FORK` default: `/home/icarito/Proyectos/godot3-box3d/godot-box3d-3-gdtk`
- módulos extra: este repo en `modules/`

No cambies de rama ni limpies esos árboles sin pedirlo. El script verifica que el
binario tenga `ImGuiCanvas` y `SlugVector2D`.

## Estilo de cambios

- Godot 3 GDScript, no sintaxis Godot 4.
- Preferir helpers puros `extends Reference` para parsers/modelos.
- Tests de modelos: `extends SceneTree`, `load("res://...").new()`, `check()`,
  `OS.exit_code`, `quit()`.
- Mantener Wi-Fi, hosts, acciones y publisher separados hasta integrar en el shell.
- No bloquear `_process()` ni `neighborhood_ui.refresh()` con discovery o comandos.
- No pasar secretos por argumentos, logs, TXT DNS-SD ni Diario.
- No duplicar el ciclo de vida de servicios: Deskflow debe reutilizar
  `_toggle_service()`, `_service_running()` y `service_pids`.

## Vecindario

La dirección de producto está en:

- `SPEC-sugar-journal-neighborhood.md`
- `SPEC-sugar-neighborhood-host-actions.md`

Separaciones importantes:

- Wi-Fi es infraestructura, no presencia social.
- Host descubierto no es persona Sugar.
- Deskflow es control compartido práctico, no colaboración Sugar.
- `gvd` hoy recibe/muestra pantalla; emitir desde gdtk es fase posterior.

## gvd

El prototipo vive en:

```sh
/home/icarito/Proyectos/gvd
```

Usar `python3 /home/icarito/Proyectos/gvd/gvd.py caps --json` para detectar
capacidades sin abrir streams. El stream RTP/H.264/UDP no cifra ni autentica; sólo
LAN confiable o red protegida.

## Delegación Kilo

Cuando se lancen subagentes Kilo desde este repo, usar DeepSeek v4.1 Flash:

```sh
kilo run --dir /home/icarito/Proyectos/gdtk \
  --agent code \
  -m kilo/deepseek/deepseek-v4.1-flash \
  --auto --format json --title "..." "..."
```

Usar `--agent ask` para mapeo/lectura y `--agent code` para cambios acotados.
Los probes locales con ambos agentes devolvieron `KILO_OK`/`KILO_CODE_OK`.
Con `--format json`, Kilo puede duplicar eventos; extraer o deduplicar `type:"text"`.

Evitar correr varios `kilo run` simultáneos: esta instalación puede chocar con
`Failed query: update "credential" ... connector_id = "kilo"`. Delegar en serie.

Cada subagente debe tener write set explícito, no hacer commit, no deployar y no
revertir cambios ajenos.
