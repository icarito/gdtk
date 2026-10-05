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
	// Multimedia: viajan por Deskflow (InputCapture) y el receptor las vuelve a
	// teclas Godot para su OSD (sin esto, el emisor no las mandaba y el receptor
	// las descartaba como scancode 0).
	EVDEV_KEY_MUTE = 113,
	EVDEV_KEY_VOLUMEDOWN = 114,
	EVDEV_KEY_VOLUMEUP = 115,
	EVDEV_KEY_BRIGHTNESSDOWN = 224,
	EVDEV_KEY_BRIGHTNESSUP = 225,
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
		case KEY_VOLUMEMUTE:
			return EVDEV_KEY_MUTE;
		case KEY_VOLUMEDOWN:
			return EVDEV_KEY_VOLUMEDOWN;
		case KEY_VOLUMEUP:
			return EVDEV_KEY_VOLUMEUP;
		case KEY_BRIGHTNESSDOWN:
			return EVDEV_KEY_BRIGHTNESSDOWN;
		case KEY_BRIGHTNESSUP:
			return EVDEV_KEY_BRIGHTNESSUP;
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

void WaylandCompositor::_cb_pointer_lock(void *p_ud, int p_id, int p_locked) {
	WaylandCompositor *self = static_cast<WaylandCompositor *>(p_ud);
	self->emit_signal("pointer_lock", p_id, p_locked != 0);
}

void WaylandCompositor::_cb_cursor_hidden(void *p_ud, int p_hidden) {
	WaylandCompositor *self = static_cast<WaylandCompositor *>(p_ud);
	self->emit_signal("client_cursor_hidden", p_hidden != 0);
}

void WaylandCompositor::_cb_cursor_shape(void *p_ud, int p_shape) {
	WaylandCompositor *self = static_cast<WaylandCompositor *>(p_ud);
	self->cursor_image_data = PoolVector<uint8_t>(); // la forma reemplaza a la imagen
	self->emit_signal("client_cursor_shape", p_shape);
}

void WaylandCompositor::_cb_cursor_image(void *p_ud, const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride, int p_hx, int p_hy) {
	static_cast<WaylandCompositor *>(p_ud)->_on_cursor_image(p_data, p_w, p_h, p_format, p_stride, p_hx, p_hy);
}

void WaylandCompositor::_cb_drag_icon(void *p_ud, const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride, int p_dx, int p_dy) {
	static_cast<WaylandCompositor *>(p_ud)->_on_drag_icon(p_data, p_w, p_h, p_format, p_stride, p_dx, p_dy);
}

void WaylandCompositor::_cb_drag_state(void *p_ud, int p_active) {
	WaylandCompositor *self = static_cast<WaylandCompositor *>(p_ud);
	self->drag_active = p_active != 0;
	self->emit_signal("drag_state_changed", self->drag_active);
}

void WaylandCompositor::_cb_output_added(void *p_ud, int p_id) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("output_added", p_id);
}

void WaylandCompositor::_cb_output_changed(void *p_ud, int p_id) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("output_changed", p_id);
}

void WaylandCompositor::_cb_output_removed(void *p_ud, int p_id) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("output_removed", p_id);
}

void WaylandCompositor::_cb_toplevel_output_changed(void *p_ud, int p_toplevel_id, int p_output_id) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("toplevel_output_changed", p_toplevel_id, p_output_id);
}

void WaylandCompositor::_cb_activate(void *p_ud, int p_id) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("toplevel_activate", p_id);
}

void WaylandCompositor::_cb_minimize(void *p_ud, int p_id) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("toplevel_minimize", p_id);
}

void WaylandCompositor::_cb_maximize(void *p_ud, int p_id, int p_maximized) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("toplevel_maximize", p_id, p_maximized);
}

void WaylandCompositor::_cb_fullscreen(void *p_ud, int p_id, int p_fullscreen) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("toplevel_fullscreen", p_id, p_fullscreen);
}

void WaylandCompositor::_cb_move(void *p_ud, int p_id) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("toplevel_move", p_id);
}

