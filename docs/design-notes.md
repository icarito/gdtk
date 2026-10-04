# Design notes: the original feasibility study (September 2026)

gdtk started as an *immediate-mode UI toolkit for Godot 3*: lightweight custom UIs
(a mobile XMPP client, a Sugar-like shell) on the Godot 3.6 fork `godot-box3d-3`,
using Dear ImGui as the widget layer. This is the feasibility review that
started the project, kept for history. The shell outgrew it: see the
[README](../README.md) for what exists today.

| Piece | Verdict | Notes |
|---|---|---|
| ImGui inside Godot 3 | Viable | C++ module; rendering through `VisualServer.canvas_item_add_triangle_array`, one child canvas item per `ImDrawCmd` for scissoring (`canvas_item_set_custom_rect` + `set_clip`). Same on GLES2, GLES3 and FRT. |
| On-screen keyboard on Android/iOS | Viable, cheap | `io.WantTextInput` → `OS.show_virtual_keyboard()`; Godot already delivers text as `InputEventKey.unicode`. |
| CJK IME / color emoji | High risk | ImGui has no preedit/composition; CJK atlases are heavy unless loaded dynamically (ImGui ≥ 1.92). Color emoji need FreeType with color loading. For serious multilingual chat: Godot's `LineEdit` for the input field, ImGui for the rest. |
| Wayland (as a client) | Already solved | The fork ships FRT/SDL2 with native EGL on Wayland. |
| Sugar-like shell (kiosk) | Viable | Fullscreen Godot under a kiosk compositor; activities as scenes in the same process. |
| Godot as a Wayland compositor | Research | Embed wlroots with surfaces as textures (prior art: gdwlroots, used by Simula). Owning DRM, the seat and Xwayland was deferred until after the kiosk. |
| XMPP | Viable | Native libstrophe as a module; pure GDScript over `StreamPeerSSL` only for a prototype. Background delivery needs platform code (Android foreground service, iOS push). |

Alternatives to ImGui that were evaluated: Nuklear/microui (same IME problems,
fewer widgets), RmlUi (HTML/CSS, heavier), Clay (layout only). ImGui won on
ecosystem; the text-input problem is the same for all of them.

## What happened next

- The ImGui module, ImPlot/ImPlot3D and Slug vector rendering landed in the
  engine fork; `bench/RESULTS.md` compares ImGui against Godot's own controls.
- Instead of a kiosk compositor, the shell runs fullscreen under sway and embeds
  its own wlroots compositor (`modules/wayland`), leaving DRM and seat ownership
  to sway.
- The Sugar shell grew the Group/Neighborhood model and cross-machine sharing.
  XMPP was not pursued in this repository.
