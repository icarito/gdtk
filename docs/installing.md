# Installing the session

## Automated install (releases)

`install.sh` (repo root) installs a published release on a user's machine: it
installs the runtime dependencies, unpacks the prebuilt binary and scripts into
`~/gdtk`, regenerates the session `.desktop` entries with the real `$HOME`, and
copies the portal configuration.

```sh
curl -fsSL https://raw.githubusercontent.com/icarito/gdtk/main/install.sh | sh
# or: sh install.sh --help   (--home, --version, --driver, --no-deps, --minimal,
#                             --no-session, --from ARCHIVO, -y)
```

The tarball it consumes (`gdtk-<version>-linux-x86_64.tar.gz`, plus `.sha256`) is
produced by the `release` GitHub Actions workflow on a `v*` tag, or locally with
`tools/make-release.sh` (which compiles the engine, or reuses `GDTK_BIN` with
`GDTK_NO_BUILD=1`). The tarball layout is `bin/godot-gdtk`, `shell/`, `addons/`,
`settings/`, `mcp/`, `tools/`, `session/` and `VERSION`; `install.sh` regenerates
the `.desktop` files, so they are not shipped.

## Layout on disk

- **Repository**: where the code is edited (e.g. `~/Proyectos/gdtk`).
- **Installation**: `~/gdtk`, what the session actually runs: `bin/godot-gdtk`,
  `shell/`, `settings/`, `session/`, `tools/gvd`. It has no `.git`, tests or
  engine modules; `deploy.sh` (or an rsync of the script directories) fills it.

## Startup chain

```
/usr/share/wayland-sessions/gdtk.desktop   (absolute Exec path)
  → session/gdtk-session-sway
    → sway with session/sway.conf
      → session/gdtk-supervisor            (relaunch, heartbeat, last_good fallback)
        → bin/godot-gdtk --path ~/gdtk/shell
```

Install the display-manager entries once (and again if the installation moves):

```sh
sudo install -m644 session/gdtk.desktop session/gdtk-sway.desktop /usr/share/wayland-sessions/
sudo install -d /usr/share/xsessions
sudo install -m644 session/gdtk-x11.desktop /usr/share/xsessions/
```

## Runtime dependencies

The session degrades gracefully: every optional piece that is missing is logged
and skipped. Full tables (Spanish) in [`session/DEPS.md`](../session/DEPS.md).

| Area | Packages |
|---|---|
| Binary (engine) | `wlroots0.20`, `libei`, `sdl2-compat`, `libglvnd`, `libxkbcommon`, `wayland`, `systemd-libs`, `mesa`, `vulkan-icd-loader` |
| Session | `sway`, `dbus` |
| Portals and screen capture | `xdg-desktop-portal`, `xdg-desktop-portal-wlr`, `xdg-desktop-portal-gtk`, `pipewire`, `wireplumber`, `grim` |
| Desktop services | a polkit agent (`polkit-gnome` or similar), `gnome-keyring`, `mako`, optionally `dex` |
| Neighborhood | `avahi` (`avahi-publish-service`, `avahi-browse`) |
| Sharing | `deskflow` (keyboard and mouse), GStreamer with x264/VA-API (gvd), `pactl` (audio) |
| Hardware extras | `iio-sensor-proxy` (auto-rotation), `brightnessctl` (fallback) |

The CPU governor dockapp needs a one-time, per-machine setup of its PolicyKit
helper:

```sh
sudo ~/gdtk/session/gdtk-governor-provision install
```

## Logs and state

- `~/.local/state/gdtk/`: `shell.log` (current run), `shell.prev.log`,
  `supervisor.log`, `crash-*.log`, `autostart.log`.
- `~/.config/gdtk/`: `settings.json`, Frame layout, group placements and peer
  tokens.
- `session/gdtk-version status`: which shell version is running (live tree or the
  `last_good` fallback).
- `journalctl -b | grep -i gdtk`: display-manager and session failures.

## Security notes

The peer channel (TCP 7788), the gvd video streams (RTP/UDP) and the audio tunnel
are neither encrypted nor authenticated beyond per-pair tokens and IP allow-lists.
Use them only on a network you trust.
