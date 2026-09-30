#include "wayland_compositor.h"

#include "wl_server.h"

#include "core/class_db.h"
#include "core/image.h"
#include "core/list.h"
#include "core/map.h"
#include "core/math/rect2.h"
#include "core/os/keyboard.h"
#include "core/os/os.h"
#include "servers/visual_server.h"

#include <drm_fourcc.h>
#include <string.h>
#include <sys/wait.h>

// Codigos evdev (linux/input-event-codes.h) sin incluir ese header: choca con los
// KEY_* de core/os/keyboard.h.
enum {
	EVDEV_KEY_ESC = 1,
	EVDEV_KEY_1 = 2,
	EVDEV_KEY_2 = 3,
	EVDEV_KEY_3 = 4,
	EVDEV_KEY_4 = 5,
	EVDEV_KEY_5 = 6,
	EVDEV_KEY_6 = 7,
	EVDEV_KEY_7 = 8,
	EVDEV_KEY_8 = 9,
	EVDEV_KEY_9 = 10,
	EVDEV_KEY_0 = 11,
	EVDEV_KEY_MINUS = 12,
	EVDEV_KEY_EQUAL = 13,
	EVDEV_KEY_BACKSPACE = 14,
	EVDEV_KEY_TAB = 15,
	EVDEV_KEY_LEFTBRACE = 26,
	EVDEV_KEY_RIGHTBRACE = 27,
	EVDEV_KEY_ENTER = 28,
	EVDEV_KEY_LEFTCTRL = 29,
	EVDEV_KEY_A = 30,
	EVDEV_KEY_S = 31,
	EVDEV_KEY_D = 32,
	EVDEV_KEY_F = 33,
	EVDEV_KEY_G = 34,
	EVDEV_KEY_H = 35,
	EVDEV_KEY_J = 36,
	EVDEV_KEY_K = 37,
	EVDEV_KEY_L = 38,
	EVDEV_KEY_Z = 44,
	EVDEV_KEY_X = 45,
	EVDEV_KEY_C = 46,
	EVDEV_KEY_V = 47,
	EVDEV_KEY_B = 48,
	EVDEV_KEY_N = 49,
	EVDEV_KEY_M = 50,
	EVDEV_KEY_Q = 16,
	EVDEV_KEY_W = 17,
	EVDEV_KEY_E = 18,
	EVDEV_KEY_R = 19,
	EVDEV_KEY_T = 20,
	EVDEV_KEY_Y = 21,
	EVDEV_KEY_U = 22,
	EVDEV_KEY_I = 23,
	EVDEV_KEY_O = 24,
	EVDEV_KEY_P = 25,
	EVDEV_KEY_SEMICOLON = 39,
	EVDEV_KEY_APOSTROPHE = 40,
	EVDEV_KEY_GRAVE = 41,
	EVDEV_KEY_BACKSLASH = 43,
	EVDEV_KEY_COMMA = 51,
	EVDEV_KEY_DOT = 52,
	EVDEV_KEY_SLASH = 53,
	EVDEV_KEY_LEFTSHIFT = 42,
	EVDEV_KEY_RIGHTSHIFT = 54,
	EVDEV_KEY_LEFTALT = 56,
	EVDEV_KEY_RIGHTCTRL = 97,
	EVDEV_KEY_SPACE = 57,
	EVDEV_KEY_CAPSLOCK = 58,
	EVDEV_KEY_F1 = 59,
	EVDEV_KEY_F2 = 60,
	EVDEV_KEY_F3 = 61,
	EVDEV_KEY_F4 = 62,
	EVDEV_KEY_F5 = 63,
	EVDEV_KEY_F6 = 64,
	EVDEV_KEY_F7 = 65,
	EVDEV_KEY_F8 = 66,
	EVDEV_KEY_F9 = 67,
	EVDEV_KEY_F10 = 68,
	EVDEV_KEY_F11 = 87,
	EVDEV_KEY_F12 = 88,
	EVDEV_KEY_NUMLOCK = 69,
	EVDEV_KEY_SCROLLLOCK = 70,
	EVDEV_KEY_KP7 = 71,
	EVDEV_KEY_KP8 = 72,
	EVDEV_KEY_KP9 = 73,
	EVDEV_KEY_KPSUBTRACT = 74,
	EVDEV_KEY_KP4 = 75,
	EVDEV_KEY_KP5 = 76,
	EVDEV_KEY_KP6 = 77,
	EVDEV_KEY_KPADD = 78,
	EVDEV_KEY_KP1 = 79,
	EVDEV_KEY_KP2 = 80,
	EVDEV_KEY_KP3 = 81,
	EVDEV_KEY_KP0 = 82,
	EVDEV_KEY_KPPERIOD = 83,
	EVDEV_KEY_102ND = 86,
	EVDEV_KEY_KPENTER = 96,
	EVDEV_KEY_KPDIVIDE = 98,
	EVDEV_KEY_SYSRQ = 99,
	EVDEV_KEY_RIGHTALT = 100,
	EVDEV_KEY_HOME = 102,
	EVDEV_KEY_UP = 103,
	EVDEV_KEY_PAGEUP = 104,
	EVDEV_KEY_LEFT = 105,
	EVDEV_KEY_RIGHT = 106,
	EVDEV_KEY_END = 107,
	EVDEV_KEY_DOWN = 108,
	EVDEV_KEY_PAGEDOWN = 109,
	EVDEV_KEY_INSERT = 110,
	EVDEV_KEY_DELETE = 111,
	EVDEV_KEY_KPASTERISK = 55,
	EVDEV_KEY_PAUSE = 119,
	EVDEV_KEY_LEFTMETA = 125,
	EVDEV_KEY_RIGHTMETA = 126,
	EVDEV_KEY_COMPOSE = 127,
	EVDEV_BTN_LEFT = 0x110,
	EVDEV_BTN_RIGHT = 0x111,
	EVDEV_BTN_MIDDLE = 0x112,
	EVDEV_BTN_SIDE = 0x113,
	EVDEV_BTN_EXTRA = 0x114,
};