void WaylandCompositor::_cb_resize(void *p_ud, int p_id, int p_edges) {
	static_cast<WaylandCompositor *>(p_ud)->emit_signal("toplevel_resize", p_id, p_edges);
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

// Icono de drag and drop: mismo camino shm que _on_frame pero en una textura
// aparte. `p_data`==NULL limpia el icono (fin del drag o icono reemplazado). El
// shell lo dibuja pegado al puntero (+ drag_icon_offset) mientras is_dragging()
// sea true. El buffer wl_shm ARGB8888 viene CON alfa premultiplicado: la shell lo
// pinta con CanvasItemMaterial BLEND_MODE_PREMULT_ALPHA (igual que los tiles).
void WaylandCompositor::_on_drag_icon(const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride, int p_dx, int p_dy) {
	if (p_data == NULL || p_w <= 0 || p_h <= 0) {
		drag_icon_texture = Ref<ImageTexture>();
		drag_icon_offset = Vector2();
		emit_signal("drag_icon_changed");
		return;
	}
	// Algunos buffers reportan stride 0 (tightly packed): usar w*4.
	if (p_stride <= 0) {
		p_stride = p_w * 4;
	}
	if (p_stride < p_w * 4) {
		drag_icon_texture = Ref<ImageTexture>();
		drag_icon_offset = Vector2();
		emit_signal("drag_icon_changed");
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

	Ref<ImageTexture> tex = drag_icon_texture;
	if (tex.is_null() || tex->get_width() != p_w || tex->get_height() != p_h) {
		tex.instance();
		tex->create_from_image(img, 0);
	} else {
		tex->set_data(img);
	}
	drag_icon_texture = tex;
	// Hotspot: top-left del icono en puntero+(dx,dy) (offset del attach/offset).
	drag_icon_offset = Vector2(p_dx, p_dy);
	emit_signal("drag_icon_changed");
}

// Cursor por surface del cliente con foco (wl_pointer.set_cursor): RGBA8 al shell,
// que lo dibuja con hotspot. Mismo formato wl_shm que el icono de drag.
void WaylandCompositor::_on_cursor_image(const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride, int p_hx, int p_hy) {
	if (p_data == NULL || p_w <= 0 || p_h <= 0) {
		return;
	}
	if (p_stride <= 0) {
		p_stride = p_w * 4;
	}
	if (p_stride < p_w * 4) {
		return;
	}
	bool swap_rb = p_format == DRM_FORMAT_ARGB8888 || p_format == DRM_FORMAT_XRGB8888;
	bool has_alpha = p_format == DRM_FORMAT_ARGB8888 || p_format == DRM_FORMAT_ABGR8888;
	PoolVector<uint8_t> data;
	data.resize(p_w * p_h * 4);
	{
		PoolVector<uint8_t>::Write w = data.write();
		for (int y = 0; y < p_h; y++) {
			const unsigned char *src = p_data + (size_t)y * (size_t)p_stride;
			uint8_t *d = w.ptr() + (size_t)y * (size_t)p_w * 4;
			for (int x = 0; x < p_w; x++, src += 4, d += 4) {
				d[0] = swap_rb ? src[2] : src[0];
				d[1] = src[1];
				d[2] = swap_rb ? src[0] : src[2];
				d[3] = has_alpha ? src[3] : 255;
			}
		}
	}
	Vector2 hot(p_hx, p_hy);
	// Ancho y alto van en el tamaño del buffer: mismo largo con otro w/h es raro pero posible.
	if (hot == cursor_image_hotspot && data.size() == cursor_image_data.size()) {
		PoolVector<uint8_t>::Read a = data.read();
		PoolVector<uint8_t>::Read b = cursor_image_data.read();
		if (memcmp(a.ptr(), b.ptr(), data.size()) == 0) {
			return;
		}
	}
	cursor_image_data = data;
	cursor_image_hotspot = hot;
	Ref<Image> img = memnew(Image(p_w, p_h, false, Image::FORMAT_RGBA8, data));
	emit_signal("client_cursor_image", img, hot);
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
	ClassDB::bind_method(D_METHOD("is_csd", "id"), &WaylandCompositor::is_csd);
	ClassDB::bind_method(D_METHOD("get_ids"), &WaylandCompositor::get_ids);
	ClassDB::bind_method(D_METHOD("get_layer_surfaces"), &WaylandCompositor::get_layer_surfaces);
	ClassDB::bind_method(D_METHOD("get_drag_icon_texture"), &WaylandCompositor::get_drag_icon_texture);
	ClassDB::bind_method(D_METHOD("get_drag_icon_offset"), &WaylandCompositor::get_drag_icon_offset);
	ClassDB::bind_method(D_METHOD("is_dragging"), &WaylandCompositor::is_dragging);
	ClassDB::bind_method(D_METHOD("end_frame"), &WaylandCompositor::end_frame);
	ClassDB::bind_method(D_METHOD("send_frame_callbacks"), &WaylandCompositor::send_frame_callbacks);
	ClassDB::bind_method(D_METHOD("set_size", "id", "size"), &WaylandCompositor::set_size);
	ClassDB::bind_method(D_METHOD("set_maximized", "id", "maximized"), &WaylandCompositor::set_maximized);
	ClassDB::bind_method(D_METHOD("set_popup_bounds", "id", "box"), &WaylandCompositor::set_popup_bounds);
	ClassDB::bind_method(D_METHOD("set_fullscreen", "id", "fullscreen"), &WaylandCompositor::set_fullscreen);
	ClassDB::bind_method(D_METHOD("close", "id"), &WaylandCompositor::close);
	ClassDB::bind_method(D_METHOD("focus", "id", "raise"), &WaylandCompositor::focus, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("pointer_motion", "id", "pos"), &WaylandCompositor::pointer_motion);
	ClassDB::bind_method(D_METHOD("pointer_motion_relative", "delta"), &WaylandCompositor::pointer_motion_relative);
	ClassDB::bind_method(D_METHOD("pointer_clear_focus"), &WaylandCompositor::pointer_clear_focus);
	ClassDB::bind_method(D_METHOD("pointer_has_focus"), &WaylandCompositor::pointer_has_focus);
	ClassDB::bind_method(D_METHOD("client_cursor_hidden"), &WaylandCompositor::client_cursor_hidden);
	ClassDB::bind_method(D_METHOD("set_local_pointer_enabled", "enabled"), &WaylandCompositor::set_local_pointer_enabled);
	ClassDB::bind_method(D_METHOD("pointer_button", "button_index", "pressed"), &WaylandCompositor::pointer_button);
	ClassDB::bind_method(D_METHOD("pointer_axis", "dy"), &WaylandCompositor::pointer_axis);
	ClassDB::bind_method(D_METHOD("pointer_axis_h", "dx"), &WaylandCompositor::pointer_axis_h);
	ClassDB::bind_method(D_METHOD("pointer_axis_finger", "delta"), &WaylandCompositor::pointer_axis_finger);
	ClassDB::bind_method(D_METHOD("pointer_axis_stop"), &WaylandCompositor::pointer_axis_stop);
	ClassDB::bind_method(D_METHOD("gesture_pinch", "phase", "fingers", "scale"),
			&WaylandCompositor::gesture_pinch);
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

	ClassDB::bind_method(D_METHOD("add_output", "name", "rect", "scale", "primary"), &WaylandCompositor::add_output, DEFVAL(1.0), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("configure_output", "id", "rect", "scale"), &WaylandCompositor::configure_output, DEFVAL(1.0));
	ClassDB::bind_method(D_METHOD("remove_output", "id"), &WaylandCompositor::remove_output);
	ClassDB::bind_method(D_METHOD("set_toplevel_output", "toplevel_id", "output_id"), &WaylandCompositor::set_toplevel_output);
	ClassDB::bind_method(D_METHOD("get_toplevel_output", "toplevel_id"), &WaylandCompositor::get_toplevel_output);
	ClassDB::bind_method(D_METHOD("get_outputs"), &WaylandCompositor::get_outputs);
	ClassDB::bind_method(D_METHOD("get_output", "id"), &WaylandCompositor::get_output);
	ClassDB::bind_method(D_METHOD("get_primary_output_id"), &WaylandCompositor::get_primary_output_id);

	ADD_SIGNAL(MethodInfo("toplevel_added", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("toplevel_removed", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("toplevel_activate", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("toplevel_minimize", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("toplevel_maximize", PropertyInfo(Variant::INT, "id"), PropertyInfo(Variant::INT, "maximized")));
	ADD_SIGNAL(MethodInfo("toplevel_fullscreen", PropertyInfo(Variant::INT, "id"), PropertyInfo(Variant::INT, "fullscreen")));
	ADD_SIGNAL(MethodInfo("toplevel_move", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("toplevel_resize", PropertyInfo(Variant::INT, "id"), PropertyInfo(Variant::INT, "edges")));
	ADD_SIGNAL(MethodInfo("layers_changed"));
	ADD_SIGNAL(MethodInfo("pointer_lock", PropertyInfo(Variant::INT, "id"), PropertyInfo(Variant::BOOL, "locked")));
	ADD_SIGNAL(MethodInfo("client_cursor_hidden", PropertyInfo(Variant::BOOL, "hidden")));
	ADD_SIGNAL(MethodInfo("client_cursor_shape", PropertyInfo(Variant::INT, "shape")));
	ADD_SIGNAL(MethodInfo("client_cursor_image", PropertyInfo(Variant::OBJECT, "image", PROPERTY_HINT_RESOURCE_TYPE, "Image"), PropertyInfo(Variant::VECTOR2, "hotspot")));
	ADD_SIGNAL(MethodInfo("drag_icon_changed"));
	ADD_SIGNAL(MethodInfo("drag_state_changed", PropertyInfo(Variant::BOOL, "active")));
	ADD_SIGNAL(MethodInfo("process_exited", PropertyInfo(Variant::INT, "pid"), PropertyInfo(Variant::INT, "code")));
	ADD_SIGNAL(MethodInfo("output_added", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("output_changed", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("output_removed", PropertyInfo(Variant::INT, "id")));
	ADD_SIGNAL(MethodInfo("toplevel_output_changed", PropertyInfo(Variant::INT, "toplevel_id"), PropertyInfo(Variant::INT, "output_id")));
}

void WaylandCompositor::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_PROCESS: {
			if (server != NULL) {
				// Los frame callbacks se mandan al presentar (end_frame), no en cada
				// vuelta del motor: el reloj del cliente sigue a la presentación real
				// del shell y no al tick (SPEC-rendimiento-compositor). Acá sólo se
				// despachan los eventos de entrada/salida de las apps.
				wl_server_dispatch(server);
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
	local_pointer_enabled = true;
	drag_active = false;
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
	cb.maximize = &WaylandCompositor::_cb_maximize;
	cb.fullscreen = &WaylandCompositor::_cb_fullscreen;
	cb.move = &WaylandCompositor::_cb_move;
	cb.resize = &WaylandCompositor::_cb_resize;
	cb.damage = &WaylandCompositor::_cb_damage;
	cb.pointer_lock = &WaylandCompositor::_cb_pointer_lock;
	cb.cursor_hidden = &WaylandCompositor::_cb_cursor_hidden;
	cb.cursor_shape = &WaylandCompositor::_cb_cursor_shape;
	cb.cursor_image = &WaylandCompositor::_cb_cursor_image;
	cb.drag_icon = &WaylandCompositor::_cb_drag_icon;
	cb.drag_state = &WaylandCompositor::_cb_drag_state;
	cb.output_added = &WaylandCompositor::_cb_output_added;
	cb.output_changed = &WaylandCompositor::_cb_output_changed;
	cb.output_removed = &WaylandCompositor::_cb_output_removed;
	cb.toplevel_output_changed = &WaylandCompositor::_cb_toplevel_output_changed;

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

bool WaylandCompositor::is_csd(int p_id) const {
	if (server == NULL) {
		return false;
	}
	return wl_server_csd(server, p_id) != 0;
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

// Textura del icono de drag and drop (null si no hay drag o el cliente no lo envio).
Ref<Texture> WaylandCompositor::get_drag_icon_texture() const {
	return drag_icon_texture;
}

// Hotspot del icono: top-left = puntero + este offset.
Vector2 WaylandCompositor::get_drag_icon_offset() const {
	return drag_icon_offset;
}

// Hay un drag and drop nativo en curso. El shell lo consulta para no perder el
// boton cuando el cursor sale de toda ventana (cancelar el drop).
bool WaylandCompositor::is_dragging() const {
	return drag_active;
}

// Fin de un frame del shell: lo que no se dibujó deja de recibir frame callbacks (la app
// oculta deja de pintar, como en cualquier compositor) y sus commits no piden redibujo.
// Los frame callbacks se emiten acá, tras la presentación: el cliente no dibuja "al
// ritmo del motor" sino al ritmo al que el shell realmente mostró un frame
// (SPEC-rendimiento-compositor). Antes se mandaban en cada NOTIFICATION_PROCESS, lo
// que hacía renderizar de más a las apps visibles.
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
	send_frame_callbacks();
}

// Sólo frame callbacks (sin recalcular visibilidad), para el camino present-only del shell
// (una ventana visible commiteó contenido y sólo hace falta re-muestrear la textura).
void WaylandCompositor::send_frame_callbacks() {
	if (server != NULL) {
		wl_server_frame_done(server);
	}
}

void WaylandCompositor::set_size(int p_id, const Vector2 &p_size) {
	if (server != NULL) {
		wl_server_set_size(server, p_id, (int)p_size.x, (int)p_size.y);
	}
}

void WaylandCompositor::set_popup_bounds(int p_id, const Rect2 &p_box) {
	if (server != NULL) {
		wl_server_set_popup_bounds(server, p_id, (int)Math::floor(p_box.position.x), (int)Math::floor(p_box.position.y),
				(int)p_box.size.x, (int)p_box.size.y);
	}
}

void WaylandCompositor::set_maximized(int p_id, bool p_maximized) {
	if (server != NULL) {
		wl_server_set_maximized(server, p_id, p_maximized ? 1 : 0);
	}
}

void WaylandCompositor::set_fullscreen(int p_id, bool p_fullscreen) {
	if (server != NULL) {
		wl_server_set_fullscreen(server, p_id, p_fullscreen ? 1 : 0);
	}
}

void WaylandCompositor::close(int p_id) {
	if (server != NULL) {
		wl_server_close(server, p_id);
	}
}

void WaylandCompositor::focus(int p_id, bool p_raise) {
	if (server != NULL) {
		wl_server_focus(server, p_id, p_raise ? 1 : 0);
	}
}

void WaylandCompositor::pointer_motion(int p_id, const Vector2 &p_pos) {
	if (server != NULL && local_pointer_enabled) {
		wl_server_pointer_motion(server, p_id, p_pos.x, p_pos.y,
				(uint32_t)OS::get_singleton()->get_ticks_msec());
	}
}

// Movimiento relativo para el cliente con pointer lock (SDL emuladores/juegos).
// El shell lo llama con event.relative mientras tiene el puntero capturado.
void WaylandCompositor::pointer_motion_relative(const Vector2 &p_delta) {
	if (server != NULL && local_pointer_enabled) {
		wl_server_pointer_motion_relative(server, p_delta.x, p_delta.y,
				(uint32_t)OS::get_singleton()->get_ticks_msec());
	}
}

void WaylandCompositor::pointer_clear_focus() {
	if (server != NULL) {
		wl_server_pointer_clear_focus(server);
	}
}

bool WaylandCompositor::pointer_has_focus() const {
	return server != NULL && wl_server_pointer_has_focus(server);
}

bool WaylandCompositor::client_cursor_hidden() const {
	return server != NULL && wl_server_client_cursor_hidden(server);
}

void WaylandCompositor::set_local_pointer_enabled(bool p_enabled) {
	if (local_pointer_enabled == p_enabled) {
		return;
	}
	local_pointer_enabled = p_enabled;
	if (!local_pointer_enabled) {
		pointer_clear_focus();
	}
}

void WaylandCompositor::pointer_button(int p_button_index, bool p_pressed) {
	if (server == NULL || !local_pointer_enabled) {
		return;
	}
	uint32_t t = (uint32_t)OS::get_singleton()->get_ticks_msec();
	if (p_button_index == BUTTON_WHEEL_UP || p_button_index == BUTTON_WHEEL_DOWN) {
		if (p_pressed) {
			wl_server_pointer_axis(server, t, p_button_index == BUTTON_WHEEL_UP ? -10.0 : 10.0);
		}
		return;
	}
	// Scroll horizontal de dos dedos (atrás/adelante en el navegador).
	if (p_button_index == BUTTON_WHEEL_LEFT || p_button_index == BUTTON_WHEEL_RIGHT) {
		if (p_pressed) {
			wl_server_pointer_axis_h(server, t, p_button_index == BUTTON_WHEEL_LEFT ? -10.0 : 10.0);
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
	if (server != NULL && local_pointer_enabled) {
		wl_server_pointer_axis(server, (uint32_t)OS::get_singleton()->get_ticks_msec(), p_dy);
	}
}

// Eje horizontal continuo (pan de dos dedos). Complementa pointer_axis: el shell lo
// usa para InputEventPanGesture cuando el backend lo emite; la rueda clásica llega
// por pointer_button(BUTTON_WHEEL_LEFT/RIGHT) y también termina en axis_h.
void WaylandCompositor::pointer_axis_h(double p_dx) {
	if (server != NULL && local_pointer_enabled) {
		wl_server_pointer_axis_h(server, (uint32_t)OS::get_singleton()->get_ticks_msec(), p_dx);
	}
}

// Scroll de touchpad con source FINGER (delta en px de superficie) y su axis_stop.
void WaylandCompositor::pointer_axis_finger(Vector2 p_delta) {
	if (server != NULL && local_pointer_enabled) {
		wl_server_pointer_axis_finger(server, (uint32_t)OS::get_singleton()->get_ticks_msec(), p_delta.x, p_delta.y);
	}
}

void WaylandCompositor::pointer_axis_stop() {
	if (server != NULL && local_pointer_enabled) {
		wl_server_pointer_axis_stop(server, (uint32_t)OS::get_singleton()->get_ticks_msec());
	}
}

// Pinch del touchpad: el shell arma begin→update→end por cada gesto detectado por
// sway. Se reenvía al cliente con foco del puntero (ver wl_server_gesture_pinch).
// dx/dy/rotation no se usan para zoom: van en 0.
void WaylandCompositor::gesture_pinch(int p_phase, int p_fingers, double p_scale) {
	if (server != NULL && local_pointer_enabled) {
		wl_server_gesture_pinch(server, (uint32_t)OS::get_singleton()->get_ticks_msec(),
				p_phase, p_fingers < 0 ? 0u : (uint32_t)p_fingers,
				0.0, 0.0, p_scale, 0.0);
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

Dictionary WaylandCompositor::_output_dict(int p_output_id) const {
	Dictionary d;
	if (server == NULL) {
		return d;
	}
	wl_server_output_info info;
	if (!wl_server_output_get(server, p_output_id, &info)) {
		return d;
	}
	d["id"] = info.id;
	d["name"] = String(info.name != NULL ? info.name : "");
	d["rect"] = Rect2(info.x, info.y, info.width, info.height);
	d["scale"] = info.scale;
	d["primary"] = info.primary != 0;
	d["enabled"] = info.enabled != 0;
	return d;
}

int WaylandCompositor::add_output(const String &p_name, const Rect2 &p_rect, float p_scale, bool p_primary) {
	if (server == NULL) {
		return 0;
	}
	int scale = (int)(p_scale + 0.5f);
	if (scale < 1) {
		scale = 1;
	}
	return wl_server_output_add(server, p_name.utf8().get_data(),
			(int)p_rect.position.x, (int)p_rect.position.y,
			(int)p_rect.size.x, (int)p_rect.size.y, scale, p_primary ? 1 : 0);
}

bool WaylandCompositor::configure_output(int p_output_id, const Rect2 &p_rect, float p_scale) {
	if (server == NULL) {
		return false;
	}
	int scale = (int)(p_scale + 0.5f);
	if (scale < 1) {
		scale = 1;
	}
	return wl_server_output_configure(server, p_output_id,
			(int)p_rect.position.x, (int)p_rect.position.y,
			(int)p_rect.size.x, (int)p_rect.size.y, scale) != 0;
}

void WaylandCompositor::remove_output(int p_output_id) {
	if (server != NULL) {
		wl_server_output_remove(server, p_output_id);
	}
}

void WaylandCompositor::set_toplevel_output(int p_toplevel_id, int p_output_id) {
	if (server != NULL) {
		wl_server_toplevel_set_output(server, p_toplevel_id, p_output_id);
	}
}

int WaylandCompositor::get_toplevel_output(int p_toplevel_id) const {
	return server != NULL ? wl_server_toplevel_output(server, p_toplevel_id) : 0;
}

Array WaylandCompositor::get_outputs() const {
	Array out;
	if (server == NULL) {
		return out;
	}
	int count = wl_server_outputs(server, NULL, 0);
	if (count <= 0) {
		return out;
	}
	Vector<int> ids;
	ids.resize(count);
	int n = wl_server_outputs(server, ids.ptrw(), count);
	for (int i = 0; i < n; i++) {
		out.push_back(_output_dict(ids[i]));
	}
	return out;
}

Dictionary WaylandCompositor::get_output(int p_output_id) const {
	return _output_dict(p_output_id);
}

int WaylandCompositor::get_primary_output_id() const {
	return server != NULL ? wl_server_output_primary(server) : 0;
}
