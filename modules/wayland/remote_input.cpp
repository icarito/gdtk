#include "remote_input.h"

#include "eis_server.h"
#include "remote_pointer.h"

#include "core/class_db.h"
#include "core/os/input.h"
#include "core/os/keyboard.h"
#include "core/os/os.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xkbcommon/xkbcommon.h>

uint32_t _scancode_to_evdev(uint32_t p_scancode); // wayland_compositor.cpp

enum {
	EVDEV_KEY_RIGHTCTRL = 97,
	EVDEV_KEY_RIGHTSHIFT = 54,
	EVDEV_BTN_LEFT = 0x110,
	EVDEV_BTN_RIGHT = 0x111,
	EVDEV_BTN_MIDDLE = 0x112,
	EVDEV_BTN_SIDE = 0x113,
	EVDEV_BTN_EXTRA = 0x114,
};

// Unidades de scroll suave por muesca (el compositor manda 10 por muesca a las apps).
static const double SCROLL_STEP = 10.0;

void RemoteInput::_set_mods(InputEventWithModifiers *p_event) const {
	p_event->set_shift(xkb_state_mod_name_is_active(state, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) > 0);
	p_event->set_control(xkb_state_mod_name_is_active(state, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE) > 0);
	p_event->set_alt(xkb_state_mod_name_is_active(state, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE) > 0);
	p_event->set_metakey(xkb_state_mod_name_is_active(state, XKB_MOD_NAME_LOGO, XKB_STATE_MODS_EFFECTIVE) > 0);
}

// Si el mouse propio se movió desde la última vez, el puntero sigue desde ahí.
Vector2 RemoteInput::_pointer() {
	Vector2 cur = Input::get_singleton()->get_mouse_position();
	if (cur != seen) {
		pointer = cur;
		seen = cur;
	}
	return pointer;
}

void RemoteInput::_cb_motion(void *p_ud, double p_x, double p_y, int p_absolute) {
	RemoteInput *self = static_cast<RemoteInput *>(p_ud);
	Size2 size = OS::get_singleton()->get_window_size();
	if (remote_pointer_ready(self->host)) {
		// El host mueve su cursor nativo y entrega el evento al shell como local;
		// no se inyecta nada (y no hay cursor dibujado: es el mismo del host).
		Vector2 pos = self->_pointer();
		pos = p_absolute ? Vector2(p_x, p_y) : pos + Vector2(p_x, p_y);
		pos.x = CLAMP(pos.x, 0, size.x - 1);
		pos.y = CLAMP(pos.y, 0, size.y - 1);
		self->pointer = pos;
		self->seen = pos;
		remote_pointer_motion_abs(self->host, (int)pos.x, (int)pos.y, (int)size.x, (int)size.y);
		return;
	}
	Input *input = Input::get_singleton();
	Vector2 old = self->_pointer();
	Vector2 pos = p_absolute ? Vector2(p_x, p_y) : old + Vector2(p_x, p_y);
	pos.x = CLAMP(pos.x, 0, size.x - 1);
	pos.y = CLAMP(pos.y, 0, size.y - 1);
	self->pointer = pos;
	Ref<InputEventMouseMotion> ev;
	ev.instance();
	ev->set_device(DEVICE_ID);
	ev->set_position(pos);
	ev->set_global_position(pos);
	ev->set_relative(pos - old);
	ev->set_button_mask(self->buttons | input->get_mouse_button_mask());
	self->_set_mods(ev.ptr());
	input->parse_input_event(ev);
}

void RemoteInput::_cb_button(void *p_ud, uint32_t p_button, int p_pressed) {
	RemoteInput *self = static_cast<RemoteInput *>(p_ud);
	if (remote_pointer_ready(self->host)) {
		remote_pointer_button(self->host, p_button, p_pressed);
		return;
	}
	int index = 0;
	switch (p_button) {
		case EVDEV_BTN_LEFT: index = BUTTON_LEFT; break;
		case EVDEV_BTN_RIGHT: index = BUTTON_RIGHT; break;
		case EVDEV_BTN_MIDDLE: index = BUTTON_MIDDLE; break;
		case EVDEV_BTN_SIDE: index = BUTTON_XBUTTON1; break;
		case EVDEV_BTN_EXTRA: index = BUTTON_XBUTTON2; break;
		default: return;
	}
	Input *input = Input::get_singleton();
	Vector2 pos = self->_pointer();
	int bit = 1 << (index - 1);
	self->buttons = p_pressed ? (self->buttons | bit) : (self->buttons & ~bit);
	int mask = p_pressed ? (input->get_mouse_button_mask() | bit) : (input->get_mouse_button_mask() & ~bit);
	mask |= self->buttons;
	Ref<InputEventMouseButton> ev;
	ev.instance();
	ev->set_device(DEVICE_ID);
	ev->set_position(pos);
	ev->set_global_position(pos);
	ev->set_button_index(index);
	ev->set_pressed(p_pressed);
	ev->set_button_mask(mask);
	self->_set_mods(ev.ptr());
	input->parse_input_event(ev);
}