// Los codigos evdev de las letras siguen el orden fisico QWERTY, no el alfabetico.
static uint32_t _letter_to_evdev(uint32_t p_scancode) {
	switch (p_scancode) {
		case KEY_Q: return EVDEV_KEY_Q;
		case KEY_W: return EVDEV_KEY_W;
		case KEY_E: return EVDEV_KEY_E;
		case KEY_R: return EVDEV_KEY_R;
		case KEY_T: return EVDEV_KEY_T;
		case KEY_Y: return EVDEV_KEY_Y;
		case KEY_U: return EVDEV_KEY_U;
		case KEY_I: return EVDEV_KEY_I;
		case KEY_O: return EVDEV_KEY_O;
		case KEY_P: return EVDEV_KEY_P;
		case KEY_A: return EVDEV_KEY_A;
		case KEY_S: return EVDEV_KEY_S;
		case KEY_D: return EVDEV_KEY_D;
		case KEY_F: return EVDEV_KEY_F;
		case KEY_G: return EVDEV_KEY_G;
		case KEY_H: return EVDEV_KEY_H;
		case KEY_J: return EVDEV_KEY_J;
		case KEY_K: return EVDEV_KEY_K;
		case KEY_L: return EVDEV_KEY_L;
		case KEY_Z: return EVDEV_KEY_Z;
		case KEY_X: return EVDEV_KEY_X;
		case KEY_C: return EVDEV_KEY_C;
		case KEY_V: return EVDEV_KEY_V;
		case KEY_B: return EVDEV_KEY_B;
		case KEY_N: return EVDEV_KEY_N;
		case KEY_M: return EVDEV_KEY_M;
		default: return 0;
	}
}

