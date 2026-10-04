# gdtk

**A Sugar-inspired desktop shell built on Godot 3, with its own embedded Wayland
compositor and a "group of machines" model for sharing screens, input, audio and
windows across the computers on your desk.**

gdtk turns a Godot 3.6 engine fork into a full graphical session. The shell UI is
drawn with Dear ImGui inside Godot; regular Linux applications (Firefox, terminals,
GTK and Qt apps, Xwayland) run inside a wlroots compositor embedded in the same
process. On top of that sits a model taken from the
[Sugar](https://sugarlabs.org/) learning environment: you zoom out from your
**Home** to your **Group** of machines and then to the whole **Neighborhood** on
your network, and you share things by dragging them onto another computer.

> **Status: alpha / initial release.** gdtk runs daily as a pilot session on a few
> machines (a modern laptop, a 2008 ThinkPad X200 with GLES2 graphics, a Surface
> Pro 3). It is not yet a complete replacement for GNOME or KDE: see
> [Known gaps](#known-gaps).

## Highlights

- **Three zoom levels, Sugar style.** Home (ring of activities around "this
  computer"), Group (your paired machines, placed where they physically sit) and
  Neighborhood (everything discovered on the network: gdtk hosts, Wi-Fi, Bluetooth).
  Switch with F1–F3, Super+wheel, pinch or three-finger swipes.
- **Share by drag and drop.** Drop a window onto a machine in the Group view and it
  is streamed there live as H.264; close either copy to stop. The remote window
  follows resizes on both sides and is framed in the sender's color.
- **Your machines as one desk.** Per machine, from the same menu: extend your
  screen, share keyboard and mouse (Deskflow over a native InputCapture portal),
  send your audio (PulseAudio/PipeWire tunnel). The clipboard is shared across the
  group automatically.
- **Embedded Wayland compositor.** wlroots inside the Godot process: xdg-shell,
  popups and subsurfaces, layer-shell, zero-copy dmabuf, text input/IME, data
  control, drag and drop, Xwayland, plus a RemoteDesktop/ScreenCast/InputCapture
  portal backend.
- **Hybrid window management.** Each window is independently floating or tiled,
  with WindowMaker-style decorations, exposé, snapping, Super+drag to move/resize
  and support for client-side decorations.
- **The Frame.** Sugar's edge panels: pinned launchers, a window strip and square
  "dockapps" (CPU/memory/swap, temperature, battery and CPU governor, clock,
  keyboard layout, clipboard history, active shares), plus on-screen volume and
  brightness and touchpad gestures.
- **Hot reload without losing your apps.** The shell's scripts reload
  transactionally while the compositor and every running application stay alive.
  A supervisor with a semantic heartbeat restarts the shell, or falls back to the
  last known-good version, if something breaks.
- **Scriptable.** A local JSON-RPC control port and an MCP bridge let tools and AI
  agents drive the shell (screenshots, input, windows, launch, metrics).
- **Light.** When nothing changes the shell stops redrawing and throttles its main
  loop. It runs on GLES2 hardware from 2008.

## Architecture at a glance

```
GDM → gdtk session → sway (host compositor) → gdtk-supervisor
                                               └─ godot-gdtk (one process)
                                                  ├─ Host (lives for the whole session)
                                                  │   ├─ WaylandCompositor  ← wlroots, C; your apps run here
                                                  │   ├─ RemoteInput        ← EIS + xdg-desktop-portal backend
                                                  │   └─ PeerControl        ← LAN channel to other gdtk shells
                                                  └─ Shell (hot-reloadable GDScript, drawn with ImGui)
                                                      ├─ Home / Group / Neighborhood views
                                                      ├─ window manager, Frame and dockapps
                                                      └─ pure models (layouts, protocols, parsers) + tests
Settings  = a separate Godot app, talks to the shell through ~/.config/gdtk/settings.json
gvd       = H.264/RTP screen and window streaming (tools/gvd)
mcp/      = MCP bridge to the shell's JSON-RPC control port
```

Machines find each other over mDNS (DNS-SD); pairing is trust-on-first-use with a
per-pair token. Details in [docs/architecture.md](docs/architecture.md).

## Getting started

gdtk needs its Godot 3.6 fork (with the ImGui module) compiled together with this
repository's `modules/`. Building and deploying are covered in
[docs/building.md](docs/building.md); installing the session and its runtime
dependencies in [docs/installing.md](docs/installing.md).

Quick look without installing a session (after building):

```sh
./run_shell.sh         # the shell in a nested window
tools/verify_all.sh    # the test suite, isolated from any live session
```

## Repository layout

| Path | What lives there |
|---|---|
| `shell/` | The shell (Godot project): views, window manager, Frame, dockapps, neighborhood, peer channel and pure models |
| `settings/` | The Settings app (separate Godot project) |
| `modules/wayland/` | Engine module: embedded wlroots compositor, EIS/portal backend |
| `session/` | Session startup, supervisor, version store, hardware and helper scripts |
| `tools/gvd/` | Screen/window streaming over H.264/RTP |
| `mcp/` | MCP bridge to the shell's control port |
| `tests/` | Headless tests (one per model/area) and end-to-end drivers |
| `bench/`, `demo/`, `addons/` | ImGui vs Godot UI benchmarks, the ImGui demo, the debug HUD |
| `docs/` | Human documentation (this release) |
| `.operator-shared/` | Design specs, guides, plans and work logs (Spanish; the normative detail) |

## Documentation

- [docs/architecture.md](docs/architecture.md): processes, components, contracts and data flows
- [docs/building.md](docs/building.md): engine trees, compiling and deploying
- [docs/installing.md](docs/installing.md): session setup, dependencies, logs
- [docs/design-notes.md](docs/design-notes.md): the original feasibility study
- [AGENTS.md](AGENTS.md): working rules for contributors and coding agents (Spanish)

## Known gaps

Before gdtk can be anyone's only session it still needs:

- **Screen locking and idle handling** (blanking, lock on resume).
- **Multiple monitors.** HiDPI works through a single global UI scale that is
  also passed to applications; extending the desktop to more than one physical
  output is designed (`SPEC-embedded-multi-output.md`) but not wired yet.
- **IME in the shell's own text fields.** Applications already get input methods
  (fcitx5, IBus, on-screen keyboards) through text-input-v3/input-method-v2.
- **Power key.** Suspending on lid close is left to logind; the power key is not
  mapped to suspend yet.

Streams (gvd), the audio tunnel and the peer channel are not encrypted: use them
on a trusted LAN only.
