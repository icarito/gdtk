# Architecture

This document describes how gdtk is put together at the time of the initial
release. The normative detail for each area lives in the design specs under
[`.operator-shared/specs/`](../.operator-shared/specs/) (Spanish); start with
`SPEC-architecture.md`.

## Process layout

```
GDM ─ gdtk.desktop ─ session/gdtk-session-sway ─ sway (host compositor)
                                                  └─ session/gdtk-supervisor
                                                      └─ godot-gdtk --path ~/gdtk/shell   ← one process
                                                          ├─ autoload Host (host.gd): lives for the whole run
                                                          │   ├─ WaylandCompositor  (modules/wayland: embedded wlroots)
                                                          │   │     └─ user applications (and Xwayland)
                                                          │   ├─ RemoteInput (EIS + xdg-desktop-portal backend)
                                                          │   ├─ PeerControl (LAN channel between gdtk shells)
                                                          │   └─ Remote (JSON-RPC control port, localhost:7777)
                                                          └─ main.tscn (main.gd): swaps shell.gd without closing apps
                                                              └─ shell.gd on an ImGuiCanvas: views, windows, services
                                                                  ├─ frame.gd (Frame bars, launchers, dockapps)
                                                                  ├─ neighborhood_ui.gd, tiles_ui.gd, layers.gd, …
                                                                  └─ pure models (extends Reference) + tests
```

- **Two compositors.** The shell itself is a fullscreen client of sway (which owns
  DRM, input devices and outputs). Applications are clients of the compositor
  embedded in the shell, which has its own `WAYLAND_DISPLAY`. Surfaces arrive as
  Godot textures; the shell composes them, draws decorations and forwards input.
- **Settings** (`settings/`) is a separate Godot project launched as a Wayland
  window. It writes `~/.config/gdtk/settings.json`; the shell picks changes up
  through `shell/settings_bridge.gd`.
- **The engine.** A fork of Godot 3.6 (`godot-box3d-3`) with the FRT/SDL2 platform,
  a Dear ImGui module (with ImPlot/ImPlot3D and a radial menu) and Slug vector
  text/icon rendering, built together with this repository's `modules/wayland`.

## Session robustness

- **Hot reload.** `main.gd` compiles and instantiates a new `shell.gd` as a
  candidate and only swaps it in if it comes up healthy; the compositor, portal
  backend and every application survive. Scripts meant to be reloaded are loaded
  through `Host.sc()` (compiled from source text); `preload`ed models stay cached
  until the process restarts.
- **Supervisor.** `session/gdtk-supervisor` relaunches the shell if it dies, and
  watches a semantic heartbeat so that a process that is alive but stuck is not
  promoted as "good". A shell that stays healthy is snapshotted as `last_good`; two
  consecutive crashes at startup fall back to it.
- **Isolated development.** `tools/run-isolated-shell.sh` runs a nested instance
  with its own runtime directory, ports, token and logs, so the live session is
  never touched while iterating.

## Cross-cutting contracts

1. **The render thread never waits.** `_process`, ImGui frames and dockapp
   `refresh()` never run commands, read `/proc` or `/sys`, or call D-Bus. That work
   happens in worker threads that publish a snapshot the UI copies.
2. **The shell sleeps.** No state change means no redraw; code that changes
   something visible requests a redraw explicitly.
3. **Logic is pure and tested.** Parsers, layouts and decisions live in
   `extends Reference` scripts without I/O or nodes, each with a headless test in
   `tests/`. `shell.gd` and `frame.gd` only wire things together.
4. **Honest state.** Without a measurement nothing is invented: dockapps show
   "no data", "unavailable" or "error".
5. **No secrets** in process arguments, logs, DNS-SD records or persistent history.

## Views and window management

- **Zoom model** (`zoom_model.gd`): Home → Group → Neighborhood, with the
  "this computer" icon as the visible anchor of the zoom. A vertical gesture chain
  links Neighborhood, Group, screens, exposé, Home and the app grid.
- **Windows** (`wm_*.gd`, `float_layout.gd`, `window_chrome.gd`): every window is
  independently floating or tiled; decorations are drawn by the shell unless the
  client draws its own (CSD); exposé, snapping and Super+drag work for both.
- **Frame** (`frame.gd`): edge bars with pinned launchers, a window strip and
  dockapps. Each dockapp is a `shell/applet_<name>.gd` module with a small
  duck-typed contract (`state/value/detail`, `refresh()`, `stop()`, optional
  `draw()`); see `.operator-shared/guides/dockapp.md`.

## Group and Neighborhood

- **Discovery.** Each shell announces itself over mDNS (`_gdtk-gvd._udp`,
  `_gdtk-deskflow._tcp`) with a small TXT record: host id, name, device kind and
  icon, accent color and the peer channel port (`neighborhood_publish.gd`).
  `neighborhood_hosts.gd` merges announcements into hosts; Wi-Fi and Bluetooth are
  shown separately (infrastructure is not presence).
- **Group membership** comes from what the user already decided: a placement in
  `neighborhood-directions.json`, a pairing token or a configured screen.
- **Peer channel** (`peer_link.gd`, `peer_control.gd`, `peer_call.gd`): one JSON
  request per TCP connection on port 7788, with a whitelist of methods (open or
  stop a screen receiver, sharing notices, clipboard, audio, video size).
  Authentication is trust-on-first-use: the first request from a confirmed
  neighbor provisions a per-pair token that must be presented afterwards. The
  channel is not encrypted.

### Sharing features

| Feature | How it works |
|---|---|
| Extend my screen | `gvd` streams a screen as H.264/RTP; the peer channel asks the other machine to open its receiver first. |
| Share keyboard and mouse | Deskflow. The server side uses gdtk's own InputCapture portal backend (`modules/wayland/eis_server.c`); clients follow the server automatically. The pointer never crosses machines in the middle of a local drag. |
| Share a window | Dropping a window's Frame block on a machine starts `window_cast.gd`: the window is composed into an offscreen viewport and written to a frame file in `$XDG_RUNTIME_DIR` (seqlock, never a FIFO), read by `gvd send --capture shm`. Resizes on the sending side restart the encoder at the new size; the receiver fits its window to the video. Closing either window stops the share. |
| Send audio | The receiver opens `module-native-protocol-tcp` restricted to the sender's IP; the sender creates a `module-tunnel-sink`, makes it the default and moves its streams there. Works with PipeWire and PulseAudio. |
| Group clipboard | Text copied on one machine (via `ext-data-control` in the embedded compositor) is pushed to the other group members over the peer channel. |

## Control and observability

- `shell/remote.gd`: JSON-RPC 2.0 on `127.0.0.1:7777`, token in
  `$XDG_RUNTIME_DIR/gdtk-control.token`. State, screenshots, synthetic input,
  window operations, launch, metrics.
- `mcp/gdtk_mcp.py`: exposes the same commands as an MCP server for coding agents.
- `addons/debug_hud`: in-shell HUD with frame timing and per-area counters.
- Logs: `~/.local/state/gdtk/` (`shell.log`, `supervisor.log`, crash logs).