// Traduce el physical_scancode de Godot (posicion fisica de la tecla, mapa US)
// a evdev. Convencion acordada con FRT para teclas sin constante propia en
// Godot 3 (ver map_key_sdl2_scancode en platform/frt/sdl2_godot_map.h):
//   KEY_HYPER_R = RALT (AltGr)        -> KEY_RIGHTALT
//   KEY_HYPER_L = NONUSBACKSLASH (<> ISO) -> KEY_102ND
uint32_t _scancode_to_evdev(uint32_t p_scancode) { // también la usa remote_input.cpp
	if (p_scancode == 0) {
		return 0;
	}
	uint32_t letter = _letter_to_evdev(p_scancode);
	if (letter != 0) {
		return letter;
	}
	if (p_scancode >= KEY_1 && p_scancode <= KEY_9) {
		return EVDEV_KEY_1 + (p_scancode - KEY_1);
	}
	if (p_scancode == KEY_0) {
		return EVDEV_KEY_0;
	}
	switch (p_scancode) {
		case KEY_SPACE:
			return EVDEV_KEY_SPACE;
		case KEY_ENTER:
			return EVDEV_KEY_ENTER;
		case KEY_KP_ENTER:
			return EVDEV_KEY_KPENTER;
		case KEY_BACKSPACE:
			return EVDEV_KEY_BACKSPACE;
		case KEY_TAB:
			return EVDEV_KEY_TAB;
		case KEY_ESCAPE:
			return EVDEV_KEY_ESC;
		case KEY_LEFT:
			return EVDEV_KEY_LEFT;
		case KEY_RIGHT:
			return EVDEV_KEY_RIGHT;
		case KEY_UP:
			return EVDEV_KEY_UP;
		case KEY_DOWN:
			return EVDEV_KEY_DOWN;
		case KEY_HOME:
			return EVDEV_KEY_HOME;
		case KEY_END:
			return EVDEV_KEY_END;
		case KEY_INSERT:
			return EVDEV_KEY_INSERT;
		case KEY_DELETE:
			return EVDEV_KEY_DELETE;
		case KEY_PAGEUP:
			return EVDEV_KEY_PAGEUP;
		case KEY_PAGEDOWN:
			return EVDEV_KEY_PAGEDOWN;
		case KEY_SHIFT:
			return EVDEV_KEY_LEFTSHIFT;
		case KEY_CONTROL:
			return EVDEV_KEY_LEFTCTRL;
		case KEY_ALT:
			return EVDEV_KEY_LEFTALT;
		case KEY_CAPSLOCK:
			return EVDEV_KEY_CAPSLOCK;
		case KEY_NUMLOCK:
			return EVDEV_KEY_NUMLOCK;
		case KEY_SCROLLLOCK:
			return EVDEV_KEY_SCROLLLOCK;
		case KEY_PRINT:
			return EVDEV_KEY_SYSRQ;
		case KEY_PAUSE:
			return EVDEV_KEY_PAUSE;
		case KEY_F1:
			return EVDEV_KEY_F1;
		case KEY_F2:
			return EVDEV_KEY_F2;
		case KEY_F3:
			return EVDEV_KEY_F3;
		case KEY_F4:
			return EVDEV_KEY_F4;
		case KEY_F5:
			return EVDEV_KEY_F5;
		case KEY_F6:
			return EVDEV_KEY_F6;
		case KEY_F7:
			return EVDEV_KEY_F7;
		case KEY_F8:
			return EVDEV_KEY_F8;
		case KEY_F9:
			return EVDEV_KEY_F9;
		case KEY_F10:
			return EVDEV_KEY_F10;
		case KEY_F11:
			return EVDEV_KEY_F11;
		case KEY_F12:
			return EVDEV_KEY_F12;
		case KEY_MINUS:
			return EVDEV_KEY_MINUS;
		case KEY_EQUAL:
			return EVDEV_KEY_EQUAL;
		case KEY_BRACKETLEFT:
			return EVDEV_KEY_LEFTBRACE;
		case KEY_BRACKETRIGHT:
			return EVDEV_KEY_RIGHTBRACE;
		case KEY_QUOTELEFT:
			return EVDEV_KEY_GRAVE;
		case KEY_SEMICOLON:
			return EVDEV_KEY_SEMICOLON;
		case KEY_APOSTROPHE:
			return EVDEV_KEY_APOSTROPHE;
		case KEY_COMMA:
			return EVDEV_KEY_COMMA;
		case KEY_PERIOD:
			return EVDEV_KEY_DOT;
		case KEY_SLASH:
			return EVDEV_KEY_SLASH;
		case KEY_BACKSLASH:
			return EVDEV_KEY_BACKSLASH;
		case KEY_KP_0:
			return EVDEV_KEY_KP0;
		case KEY_KP_1:
			return EVDEV_KEY_KP1;
		case KEY_KP_2:
			return EVDEV_KEY_KP2;
		case KEY_KP_3:
			return EVDEV_KEY_KP3;
		case KEY_KP_4:
			return EVDEV_KEY_KP4;
		case KEY_KP_5:
			return EVDEV_KEY_KP5;
		case KEY_KP_6:
			return EVDEV_KEY_KP6;
		case KEY_KP_7:
			return EVDEV_KEY_KP7;
		case KEY_KP_8:
			return EVDEV_KEY_KP8;
		case KEY_KP_9:
			return EVDEV_KEY_KP9;
		case KEY_KP_PERIOD:
			return EVDEV_KEY_KPPERIOD;
		case KEY_KP_DIVIDE:
			return EVDEV_KEY_KPDIVIDE;
		case KEY_KP_MULTIPLY:
			return EVDEV_KEY_KPASTERISK;
		case KEY_KP_SUBTRACT:
			return EVDEV_KEY_KPSUBTRACT;
		case KEY_KP_ADD:
			return EVDEV_KEY_KPADD;
		case KEY_SUPER_L:
			return EVDEV_KEY_LEFTMETA;
		case KEY_SUPER_R:
			return EVDEV_KEY_RIGHTMETA;
		case KEY_MENU:
			return EVDEV_KEY_COMPOSE;
		case KEY_HYPER_R:
			return EVDEV_KEY_RIGHTALT;
		case KEY_HYPER_L:
			return EVDEV_KEY_102ND;
		default:
			return 0;
	}
}

