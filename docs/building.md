# Building and deploying

gdtk is not a stock Godot project: the shell needs engine classes that only exist
in its Godot 3.6 fork (`ImGuiCanvas`, `SlugVector2D`, `WaylandCompositor`,
`RemoteInput`). The engine is compiled together with this repository's
`modules/` directory.

## Source trees

| Tree | Role |
|---|---|
| `godot3-box3d/godot-dev` | Engine tree used for gdtk development builds (a `git worktree` of the same commit as the main tree, with the fork's patches applied). |
| `godot3-box3d/godot-gdtk-slug` | Engine tree used by `deploy.sh` for release builds (`GODOT=`). |
| `godot3-box3d/godot-box3d-3-gdtk` | The fork's extra modules, including the ImGui module (`FORK=`). |
| this repository | `modules/wayland` (embedded compositor, EIS/portal backend), the shell, settings and session. |

Keeping gdtk on its own engine tree means other projects built from the same fork
never change its patches, and scons does not rebuild everything when switching.
The object cache (`SCONS_CACHE=~/.cache/scons-godot3`) is shared between trees.

Build dependencies beyond Godot's own (pkg-config names): `wlroots-0.20`,
`wayland-server`, `wayland-client`, `xkbcommon`, `egl`, `libeis-1.0` (from libei),
`libsystemd` (sd-bus) and SDL2.

## Release build (what `deploy.sh` does)

The deployed binary has no editor (`tools=no`) and drops the modules the shell
does not use (physics, networking, VR, glTF, audio codecs…):

```sh
cd ~/Proyectos/godot3-box3d/godot-dev
scons -j8 platform=frt arch=x86_64 target=release_debug tools=no frt_desktop_gl=yes production=yes \
  lto=none use_static_cpp=no extra_suffix=gdtklite imgui_implot3d=yes \
  custom_modules=$HOME/Proyectos/godot3-box3d/godot-box3d-3-gdtk,$HOME/Proyectos/gdtk/modules \
  $(for m in bullet csg gridmap enet upnp webrtc websocket webxr mobile_vr gdnative visual_script theora webm \
    vorbis opus ogg stb_vorbis minimp3 gltf jsonrpc camera opensimplex raycast box3d decal; do echo module_${m}_enabled=no; done)
```

For development, build with the editor instead (`tools=yes extra_suffix=gdtk`,
without the `module_*_enabled=no` list). The resulting
`bin/godot.frt.opt.tools.x86_64.gdtk` is also what runs the headless tests.

## Deploying to a machine

```sh
./deploy.sh user@host            # build, then install binary + shell + settings + session
./deploy.sh user@host GLES2      # for GLES2-only hardware (e.g. Intel GM45)
```

`deploy.sh` verifies that the binary contains `ImGuiCanvas` and `SlugVector2D`,
copies an explicit list of `session/` scripts and the vendored `tools/gvd` (whose C
helpers are recompiled on the target machine on first use).

Script-only changes do not need a rebuild: sync `shell/`, `settings/` and
`session/` into the installation (`~/gdtk`) and reload the shell. Engine changes
(`modules/`) always need a rebuild and a session restart.

## Running and testing

```sh
./run_shell.sh                 # shell in a nested window
./run_compositor.sh            # compositor demo
tools/run-isolated-shell.sh    # nested instance with its own runtime dir, ports and logs
tools/verify_all.sh            # every headless test, isolated from the live session
```

A single test:

```sh
<godot-dev binary> --no-window --path shell -s $PWD/tests/<name>_test.gd
```

The development binary lacks the native classes, so scripts that use them
(`shell.gd`) report a known parse error when loaded by unrelated tests; check for
the `ok`/`FAIL` lines. `tests/parse_check.gd`, run with the installed binary,
checks that those scripts compile.
