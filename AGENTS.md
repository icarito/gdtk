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
/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk --no-window --path shell -s $PWD/tests/expose_layout_test.gd
/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk --no-window --path shell -s $PWD/tests/frame_menu_test.gd
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

## Setup de pruebas y updates (repo vs instalación)

**No confundir dos paths parecidos:**

- **Repo (fuente de verdad, git)**: `~/Proyectos/gdtk`, es decir
  `/home/icarito/Proyectos/gdtk`. Ojo: `/home/icarito/Proyectos` es un **symlink** a
  `/run/media/icarito/DATA/icarito/Proyectos`, así que el repo vive físicamente en
  el disco `DATA` (`/dev/nvme0n1p1`). Acá están `AGENTS.md`, `tests/`, `bench/`,
  `demo/`, `modules/` y `.git`; acá se edita y se commitea. Si `DATA` no está
  montado el symlink queda colgando y el repo "desaparece": montar con
  `udisksctl mount -b /dev/nvme0n1p1` (o esperar el automontaje de udisks).
- **Instalación (lo que corre la sesión)**: `~/gdtk` = `/home/icarito/gdtk`. Tiene
  `bin/godot-gdtk`, pero **no** `.git` ni `tests/` ni `modules/`. No editar acá: se
  pisa con el sync. La sesión lanza `~/gdtk/bin/godot-gdtk ... --path ~/gdtk/shell`.

### Cadena de arranque de la sesión

`/usr/share/wayland-sessions/gdtk.desktop` (Exec **absoluto**) →
`session/gdtk-session-sway` → `session/sway.conf` → `session/gdtk-supervisor`
(relanza el shell si se cae) → `bin/godot-gdtk --path ~/gdtk/shell`.

Si el `.desktop` apunta a una ruta vieja, GDM falla con
`env: «...»: No existe el fichero o el directorio` y cae a otro escritorio. Al mover
el proyecto/instalación hay que reinstalar las entradas:

```sh
sudo install -d /usr/share/xsessions
sudo install -m644 session/gdtk.desktop session/gdtk-sway.desktop /usr/share/wayland-sessions/
sudo install -m644 session/gdtk-x11.desktop /usr/share/xsessions/
```

### Tests

Correr **desde el repo** (la instalación no tiene `tests/`), con el binario dev:

```sh
cd ~/Proyectos/gdtk
/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk \
  --no-window --path shell -s $PWD/tests/<test>.gd
```

El binario dev **no** trae las clases nativas (`RemoteInput`, etc.), así que los
tests/scripts que las usan (`shell.gd`) fallan al parsear con
`The identifier "RemoteInput" isn't declared`. Es ruido conocido. Para validar
**parseo** de esos scripts usar el binario instalado:

```sh
~/gdtk/bin/godot-gdtk --no-window --path shell -s <script.gd>
# en el script: GDScript.set_source_code(fuente) + g.reload() == 0 si parsea
```

### Aplicar cambios

- **Sólo scripts** (`.gd`, `.tscn`): sincronizar a la instalación y **recargar el
  shell** (menú central → *Recargar el shell*). Los `.gd` se leen al arrancar; editar
  la instalación no alcanza.

  ```sh
  cd ~/Proyectos/gdtk
  rsync -a --exclude '.import' shell settings session ~/gdtk/
  ```

- **Engine** (`modules/wayland/*`, `modules/imgui`, etc.): requiere **recompilar** e
  instalar el binario. `deploy.sh <usuario>@<host>` lo hace para un host remoto
  (`tengu.local`, `cupid`, …). Para bastion mismo `ssh localhost` hoy falla por host
  key: build + `objcopy --remove-section .note.gnu.property` + copiar a
  `~/gdtk/bin/godot-gdtk`. Comparar fechas: si
  `stat ~/gdtk/bin/godot-gdtk` es más viejo que los `modules/`, ese binario **no**
  tiene esos cambios (p. ej. el soporte EIS/Deskflow).

### Logs y estado

- `~/.local/state/gdtk/`: `supervisor.log`, `shell.log` (corrida actual),
  `shell.prev.log`, `crash-*.log`, `autostart.log`.
- `journalctl -b | grep -i gdtk` para fallos de GDM/sesión.
- Banderas runtime: `/run/user/1000/gdtk-{supervisor.lock,shell.pid,restart,quit}`.

### Portal y Deskflow

- El shell publica el backend `org.freedesktop.impl.portal.desktop.gdtk`
  (RemoteDesktop/ScreenCast/InputCapture, vía `modules/wayland/eis_server.c`). El
  frontend `xdg-desktop-portal` lo elige por `XDG_CURRENT_DESKTOP=gdtk` y
  `~/.config/xdg-desktop-portal/gdtk-portals.conf` (lo fija `session/portal.sh`).
- `deskflow-core server` usa EIS: si cambian `modules/wayland/`, hay que recompilar o
  el server corre con el EIS viejo ("captura pero no anda bien").
- El tray/GUI de `deskflow` es Qt y puede fallar en Wayland
  (`Could not load the Qt platform plugin "wayland"`): **no** es fatal para el core.

### Reglas para agentes futuros

- Editar y commitear **sólo en el repo** (`~/Proyectos/gdtk`), con write set explícito.
- **Nunca** crear archivos con `class_name` de una clase nativa (p. ej.
  `RemoteInput`): choca con el binario y rompe la sesión. Un `shell/_remote_input_tmp.gd`
  así llegó a un deploy y tumbó el arranque.
- No editar `~/gdtk` a mano ni borrar su `bin/`; no confundir `~/gdtk` (instalación)
  con `~/Proyectos/gdtk` (repo).
- Tras cambios de scripts: recordar **recargar el shell**. Tras cambios de engine:
  **recompilar**.
- No revertir el trabajo sin commitear de `modules/wayland/` (EIS/Deskflow) ni otros
  cambios ajenos del árbol.
- No commitear ni deployar sin pedido explícito. Para delegación, ver "Delegación
  Kilo" más abajo.

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
