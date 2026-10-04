# Installing the session

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