void WaylandCompositor::_cb_added(void *p_ud, int p_id) {
	static_cast<WaylandCompositor *>(p_ud)->_on_added(p_id);
}

void WaylandCompositor::_cb_removed(void *p_ud, int p_id) {
	static_cast<WaylandCompositor *>(p_ud)->_on_removed(p_id);
}

void WaylandCompositor::_cb_frame(void *p_ud, int p_id, uint64_t p_key, const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride) {
	static_cast<WaylandCompositor *>(p_ud)->_on_frame(p_id, p_key, p_data, p_w, p_h, p_format, p_stride);
}

void WaylandCompositor::_cb_dmabuf(void *p_ud, int p_id, uint64_t p_key, int p_w, int p_h) {
	static_cast<WaylandCompositor *>(p_ud)->_on_dmabuf(p_id, p_key, p_w, p_h);
}

void WaylandCompositor::_cb_title(void *p_ud, int p_id, const char *p_title) {
	static_cast<WaylandCompositor *>(p_ud)->_on_title(p_id, p_title);
}

void WaylandCompositor::_cb_layer(void *p_ud, int p_id, int p_state) {
	WaylandCompositor *self = static_cast<WaylandCompositor *>(p_ud);
	if (p_state < 0) {
		self->layer_ids.erase(p_id);
		self->toplevels.erase(p_id);
	} else {
		self->layer_ids.insert(p_id);
	}
	self->emit_signal("layers_changed");
}

void WaylandCompositor::_cb_damage(void *p_ud, int p_id) {
	static_cast<WaylandCompositor *>(p_ud)->_count_commit(p_id);
}

void WaylandCompositor::_cb_activate(void *p_ud, int p_id) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("toplevel_activate", p_id);
}

void WaylandCompositor::_cb_minimize(void *p_ud, int p_id) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("toplevel_minimize", p_id);
}

// Con end_frame en uso, sólo los commits de lo que se dibujó (o de ventanas nuevas que
// todavía no se dibujaron) piden redibujar: una app de fondo que anima no despierta al shell.
void WaylandCompositor::_count_commit(int p_id) {
	if (!throttle || drawn.has(p_id) || !toplevels.has(p_id)) {
		commit_count++;
	}
}

void WaylandCompositor::_on_added(int p_id) {
	Toplevel t;
	toplevels.insert(p_id, t);
	emit_signal("toplevel_added", p_id);
}

void WaylandCompositor::_on_removed(int p_id) {
	toplevels.erase(p_id);
	emit_signal("toplevel_removed", p_id);
}

Map<int, WaylandCompositor::Toplevel>::Element *WaylandCompositor::_toplevel_entry(int p_id) {
	Map<int, Toplevel>::Element *e = toplevels.find(p_id);
	if (e == NULL) {
		Toplevel t;
		e = toplevels.insert(p_id, t);
	}
	return e;
}