// La rueda en Godot son botones: press+release por muesca.
void RemoteInput::_wheel(int p_button, int p_steps) {
	Input *input = Input::get_singleton();
	Vector2 pos = _pointer();
	for (int i = 0; i < p_steps; i++) {
		for (int pressed = 1; pressed >= 0; pressed--) {
			Ref<InputEventMouseButton> ev;
			ev.instance();
			ev->set_device(DEVICE_ID);
			ev->set_position(pos);
			ev->set_global_position(pos);
			ev->set_button_index(p_button);
			ev->set_pressed(pressed);
			ev->set_button_mask(input->get_mouse_button_mask());
			_set_mods(ev.ptr());
			input->parse_input_event(ev);
		}
	}
}

void RemoteInput::_cb_scroll(void *p_ud, double p_dx, double p_dy, int p_discrete) {
	RemoteInput *self = static_cast<RemoteInput *>(p_ud);
	// Positivo = abajo/derecha (como libinput). Se acumula hasta completar muescas.
	double unit = p_discrete ? 120.0 : SCROLL_STEP;
	self->scroll_acc += Vector2(p_dx / unit, p_dy / unit);
	int sx = (int)self->scroll_acc.x;
	int sy = (int)self->scroll_acc.y;
	self->scroll_acc -= Vector2(sx, sy);
	if (remote_pointer_ready(self->host)) {
		if (sx != 0 || sy != 0) {
			remote_pointer_scroll(self->host, sx, sy);
		}
		return;
	}
	if (sy != 0) {
		self->_wheel(sy > 0 ? BUTTON_WHEEL_DOWN : BUTTON_WHEEL_UP, ABS(sy));
	}
	if (sx != 0) {
		self->_wheel(sx > 0 ? BUTTON_WHEEL_RIGHT : BUTTON_WHEEL_LEFT, ABS(sx));
	}
}

void RemoteInput::_cb_key(void *p_ud, uint32_t p_key, int p_pressed) {
	RemoteInput *self = static_cast<RemoteInput *>(p_ud);
	if (self->state == NULL) {
		return;
	}
	xkb_keycode_t kc = p_key + 8;
	xkb_keysym_t sym = xkb_state_key_get_one_sym(self->state, kc);
	uint32_t unicode = p_pressed ? xkb_state_key_get_utf32(self->state, kc) : 0;
	xkb_state_update_key(self->state, kc, p_pressed ? XKB_KEY_DOWN : XKB_KEY_UP);
	if (p_pressed) {
		self->pressed_keys[p_key] = 1;
	} else {
		self->pressed_keys.erase(p_key);
	}

	uint32_t physical = p_key < 256 ? self->evdev_to_godot[p_key] : 0;
	// scancode lógico: el carácter de la distribución (Godot usa Latin-1 en mayúscula);
	// si la tecla no escribe nada, la física.
	uint32_t scancode = physical;
	uint32_t cp = xkb_keysym_to_utf32(xkb_keysym_to_upper(sym));
	if (cp >= 0x20 && cp <= 0xff && cp != 0x7f) {
		scancode = cp;
	}
	Ref<InputEventKey> ev;
	ev.instance();
	ev->set_device(DEVICE_ID);
	ev->set_pressed(p_pressed);
	ev->set_scancode(scancode);
	ev->set_physical_scancode(physical);
	self->_set_mods(ev.ptr());
	if (unicode >= 0x20 && unicode != 0x7f && !ev->get_control()) {
		ev->set_unicode(unicode);
	}
	if (scancode == 0 && ev->get_unicode() == 0) {
		return;
	}
	Input::get_singleton()->parse_input_event(ev);
}

// Deskflow deja de emular al salir el cursor de esta pantalla: soltar todo lo que el
// cliente dejó apretado (si no, un Super apretado al cruzar quedaba pegado en Godot y
// cada clic local se volvía Super+arrastre hasta tocar Super de nuevo).
void RemoteInput::_cb_stop_emulating(void *p_ud) {
	RemoteInput *self = static_cast<RemoteInput *>(p_ud);
	self->_release_all();
}

