#ifndef REMOTE_INPUT_H
#define REMOTE_INPUT_H

#include "core/os/input_event.h"
#include "scene/main/node.h"

struct eis_server;
struct remote_pointer;
struct xkb_context;
struct xkb_keymap;
struct xkb_state;

// Input remoto por libei (Deskflow, lan-mouse): los eventos del servidor EIS entran
// al shell como input local (Input::parse_input_event, device = DEVICE_ID), así llegan
// al Frame, a ImGui y a las apps embebidas por el camino de siempre.
class RemoteInput : public Node {
	GDCLASS(RemoteInput, Node);

	eis_server *server;
	remote_pointer *host; // cursor nativo del compositor anfitrión (si lo expone)
	xkb_context *xkb;
	xkb_keymap *keymap;
	xkb_state *state;
	uint32_t evdev_to_godot[256];
	Vector2 scroll_acc;
	// Posición y botones propios: Input los actualiza recién al vaciar su buffer de eventos
	// (fin de vuelta), y varios eventos EIS llegan en la misma vuelta.
	Vector2 pointer, seen;
	int buttons;

	static void _cb_motion(void *p_ud, double p_x, double p_y, int p_absolute);
	static void _cb_button(void *p_ud, uint32_t p_button, int p_pressed);
	static void _cb_scroll(void *p_ud, double p_dx, double p_dy, int p_discrete);
	static void _cb_key(void *p_ud, uint32_t p_key, int p_pressed);
	static void _cb_request(void *p_ud, int p_id, int p_pid, const char *p_app_id);

	void _set_mods(InputEventWithModifiers *p_event) const;
	Vector2 _pointer();
	void _wheel(int p_button, int p_steps);

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	enum {
		DEVICE_ID = 69, // 'E': distingue lo inyectado por EIS del mouse/teclado propios
	};

	String start();
	void respond(int p_id, bool p_allow);
	bool is_pending(int p_id) const;
	int get_client_count() const;

	RemoteInput();
	~RemoteInput();
};

#endif // REMOTE_INPUT_H