void WaylandCompositor::_on_frame(int p_id, uint64_t p_key, const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride) {
	_count_commit(p_id);
	shm_commits++;
	if (p_data == NULL || p_w <= 0 || p_h <= 0 || p_stride < p_w * 4) {
		return;
	}

	// wl_shm ARGB8888/XRGB8888 (little-endian: bytes B,G,R,A) a Image::FORMAT_RGBA8.
	bool swap_rb = p_format == DRM_FORMAT_ARGB8888 || p_format == DRM_FORMAT_XRGB8888;
	bool has_alpha = p_format == DRM_FORMAT_ARGB8888 || p_format == DRM_FORMAT_ABGR8888;

	int size = p_w * p_h * 4;
	PoolVector<uint8_t> data;
	data.resize(size);
	{
		PoolVector<uint8_t>::Write w = data.write();
		uint8_t *dst = w.ptr();
		for (int y = 0; y < p_h; y++) {
			const unsigned char *src = p_data + (size_t)y * (size_t)p_stride;
			uint8_t *d = dst + (size_t)y * (size_t)p_w * 4;
			for (int x = 0; x < p_w; x++) {
				uint8_t c0 = src[0];
				uint8_t c1 = src[1];
				uint8_t c2 = src[2];
				uint8_t c3 = src[3];
				if (swap_rb) {
					d[0] = c2;
					d[1] = c1;
					d[2] = c0;
				} else {
					d[0] = c0;
					d[1] = c1;
					d[2] = c2;
				}
				d[3] = has_alpha ? c3 : 255;
				src += 4;
				d += 4;
			}
		}
	}
	Ref<Image> img = memnew(Image(p_w, p_h, false, Image::FORMAT_RGBA8, data));

	Map<int, Toplevel>::Element *e = _toplevel_entry(p_id);
	Variant vkey((int64_t)p_key);
	Ref<ImageTexture> tex = e->get().textures[vkey];
	if (tex.is_null() || tex->get_width() != p_w || tex->get_height() != p_h) {
		tex.instance();
		tex->create_from_image(img, 0);
		e->get().textures[vkey] = tex;
	} else {
		tex->set_data(img);
	}
}

void WaylandCompositor::_on_dmabuf(int p_id, uint64_t p_key, int p_w, int p_h) {
	_count_commit(p_id);
	dmabuf_commits++;
	if (p_w <= 0 || p_h <= 0 || server == NULL) {
		return;
	}

	Map<int, Toplevel>::Element *e = _toplevel_entry(p_id);
	Variant vkey((int64_t)p_key);
	Ref<ImageTexture> tex = e->get().textures[vkey];
	if (tex.is_null() || tex->get_width() != p_w || tex->get_height() != p_h) {
		tex.instance();
		tex->create(p_w, p_h, Image::FORMAT_RGBA8, 0);
		e->get().textures[vkey] = tex;
	}
	wl_server_bind_dmabuf(server, p_key,
			(unsigned int)VS::get_singleton()->texture_get_texid(tex->get_rid()));
}

void WaylandCompositor::_on_title(int p_id, const char *p_title) {
	Map<int, Toplevel>::Element *e = toplevels.find(p_id);
	if (e == NULL) {
		Toplevel t;
		e = toplevels.insert(p_id, t);
	}
	e->get().title = String::utf8(p_title != NULL ? p_title : "");
}