void RemoteInput::_cb_request(void *p_ud, int p_id, int p_pid, const char *p_app_id) {
	RemoteInput *self = static_cast<RemoteInput *>(p_ud);
	self->emit_signal("access_requested", p_id, p_pid, String::utf8(p_app_id ? p_app_id : ""));
}


// Sin clientes EIS: se sueltan las teclas/botones que quedaron apretados y se limpia el
// estado XKB. Si no, un cliente que se cortó con Ctrl/Shift apretado deja el modificador
// pegado para el próximo cliente (todo llega con Ctrl).
void RemoteInput::_release_all() {
	if (state == NULL) {
		return;
	}
	Vector<uint32_t> keys;
	for (Map<uint32_t, uint8_t>::Element *e = pressed_keys.front(); e; e = e->next()) {
		keys.push_back(e->key());
	}
	pressed_keys.clear();
	for (int i = 0; i < keys.size(); i++) {
		_cb_key(this, keys[i], 0);
	}
	for (int b = 0; b < 5; b++) {
		if (buttons & (1 << b)) {
			_cb_button(this, EVDEV_BTN_LEFT + b, 0);
		}
	}
	buttons = 0;
	scroll_acc = Vector2();
	xkb_state_unref(state);
	state = xkb_state_new(keymap);
}

void RemoteInput::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start"), &RemoteInput::start);
	ClassDB::bind_method(D_METHOD("respond", "id", "allow"), &RemoteInput::respond);
	ClassDB::bind_method(D_METHOD("is_pending", "id"), &RemoteInput::is_pending);
	ClassDB::bind_method(D_METHOD("get_client_count"), &RemoteInput::get_client_count);
	ClassDB::bind_method(D_METHOD("has_input_capture"), &RemoteInput::has_input_capture);
	ClassDB::bind_method(D_METHOD("is_capturing"), &RemoteInput::is_capturing);
	ClassDB::bind_method(D_METHOD("set_capture_ranges", "ranges"), &RemoteInput::set_capture_ranges);
	ClassDB::bind_method(D_METHOD("capture_motion", "position", "relative", "time"), &RemoteInput::capture_motion);
	ClassDB::bind_method(D_METHOD("capture_button", "button", "pressed", "time"), &RemoteInput::capture_button);
	ClassDB::bind_method(D_METHOD("capture_scroll", "x", "y", "time"), &RemoteInput::capture_scroll);
	ClassDB::bind_method(D_METHOD("capture_key", "scancode", "pressed", "time"), &RemoteInput::capture_key);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "DEVICE_ID", DEVICE_ID);
	// Un cliente pide controlar el input (Start del portal): responder con respond(id, allow).
	ADD_SIGNAL(MethodInfo("access_requested", PropertyInfo(Variant::INT, "id"), PropertyInfo(Variant::INT, "pid"), PropertyInfo(Variant::STRING, "app_id")));
}

void RemoteInput::_notification(int p_what) {
	if (p_what == NOTIFICATION_PROCESS && server != NULL) {
		Size2 size = OS::get_singleton()->get_window_size();
		eis_server_set_size(server, (int)size.x, (int)size.y);
		eis_server_dispatch(server);
		int clients = eis_server_clients(server);
		if (last_clients > 0 && clients == 0) {
			_release_all();
		}
		last_clients = clients;
	}
}

// Keymap de la sesión (XKB_DEFAULT_*, ver session/keyboard.sh): se le da a los clientes
// y con él se traducen sus teclas. Devuelve "" o por qué no hay portal.
String RemoteInput::start() {
	if (server != NULL) {
		return String(eis_server_error(server));
	}
	for (int c = 0x20; c <= 0xff; c++) {
		uint32_t e = _scancode_to_evdev(c);
		if (e > 0 && e < 256 && evdev_to_godot[e] == 0) {
			evdev_to_godot[e] = c;
		}
	}
	for (int c = SPKEY; c <= SPKEY + 0xff; c++) {
		uint32_t e = _scancode_to_evdev(c);
		if (e > 0 && e < 256 && evdev_to_godot[e] == 0) {
			evdev_to_godot[e] = c;
		}
	}
	evdev_to_godot[EVDEV_KEY_RIGHTSHIFT] = KEY_SHIFT;
	evdev_to_godot[EVDEV_KEY_RIGHTCTRL] = KEY_CONTROL;

	xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	struct xkb_rule_names names = {};
	keymap = xkb ? xkb_keymap_new_from_names(xkb, &names, XKB_KEYMAP_COMPILE_NO_FLAGS) : NULL;
	state = keymap ? xkb_state_new(keymap) : NULL;
	char *text = keymap ? xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1) : NULL;

	eis_server_callbacks cb = {};
	cb.ud = this;
	cb.motion = &RemoteInput::_cb_motion;
	cb.button = &RemoteInput::_cb_button;
	cb.scroll = &RemoteInput::_cb_scroll;
	cb.key = &RemoteInput::_cb_key;
	cb.stop_emulating = &RemoteInput::_cb_stop_emulating;
	cb.request = &RemoteInput::_cb_request;
	Size2 size = OS::get_singleton()->get_window_size();
	// GDTK_EIS_SOCKET: socket EIS sin permiso, sólo para pruebas (LIBEI_SOCKET del cliente).
	CharString test = OS::get_singleton()->get_environment("GDTK_EIS_SOCKET").utf8();
	server = eis_server_create(cb, text, (int)size.x, (int)size.y, test.length() ? test.get_data() : NULL);
	free(text);
	// Si el host (sway, cage) expone wlr_virtual_pointer, el puntero va por ahí: se mueve
	// su cursor nativo y no se dibuja uno propio (ver remote_pointer.c).
	host = remote_pointer_create();
	if (remote_pointer_ready(host)) {
		fprintf(stderr, "RemoteInput: puntero por wlr_virtual_pointer (cursor del host)\n");
	}
	set_process(true);
	return String(eis_server_error(server));
}

