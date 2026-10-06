#ifndef REMOTE_INPUT_H
#define REMOTE_INPUT_H

#include "core/map.h"
#include "core/os/input_event.h"
#include "core/pool_vector.h"
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
	// Teclas/botones que un cliente dejó apretados: se liberan si se queda sin clientes
	// (si no, el estado XKB queda con Ctrl/Shift pegados para el próximo cliente).
	Map<uint32_t, uint8_t> pressed_keys;
	int last_clients;
	// Posición y botones propios: Input los actualiza recién al vaciar su buffer de eventos
	// (fin de vuelta), y varios eventos EIS llegan en la misma vuelta.
	Vector2 pointer, seen;
	int buttons;
	// Si true, el puntero entrante se inyecta al pipeline Godot aunque el compositor
	// exponga wlr_virtual_pointer. Lo pide el shell mientras hay una «Pantalla
	// compartida» activa: necesita ver el mouse para reenviarlo a la ventana.
	bool pointer_to_godot;

	static void _cb_motion(void *p_ud, double p_x, double p_y, int p_absolute);
	static void _cb_button(void *p_ud, uint32_t p_button, int p_pressed);
	static void _cb_scroll(void *p_ud, double p_dx, double p_dy, int p_discrete);
	static void _cb_key(void *p_ud, uint32_t p_key, int p_pressed);
	static void _cb_stop_emulating(void *p_ud);
	static void _cb_request(void *p_ud, int p_id, int p_pid, const char *p_app_id);

	void _set_mods(InputEventWithModifiers *p_event) const;
	Vector2 _pointer();
	void _wheel(int p_button, int p_steps);
	void _release_all();

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
	// 1 si el backend del portal InputCapture quedó registrado en el bus de la sesión.
	bool has_input_capture() const;
	bool is_capturing() const;
	bool release_capture();
	// Tramos porcentuales por borde donde InputCapture puede activarse, en el orden
	// [left_lo,left_hi, right_lo,right_hi, top_lo,top_hi, bottom_lo,bottom_hi].
	// Debe venir del layout de Deskflow (down(0,67) etc.); si no, NULL/[] = 0..100.
	bool set_capture_ranges(const PoolRealArray &p_ranges);
	// Puntero entrante al pipeline Godot (en vez del wlr_virtual_pointer del host):
	// necesario para que el shell pueda interceptarlo sobre una ventana compartida.
	void set_pointer_to_godot(bool p_enabled);
	// Eventos locales para el portal InputCapture. DEVICE_ID se filtra en GDScript.
	bool capture_motion(const Vector2 &p_pos, const Vector2 &p_relative, uint64_t p_time);
	bool capture_button(int p_button, bool p_pressed, uint64_t p_time);
	bool capture_scroll(double p_x, double p_y, uint64_t p_time);
	bool capture_key(uint32_t p_scancode, bool p_pressed, uint64_t p_time);

	RemoteInput();
	~RemoteInput();
};

#endif // REMOTE_INPUT_H