void WaylandCompositor::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start"), &WaylandCompositor::start);
	ClassDB::bind_method(D_METHOD("launch", "cmd", "args"), &WaylandCompositor::launch, DEFVAL(PoolStringArray()));
	ClassDB::bind_method(D_METHOD("get_texture", "id"), &WaylandCompositor::get_texture);
	ClassDB::bind_method(D_METHOD("get_layers", "id"), &WaylandCompositor::get_layers);
	ClassDB::bind_method(D_METHOD("get_geometry", "id"), &WaylandCompositor::get_geometry);
	ClassDB::bind_method(D_METHOD("get_title", "id"), &WaylandCompositor::get_title);
	ClassDB::bind_method(D_METHOD("get_parent_id", "id"), &WaylandCompositor::get_parent_id);
	ClassDB::bind_method(D_METHOD("get_app_id", "id"), &WaylandCompositor::get_app_id);
	ClassDB::bind_method(D_METHOD("get_ids"), &WaylandCompositor::get_ids);
	ClassDB::bind_method(D_METHOD("get_layer_surfaces"), &WaylandCompositor::get_layer_surfaces);
	ClassDB::bind_method(D_METHOD("end_frame"), &WaylandCompositor::end_frame);
	ClassDB::bind_method(D_METHOD("set_size", "id", "size"), &WaylandCompositor::set_size);
	ClassDB::bind_method(D_METHOD("close", "id"), &WaylandCompositor::close);
	ClassDB::bind_method(D_METHOD("focus", "id"), &WaylandCompositor::focus);
	ClassDB::bind_method(D_METHOD("pointer_motion", "id", "pos"), &WaylandCompositor::pointer_motion);
	ClassDB::bind_method(D_METHOD("pointer_button", "button_index", "pressed"), &WaylandCompositor::pointer_button);
	ClassDB::bind_method(D_METHOD("pointer_axis", "dy"), &WaylandCompositor::pointer_axis);
	ClassDB::bind_method(D_METHOD("key", "event"), &WaylandCompositor::key);

	ClassDB::bind_method(D_METHOD("set_default_size", "size"), &WaylandCompositor::set_default_size);
	ClassDB::bind_method(D_METHOD("get_default_size"), &WaylandCompositor::get_default_size);
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "default_size"), "set_default_size", "get_default_size");

	ClassDB::bind_method(D_METHOD("get_commit_count"), &WaylandCompositor::get_commit_count);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "commit_count"), "", "get_commit_count");

	ClassDB::bind_method(D_METHOD("get_dmabuf_commits"), &WaylandCompositor::get_dmabuf_commits);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "dmabuf_commits"), "", "get_dmabuf_commits");

	ClassDB::bind_method(D_METHOD("get_shm_commits"), &WaylandCompositor::get_shm_commits);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "shm_commits"), "", "get_shm_commits");

	ClassDB::bind_method(D_METHOD("get_dmabuf_state"), &WaylandCompositor::get_dmabuf_state);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "dmabuf_state"), "", "get_dmabuf_state");

	ADD_SIGNAL(MethodInfo("toplevel_added", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("toplevel_removed", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("toplevel_activate", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("toplevel_minimize", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("layers_changed"));
	ADD_SIGNAL(MethodInfo("process_exited", PropertyInfo(Variant::INT, "pid"), PropertyInfo(Variant::INT, "code")));
}

void WaylandCompositor::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_PROCESS: {
			if (server != NULL) {
				wl_server_dispatch(server);
				wl_server_frame_done(server);
			}
			_reap_children();
		} break;
		default:
			break;
	}
}

WaylandCompositor::WaylandCompositor() {
	server = NULL;
	default_size = Vector2(1024, 700);
	commit_count = 0;
	dmabuf_commits = 0;
	shm_commits = 0;
	throttle = false;
}

// Recoge los hijos lanzados que terminaron (si no, quedan zombies) y avisa con su código.
void WaylandCompositor::_reap_children() {
	for (int i = children.size() - 1; i >= 0; i--) {
		int status = 0;
		pid_t r = waitpid((pid_t)children[i], &status, WNOHANG);
		if (r == 0) {
			continue;
		}
		int pid = children[i];
		children.remove(i);
		if (r > 0) {
			int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
			emit_signal("process_exited", pid, code);
		}
	}
}

WaylandCompositor::~WaylandCompositor() {
	if (server != NULL) {
		wl_server_destroy(server);
		server = NULL;
	}
}

String WaylandCompositor::start() {
	if (server != NULL) {
		return String(wl_server_socket(server));
	}
	wl_server_callbacks cb;
	memset(&cb, 0, sizeof(cb));
	cb.ud = this;
	cb.added = &WaylandCompositor::_cb_added;
	cb.removed = &WaylandCompositor::_cb_removed;
	cb.frame = &WaylandCompositor::_cb_frame;
	cb.dmabuf = &WaylandCompositor::_cb_dmabuf;
	cb.title = &WaylandCompositor::_cb_title;
	cb.layer = &WaylandCompositor::_cb_layer;
	cb.activate = &WaylandCompositor::_cb_activate;
	cb.minimize = &WaylandCompositor::_cb_minimize;
	cb.damage = &WaylandCompositor::_cb_damage;

	server = wl_server_create(cb, (int)default_size.x, (int)default_size.y);
	if (server == NULL) {
		ERR_PRINT("WaylandCompositor: no se pudo crear el servidor wayland");
		return String();
	}
	set_process(true);
	String socket = String(wl_server_socket(server));
	// Como sesión (DesktopNames=gdtk): lo que active D-Bus/systemd (notificaciones,
	// apps DBusActivatable) tiene que conectarse a este compositor y no a otro display.
	if (OS::get_singleton()->get_environment("XDG_CURRENT_DESKTOP").to_lower().split(":").find("gdtk") >= 0) {
		List<String> args;
		args.push_back("--systemd");
		args.push_back("WAYLAND_DISPLAY=" + socket);
		OS::get_singleton()->execute("dbus-update-activation-environment", args, true);
	}
	return socket;
}

int WaylandCompositor::launch(const String &p_cmd, const PoolStringArray &p_args) {
	if (server == NULL || p_cmd.empty()) {
		return -1;
	}
	List<String> args;
	// Las apps sólo X11 van al Xwayland embebido; las demás siguen en Wayland.
	String xdisplay = String(wl_server_xdisplay(server));
	if (xdisplay.empty()) {
		args.push_back("-u");
		args.push_back("DISPLAY");
	} else {
		args.push_back("DISPLAY=" + xdisplay);
	}
	args.push_back("WAYLAND_DISPLAY=" + String(wl_server_socket(server)));
	args.push_back("GDK_BACKEND=wayland");
	// Chromium/Electron (ozone auto) y Qt5 eligen X11 si la sesión dice x11 (sesión X de
	// tengu), y sin DISPLAY no abren.
	args.push_back("XDG_SESSION_TYPE=wayland");
	// Con dmabuf disponible los clientes usan la GPU de verdad; si el server
	// quedo en modo solo-shm, forzamos el fallback software como antes.
	if (!wl_server_dmabuf_enabled(server)) {
		args.push_back("GSK_RENDERER=cairo");
		args.push_back("LIBGL_ALWAYS_SOFTWARE=1");
	}
	args.push_back("SDL_VIDEODRIVER=wayland");
	args.push_back(p_cmd);
	for (int i = 0; i < p_args.size(); i++) {
		args.push_back(p_args[i]);
	}
	OS::ProcessID pid = 0;
	Error err = OS::get_singleton()->execute("env", args, false, &pid);
	if (err != OK) {
		ERR_PRINT("WaylandCompositor: fallo al lanzar " + p_cmd);
		return -1;
	}
	children.push_back((int)pid);
	return (int)pid;
}

Ref<Texture> WaylandCompositor::get_texture(int p_id) const {
	const Map<int, Toplevel>::Element *e = toplevels.find(p_id);
	if (e == NULL || e->get().root_key == 0) {
		return Ref<Texture>();
	}
	Variant vkey((int64_t)e->get().root_key);
	if (!e->get().textures.has(vkey)) {
		return Ref<Texture>();
	}
	return e->get().textures[vkey];
}

Array WaylandCompositor::get_layers(int p_id) {
	Array layers;
	Map<int, Toplevel>::Element *e = toplevels.find(p_id);
	if (e == NULL || server == NULL) {
		return layers;
	}

	const int MAX_LAYERS = 64;
	wl_server_layer raw[MAX_LAYERS];
	int count = wl_server_layers(server, p_id, raw, MAX_LAYERS);

	drawn_collect.insert(p_id);
	Dictionary present;
	for (int i = 0; i < count; i++) {
		Variant vkey((int64_t)raw[i].key);
		present[vkey] = true;
		Dictionary layer;
		layer["key"] = (int64_t)raw[i].key;
		layer["texture"] = e->get().textures[vkey];
		layer["rect"] = Rect2((float)raw[i].x, (float)raw[i].y, (float)raw[i].w, (float)raw[i].h);
		layers.push_back(layer);
	}

	// La primera capa es la raiz (for_each_surface va raiz -> hojas).
	if (count > 0) {
		e->get().root_key = raw[0].key;
	}

	// Liberar texturas de surfaces que ya no estan en el arbol (popup cerrado,
	// subsurface destruida, etc.).
	Array keys = e->get().textures.keys();
	for (int i = 0; i < keys.size(); i++) {
		if (!present.has(keys[i])) {
			e->get().textures.erase(keys[i]);
		}
	}
	return layers;
}

Rect2 WaylandCompositor::get_geometry(int p_id) const {
	int x = 0, y = 0, w = 0, h = 0;
	if (server == NULL || !wl_server_geometry(server, p_id, &x, &y, &w, &h)) {
		return Rect2();
	}
	return Rect2(x, y, w, h);
}

String WaylandCompositor::get_title(int p_id) const {
	const Map<int, Toplevel>::Element *e = toplevels.find(p_id);
	if (e == NULL) {
		return String();
	}
	return e->get().title;
}

int WaylandCompositor::get_parent_id(int p_id) const {
	if (server == NULL) {
		return 0;
	}
	return wl_server_parent(server, p_id);
}

String WaylandCompositor::get_app_id(int p_id) const {
	if (server == NULL) {
		return String();
	}
	return String::utf8(wl_server_app_id(server, p_id));
}

Array WaylandCompositor::get_ids() const {
	Array ids;
	for (const Map<int, Toplevel>::Element *e = toplevels.front(); e != NULL; e = e->next()) {
		if (!layer_ids.has(e->key())) {
			ids.push_back(e->key());
		}
	}
	return ids;
}

// Layer surfaces mapeadas (notificaciones...), de la capa más baja a la más alta:
// [{id, layer (0 background..3 overlay), rect (coords de la vista)}].
Array WaylandCompositor::get_layer_surfaces() {
	Array out;
	if (server == NULL) {
		return out;
	}
	const int MAX = 32;
	wl_server_layer_surface raw[MAX];
	int n = wl_server_layer_surfaces(server, raw, MAX);
	for (int i = 0; i < n; i++) {
		Dictionary d;
		d["id"] = raw[i].id;
		d["layer"] = raw[i].layer;
		d["rect"] = Rect2(raw[i].x, raw[i].y, raw[i].w, raw[i].h);
		out.push_back(d);
	}
	return out;
}

// Fin de un frame del shell: lo que no se dibujó deja de recibir frame callbacks (la app
// oculta deja de pintar, como en cualquier compositor) y sus commits no piden redibujo.
void WaylandCompositor::end_frame() {
	drawn = drawn_collect;
	drawn_collect.clear();
	throttle = true;
	if (server == NULL) {
		return;
	}
	Vector<int> ids;
	for (Set<int>::Element *e = drawn.front(); e != NULL; e = e->next()) {
		ids.push_back(e->get());
	}
	wl_server_set_visible(server, ids.ptr(), ids.size());
}

void WaylandCompositor::set_size(int p_id, const Vector2 &p_size) {
	if (server != NULL) {
		wl_server_set_size(server, p_id, (int)p_size.x, (int)p_size.y);
	}
}

void WaylandCompositor::close(int p_id) {
	if (server != NULL) {
		wl_server_close(server, p_id);
	}
}

void WaylandCompositor::focus(int p_id) {
	if (server != NULL) {
		wl_server_focus(server, p_id);
	}
}

void WaylandCompositor::pointer_motion(int p_id, const Vector2 &p_pos) {
	if (server != NULL) {
		wl_server_pointer_motion(server, p_id, p_pos.x, p_pos.y,
				(uint32_t)OS::get_singleton()->get_ticks_msec());
	}
}

void WaylandCompositor::pointer_button(int p_button_index, bool p_pressed) {
	if (server == NULL) {
		return;
	}
	uint32_t t = (uint32_t)OS::get_singleton()->get_ticks_msec();
	if (p_button_index == BUTTON_WHEEL_UP || p_button_index == BUTTON_WHEEL_DOWN) {
		if (p_pressed) {
			wl_server_pointer_axis(server, t, p_button_index == BUTTON_WHEEL_UP ? -10.0 : 10.0);
		}
		return;
	}
	uint32_t btn = 0;
	switch (p_button_index) {
		case BUTTON_LEFT:
			btn = EVDEV_BTN_LEFT;
			break;
		case BUTTON_RIGHT:
			btn = EVDEV_BTN_RIGHT;
			break;
		case BUTTON_MIDDLE:
			btn = EVDEV_BTN_MIDDLE;
			break;
		case BUTTON_XBUTTON1:
			btn = EVDEV_BTN_SIDE;
			break;
		case BUTTON_XBUTTON2:
			btn = EVDEV_BTN_EXTRA;
			break;
		default:
			return;
	}
	wl_server_pointer_button(server, t, btn, p_pressed ? 1 : 0);
}

void WaylandCompositor::pointer_axis(double p_dy) {
	if (server != NULL) {
		wl_server_pointer_axis(server, (uint32_t)OS::get_singleton()->get_ticks_msec(), p_dy);
	}
}

void WaylandCompositor::key(const Ref<InputEventKey> &p_event) {
	if (server == NULL || p_event.is_null()) {
		return;
	}
	uint32_t scancode = p_event->get_physical_scancode();
	if (scancode == 0) {
		scancode = p_event->get_scancode();
	}
	uint32_t evdev = _scancode_to_evdev(scancode);
	if (evdev == 0) {
		return;
	}
	wl_server_key(server, (uint32_t)OS::get_singleton()->get_ticks_msec(), evdev,
			p_event->is_pressed() ? 1 : 0);
}

void WaylandCompositor::set_default_size(const Vector2 &p_size) {
	default_size = p_size;
	if (server != NULL) {
		wl_server_set_default_size(server, (int)p_size.x, (int)p_size.y);
	}
}

Vector2 WaylandCompositor::get_default_size() const {
	return default_size;
}

int WaylandCompositor::get_commit_count() const {
	return commit_count;
}

int WaylandCompositor::get_dmabuf_commits() const {
	return dmabuf_commits;
}

int WaylandCompositor::get_shm_commits() const {
	return shm_commits;
}

String WaylandCompositor::get_dmabuf_state() const {
	if (server == NULL) {
		return String("off (sin servidor)");
	}
	if (wl_server_dmabuf_enabled(server)) {
		return String("on");
	}
	return String("off (") + String(wl_server_dmabuf_reason(server)) + String(")");
}