void RemoteInput::respond(int p_id, bool p_allow) {
	if (server != NULL) {
		eis_server_respond(server, p_id, p_allow ? 1 : 0);
	}
}

bool RemoteInput::is_pending(int p_id) const {
	return server != NULL && eis_server_pending(server, p_id);
}

int RemoteInput::get_client_count() const {
	return server != NULL ? eis_server_clients(server) : 0;
}

bool RemoteInput::has_input_capture() const {
	return server != NULL && eis_server_has_input_capture(server);
}

bool RemoteInput::is_capturing() const {
	return eis_server_is_capturing(server);
}

bool RemoteInput::set_capture_ranges(const PoolRealArray &p_ranges) {
	if (server == NULL) {
		return false;
	}
	if (p_ranges.size() < 8) {
		eis_server_set_capture_ranges(server, NULL);
		return false;
	}
	PoolRealArray::Read r = p_ranges.read();
	double ranges[8];
	for (int i = 0; i < 8; i++) {
		ranges[i] = (double)r[i];
	}
	eis_server_set_capture_ranges(server, ranges);
	return true;
}

bool RemoteInput::capture_motion(const Vector2 &p_pos, const Vector2 &p_relative, uint64_t p_time) {
	return server != NULL && eis_server_capture_motion(server, p_pos.x, p_pos.y, p_relative.x, p_relative.y, p_time);
}

bool RemoteInput::capture_button(int p_button, bool p_pressed, uint64_t p_time) {
	uint32_t evdev = 0;
	switch (p_button) {
		case BUTTON_LEFT: evdev = EVDEV_BTN_LEFT; break;
		case BUTTON_RIGHT: evdev = EVDEV_BTN_RIGHT; break;
		case BUTTON_MIDDLE: evdev = EVDEV_BTN_MIDDLE; break;
		case BUTTON_XBUTTON1: evdev = EVDEV_BTN_SIDE; break;
		case BUTTON_XBUTTON2: evdev = EVDEV_BTN_EXTRA; break;
		default: return false;
	}
	return server != NULL && eis_server_capture_button(server, evdev, p_pressed, p_time);
}

bool RemoteInput::capture_scroll(double p_x, double p_y, uint64_t p_time) {
	return server != NULL && eis_server_capture_scroll(server, p_x, p_y, p_time);
}

bool RemoteInput::capture_key(uint32_t p_scancode, bool p_pressed, uint64_t p_time) {
	uint32_t evdev = _scancode_to_evdev(p_scancode);
	return evdev != 0 && server != NULL && eis_server_capture_key(server, evdev, p_pressed, p_time);
}

RemoteInput::RemoteInput() {
	server = NULL;
	host = NULL;
	xkb = NULL;
	keymap = NULL;
	state = NULL;
	buttons = 0;
	memset(evdev_to_godot, 0, sizeof(evdev_to_godot));
}

RemoteInput::~RemoteInput() {
	if (server != NULL) {
		eis_server_destroy(server);
	}
	if (host != NULL) {
		remote_pointer_destroy(host);
	}
	if (state != NULL) {
		xkb_state_unref(state);
	}
	if (keymap != NULL) {
		xkb_keymap_unref(keymap);
	}
	if (xkb != NULL) {
		xkb_context_unref(xkb);
	}
}
