#define _GNU_SOURCE

#include "wl_server.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/render/dmabuf.h>
#include <wlr/render/drm_format_set.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/types/wlr_linux_drm_syncobj_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/interfaces/wlr_keyboard.h>
#include <wlr/render/dmabuf.h>
#include <wlr/render/drm_format_set.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor_shape_v1.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_ext_data_control_v1.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_pointer_gestures_v1.h>
#include <wlr/types/wlr_primary_selection.h>
#include <wlr/types/wlr_primary_selection_v1.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_xdg_output_v1.h>
#include <wlr/types/wlr_linux_dmabuf_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_shm.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_text_input_v3.h>
#include <wlr/types/wlr_input_method_v2.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_xdg_foreign_registry.h>
#include <wlr/types/wlr_xdg_foreign_v1.h>
#include <wlr/types/wlr_xdg_foreign_v2.h>
#include <wlr/types/wlr_server_decoration.h>
#include <wlr/util/log.h>
#include <wlr/xwayland/xwayland.h>
#include <xkbcommon/xkbcommon.h>

#include "scanout.h"

struct wl_server;
struct drag_icon_watch;

// Una ventana: xdg (tl) o X11 vía Xwayland (xs); exactamente uno de los dos.
typedef struct toplevel {
	struct wl_list link;
	struct wl_server *server;
	int id;
	struct wlr_xdg_toplevel *tl;
	struct wlr_xwayland_surface *xs;
	bool added; // X: `added` se avisa en el primer map (antes no hay surface)
	bool mapped;
	bool want_focus;
	bool visible; // dibujado en el último frame del shell (ver wl_server_set_visible)
	int output_id; // salida logica asignada (0 = sin asignar; por defecto la principal)

	struct wl_listener commit;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener destroy;
	struct wl_listener set_title;
	// se registra en ambas rutas (xdg y Xwayland)
	struct wl_listener request_minimize;
	// sólo xdg: CSD pide maximizar/desmaximizar (GTK4 headerbar, etc.)
	struct wl_listener request_maximize;
	// xdg y Xwayland: pantalla completa (video de YouTube, etc.)
	struct wl_listener request_fullscreen;
	// xdg: arrastre/redimensión interactiva pedida por el cliente (CSD: barra de
	// GTK4, bordes de la app). El shell la ejecuta (ver wl_server_callbacks.move/resize).
	struct wl_listener request_move;
	struct wl_listener request_resize;
	// xdg: el cliente se dibuja su propia decoración (CSD). Arranca en true y pasa a
	// false cuando negocia SERVER_SIDE por xdg-decoration. Xwayland siempre false.
	bool csd;
	// Caja donde pueden caer sus popups, en coords de la surface raíz (la pantalla vista
	// desde la ventana). La fija el shell (wl_server_set_popup_bounds): sólo él sabe dónde
	// dibuja la ventana; sin ella se asume la ventana en el origen de la vista.
	bool has_popup_bounds;
	struct wlr_box popup_bounds;
	// sólo X
	struct wl_listener associate;
	struct wl_listener dissociate;
	struct wl_listener request_configure;
} toplevel;

// Ventana X override-redirect (menú, tooltip): se dibuja como capa de su dueño, en
// coords del root X, que coinciden con las de la vista (las ventanas X van en 0,0).
typedef struct xor_surf {
	struct wl_list link;
	struct wl_server *server;
	struct wlr_xwayland_surface *xs;
	int owner;
	bool mapped;
	struct wl_listener associate;
	struct wl_listener dissociate;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener destroy;
} xor_surf;

// Estado por surface del arbol (raiz, subsurfaces, popups). Mantiene retenido
// con wlr_buffer_lock el ultimo buffer importado para que Godot pueda
// samplearlo; la identidad es el puntero de la surface (`key`).
//
// Scanout directo (P4): en vez de importar a textura, el buffer dmabuf se le
// entrega al compositor anfitrion (sway). Cada buffer presentado queda retenido en
// `scanout_refs` hasta que sway lo libera; recien ahi se suelta el wlr_buffer y el
// cliente recibe su release (puente de ciclo de vida entre los dos compositores).
typedef struct scanout_ref {
	struct wl_list link;
	uint64_t token;
	struct wlr_buffer *buffer;
} scanout_ref;

typedef struct surface_state {
	struct wl_list link;
	struct wl_server *server;
	struct wlr_surface *surface;
	uint64_t key;
	int id;
	struct wlr_buffer *buffer;
	// Scanout directo activo para esta surface raiz (solo toplevel fullscreen en la
	// salida principal). `scale` es el entero de la salida.
	bool scanout;
	int scanout_scale;
	struct wlr_buffer *scanout_last; // ultimo buffer presentado (dedup de commits sin buffer nuevo)
	struct wl_list scanout_refs; // scanout_ref.link
	struct wl_listener commit;
	struct wl_listener destroy;
	struct wl_listener new_subsurface;
} surface_state;

// Un text-input-v3 de un cliente: el campo de texto que pide IME (text-input-v3).
// Vive en s->text_inputs; el relay le reenvia el preedit/commit del motor.
typedef struct text_input_relay {
	struct wl_list link;
	struct wl_server *server;
	struct wlr_text_input_v3 *input;
	struct wl_listener enable;
	struct wl_listener commit;
	struct wl_listener disable;
	struct wl_listener destroy;
} text_input_relay;

// Una salida logica: un wlr_output headless del backend + su ubicacion en el
// layout global del compositor embebido. La geometria (width/height) es LOGICA;
// el modo fisico del wlr_output se fija en width*scale/height*scale. La principal
// (primary) existe siempre tras wl_server_create; el resto son secundarias. Las
// surfaces de los toplevels reciben wl_surface.enter/leave al mapear y al
// reasignarse. No renderiza por si sola: la presentacion por output es fase
// posterior (OutputContext), aca solo se mantiene el modelo y el protocolo.
typedef struct logical_output {
	struct wl_list link;
	struct wl_server *server;
	int id;
	char *name; // alias estable (heap); NULL si la salida no tiene nombre
	struct wlr_output *output;
	int x, y, width, height; // geometria logica global
	int scale;
	bool primary;
	bool enabled;
} logical_output;

struct wl_server {
	struct wl_display *display;
	struct wl_event_loop *loop;
	struct wlr_backend *backend;
	struct wlr_output *output;
	struct wlr_compositor *compositor;
	struct wlr_subcompositor *subcompositor;
	struct wlr_data_device_manager *data_device_manager;
	struct wlr_xdg_shell *xdg_shell;
	struct wlr_seat *seat;
	struct wlr_keyboard keyboard;

	// xdg-foreign (v1/v2): deja que un cliente (el portal GTK del selector de
	// archivos) declare su ventana hija de la ventana de otra app. El parent que
	// marca wlroots hace que el shell lo trate como diálogo y lo flote sobre su
	// host en vez de como una ventana suelta (actividad/workspace nuevo).
	struct wlr_xdg_foreign_registry *foreign_registry;
	struct wlr_xdg_foreign_v1 *foreign_v1;
	struct wlr_xdg_foreign_v2 *foreign_v2;

	// IME (K14): text-input-v3 del cliente y el motor IME (fcitx5/ibus) por
	// input-method-v2. Relay minimo: activa el motor con el foco de text-input,
	// reenvia preedit/commit y le cede el teclado durante sus grabs.
	struct wlr_text_input_manager_v3 *text_input_manager;
	struct wlr_input_method_manager_v2 *input_method_manager;
	struct wlr_input_method_v2 *input_method;
	struct wlr_text_input_v3 *active_text_input;
	struct wlr_input_method_keyboard_grab_v2 *keyboard_grab;
	struct wl_list text_inputs; // text_input_relay.link
	struct wl_listener new_text_input;
	struct wl_listener new_input_method;
	struct wl_listener input_method_commit;
	struct wl_listener input_method_grab_keyboard;
	struct wl_listener input_method_destroy;
	struct wl_listener keyboard_grab_destroy;

	// Todo lo EGL/GL vive aqui y se resuelve con eglGetProcAddress: no se
	// linkea libGL/libGLES, solo egl.
	EGLDisplay egl_dpy;
	PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHR;
	PFNEGLDESTROYIMAGEKHRPROC eglDestroyImageKHR;
	PFNEGLQUERYDMABUFFORMATSEXTPROC eglQueryDmaBufFormatsEXT;
	PFNEGLQUERYDMABUFMODIFIERSEXTPROC eglQueryDmaBufModifiersEXT;
	PFNGLBINDTEXTUREPROC glBindTexture;
	PFNGLGETINTEGERVPROC glGetIntegerv;
	PFNGLTEXPARAMETERIPROC glTexParameteri;
	PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glEGLImageTargetTexture2DOES;
	bool dmabuf_enabled;
	const char *dmabuf_reason;
	struct wlr_linux_dmabuf_v1 *linux_dmabuf;
	// Sincronizacion explicita (linux-drm-syncobj-v1): el cliente adjunta puntos de
	// acquire/release a cada buffer. Antes de muestrear esperamos el acquire en la GPU
	// (eglWaitSyncKHR sobre el sync_file exportado) y liberamos el release del buffer
	// cuando lo soltamos (SPEC-dmabuf §5). Fallback a implicit sync (Mesa) si algo falta.
	struct wlr_linux_drm_syncobj_manager_v1 *linux_drm_syncobj;
	bool syncobj_enabled;
	const char *syncobj_reason;
	bool syncobj_seen; // ya se atendió un commit con puntos de sync explícitos
	int syncobj_drm_fd;
	PFNEGLCREATESYNCKHRPROC eglCreateSyncKHR;
	PFNEGLDESTROYSYNCKHRPROC eglDestroySyncKHR;
	PFNEGLWAITSYNCKHRPROC eglWaitSyncKHR;

	wl_server_callbacks cb;
	struct wl_listener new_toplevel;
	struct wl_listener new_popup;
	struct wl_listener new_decoration;
	struct wl_listener new_layer;
	struct wl_listener request_activate;
	struct wl_listener request_set_selection;
	struct wl_listener request_set_primary_selection;
	// Drag and drop nativo (wl_data_device). wlroots pide arrancar el drag vía
	// request_start_drag; el compositor valida el serial y llama a
	// wlr_seat_start_pointer_drag. En start_drag se registra el drag (para
	// restaurar el foco de puntero al terminar) y su icono, si lo hay.
	struct wl_listener request_start_drag;
	struct wl_listener start_drag;
	struct wl_listener drag_destroy;
	struct wlr_drag *drag;
	struct drag_icon_watch *drag_icon;
	struct wl_list toplevels;
	struct wl_list layers;
	struct wlr_xwayland *xwayland;
	struct wl_listener new_xsurface;
	struct wl_list xors;
	int x_focus_id; // última ventana X enfocada: dueña de los menús sin padre
	bool throttle; // true tras el primer wl_server_set_visible: frame callbacks sólo a lo visible
	int next_id;
	int default_w, default_h;
	// Scanout directo (P4): habilitado por GDTK_SCANOUT_DIRECT; `scanout_token`
	// identifica cada buffer presentado al host.
	bool scanout_enabled;
	uint64_t scanout_token;
	// Pausa pedida por el shell mientras hay un overlay suyo encima (Frame/OSD/...):
	// con esto en true el scanout no se engancha y las ventanas ya en scanout se
	// devuelven al camino textura.
	bool scanout_suspended;
	// Último motivo por el que `scanout_candidate` rechazó (o aceptó) el scanout, sólo
	// diagnóstico (RPC state.compositor.scanout_reason). Apunta a un literal estático.
	const char *scanout_reason;

	// Salidas logicas: coleccion explicita de wlr_output headless. `output_layout`
	// (xdg-output usa este) y `outputs` (logical_output.link) viven toda la corrida.
	// `s->output` (arriba) es un alias directo al wlr_output de la principal para
	// el codigo previo (layer-shell, etc.). `creating` suprime output_added
	// durante wl_server_create (el nodo Godot aun no tiene el puntero al server).
	struct wlr_output_layout *output_layout;
	struct wl_list outputs;
	int next_output_id;
	int primary_output_id;
	bool creating;

	// Estado por surface de todos los toplevels. Se recorre entero en cada
	// dispatch para reimportar buffers nuevos; se limpia en events.destroy.
	struct wl_list surfaces;

	const char *socket_name;
	struct wlr_surface *pointer_surface;
	int pointer_id;

	// Pointer lock de clientes alojados (zwp_pointer_constraints_v1 + relative
	// pointer). Los emuladores/juegos SDL piden lock para capturar el mouse; el
	// compositor activa la restricción de la surface enfocada, avisa al shell
	// (cb.pointer_lock) y reenvía el movimiento relativo que el shell captura.
	struct wlr_pointer_constraints_v1 *pointer_constraints;
	struct wlr_relative_pointer_manager_v1 *relative_pointer_manager;
	struct wl_listener new_constraint;
	struct wlr_pointer_constraint_v1 *active_constraint;
	int pointer_locked;

	// Cursor pedido por el cliente con foco (wl_pointer.set_cursor). 1 mientras
	// manda surface NULL: el shell oculta su cursor dibujado (juegos con lock).
	struct wl_listener request_set_cursor;
	int client_cursor_hidden;
	// wp_cursor_shape_v1 y cursor por surface (ver handle_request_set_cursor).
	struct wl_listener request_cursor_shape;
	struct wlr_surface *cursor_surface; // surface de cursor vigente (NULL si no hay)
	struct wl_listener cursor_commit;
	struct wl_listener cursor_destroy;
	int cursor_hx, cursor_hy;

	// Pointer gestures (zwp_pointer_gesture_pinch_v1): el shell reenvía el pinch
	// del touchpad (vía sway bindgesture → RPC) y wlroots lo entrega al cliente
	// con foco (Firefox/Nautilus). El global se crea siempre; sólo se emiten
	// eventos cuando el shell llama wl_server_gesture_pinch.
	struct wlr_pointer_gestures_v1 *pointer_gestures;
};

static void handle_new_constraint(struct wl_listener *listener, void *data);
static void update_pointer_constraint(struct wl_server *s);

static toplevel *toplevel_find(struct wl_server *s, int id) {
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if (t->id == id) {
			return t;
		}
	}
	return NULL;
}

static toplevel *toplevel_find_surface(struct wl_server *s, struct wlr_surface *surface) {
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if ((t->tl != NULL ? t->tl->base->surface : t->xs->surface) == surface) {
			return t;
		}
	}
	return NULL;
}

static surface_state *surface_state_find(struct wl_server *s, struct wlr_surface *surface) {
	surface_state *st;
	wl_list_for_each(st, &s->surfaces, link) {
		if (st->surface == surface) {
			return st;
		}
	}
	return NULL;
}

static surface_state *surface_state_find_key(struct wl_server *s, uint64_t key) {
	surface_state *st;
	wl_list_for_each(st, &s->surfaces, link) {
		if (st->key == key) {
			return st;
		}
	}
	return NULL;
}

static void surface_state_release_buffer(surface_state *st) {
	if (st->buffer != NULL) {
		wlr_buffer_unlock(st->buffer);
		st->buffer = NULL;
	}
}

// --- Scanout directo (P4 opcion B) ------------------------------------------

static void scanout_refs_clear(surface_state *st) {
	scanout_ref *r, *tmp;
	wl_list_for_each_safe(r, tmp, &st->scanout_refs, link) {
		wlr_buffer_unlock(r->buffer);
		wl_list_remove(&r->link);
		free(r);
	}
	st->scanout_last = NULL;
}

// sway libero un wl_buffer espejo: soltar el wlr_buffer retenido (recien ahi el
// cliente del compositor embebido recibe su release y puede reciclar el buffer).
static void scanout_on_release(void *ud, int id, uint64_t token) {
	struct wl_server *s = ud;
	if (s == NULL || id <= 0) {
		return;
	}
	surface_state *st;
	wl_list_for_each(st, &s->surfaces, link) {
		if (!st->scanout || st->id != id) {
			continue;
		}
		scanout_ref *r, *tmp;
		wl_list_for_each_safe(r, tmp, &st->scanout_refs, link) {
			if (r->token == token) {
				wlr_buffer_unlock(r->buffer);
				wl_list_remove(&r->link);
				free(r);
				return;
			}
		}
	}
}

static logical_output *scanout_primary_output(struct wl_server *s) {
	logical_output *o;
	wl_list_for_each(o, &s->outputs, link) {
		if (o->id == s->primary_output_id) {
			return o;
		}
	}
	return NULL;
}

// Candidato: surface raiz de un toplevel xdg fullscreen en la salida principal.
// Nada de subsurfaces/popups, Xwayland ni salidas secundarias en el MVP.
//
// Se aparta tambien si hay un popup abierto (menu del cliente: lo dibuja Godot y la
// subsurface del host lo taparia) o si otra ventana visible comparte la principal.
static bool scanout_has_visible_sibling(struct wl_server *s, int self_id) {
	if (!s->throttle) {
		return false; // todavia sin la lista de visibilidad del shell
	}
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if (t->id == self_id || !t->mapped || !t->visible) {
			continue;
		}
		if (t->output_id == s->primary_output_id || t->output_id == 0) {
			return true;
		}
	}
	return false;
}

static bool scanout_candidate(struct wl_server *s, surface_state *st) {
	if (!s->scanout_enabled) {
		s->scanout_reason = "bridge off";
		return false;
	}
	if (s->scanout_suspended) {
		s->scanout_reason = "suspendido (overlay del shell)";
		return false;
	}
	if (st->surface == NULL || st->id <= 0) {
		s->scanout_reason = "sin surface/id";
		return false;
	}
	toplevel *t = toplevel_find(s, st->id);
	if (t == NULL || !t->mapped || t->tl == NULL) {
		s->scanout_reason = "toplevel no mapeado";
		return false;
	}
	if (t->tl->base->surface != st->surface) {
		s->scanout_reason = "surface no raiz (subsurface)";
		return false;
	}
	if (t->output_id != s->primary_output_id) {
		s->scanout_reason = "salida no primaria";
		return false;
	}
	if (!wl_list_empty(&t->tl->base->popups)) {
		s->scanout_reason = "popup abierto";
		return false;
	}
	if (scanout_has_visible_sibling(s, st->id)) {
		s->scanout_reason = "otra ventana visible";
		return false;
	}
	if (!t->tl->current.fullscreen) {
		s->scanout_reason = "xdg no fullscreen";
		return false;
	}
	s->scanout_reason = "on";
	return true;
}

static void scanout_buffer(surface_state *st, struct wlr_buffer *buf,
		const struct wlr_dmabuf_attributes *attribs) {
	struct wl_server *s = st->server;
	logical_output *o = scanout_primary_output(s);
	st->scanout = true;
	st->scanout_scale = (o != NULL && o->scale > 0) ? o->scale : 1;
	st->scanout_last = buf;
	scanout_ref *r = calloc(1, sizeof(*r));
	r->token = ++s->scanout_token;
	r->buffer = buf;
	wlr_buffer_lock(buf);
	wl_list_insert(&st->scanout_refs, &r->link);
	// Fullscreen en la principal: el shell lo dibuja en (0,0) del viewport.
	gdtk_scanout_present(st->id, attribs, 0, 0, attribs->width, attribs->height,
			st->scanout_scale, r->token);
}

static void scanout_off(surface_state *st) {
	if (!st->scanout) {
		return;
	}
	gdtk_scanout_hide(st->id);
	scanout_refs_clear(st);
	st->scanout = false;
}

// Devuelve la surface raiz que esta en scanout para el toplevel `id` (NULL si no hay).
static surface_state *scanout_state_for_id(struct wl_server *s, int id) {
	surface_state *st;
	wl_list_for_each(st, &s->surfaces, link) {
		if (st->scanout && st->id == id) {
			return st;
		}
	}
	return NULL;
}

// Apaga el scanout de `st` reimportando su ultimo dmabuf como textura de Godot. Es el
// camino de pausa: sin esto, al ocultar la subsurface del host (overlay del shell,
// menu del cliente, otra ventana encima) quedaria un hueco hasta el proximo commit
// del cliente, que en una app quieta puede no llegar nunca.
static void scanout_off_reimport(struct wl_server *s, surface_state *st) {
	if (!st->scanout) {
		return;
	}
	struct wlr_buffer *buf = st->scanout_last;
	struct wlr_dmabuf_attributes attribs;
	bool import = buf != NULL && s->dmabuf_enabled && wlr_buffer_get_dmabuf(buf, &attribs);
	if (import && buf != st->buffer) {
		// Retener el buffer como el vigente ANTES de soltar los refs del scanout.
		wlr_buffer_lock(buf);
		if (st->buffer != NULL) {
			wlr_buffer_unlock(st->buffer);
		}
		st->buffer = buf;
	}
	gdtk_scanout_hide(st->id);
	st->scanout = false;
	scanout_refs_clear(st);
	if (import && s->cb.dmabuf != NULL) {
		// Sync implicita (Mesa/Intel) como el import dmabuf normal de wl_server_bind_dmabuf.
		s->cb.dmabuf(s->cb.ud, st->id, st->key, attribs.width, attribs.height);
	}
}

static int surface_state_resolve_id(struct wl_server *s, struct wlr_surface *surface, int depth);

// Espera explícita del acquire point / release del buffer (linux-drm-syncobj-v1); definida
// junto a setup_dmabuf. No-op si el server no habilitó syncobj.
static void syncobj_apply(struct wl_server *s, surface_state *st);

// Importa el buffer current de la surface si hay uno. Se llama desde el commit
// de la surface, unico momento en que wlroots deja valido current.buffer. Los
// commits sin buffer (ack de configure, frame callbacks) se ignoran para no
// soltar el ultimo buffer importado.
static void surface_state_import(surface_state *st) {
	struct wl_server *s = st->server;
	if (st->id <= 0) {
		st->id = surface_state_resolve_id(s, st->surface, 0);
	}
	if (st->id <= 0) {
		return;
	}
	struct wlr_buffer *buf = st->surface->current.buffer;
	if (buf == NULL) {
		return;
	}

	struct wlr_dmabuf_attributes attribs;
	bool has_dmabuf = s->dmabuf_enabled && wlr_buffer_get_dmabuf(buf, &attribs);

	// Scanout directo: el dmabuf va al compositor anfitrion en vez de a una textura
	// de Godot. Si deja de ser candidato, se apaga y sigue el camino actual.
	if (has_dmabuf && scanout_candidate(s, st)) {
		if (buf != st->scanout_last) {
			scanout_buffer(st, buf, &attribs);
		}
		return;
	}
	if (st->scanout) {
		scanout_off(st);
	}

	if (buf != st->buffer) {
		wlr_buffer_lock(buf);
		if (st->buffer != NULL) {
			wlr_buffer_unlock(st->buffer);
		}
		st->buffer = buf;
	}

	if (has_dmabuf) {
		if (s->syncobj_enabled) {
			syncobj_apply(s, st);
		}
		if (s->cb.dmabuf != NULL) {
			s->cb.dmabuf(s->cb.ud, st->id, st->key, attribs.width, attribs.height);
		}
		return;
	}

	// Camino shm: puntero directo al buffer del cliente, sin copia en C.
	void *ptr = NULL;
	uint32_t format = 0;
	size_t stride = 0;
	if (!wlr_buffer_begin_data_ptr_access(buf, WLR_BUFFER_DATA_PTR_ACCESS_READ,
			&ptr, &format, &stride)) {
		return;
	}
	if (s->cb.frame != NULL) {
		s->cb.frame(s->cb.ud, st->id, st->key, (const unsigned char *)ptr, buf->width,
				buf->height, format, (int)stride);
	}
	wlr_buffer_end_data_ptr_access(buf);
}

static void handle_surface_commit(struct wl_listener *listener, void *data) {
	surface_state *st = wl_container_of(listener, st, commit);
	surface_state_import(st);
}

static void surface_state_acquire(struct wl_server *s, struct wlr_surface *surface, int id);

// Resuelve el toplevel dueno de una surface subiendo por los popups: un popup
// no esta en el arbol de subsurfaces, su padre lo referencia xdg_popup.parent.
static int surface_state_resolve_id(struct wl_server *s, struct wlr_surface *surface, int depth) {
	if (surface == NULL || depth > 16) {
		return 0;
	}
	surface_state *st = surface_state_find(s, surface);
	if (st != NULL && st->id > 0) {
		return st->id;
	}
	struct wlr_xdg_surface *xdg = wlr_xdg_surface_try_from_wlr_surface(surface);
	if (xdg != NULL && xdg->role == WLR_XDG_SURFACE_ROLE_POPUP && xdg->popup != NULL) {
		return surface_state_resolve_id(s, xdg->popup->parent, depth + 1);
	}
	toplevel *t = toplevel_find_surface(s, wlr_surface_get_root_surface(surface));
	return t != NULL ? t->id : 0;
}

static void handle_new_subsurface(struct wl_listener *listener, void *data) {
	surface_state *st = wl_container_of(listener, st, new_subsurface);
	struct wlr_subsurface *sub = data;
	if (sub != NULL && sub->surface != NULL &&
			surface_state_find(st->server, sub->surface) == NULL) {
		surface_state_acquire(st->server, sub->surface, st->id);
	}
}

static void handle_surface_destroy(struct wl_listener *listener, void *data) {
	surface_state *st = wl_container_of(listener, st, destroy);
	wl_list_remove(&st->commit.link);
	wl_list_remove(&st->new_subsurface.link);
	wl_list_remove(&st->destroy.link);
	wl_list_remove(&st->link);
	// Si la ventana estaba en scanout y el cliente muere sin un ultimo commit, la
	// subsurface del host quedaria mostrando el ultimo frame: ocultarla y liberar.
	if (st->scanout) {
		gdtk_scanout_hide(st->id);
		st->scanout = false;
	}
	surface_state_release_buffer(st);
	scanout_refs_clear(st);
	free(st);
}

static void surface_state_acquire(struct wl_server *s, struct wlr_surface *surface, int id) {
	surface_state *st = calloc(1, sizeof(*st));
	if (st == NULL) {
		return;
	}
	st->server = s;
	st->surface = surface;
	st->key = (uint64_t)(uintptr_t)surface;
	st->id = id;
	wl_list_init(&st->scanout_refs);
	st->commit.notify = handle_surface_commit;
	wl_signal_add(&surface->events.commit, &st->commit);
	st->new_subsurface.notify = handle_new_subsurface;
	wl_signal_add(&surface->events.new_subsurface, &st->new_subsurface);
	st->destroy.notify = handle_surface_destroy;
	wl_signal_add(&surface->events.destroy, &st->destroy);
	wl_list_insert(s->surfaces.prev, &st->link);
}

// --- IME: relay text-input-v3 <-> input-method-v2 (K14) ---
// El motor IME (fcitx5/ibus) se conecta por input-method-v2; los clientes piden
// texto por text-input-v3. Aqui solo se enruta: foco de text-input al toplevel
// enfocado, ida de surrounding/content-type, vuelta de preedit/commit, y cesion
// del teclado mientras el motor tiene un grab. Sin procesos en el render: todo
// corre en el hilo de dispatch de Wayland.

static void handle_text_input_enable(struct wl_listener *listener, void *data);

static void handle_text_input_commit(struct wl_listener *listener, void *data);

static void handle_text_input_disable(struct wl_listener *listener, void *data);

static void handle_text_input_destroy(struct wl_listener *listener, void *data);

static void handle_new_text_input(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_text_input);
	struct wlr_text_input_v3 *input = data;
	text_input_relay *ti = calloc(1, sizeof(*ti));
	if (ti == NULL) {
		return;
	}
	ti->server = s;
	ti->input = input;
	ti->enable.notify = handle_text_input_enable;
	wl_signal_add(&input->events.enable, &ti->enable);
	ti->commit.notify = handle_text_input_commit;
	wl_signal_add(&input->events.commit, &ti->commit);
	ti->disable.notify = handle_text_input_disable;
	wl_signal_add(&input->events.disable, &ti->disable);
	ti->destroy.notify = handle_text_input_destroy;
	wl_signal_add(&input->events.destroy, &ti->destroy);
	wl_list_insert(&s->text_inputs, &ti->link);
}

// El cliente habilito su campo: activar el motor y mandarle el contexto.
static void handle_text_input_enable(struct wl_listener *listener, void *data) {
	text_input_relay *ti = wl_container_of(listener, ti, enable);
	struct wl_server *s = ti->server;
	if (s->input_method == NULL) {
		return;
	}
	s->active_text_input = ti->input;
	wlr_input_method_v2_send_activate(s->input_method);
	if ((ti->input->active_features & WLR_TEXT_INPUT_V3_FEATURE_SURROUNDING_TEXT) &&
			ti->input->current.surrounding.text != NULL) {
		wlr_input_method_v2_send_surrounding_text(s->input_method,
				ti->input->current.surrounding.text,
				ti->input->current.surrounding.cursor,
				ti->input->current.surrounding.anchor);
	}
	if (ti->input->active_features & WLR_TEXT_INPUT_V3_FEATURE_CONTENT_TYPE) {
		wlr_input_method_v2_send_content_type(s->input_method,
				ti->input->current.content_type.hint,
				ti->input->current.content_type.purpose);
	}
	wlr_input_method_v2_send_done(s->input_method);
}

// Reenvia el estado actual al motor para que refina su candidato.
static void handle_text_input_commit(struct wl_listener *listener, void *data) {
	text_input_relay *ti = wl_container_of(listener, ti, commit);
	struct wl_server *s = ti->server;
	if (s->input_method == NULL || s->active_text_input != ti->input) {
		return;
	}
	if ((ti->input->active_features & WLR_TEXT_INPUT_V3_FEATURE_SURROUNDING_TEXT) &&
			ti->input->current.surrounding.text != NULL) {
		wlr_input_method_v2_send_surrounding_text(s->input_method,
				ti->input->current.surrounding.text,
				ti->input->current.surrounding.cursor,
				ti->input->current.surrounding.anchor);
	}
	if (ti->input->active_features & WLR_TEXT_INPUT_V3_FEATURE_CONTENT_TYPE) {
		wlr_input_method_v2_send_content_type(s->input_method,
				ti->input->current.content_type.hint,
				ti->input->current.content_type.purpose);
	}
	wlr_input_method_v2_send_done(s->input_method);
}

static void handle_text_input_disable(struct wl_listener *listener, void *data) {
	text_input_relay *ti = wl_container_of(listener, ti, disable);
	struct wl_server *s = ti->server;
	if (s->active_text_input != ti->input) {
		return;
	}
	s->active_text_input = NULL;
	if (s->input_method != NULL) {
		wlr_input_method_v2_send_deactivate(s->input_method);
	}
}

static void handle_text_input_destroy(struct wl_listener *listener, void *data) {
	text_input_relay *ti = wl_container_of(listener, ti, destroy);
	struct wl_server *s = ti->server;
	if (s->active_text_input == ti->input) {
		s->active_text_input = NULL;
		if (s->input_method != NULL) {
			wlr_input_method_v2_send_deactivate(s->input_method);
		}
	}
	wl_list_remove(&ti->enable.link);
	wl_list_remove(&ti->commit.link);
	wl_list_remove(&ti->disable.link);
	wl_list_remove(&ti->destroy.link);
	wl_list_remove(&ti->link);
	free(ti);
}

// El toplevel enfocado manda en el foco de text-input. Como text-input-v3 es
// por cliente, se entra en los text-input del mismo cliente que la surface y se
// sale del resto.
static void text_input_relay_set_focus(struct wl_server *s, struct wlr_surface *surface) {
	if (s == NULL) {
		return;
	}
	text_input_relay *ti;
	wl_list_for_each(ti, &s->text_inputs, link) {
		struct wlr_text_input_v3 *input = ti->input;
		bool same_client = surface != NULL && input->resource != NULL &&
				wl_resource_get_client(input->resource) ==
				wl_resource_get_client(surface->resource);
		if (same_client) {
			if (input->focused_surface != surface) {
				if (input->focused_surface != NULL) {
					wlr_text_input_v3_send_leave(input);
				}
				wlr_text_input_v3_send_enter(input, surface);
			}
		} else if (input->focused_surface != NULL) {
			wlr_text_input_v3_send_leave(input);
		}
	}
}

static void handle_input_method_commit(struct wl_listener *listener, void *data);

static void handle_input_method_grab_keyboard(struct wl_listener *listener, void *data);

static void handle_input_method_destroy(struct wl_listener *listener, void *data);

static void handle_keyboard_grab_destroy(struct wl_listener *listener, void *data);

static void handle_new_input_method(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_input_method);
	struct wlr_input_method_v2 *im = data;
	if (s->input_method != NULL) {
		// Un solo motor IME a la vez: el segundo recibe unavailable.
		wlr_input_method_v2_send_unavailable(im);
		return;
	}
	s->input_method = im;
	s->input_method_commit.notify = handle_input_method_commit;
	wl_signal_add(&im->events.commit, &s->input_method_commit);
	s->input_method_grab_keyboard.notify = handle_input_method_grab_keyboard;
	wl_signal_add(&im->events.grab_keyboard, &s->input_method_grab_keyboard);
	s->input_method_destroy.notify = handle_input_method_destroy;
	wl_signal_add(&im->events.destroy, &s->input_method_destroy);
}

// El motor produjo texto: reenviar preedit/commit/delete al campo enfocado.
static void handle_input_method_commit(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, input_method_commit);
	struct wlr_input_method_v2 *im = data;
	struct wlr_text_input_v3 *input = s->active_text_input;
	if (input == NULL) {
		return;
	}
	if (im->current.preedit.text != NULL) {
		wlr_text_input_v3_send_preedit_string(input, im->current.preedit.text,
				im->current.preedit.cursor_begin, im->current.preedit.cursor_end);
	}
	if (im->current.commit_text != NULL) {
		wlr_text_input_v3_send_commit_string(input, im->current.commit_text);
	}
	if (im->current.delete.before_length > 0 || im->current.delete.after_length > 0) {
		wlr_text_input_v3_send_delete_surrounding_text(input,
				im->current.delete.before_length, im->current.delete.after_length);
	}
	wlr_text_input_v3_send_done(input);
}

// El motor toma el teclado (composición/preedit): se le da el keymap y los
// modificadores; wl_server_key le reenvia las teclas mientras dure el grab.
static void handle_input_method_grab_keyboard(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, input_method_grab_keyboard);
	struct wlr_input_method_keyboard_grab_v2 *grab = data;
	if (s->keyboard_grab != NULL) {
		wl_list_remove(&s->keyboard_grab_destroy.link);
		wlr_input_method_keyboard_grab_v2_destroy(s->keyboard_grab);
		s->keyboard_grab = NULL;
	}
	s->keyboard_grab = grab;
	wlr_input_method_keyboard_grab_v2_set_keyboard(grab, &s->keyboard);
	wlr_input_method_keyboard_grab_v2_send_modifiers(grab, &s->keyboard.modifiers);
	s->keyboard_grab_destroy.notify = handle_keyboard_grab_destroy;
	wl_signal_add(&grab->events.destroy, &s->keyboard_grab_destroy);
}
static void handle_keyboard_grab_destroy(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, keyboard_grab_destroy);

	wl_list_remove(&s->keyboard_grab_destroy.link);
	wl_list_init(&s->keyboard_grab_destroy.link);
	s->keyboard_grab = NULL;
}

// Suelta un grab del teclado del IME que ya no tiene de qué apropiarse (IME
// colgado o apagado sin que llegue el destroy del grab). La soltar por el canal
// del protocolo: destroy del recurso dispara events.destroy, así que el handler
// oficial vuelve a correr; con la lista del listener auto-inicializada esa doble
// pasada es inocua. Sin esto el teclado queda mudo hasta matar el IME.
static void release_stale_keyboard_grab(struct wl_server *s) {
	if (s->keyboard_grab == NULL) {
		return;
	}
	wl_list_remove(&s->keyboard_grab_destroy.link);
	wl_list_init(&s->keyboard_grab_destroy.link);
	wlr_input_method_keyboard_grab_v2_destroy(s->keyboard_grab);
	s->keyboard_grab = NULL;
	wlr_log(WLR_INFO, "wl_server: keyboard_grab del IME soltado sin text-input activo");
}

static void handle_input_method_destroy(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, input_method_destroy);
	s->active_text_input = NULL;
	wl_list_remove(&s->input_method_commit.link);
	wl_list_remove(&s->input_method_grab_keyboard.link);
	wl_list_remove(&s->input_method_destroy.link);
	// Mismo safety que wl_server_key: si el grab sobrevivió (orden de señales
	// atípico del kill del IME), no puede sobrevivir al IME.
	release_stale_keyboard_grab(s);
	s->input_method = NULL;
}

// Atributos EGL de import por plano (hasta 4, como WLR_DMABUF_MAX_PLANES).
static const EGLint dmabuf_plane_fd[4] = {
	EGL_DMA_BUF_PLANE0_FD_EXT, EGL_DMA_BUF_PLANE1_FD_EXT,
	EGL_DMA_BUF_PLANE2_FD_EXT, EGL_DMA_BUF_PLANE3_FD_EXT,
};
static const EGLint dmabuf_plane_offset[4] = {
	EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGL_DMA_BUF_PLANE1_OFFSET_EXT,
	EGL_DMA_BUF_PLANE2_OFFSET_EXT, EGL_DMA_BUF_PLANE3_OFFSET_EXT,
};
static const EGLint dmabuf_plane_pitch[4] = {
	EGL_DMA_BUF_PLANE0_PITCH_EXT, EGL_DMA_BUF_PLANE1_PITCH_EXT,
	EGL_DMA_BUF_PLANE2_PITCH_EXT, EGL_DMA_BUF_PLANE3_PITCH_EXT,
};
static const EGLint dmabuf_plane_mod_lo[4] = {
	EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
	EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT,
};
static const EGLint dmabuf_plane_mod_hi[4] = {
	EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,
	EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT,
};

// Arma la lista EGL de import de un dmabuf (todos sus planos). En esta GPU
// (Intel Iris Xe) Mesa asigna XRGB8888/ARGB8888 con modificadores con planos
// auxiliares CCS, por eso no alcanza con aceptar n_planes == 1.
static void dmabuf_egl_attrs(const struct wlr_dmabuf_attributes *attribs, EGLint *attrs) {
	int i = 0;
	attrs[i++] = EGL_WIDTH;
	attrs[i++] = attribs->width;
	attrs[i++] = EGL_HEIGHT;
	attrs[i++] = attribs->height;
	attrs[i++] = EGL_LINUX_DRM_FOURCC_EXT;
	attrs[i++] = (EGLint)attribs->format;
	int n = attribs->n_planes;
	if (n > 4) {
		n = 4;
	}
	for (int p = 0; p < n; p++) {
		attrs[i++] = dmabuf_plane_fd[p];
		attrs[i++] = attribs->fd[p];
		attrs[i++] = dmabuf_plane_offset[p];
		attrs[i++] = (EGLint)attribs->offset[p];
		attrs[i++] = dmabuf_plane_pitch[p];
		attrs[i++] = (EGLint)attribs->stride[p];
		if (attribs->modifier != DRM_FORMAT_MOD_INVALID) {
			attrs[i++] = dmabuf_plane_mod_lo[p];
			attrs[i++] = (EGLint)(attribs->modifier & 0xffffffffu);
			attrs[i++] = dmabuf_plane_mod_hi[p];
			attrs[i++] = (EGLint)(attribs->modifier >> 32);
		}
	}
	attrs[i++] = EGL_NONE;
}

// Solo aceptamos dmabuf que EGL pueda importar. Si falla, el cliente recibe
// `failed` y cae a shm.
static bool check_dmabuf(struct wlr_dmabuf_attributes *attribs, void *data) {
	struct wl_server *s = data;
	if (s->eglCreateImageKHR == NULL || attribs->n_planes < 1 || attribs->n_planes > 4) {
		return false;
	}
	EGLint attrs[64];
	dmabuf_egl_attrs(attribs, attrs);
	EGLImageKHR image = s->eglCreateImageKHR(s->egl_dpy, EGL_NO_CONTEXT,
			EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
	if (image == EGL_NO_IMAGE_KHR) {
		return false;
	}
	s->eglDestroyImageKHR(s->egl_dpy, image);
	return true;
}

// Llena `set` con los format+modifier que EGL puede importar; omite los
// external_only y usa DRM_FORMAT_MOD_INVALID cuando no hay modifiers.
static bool fill_formats(struct wl_server *s, struct wlr_drm_format_set *set) {
	EGLint num_formats = 0;
	if (!s->eglQueryDmaBufFormatsEXT(s->egl_dpy, 0, NULL, &num_formats) ||
			num_formats <= 0) {
		return false;
	}
	EGLint *formats = malloc((size_t)num_formats * sizeof(EGLint));
	if (formats == NULL) {
		return false;
	}
	if (!s->eglQueryDmaBufFormatsEXT(s->egl_dpy, num_formats, formats, &num_formats)) {
		free(formats);
		return false;
	}

	bool any = false;
	for (EGLint i = 0; i < num_formats; i++) {
		EGLint num_mods = 0;
		if (!s->eglQueryDmaBufModifiersEXT(s->egl_dpy, formats[i], 0, NULL, NULL, &num_mods)) {
			num_mods = 0;
		}
		if (num_mods <= 0) {
			if (wlr_drm_format_set_add(set, (uint32_t)formats[i], DRM_FORMAT_MOD_INVALID)) {
				any = true;
			}
			continue;
		}
		EGLuint64KHR *mods = malloc((size_t)num_mods * sizeof(EGLuint64KHR));
		EGLBoolean *external_only = malloc((size_t)num_mods * sizeof(EGLBoolean));
		if (mods == NULL || external_only == NULL) {
			free(mods);
			free(external_only);
			continue;
		}
		if (s->eglQueryDmaBufModifiersEXT(s->egl_dpy, formats[i], num_mods, mods,
				external_only, &num_mods)) {
			for (EGLint j = 0; j < num_mods; j++) {
				if (external_only[j]) {
					continue;
				}
				if (wlr_drm_format_set_add(set, (uint32_t)formats[i], (uint64_t)mods[j])) {
					any = true;
				}
			}
		}
		free(mods);
		free(external_only);
	}
	free(formats);
	return any;
}

// Anuncia linux-drm-syncobj-v1 (sincronizacion explicita) si el EGL del shell puede
// esperar fences en la GPU (EGL_ANDROID_native_fence_sync + EGL_KHR_wait_sync) y el render
// node se abre. Si falta algo, queda el implicit sync de Mesa. GDTK_NO_EXPLICIT_SYNC fuerza
// el camino viejo.
static void setup_syncobj(struct wl_server *s, const char *node) {
	s->syncobj_enabled = false;
	s->syncobj_reason = "off";
	if (getenv("GDTK_NO_EXPLICIT_SYNC") != NULL) {
		s->syncobj_reason = "off (forzado)";
		return;
	}
	const char *exts = eglQueryString(s->egl_dpy, EGL_EXTENSIONS);
	if (exts == NULL ||
			strstr(exts, "EGL_ANDROID_native_fence_sync") == NULL ||
			strstr(exts, "EGL_KHR_wait_sync") == NULL) {
		s->syncobj_reason = "off (sin EGL fence)";
		return;
	}
	s->eglCreateSyncKHR = (PFNEGLCREATESYNCKHRPROC)eglGetProcAddress("eglCreateSyncKHR");
	s->eglDestroySyncKHR = (PFNEGLDESTROYSYNCKHRPROC)eglGetProcAddress("eglDestroySyncKHR");
	s->eglWaitSyncKHR = (PFNEGLWAITSYNCKHRPROC)eglGetProcAddress("eglWaitSyncKHR");
	if (s->eglCreateSyncKHR == NULL || s->eglDestroySyncKHR == NULL || s->eglWaitSyncKHR == NULL) {
		s->syncobj_reason = "off (faltan funciones EGL)";
		return;
	}
	int fd = open(node, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		s->syncobj_reason = "off (sin render node)";
		return;
	}
	// El manager guarda el fd (no lo duplica): se cierra en wl_server_destroy.
	s->linux_drm_syncobj = wlr_linux_drm_syncobj_manager_v1_create(s->display, 1, fd);
	if (s->linux_drm_syncobj == NULL) {
		close(fd);
		s->syncobj_reason = "off (manager fallo)";
		return;
	}
	s->syncobj_drm_fd = fd;
	s->syncobj_enabled = true;
	s->syncobj_reason = "on";
}

// Anuncia linux-dmabuf con feedback armado a mano (main_device = render node).
// Si falta EGL, extensiones, funciones o el render node: solo shm, con motivo.
static void setup_dmabuf(struct wl_server *s) {
	s->dmabuf_enabled = false;
	s->dmabuf_reason = "sin EGL (GLX/x11)";

	if (getenv("GDTK_FORCE_SHM") != NULL) {
		s->dmabuf_reason = "forzado";
		return;
	}

	s->egl_dpy = eglGetCurrentDisplay();
	if (s->egl_dpy == EGL_NO_DISPLAY) {
		return;
	}

	const char *exts = eglQueryString(s->egl_dpy, EGL_EXTENSIONS);
	if (exts == NULL ||
			strstr(exts, "EGL_EXT_image_dma_buf_import") == NULL ||
			strstr(exts, "EGL_EXT_image_dma_buf_import_modifiers") == NULL) {
		s->dmabuf_reason = "sin EGL_EXT_image_dma_buf_import(_modifiers)";
		return;
	}

	s->eglCreateImageKHR = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
	s->eglDestroyImageKHR = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
	s->eglQueryDmaBufFormatsEXT = (PFNEGLQUERYDMABUFFORMATSEXTPROC)eglGetProcAddress("eglQueryDmaBufFormatsEXT");
	s->eglQueryDmaBufModifiersEXT = (PFNEGLQUERYDMABUFMODIFIERSEXTPROC)eglGetProcAddress("eglQueryDmaBufModifiersEXT");
	s->glBindTexture = (PFNGLBINDTEXTUREPROC)eglGetProcAddress("glBindTexture");
	s->glGetIntegerv = (PFNGLGETINTEGERVPROC)eglGetProcAddress("glGetIntegerv");
	s->glTexParameteri = (PFNGLTEXPARAMETERIPROC)eglGetProcAddress("glTexParameteri");
	s->glEGLImageTargetTexture2DOES = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	if (s->eglCreateImageKHR == NULL || s->eglDestroyImageKHR == NULL ||
			s->eglQueryDmaBufFormatsEXT == NULL || s->eglQueryDmaBufModifiersEXT == NULL ||
			s->glBindTexture == NULL || s->glGetIntegerv == NULL ||
			s->glTexParameteri == NULL || s->glEGLImageTargetTexture2DOES == NULL) {
		s->dmabuf_reason = "faltan funciones EGL/GL";
		return;
	}

	const char *node = getenv("GDTK_DRM_RENDER_NODE");
	if (node == NULL) {
		node = "/dev/dri/renderD128";
	}
	struct stat st;
	if (stat(node, &st) != 0) {
		s->dmabuf_reason = "sin render node";
		return;
	}

	struct wlr_linux_dmabuf_feedback_v1 feedback = {0};
	struct wlr_linux_dmabuf_feedback_v1_tranche *tranche =
			wlr_linux_dmabuf_feedback_add_tranche(&feedback);
	if (tranche == NULL) {
		s->dmabuf_reason = "sin memoria (feedback)";
		return;
	}
	feedback.main_device = st.st_rdev;
	tranche->target_device = st.st_rdev;
	if (!fill_formats(s, &tranche->formats)) {
		wlr_linux_dmabuf_feedback_v1_finish(&feedback);
		s->dmabuf_reason = "sin formatos dmabuf";
		return;
	}

	// wlr_linux_dmabuf_v1_create copia el feedback; finish libera nuestros
	// wlr_drm_format_set (no volver a llamar wlr_drm_format_set_finish: double free).
	s->linux_dmabuf = wlr_linux_dmabuf_v1_create(s->display, 4, &feedback);
	wlr_linux_dmabuf_feedback_v1_finish(&feedback);
	if (s->linux_dmabuf == NULL) {
		s->dmabuf_reason = "wlr_linux_dmabuf_v1_create fallo";
		return;
	}
	wlr_linux_dmabuf_v1_set_check_dmabuf_callback(s->linux_dmabuf, check_dmabuf, s);

	s->dmabuf_enabled = true;
	s->dmabuf_reason = "on";

	setup_syncobj(s, node);
}

// Anuncia linux-drm-syncobj-v1 para sincronizacion explicita. Sólo si el EGL del shell
// puede esperar un fence en la GPU (EGL_ANDROID_native_fence_sync + EGL_KHR_wait_sync) y
// el render node se puede abrir; si no, queda el implicit sync de Mesa. GDTK_NO_EXPLICIT_SYNC
// fuerza el camino viejo (diagnóstico).
static void syncobj_apply(struct wl_server *s, surface_state *st) {
	struct wlr_linux_drm_syncobj_surface_v1_state *ss =
			wlr_linux_drm_syncobj_v1_get_surface_state(st->surface);
	if (ss == NULL || st->buffer == NULL) {
		return;
	}
	if (!s->syncobj_seen) {
		s->syncobj_seen = true;
		fprintf(stderr, "wl_server: explicit sync activo en un cliente\n");
	}
	// Release: se señaliza cuando soltamos este buffer (wlr_buffer.events.release), que
	// pasa al importar el próximo (surface_state_import desbloquea el anterior).
	wlr_linux_drm_syncobj_v1_state_signal_release_with_buffer(ss, st->buffer);
	// Acquire: esperar en la GPU antes de muestrear. export_sync_file exige que el punto
	// ya haya materializado; si no, seguimos con implicit sync (sin tearing en Mesa/Intel).
	if (ss->acquire_timeline != NULL) {
		int fd = wlr_drm_syncobj_timeline_export_sync_file(ss->acquire_timeline, ss->acquire_point);
		if (fd >= 0) {
			EGLint attrs[] = { EGL_SYNC_NATIVE_FENCE_FD_ANDROID, fd, EGL_NONE };
			EGLSyncKHR sync = s->eglCreateSyncKHR(s->egl_dpy, EGL_SYNC_NATIVE_FENCE_ANDROID, attrs);
			if (sync != EGL_NO_SYNC_KHR) {
				s->eglWaitSyncKHR(s->egl_dpy, sync, 0);
				s->eglDestroySyncKHR(s->egl_dpy, sync);
			} else {
				close(fd);
			}
		}
	}
}

static void handle_toplevel_set_title(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, set_title);
	if (t->added && t->server->cb.title != NULL) {
		const char *title = t->tl != NULL ? t->tl->title : t->xs->title;
		t->server->cb.title(t->server->cb.ud, t->id, title != NULL ? title : "");
	}
}

// --- Salidas logicas (multi-output) -----------------------------------------

static logical_output *output_find(struct wl_server *s, int id) {
	if (s == NULL || id <= 0) {
		return NULL;
	}
	logical_output *o;
	wl_list_for_each(o, &s->outputs, link) {
		if (o->id == id) {
			return o;
		}
	}
	return NULL;
}

static struct wlr_surface *toplevel_root_surface(toplevel *t) {
	if (t->tl != NULL && t->tl->base != NULL) {
		return t->tl->base->surface;
	}
	if (t->xs != NULL) {
		return t->xs->surface;
	}
	return NULL;
}

// Fija modo (width*scale) y escala del wlr_output. El layout usa el tamano
// efectivo del output = ancho/scale, o sea la geometria logica pedida.
static void output_commit(logical_output *o) {
	struct wlr_output_state state;
	wlr_output_state_init(&state);
	int scale = o->scale > 0 ? o->scale : 1;
	wlr_output_state_set_enabled(&state, o->enabled);
	wlr_output_state_set_custom_mode(&state, o->width * scale, o->height * scale, 60000);
	wlr_output_state_set_scale(&state, (float)scale);
	if (!wlr_output_commit_state(o->output, &state)) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo configurar la salida %d (%dx%d @%d)",
				o->id, o->width, o->height, o->scale);
	}
	wlr_output_state_finish(&state);
}

// Avisa al cliente el cambio de salida: leave de la vieja y enter de la nueva,
// recorriendo todo el arbol (subsurfaces y popups, como frame_done). Las
// wlr_surface_send_* son no-op si la surface ya estaba (o no estaba).
struct output_emit_ctx {
	struct wlr_output *output;
	bool enter;
};

static void output_emit_iter(struct wlr_surface *surface, int sx, int sy, void *data) {
	(void)sx;
	(void)sy;
	struct output_emit_ctx *ctx = data;
	if (ctx->enter) {
		wlr_surface_send_enter(surface, ctx->output);
	} else {
		wlr_surface_send_leave(surface, ctx->output);
	}
}

static void toplevel_emit_output(toplevel *t, logical_output *old_o, logical_output *new_o, bool new_enter) {
	if (toplevel_root_surface(t) == NULL) {
		return;
	}
	if (old_o != NULL) {
		struct output_emit_ctx ctx = { old_o->output, false };
		if (t->tl != NULL) {
			wlr_xdg_surface_for_each_surface(t->tl->base, output_emit_iter, &ctx);
		} else if (t->xs != NULL && t->xs->surface != NULL) {
			wlr_surface_for_each_surface(t->xs->surface, output_emit_iter, &ctx);
		}
	}
	if (new_enter && new_o != NULL) {
		struct output_emit_ctx ctx = { new_o->output, true };
		if (t->tl != NULL) {
			wlr_xdg_surface_for_each_surface(t->tl->base, output_emit_iter, &ctx);
		} else if (t->xs != NULL && t->xs->surface != NULL) {
			wlr_surface_for_each_surface(t->xs->surface, output_emit_iter, &ctx);
		}
	}
}

static void toplevel_assign_output(toplevel *t, int output_id) {
	struct wl_server *s = t->server;
	if (t->output_id == output_id) {
		return;
	}
	logical_output *old_o = output_find(s, t->output_id);
	logical_output *new_o = output_find(s, output_id);
	t->output_id = output_id;
	toplevel_emit_output(t, old_o, new_o, t->mapped);
	if (s->cb.toplevel_output_changed != NULL) {
		s->cb.toplevel_output_changed(s->cb.ud, t->id, output_id);
	}
}

static void toplevel_apply_focus(toplevel *t, bool raise) {
	struct wl_server *s = t->server;
	struct wlr_surface *surface;
	if (t->tl != NULL) {
		if (!t->tl->base->initialized) {
			return;
		}
		wlr_xdg_toplevel_set_activated(t->tl, true);
		surface = t->tl->base->surface;
	} else {
		if (t->xs->surface == NULL) {
			return;
		}
		wlr_xwayland_surface_activate(t->xs, true);
		if (raise) {
			wlr_xwayland_surface_restack(t->xs, NULL, XCB_STACK_MODE_ABOVE);
		}
		s->x_focus_id = t->id;
		surface = t->xs->surface;
	}
	if (t->mapped) {
		wlr_seat_keyboard_notify_enter(s->seat, surface,
				s->keyboard.keycodes, s->keyboard.num_keycodes, &s->keyboard.modifiers);
		text_input_relay_set_focus(s, surface);
	}
}

static void handle_toplevel_commit(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, commit);
	struct wl_server *s = t->server;

	if (t->tl->base->initial_commit) {
		// ponytail: sin este configure inicial el cliente espera para siempre y nunca mapea
		wlr_xdg_toplevel_set_size(t->tl, s->default_w, s->default_h);
		return;
	}
	// La importacion de buffers la hace el listener de commit por surface
	// (surface_state); aqui solo se resuelve el configure inicial.
}

static void handle_toplevel_map(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, map);
	t->mapped = true;
	if (!t->added) {
		t->added = true;
		if (t->server->cb.added != NULL) {
			t->server->cb.added(t->server->cb.ud, t->id);
		}
		handle_toplevel_set_title(&t->set_title, NULL);
	}
	// Anuncia la salida asignada (por defecto la principal) al mapear.
	toplevel_emit_output(t, NULL, output_find(t->server, t->output_id), true);
	if (t->want_focus) {
		toplevel_apply_focus(t, true);
	}
}

static void handle_toplevel_unmap(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, unmap);
	t->mapped = false;
	// Desmapeada: sale de su salida (no-op si nunca entro).
	toplevel_emit_output(t, output_find(t->server, t->output_id), NULL, false);
}

// El cliente pide minimizarse: xdg_toplevel.set_minimized (CSD, p.ej. GTK/LibreWolf)
// o iconify de una ventana X11. La minimización real la decide el shell (cb.minimize);
// para xdg hay que devolver un configure (aunque no cambie el estado) o es violación
// de protocolo.
static void handle_toplevel_request_minimize(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, request_minimize);
	if (t->tl != NULL) {
		// schedule_configure exige la superficie inicializada (wlroots aborta si no).
		// Antes del primer configure el estado pedido ya viaja en el configure inicial.
		if (t->tl->base->initialized) {
			wlr_xdg_surface_schedule_configure(t->tl->base);
		}
	} else {
		// Xwayland emite el evento también al des-iconificar (minimize=false): no es
		// un pedido de minimizar.
		struct wlr_xwayland_minimize_event *ev = data;
		if (ev != NULL && !ev->minimize) {
			return;
		}
	}
	if (t->server->cb.minimize != NULL) {
		t->server->cb.minimize(t->server->cb.ud, t->id);
	}
}

// El cliente pide maximizar/desmaximizar (xdg_toplevel.set_maximized o el pedido X11).
// Se confirma el estado en el configure (aunque no cambie) y se avisa al shell, que es
// quien decide el layout: en modo tiled alterna entre ocupar la pantalla entera o su
// franja partida.
static void handle_toplevel_request_maximize(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, request_maximize);
	bool maximized;
	if (t->tl != NULL) {
		maximized = t->tl->requested.maximized;
		// set_* agenda un configure internamente: aborta si la superficie no está inicializada
		if (t->tl->base->initialized) {
			wlr_xdg_toplevel_set_maximized(t->tl, maximized);
			wlr_xdg_surface_schedule_configure(t->tl->base);
		}
	} else {
		maximized = t->xs->maximized_horz || t->xs->maximized_vert;
		wlr_xwayland_surface_set_maximized(t->xs, maximized, maximized);
	}
	if (t->server->cb.maximize != NULL) {
		t->server->cb.maximize(t->server->cb.ud, t->id, maximized ? 1 : 0);
	}
}

// El cliente pide pantalla completa (video de YouTube, etc.). Se confirma el estado y
// se avisa al shell, que ocupa todo el viewport con esa ventana (fullscreen_id).
static void handle_toplevel_request_fullscreen(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, request_fullscreen);
	bool fullscreen;
	if (t->tl != NULL) {
		fullscreen = t->tl->requested.fullscreen;
		// set_* agenda un configure internamente: aborta si la superficie no está inicializada
		if (t->tl->base->initialized) {
			wlr_xdg_toplevel_set_fullscreen(t->tl, fullscreen);
			wlr_xdg_surface_schedule_configure(t->tl->base);
		}
	} else {
		fullscreen = t->xs->fullscreen;
		wlr_xwayland_surface_set_fullscreen(t->xs, fullscreen);
	}
	if (t->server->cb.fullscreen != NULL) {
		t->server->cb.fullscreen(t->server->cb.ud, t->id, fullscreen ? 1 : 0);
	}
}

// El cliente pide mover su ventana (xdg_toplevel.move): arrastre de su barra CSD.
// El compositor no mueve nada: avisa al shell, que hace el arrastre interactivo.
static void handle_toplevel_request_move(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, request_move);
	if (t->server->cb.move != NULL) {
		t->server->cb.move(t->server->cb.ud, t->id);
	}
}

// El cliente pide redimensionar por un borde (xdg_toplevel.resize). Se pasa el
// bitfield de bordes tal cual; el shell arma el rect nuevo y llama set_size.
static void handle_toplevel_request_resize(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, request_resize);
	struct wlr_xdg_toplevel_resize_event *ev = data;
	if (t->server->cb.resize != NULL) {
		t->server->cb.resize(t->server->cb.ud, t->id, (int)ev->edges);
	}
}

static void toplevel_unlink(toplevel *t) {
	struct wl_listener *all[] = { &t->commit, &t->map, &t->unmap, &t->destroy, &t->set_title,
		&t->request_minimize, &t->request_maximize, &t->request_fullscreen,
		&t->request_move, &t->request_resize,
		&t->associate, &t->dissociate, &t->request_configure };
	for (size_t i = 0; i < sizeof(all) / sizeof(all[0]); i++) {
		wl_list_remove(&all[i]->link);
		wl_list_init(&all[i]->link);
	}
	wl_list_remove(&t->link);
}

static void xsurface_orphan(struct wl_server *s, struct wlr_surface *surface);

static void handle_toplevel_destroy(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, destroy);
	struct wl_server *s = t->server;

	toplevel_unlink(t);
	bool added = t->added;
	if (t->xs != NULL) {
		xsurface_orphan(s, t->xs->surface);
	}

	if (s->pointer_id == t->id) {
		s->pointer_id = 0;
		s->pointer_surface = NULL;
	}

	if (s->x_focus_id == t->id) {
		s->x_focus_id = 0;
	}
	int id = t->id;
	free(t);

	if (added && s->cb.removed != NULL) {
		s->cb.removed(s->cb.ud, id);
	}
}

// Popups (tooltips, menús): sólo se configuran, no se dibujan todavía.
// Sin el configure inicial GTK4 espera el popup para siempre y su frame clock
// (compartido con la ventana) congela también la ventana principal.
// Popups (tooltips, menus): se configuran en su commit inicial y se dibujan
// como una capa mas via wl_server_layers (wlr_xdg_surface_for_each_surface).
// Sin el configure inicial GTK4 espera el popup para siempre y su frame clock
// (compartido con la ventana) congela tambien la ventana principal.
typedef struct popup {
	struct wl_server *s;
	struct wlr_xdg_popup *p;
	struct wl_listener commit;
	struct wl_listener reposition;
	struct wl_listener destroy;
} popup;

// Reubica el popup dentro de lo visible (reglas del xdg_positioner). La caja va en coords
// de la surface raíz del toplevel: el contenido visible arranca en su geometry (las sombras
// CSD quedan fuera) y mide lo que la vista (default_w x default_h).
static toplevel *toplevel_find_xdg(struct wl_server *s, struct wlr_xdg_toplevel *tl);

static void popup_unconstrain(popup *pp) {
	struct wlr_xdg_surface *xs = wlr_xdg_surface_try_from_wlr_surface(pp->p->parent);
	while (xs != NULL && xs->role == WLR_XDG_SURFACE_ROLE_POPUP && xs->popup != NULL) {
		xs = wlr_xdg_surface_try_from_wlr_surface(xs->popup->parent);
	}
	if (xs == NULL || xs->role != WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
		return;
	}
	struct wlr_box box = { xs->geometry.x, xs->geometry.y, pp->s->default_w, pp->s->default_h };
	toplevel *t = toplevel_find_xdg(pp->s, xs->toplevel);
	if (t != NULL && t->has_popup_bounds) {
		box = t->popup_bounds;
	}
	wlr_xdg_popup_unconstrain_from_box(pp->p, &box);
}

static void handle_popup_commit(struct wl_listener *listener, void *data) {
	popup *pp = wl_container_of(listener, pp, commit);
	if (pp->p->base->initial_commit) {
		popup_unconstrain(pp);
		wlr_xdg_surface_schedule_configure(pp->p->base);
	}
}

static void handle_popup_reposition(struct wl_listener *listener, void *data) {
	popup *pp = wl_container_of(listener, pp, reposition);
	popup_unconstrain(pp);
}

static void handle_popup_destroy(struct wl_listener *listener, void *data) {
	popup *pp = wl_container_of(listener, pp, destroy);
	surface_state *st = surface_state_find(pp->s, pp->p->base->surface);
	if (st != NULL && st->id > 0 && pp->s->cb.damage != NULL) {
		pp->s->cb.damage(pp->s->cb.ud, st->id);
	}
	wl_list_remove(&pp->commit.link);
	wl_list_remove(&pp->reposition.link);
	wl_list_remove(&pp->destroy.link);
	free(pp);
}

static void handle_new_popup(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_popup);
	struct wlr_xdg_popup *p = data;
	popup *pp = calloc(1, sizeof(*pp));
	if (pp == NULL) {
		return;
	}
	pp->s = s;
	pp->p = p;
	pp->commit.notify = handle_popup_commit;
	wl_signal_add(&p->base->surface->events.commit, &pp->commit);
	pp->reposition.notify = handle_popup_reposition;
	wl_signal_add(&p->events.reposition, &pp->reposition);
	pp->destroy.notify = handle_popup_destroy;
	wl_signal_add(&p->events.destroy, &pp->destroy);

	// El popup pertenece al toplevel de su surface padre: hereda el id para
	// que sus buffers se agrupen como una capa mas de ese toplevel.
	if (surface_state_find(s, p->base->surface) == NULL) {
		int id = 0;
		surface_state *parent = surface_state_find(s, p->parent);
		if (parent != NULL) {
			id = parent->id;
		} else if (p->parent != NULL) {
			toplevel *t = toplevel_find_surface(s, wlr_surface_get_root_surface(p->parent));
			if (t != NULL) {
				id = t->id;
			}
		}
		surface_state_acquire(s, p->base->surface, id);
		// El popup es un menu del cliente sobre la ventana: apartar ya el scanout para
		// que la ventana (reimportada) quede debajo y el menu se vea al commitear.
		if (id > 0) {
			surface_state *root = scanout_state_for_id(s, id);
			if (root != NULL) {
				scanout_off_reimport(s, root);
			}
		}
	}
}

static void handle_new_toplevel(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_toplevel);
	struct wlr_xdg_toplevel *tl = data;

	toplevel *t = calloc(1, sizeof(*t));
	if (t == NULL) {
		return;
	}
	t->server = s;
	t->tl = tl;
	t->id = s->next_id++;
	t->mapped = false;
	t->added = true;
	// Salida por defecto: la principal (el shell puede reasignarla).
	t->output_id = s->primary_output_id;
	wl_list_init(&t->associate.link);
	wl_list_init(&t->dissociate.link);
	wl_list_init(&t->request_configure.link);

	struct wlr_surface *surface = tl->base->surface;

	t->commit.notify = handle_toplevel_commit;
	wl_signal_add(&surface->events.commit, &t->commit);
	t->map.notify = handle_toplevel_map;
	wl_signal_add(&surface->events.map, &t->map);
	t->unmap.notify = handle_toplevel_unmap;
	wl_signal_add(&surface->events.unmap, &t->unmap);
	t->destroy.notify = handle_toplevel_destroy;
	wl_signal_add(&tl->events.destroy, &t->destroy);
	t->set_title.notify = handle_toplevel_set_title;
	wl_signal_add(&tl->events.set_title, &t->set_title);
	t->request_minimize.notify = handle_toplevel_request_minimize;
	wl_signal_add(&tl->events.request_minimize, &t->request_minimize);
	t->request_maximize.notify = handle_toplevel_request_maximize;
	wl_signal_add(&tl->events.request_maximize, &t->request_maximize);
	t->request_fullscreen.notify = handle_toplevel_request_fullscreen;
	wl_signal_add(&tl->events.request_fullscreen, &t->request_fullscreen);
	t->request_move.notify = handle_toplevel_request_move;
	wl_signal_add(&tl->events.request_move, &t->request_move);
	t->request_resize.notify = handle_toplevel_request_resize;
	wl_signal_add(&tl->events.request_resize, &t->request_resize);
	// Sin xdg-decoration negociado, el protocolo asume decoración del cliente (CSD):
	// se dibuja el chrome sólo si un decoration object negocia SERVER_SIDE.
	t->csd = true;

	wl_list_insert(s->toplevels.prev, &t->link);

	// Estado de la surface raiz; las subsurfaces se descubren por el signal
	// new_subsurface de cada surface. Los buffers se importan en su commit.
	surface_state_acquire(s, surface, t->id);

	if (s->cb.added != NULL) {
		s->cb.added(s->cb.ud, t->id);
	}
}

// Decoraciones: respetamos lo que pide el cliente para no duplicar decoración.
//   - CLIENT_SIDE: el cliente dibuja su propia barra -> csd=true y el shell NO le
//     pinta chrome encima (antes se forzaba SERVER_SIDE y quedaban las dos).
//   - SERVER_SIDE o sin preferencia: el chrome OpenStep lo dibuja el shell
//     (csd=false), así alacritty/SDL/Qt no dibujan su propia barra.
// El arrastre en CSD llega por request_move/request_resize.
typedef struct decoration {
	struct wl_server *s;
	struct wlr_xdg_toplevel *tl;
	struct wlr_xdg_toplevel_decoration_v1 *d;
	struct wl_listener request_mode;
	struct wl_listener commit;
	struct wl_listener destroy;
} decoration;

static toplevel *toplevel_find_xdg(struct wl_server *s, struct wlr_xdg_toplevel *tl) {
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if (t->tl == tl) {
			return t;
		}
	}
	return NULL;
}

// El modo efectivo decide si el cliente se decora solo. Mientras el configure no
// se confirme (current.mode aún 0) usamos lo que pidió el cliente, para no pintar
// chrome sobre una ventana que ya está dibujando su CSD (doble decoración).
static void decoration_sync_csd(decoration *dd) {
	toplevel *t = toplevel_find_xdg(dd->s, dd->tl);
	if (t == NULL) {
		return;
	}
	enum wlr_xdg_toplevel_decoration_v1_mode mode = dd->d->current.mode;
	if (mode == WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE) {
		t->csd = true;
	} else if (mode == WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE) {
		t->csd = false;
	} else {
		t->csd = (dd->d->requested_mode == WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
	}
}

// Respetamos la decoración pedida: CLIENT_SIDE se confirma como CLIENT_SIDE (el
// cliente sigue con su barra), el resto va a SERVER_SIDE (chrome del shell). No
// tocamos nada antes del commit inicial (base sin inicializar): wlroots aborta.
// Se llama en cada commit, pero sólo manda set_mode si el modo deseado no está ya
// fijado: wlr_xdg_toplevel_decoration_v1_set_mode agenda un configure cada vez que
// se lo llama, así que repetirlo por commit sería una tormenta de configures.
static void decoration_apply(decoration *dd) {
	if (!dd->d->toplevel->base->initialized) {
		return;
	}
	enum wlr_xdg_toplevel_decoration_v1_mode want =
		(dd->d->requested_mode == WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE)
		? WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE
		: WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE;
	if (dd->d->current.mode != want && dd->d->pending.mode != want) {
		wlr_xdg_toplevel_decoration_v1_set_mode(dd->d, want);
	}
	decoration_sync_csd(dd);
}

static void handle_decoration_request_mode(struct wl_listener *listener, void *data) {
	decoration *dd = wl_container_of(listener, dd, request_mode);
	decoration_apply(dd);
}

static void handle_decoration_commit(struct wl_listener *listener, void *data) {
	decoration *dd = wl_container_of(listener, dd, commit);
	// set_mode agenda un configure: sólo válido desde el commit inicial en adelante.
	// Reintentamos en cada commit porque el request_mode suele llegar ANTES del
	// commit inicial (base aún sin inicializar) y antes no se podía fijar.
	decoration_apply(dd);
	decoration_sync_csd(dd);
}

static void handle_decoration_destroy(struct wl_listener *listener, void *data) {
	decoration *dd = wl_container_of(listener, dd, destroy);
	// Sin objeto, el protocolo vuelve al default client-side.
	toplevel *t = toplevel_find_xdg(dd->s, dd->tl);
	if (t != NULL) {
		t->csd = true;
	}
	wl_list_remove(&dd->request_mode.link);
	wl_list_remove(&dd->commit.link);
	wl_list_remove(&dd->destroy.link);
	free(dd);
}

static void handle_new_decoration(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_decoration);
	struct wlr_xdg_toplevel_decoration_v1 *d = data;
	decoration *dd = calloc(1, sizeof(*dd));
	if (dd == NULL) {
		return;
	}
	dd->s = s;
	dd->tl = d->toplevel;
	dd->d = d;
	dd->request_mode.notify = handle_decoration_request_mode;
	wl_signal_add(&d->events.request_mode, &dd->request_mode);
	dd->commit.notify = handle_decoration_commit;
	wl_signal_add(&d->toplevel->base->surface->events.commit, &dd->commit);
	dd->destroy.notify = handle_decoration_destroy;
	wl_signal_add(&d->events.destroy, &dd->destroy);
	decoration_apply(dd);
}

// --- wlr-layer-shell: notificaciones, OSDs, docks. El shell las dibuja encima de todo en
// su rect (ancla + márgenes sobre la vista). ponytail: sin exclusive zone ni foco de
// teclado (keyboard_interactivity); alcanza para notificaciones.
typedef struct layer_surf {
	struct wl_list link;
	struct wl_server *s;
	int id;
	struct wlr_layer_surface_v1 *ls;
	bool mapped;
	int x, y, w, h;
	struct wl_listener commit;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener destroy;
} layer_surf;

static layer_surf *layer_find(struct wl_server *s, int id) {
	layer_surf *l;
	wl_list_for_each(l, &s->layers, link) {
		if (l->id == id) {
			return l;
		}
	}
	return NULL;
}

// Tamaño y posición según ancla y márgenes; reconfigura si cambió el tamaño.
static void layer_arrange(layer_surf *l, bool force) {
	struct wl_server *s = l->s;
	struct wlr_layer_surface_v1_state *st = &l->ls->current;
	int W = s->default_w, H = s->default_h;
	bool left = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
	bool right = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
	bool top = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
	bool bottom = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
	int w = st->desired_width > 0 ? (int)st->desired_width : W - st->margin.left - st->margin.right;
	int h = st->desired_height > 0 ? (int)st->desired_height : H - st->margin.top - st->margin.bottom;
	if (w < 1) {
		w = 1;
	}
	if (h < 1) {
		h = 1;
	}
	// Ancla a un solo lado: pegado a ese borde; a ambos o ninguno: centrado entre márgenes.
	if (left == right) {
		l->x = st->margin.left + (W - st->margin.left - st->margin.right - w) / 2;
	} else {
		l->x = left ? st->margin.left : W - w - st->margin.right;
	}
	if (top == bottom) {
		l->y = st->margin.top + (H - st->margin.top - st->margin.bottom - h) / 2;
	} else {
		l->y = top ? st->margin.top : H - h - st->margin.bottom;
	}
	if (force || w != l->w || h != l->h) {
		l->w = w;
		l->h = h;
		wlr_layer_surface_v1_configure(l->ls, (uint32_t)w, (uint32_t)h);
	}
}

static void handle_layer_commit(struct wl_listener *listener, void *data) {
	layer_surf *l = wl_container_of(listener, l, commit);
	if (l->ls->initialized) {
		layer_arrange(l, l->ls->initial_commit);
	}
}

static void handle_layer_map(struct wl_listener *listener, void *data) {
	layer_surf *l = wl_container_of(listener, l, map);
	l->mapped = true;
	if (l->s->cb.layer != NULL) {
		l->s->cb.layer(l->s->cb.ud, l->id, 1);
	}
}

static void handle_layer_unmap(struct wl_listener *listener, void *data) {
	layer_surf *l = wl_container_of(listener, l, unmap);
	l->mapped = false;
	if (l->s->cb.layer != NULL) {
		l->s->cb.layer(l->s->cb.ud, l->id, 0);
	}
}

static void layer_free(layer_surf *l) {
	wl_list_remove(&l->commit.link);
	wl_list_remove(&l->map.link);
	wl_list_remove(&l->unmap.link);
	wl_list_remove(&l->destroy.link);
	wl_list_remove(&l->link);
	free(l);
}

static void handle_layer_destroy(struct wl_listener *listener, void *data) {
	layer_surf *l = wl_container_of(listener, l, destroy);
	struct wl_server *s = l->s;
	int id = l->id;
	if (s->pointer_id == id) {
		s->pointer_id = 0;
		s->pointer_surface = NULL;
	}
	layer_free(l);
	if (s->cb.layer != NULL) {
		s->cb.layer(s->cb.ud, id, -1);
	}
}

static void handle_new_layer(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_layer);
	struct wlr_layer_surface_v1 *ls = data;
	if (ls->output == NULL) {
		if (s->output == NULL) {
			wlr_layer_surface_v1_destroy(ls);
			return;
		}
		ls->output = s->output;
	}
	layer_surf *l = calloc(1, sizeof(*l));
	if (l == NULL) {
		wlr_layer_surface_v1_destroy(ls);
		return;
	}
	l->s = s;
	l->ls = ls;
	// Mismo espacio de ids que los toplevels: las texturas se guardan igual en C++.
	l->id = s->next_id++;
	l->commit.notify = handle_layer_commit;
	wl_signal_add(&ls->surface->events.commit, &l->commit);
	l->map.notify = handle_layer_map;
	wl_signal_add(&ls->surface->events.map, &l->map);
	l->unmap.notify = handle_layer_unmap;
	wl_signal_add(&ls->surface->events.unmap, &l->unmap);
	l->destroy.notify = handle_layer_destroy;
	wl_signal_add(&ls->events.destroy, &l->destroy);
	wl_list_insert(s->layers.prev, &l->link);
	surface_state_acquire(s, ls->surface, l->id);
}

// xdg-activation: sin validar el token (cualquier cliente puede pedir el frente).
static void handle_request_activate(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, request_activate);
	struct wlr_xdg_activation_v1_request_activate_event *ev = data;
	toplevel *t = toplevel_find_surface(s, ev->surface);
	if (t != NULL && s->cb.activate != NULL) {
		s->cb.activate(s->cb.ud, t->id);
	}
}

// Portapapeles: wlroots sólo cambia la selección si el compositor acepta el pedido.
static void handle_request_set_selection(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, request_set_selection);
	struct wlr_seat_request_set_selection_event *ev = data;
	wlr_seat_set_selection(s->seat, ev->source, ev->serial);
}

static void handle_request_set_primary_selection(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, request_set_primary_selection);
	struct wlr_seat_request_set_primary_selection_event *ev = data;
	wlr_seat_set_primary_selection(s->seat, ev->source, ev->serial);
}

// Cursor del cliente con foco (wl_pointer.set_cursor): surface NULL = ocultar.
// No se instala el cursor del cliente (el shell dibuja el suyo); solo se refleja
// el pedido de ocultarlo para que el shell oculte/restaure su cursor dibujado.
static void notify_client_cursor_hidden(struct wl_server *s, int hidden) {
	if (s->client_cursor_hidden == hidden) {
		return;
	}
	s->client_cursor_hidden = hidden;
	if (s->cb.cursor_hidden != NULL) {
		s->cb.cursor_hidden(s->cb.ud, hidden);
	}
}

// Surface de cursor del cliente: se suelta al cambiar el cursor/foco o al destruirse.
static void cursor_surface_drop(struct wl_server *s) {
	if (s->cursor_surface == NULL) {
		return;
	}
	wl_list_remove(&s->cursor_commit.link);
	wl_list_remove(&s->cursor_destroy.link);
	s->cursor_surface = NULL;
}

// Lee el buffer shm actual de la surface de cursor y se lo da al shell. Buffers no
// accesibles desde CPU (dmabuf) o > 256 px se ignoran: queda el cursor anterior.
static void cursor_surface_import(struct wl_server *s) {
	struct wlr_buffer *buf = s->cursor_surface->current.buffer;
	if (s->cb.cursor_image == NULL || buf == NULL || buf->width > 256 || buf->height > 256) {
		return;
	}
	void *ptr = NULL;
	uint32_t format = 0;
	size_t stride = 0;
	if (!wlr_buffer_begin_data_ptr_access(buf, WLR_BUFFER_DATA_PTR_ACCESS_READ,
			&ptr, &format, &stride)) {
		return;
	}
	s->cb.cursor_image(s->cb.ud, (const unsigned char *)ptr, buf->width, buf->height, format,
			(int)stride, s->cursor_hx - s->cursor_surface->current.dx,
			s->cursor_hy - s->cursor_surface->current.dy);
	wlr_buffer_end_data_ptr_access(buf);
}

static void handle_cursor_commit(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, cursor_commit);
	cursor_surface_import(s);
	// Cursores animados esperan el frame callback para el siguiente cuadro.
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	wlr_surface_send_frame_done(s->cursor_surface, &now);
}

static void handle_cursor_destroy(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, cursor_destroy);
	cursor_surface_drop(s);
}

static void notify_client_cursor_shape(struct wl_server *s, int shape) {
	if (s->cb.cursor_shape != NULL) {
		s->cb.cursor_shape(s->cb.ud, shape);
	}
}

// Cambio de foco de puntero: el cursor del cliente anterior no se hereda; el
// shell vuelve a su cursor (ARROW) hasta que el nuevo cliente pida otro.
static void client_cursor_reset(struct wl_server *s) {
	cursor_surface_drop(s);
	notify_client_cursor_hidden(s, 0);
	notify_client_cursor_shape(s, 0);
}

static void handle_request_set_cursor(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, request_set_cursor);
	struct wlr_seat_pointer_request_set_cursor_event *ev = data;
	// Solo el cliente con foco puede mandar cursor; el resto se ignora.
	if (ev->seat_client != s->seat->pointer_state.focused_client) {
		return;
	}
	notify_client_cursor_hidden(s, ev->surface == NULL);
	if (ev->surface == NULL) {
		cursor_surface_drop(s);
		return;
	}
	s->cursor_hx = ev->hotspot_x;
	s->cursor_hy = ev->hotspot_y;
	if (s->cursor_surface != ev->surface) {
		cursor_surface_drop(s);
		s->cursor_surface = ev->surface;
		s->cursor_commit.notify = handle_cursor_commit;
		wl_signal_add(&ev->surface->events.commit, &s->cursor_commit);
		s->cursor_destroy.notify = handle_cursor_destroy;
		wl_signal_add(&ev->surface->events.destroy, &s->cursor_destroy);
	}
	cursor_surface_import(s);
}

// wp_cursor_shape_v1 (enum de Godot = Input::CursorShape).
static int cursor_shape_to_godot(enum wp_cursor_shape_device_v1_shape shape) {
	switch (shape) {
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_VERTICAL_TEXT: return 1; // IBEAM
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER: return 2; // POINTING_HAND
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CROSSHAIR:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CELL:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ZOOM_IN:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ZOOM_OUT: return 3; // CROSS
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_WAIT: return 4; // WAIT (bloquea la app)
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_PROGRESS: return 5; // BUSY (app usable)
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRAB:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRABBING: return 6; // DRAG
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COPY:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALIAS: return 7; // CAN_DROP
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NOT_ALLOWED:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NO_DROP: return 8; // FORBIDDEN
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_N_RESIZE:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_S_RESIZE:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ROW_RESIZE: return 9; // VSIZE
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_E_RESIZE:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_W_RESIZE:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COL_RESIZE: return 10; // HSIZE
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NE_RESIZE:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SW_RESIZE:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NESW_RESIZE: return 11; // BDIAGSIZE
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NW_RESIZE:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SE_RESIZE:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NWSE_RESIZE: return 12; // FDIAGSIZE
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_MOVE:
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALL_SCROLL: return 13; // MOVE
	case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_HELP: return 16; // HELP
	default: return 0; // DEFAULT, CONTEXT_MENU, ...: ARROW
	}
}

static void handle_request_cursor_shape(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, request_cursor_shape);
	struct wlr_cursor_shape_manager_v1_request_set_shape_event *ev = data;
	if (ev->device_type != WLR_CURSOR_SHAPE_MANAGER_V1_DEVICE_TYPE_POINTER
			|| ev->seat_client != s->seat->pointer_state.focused_client) {
		return;
	}
	cursor_surface_drop(s); // la forma reemplaza a un cursor por surface previo
	notify_client_cursor_hidden(s, 0);
	notify_client_cursor_shape(s, cursor_shape_to_godot(ev->shape));
}

// --- Drag and drop nativo (wl_data_device) ---
// El cliente pide iniciar el drag; wlroots no lo arranca solo: hay que validar el
// serial del puntero (o touch) y llamar a wlr_seat_start_*_drag. Si no valida, se
// destruye el data source y el drag no ocurre. En start_drag se registra el drag
// (para restaurar el foco de puntero al terminar) y su icono, si lo hay. Ojo: el
// icono NO existe necesariamente en start_drag (GTK4 lo manda por set_icon
// despues) ni su buffer; por eso el watch se re-sincroniza en cada motion
// (drag_icon_sync) y el buffer se reimporta en cada commit del surface.
struct drag_icon_watch {
	struct wl_server *server;
	struct wlr_drag_icon *icon;
	struct wlr_surface *surface;
	struct wl_listener commit;
	struct wl_listener destroy;
};

static void handle_drag_icon_import(struct drag_icon_watch *w) {
	struct wl_server *s = w->server;
	if (s->cb.drag_icon == NULL || w->surface == NULL) {
		return;
	}
	struct wlr_buffer *buf = w->surface->current.buffer;
	if (buf == NULL) {
		return;
	}
	void *ptr = NULL;
	uint32_t format = 0;
	size_t stride = 0;
	// Solo los buffers accesibles desde CPU (wl_shm) se pueden leer. Con dmabuf/GL
	// begin_data_ptr_access falla: no se manda textura y el shell dibuja su
	// placeholder mientras drag_state siga activo (siempre hay feedback visual).
	if (!wlr_buffer_begin_data_ptr_access(buf, WLR_BUFFER_DATA_PTR_ACCESS_READ,
			&ptr, &format, &stride)) {
		return;
	}
	// `dx`/`dy` = offset del attach/offset del surface: top-left del icono en
	// puntero+(dx,dy). Se lee al importar porque cambia con cada commit.
	s->cb.drag_icon(s->cb.ud, (const unsigned char *)ptr, buf->width, buf->height,
			format, (int)stride, w->surface->current.dx, w->surface->current.dy);
	wlr_buffer_end_data_ptr_access(buf);
}

static void handle_drag_icon_commit(struct wl_listener *listener, void *data) {
	struct drag_icon_watch *w = wl_container_of(listener, w, commit);
	handle_drag_icon_import(w);
}

static void handle_drag_icon_destroy(struct wl_listener *listener, void *data) {
	struct drag_icon_watch *w = wl_container_of(listener, w, destroy);
	struct wl_server *s = w->server;
	wl_list_remove(&w->commit.link);
	wl_list_remove(&w->destroy.link);
	if (s->drag_icon == w) {
		s->drag_icon = NULL;
		if (s->cb.drag_icon != NULL) {
			s->cb.drag_icon(s->cb.ud, NULL, 0, 0, 0, 0, 0, 0);
		}
	}
	free(w);
}

// Suelta el watch activo. `notify`=1 avisa al shell que borre la textura (fin del
// icono); 0 cuando se reemplaza por otro sin parpadeo.
static void drag_icon_watch_drop(struct wl_server *s, int notify) {
	struct drag_icon_watch *w = s->drag_icon;
	if (w == NULL) {
		return;
	}
	s->drag_icon = NULL;
	wl_list_remove(&w->commit.link);
	wl_list_remove(&w->destroy.link);
	free(w);
	if (notify && s->cb.drag_icon != NULL) {
		s->cb.drag_icon(s->cb.ud, NULL, 0, 0, 0, 0, 0, 0);
	}
}

// Re-sincroniza el icono del drag en curso: wlroots lo expone en drag->icon, que
// puede aparecer despues de start_drag (set_icon) o cambiar de surface durante el
// drag. Si aparece uno nuevo se enganchan sus listeners y se importa su buffer.
// Se llama desde start_drag y desde cada motion/button (barato: compara punteros).
static void drag_icon_sync(struct wl_server *s) {
	if (s == NULL) {
		return;
	}
	struct wlr_drag_icon *icon = (s->drag != NULL) ? s->drag->icon : NULL;
	struct wlr_surface *surface = (icon != NULL) ? icon->surface : NULL;
	if (surface == NULL) {
		// Todavia sin icono: el shell mantiene su placeholder. Si teniamos uno
		// viejo (surface destruida), soltarlo avisando.
		drag_icon_watch_drop(s, 1);
		return;
	}
	if (s->drag_icon != NULL && s->drag_icon->icon == icon
			&& s->drag_icon->surface == surface) {
		handle_drag_icon_import(s->drag_icon);
		return;
	}
	// Icono nuevo/distinto: reemplazar sin notificar (evita parpadeo) y enganchar.
	drag_icon_watch_drop(s, 0);
	struct drag_icon_watch *w = calloc(1, sizeof(*w));
	if (w == NULL) {
		return;
	}
	w->server = s;
	w->icon = icon;
	w->surface = surface;
	w->commit.notify = handle_drag_icon_commit;
	wl_signal_add(&surface->events.commit, &w->commit);
	w->destroy.notify = handle_drag_icon_destroy;
	wl_signal_add(&icon->events.destroy, &w->destroy);
	s->drag_icon = w;
	handle_drag_icon_import(w);
}

static void handle_drag_destroy(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, drag_destroy);
	wl_list_remove(&s->drag_destroy.link);
	s->drag = NULL;
	drag_icon_watch_drop(s, 1);
	// El grab de drag ya se solto. Invalidar el cache: la proxima motion del
	// shell vuelve a hacer notify_enter y el cliente bajo el cursor recupera el
	// foco del puntero.
	s->pointer_surface = NULL;
	s->pointer_id = 0;
	if (s->cb.drag_state != NULL) {
		s->cb.drag_state(s->cb.ud, 0);
	}
}

static void handle_start_drag(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, start_drag);
	struct wlr_drag *drag = data;
	s->drag = drag;
	s->drag_destroy.notify = handle_drag_destroy;
	wl_signal_add(&drag->events.destroy, &s->drag_destroy);
	// wlr_seat_start_pointer_drag ya limpio el foco del wl_pointer: el shell cree
	// que el cursor sigue sobre `pointer_surface`, hay que invalidarlo para que
	// reenvie un notify_enter en la proxima motion.
	s->pointer_surface = NULL;
	s->pointer_id = 0;
	// Engancha el icono si ya existe en start_drag; si no, drag_icon_sync lo
	// recogera en la primera motion tras el set_icon del cliente.
	drag_icon_sync(s);
	if (s->cb.drag_state != NULL) {
		s->cb.drag_state(s->cb.ud, 1);
	}
}

static void handle_request_start_drag(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, request_start_drag);
	struct wlr_seat_request_start_drag_event *ev = data;
	if (wlr_seat_validate_pointer_grab_serial(s->seat, ev->origin, ev->serial)) {
		wlr_seat_start_pointer_drag(s->seat, ev->drag, ev->serial);
		return;
	}
	struct wlr_touch_point *point = NULL;
	if (wlr_seat_validate_touch_grab_serial(s->seat, ev->origin, ev->serial, &point)) {
		wlr_seat_start_touch_drag(s->seat, ev->drag, ev->serial, point);
		return;
	}
	if (ev->drag->source != NULL) {
		wlr_data_source_destroy(ev->drag->source);
	}
}

// --- Xwayland (perezoso: el X arranca con el primer cliente X). Las ventanas X normales
// van en 0,0 del root con el tamaño de la vista, como las xdg; los diálogos, centrados
// (así los ve el shell); los override-redirect son capas de su dueño.
// ponytail: sin decoraciones, sin mover/redimensionar por el cliente, sin ventanas X
// fuera de la vista.

static toplevel *toplevel_find_xs(struct wl_server *s, struct wlr_xwayland_surface *xs) {
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if (t->xs == xs) {
			return t;
		}
	}
	return NULL;
}

// Hit-test de una ventana X: primero sus menús (arriba), después la ventana.
static struct wlr_surface *xwayland_surface_at(toplevel *t, double x, double y, double *sx, double *sy) {
	xor_surf *o;
	wl_list_for_each_reverse(o, &t->server->xors, link) {
		if (o->mapped && o->owner == t->id && o->xs->surface != NULL) {
			double ox = x - (o->xs->x - t->xs->x);
			double oy = y - (o->xs->y - t->xs->y);
			struct wlr_surface *hit = wlr_surface_surface_at(o->xs->surface, ox, oy, sx, sy);
			if (hit != NULL) {
				return hit;
			}
		}
	}
	return t->xs->surface != NULL ? wlr_surface_surface_at(t->xs->surface, x, y, sx, sy) : NULL;
}

// Normales: toda la vista en 0,0. Diálogos (con padre): su tamaño, centrados.
static void xtoplevel_configure(toplevel *t, int w, int h) {
	struct wl_server *s = t->server;

	if (t->xs->parent == NULL) {
		wlr_xwayland_surface_configure(t->xs, 0, 0, (uint16_t)s->default_w, (uint16_t)s->default_h);
		return;
	}
	if (w <= 0 || h <= 0) {
		w = t->xs->width > 0 ? t->xs->width : s->default_w / 2;
		h = t->xs->height > 0 ? t->xs->height : s->default_h / 2;
	}
	wlr_xwayland_surface_configure(t->xs, (int16_t)((s->default_w - w) / 2),
			(int16_t)((s->default_h - h) / 2), (uint16_t)w, (uint16_t)h);
}

// Antes de asociar la surface el padre (WM_TRANSIENT_FOR) puede no estar leído: se
// concede lo pedido y la política se aplica al asociar.
static void handle_xtoplevel_request_configure(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, request_configure);
	struct wlr_xwayland_surface_configure_event *ev = data;
	if (t->xs->surface == NULL) {
		wlr_xwayland_surface_configure(t->xs, ev->x, ev->y, ev->width, ev->height);
		return;
	}
	xtoplevel_configure(t, ev->width, ev->height);
}

static void handle_xtoplevel_associate(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, associate);
	struct wlr_surface *surface = t->xs->surface;
	wl_signal_add(&surface->events.map, &t->map);
	wl_signal_add(&surface->events.unmap, &t->unmap);
	if (surface_state_find(t->server, surface) == NULL) {
		surface_state_acquire(t->server, surface, t->id);
	}
	xtoplevel_configure(t, 0, 0);
	if (surface->mapped) {
		handle_toplevel_map(&t->map, NULL);
	}
}

// La wl_surface de Xwayland puede sobrevivir a la ventana X: sus commits ya no son de nadie.
static void xsurface_orphan(struct wl_server *s, struct wlr_surface *surface) {
	surface_state *st = surface != NULL ? surface_state_find(s, surface) : NULL;
	if (st != NULL) {
		st->id = 0;
	}
}

static void handle_xtoplevel_dissociate(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, dissociate);
	xsurface_orphan(t->server, t->xs->surface);
	wl_list_remove(&t->map.link);
	wl_list_init(&t->map.link);
	wl_list_remove(&t->unmap.link);
	wl_list_init(&t->unmap.link);
	t->mapped = false;
}

static void handle_xor_map(struct wl_listener *listener, void *data);

static void handle_xor_associate(struct wl_listener *listener, void *data) {
	xor_surf *o = wl_container_of(listener, o, associate);
	wl_signal_add(&o->xs->surface->events.map, &o->map);
	wl_signal_add(&o->xs->surface->events.unmap, &o->unmap);
	if (o->xs->surface->mapped) {
		handle_xor_map(&o->map, NULL);
	}
}

static void handle_xor_dissociate(struct wl_listener *listener, void *data) {
	xor_surf *o = wl_container_of(listener, o, dissociate);
	xsurface_orphan(o->server, o->xs->surface);
	wl_list_remove(&o->map.link);
	wl_list_init(&o->map.link);
	wl_list_remove(&o->unmap.link);
	wl_list_init(&o->unmap.link);
	o->mapped = false;
}

// Dueño: la ventana X padre si la hay; si no, la última ventana X enfocada.
static void handle_xor_map(struct wl_listener *listener, void *data) {
	xor_surf *o = wl_container_of(listener, o, map);
	struct wl_server *s = o->server;
	toplevel *p = NULL;
	for (struct wlr_xwayland_surface *x = o->xs->parent; x != NULL && p == NULL; x = x->parent) {
		p = toplevel_find_xs(s, x);
	}
	o->owner = p != NULL ? p->id : s->x_focus_id;
	o->mapped = true;
	// El map llega dentro del commit del primer buffer: se importa ya (un menú quieto no
	// vuelve a commitear).
	surface_state *st = surface_state_find(s, o->xs->surface);
	if (st == NULL) {
		surface_state_acquire(s, o->xs->surface, o->owner);
		st = surface_state_find(s, o->xs->surface);
	}
	if (st != NULL) {
		st->id = o->owner;
		surface_state_import(st);
	}
}

static void handle_xor_unmap(struct wl_listener *listener, void *data) {
	xor_surf *o = wl_container_of(listener, o, unmap);
	o->mapped = false;
	if (o->server->cb.damage != NULL) {
		o->server->cb.damage(o->server->cb.ud, o->owner);
	}
}

static void xor_free(xor_surf *o) {
	struct wl_listener *all[] = { &o->associate, &o->dissociate, &o->map, &o->unmap, &o->destroy };
	for (size_t i = 0; i < sizeof(all) / sizeof(all[0]); i++) {
		wl_list_remove(&all[i]->link);
	}
	wl_list_remove(&o->link);
	free(o);
}

static void handle_xor_destroy(struct wl_listener *listener, void *data) {
	xor_surf *o = wl_container_of(listener, o, destroy);
	xor_free(o);
}

static void handle_new_xsurface(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_xsurface);
	struct wlr_xwayland_surface *xs = data;
	if (xs->override_redirect) {
		xor_surf *o = calloc(1, sizeof(*o));
		if (o == NULL) {
			return;
		}
		o->server = s;
		o->xs = xs;
		o->associate.notify = handle_xor_associate;
		wl_signal_add(&xs->events.associate, &o->associate);
		o->dissociate.notify = handle_xor_dissociate;
		wl_signal_add(&xs->events.dissociate, &o->dissociate);
		o->map.notify = handle_xor_map;
		wl_list_init(&o->map.link);
		o->unmap.notify = handle_xor_unmap;
		wl_list_init(&o->unmap.link);
		o->destroy.notify = handle_xor_destroy;
		wl_signal_add(&xs->events.destroy, &o->destroy);
		wl_list_insert(s->xors.prev, &o->link);
		return;
	}
	toplevel *t = calloc(1, sizeof(*t));
	if (t == NULL) {
		return;
	}
	t->server = s;
	t->xs = xs;
	t->id = s->next_id++;
	t->output_id = s->primary_output_id;
	wl_list_init(&t->commit.link);
	// X11 va por decoración del WM (nuestro chrome): nunca CSD. Los listeners de
	// move/resize de xdg no aplican, pero quedan inicializados para el unlink.
	wl_list_init(&t->request_move.link);
	wl_list_init(&t->request_resize.link);
	t->csd = false;
	t->map.notify = handle_toplevel_map;
	wl_list_init(&t->map.link);
	t->unmap.notify = handle_toplevel_unmap;
	wl_list_init(&t->unmap.link);
	t->destroy.notify = handle_toplevel_destroy;
	wl_signal_add(&xs->events.destroy, &t->destroy);
	t->set_title.notify = handle_toplevel_set_title;
	wl_signal_add(&xs->events.set_title, &t->set_title);
	t->request_minimize.notify = handle_toplevel_request_minimize;
	wl_signal_add(&xs->events.request_minimize, &t->request_minimize);
	t->request_maximize.notify = handle_toplevel_request_maximize;
	wl_signal_add(&xs->events.request_maximize, &t->request_maximize);
	t->request_fullscreen.notify = handle_toplevel_request_fullscreen;
	wl_signal_add(&xs->events.request_fullscreen, &t->request_fullscreen);
	t->associate.notify = handle_xtoplevel_associate;
	wl_signal_add(&xs->events.associate, &t->associate);
	t->dissociate.notify = handle_xtoplevel_dissociate;
	wl_signal_add(&xs->events.dissociate, &t->dissociate);
	t->request_configure.notify = handle_xtoplevel_request_configure;
	wl_signal_add(&xs->events.request_configure, &t->request_configure);
	wl_list_insert(s->toplevels.prev, &t->link);
}

static void output_set_size(struct wl_server *s) {
	// Redimensiona sólo la salida principal (compatibilidad con set_default_size);
	// las secundarias se ajustan con wl_server_output_configure.
	logical_output *o = output_find(s, s->primary_output_id);
	if (o == NULL) {
		return;
	}
	o->width = s->default_w;
	o->height = s->default_h;
	output_commit(o);
	wlr_output_layout_add(s->output_layout, o->output, o->x, o->y);
}

wl_server *wl_server_create(wl_server_callbacks cb, int default_w, int default_h) {
	struct wl_server *s = calloc(1, sizeof(*s));
	if (s == NULL) {
		return NULL;
	}
	s->cb = cb;
	s->default_w = default_w > 0 ? default_w : 1024;
	s->default_h = default_h > 0 ? default_h : 700;
	s->next_id = 1;
	s->next_output_id = 1;
	s->pointer_id = 0;
	s->pointer_surface = NULL;
	s->egl_dpy = EGL_NO_DISPLAY;
	wl_list_init(&s->toplevels);
	wl_list_init(&s->surfaces);
	wl_list_init(&s->layers);
	wl_list_init(&s->xors);
	wl_list_init(&s->text_inputs);
	wl_list_init(&s->outputs);
	// Scanout directo (P4): opt-in por entorno; el puente vive en scanout.c.
	// "0"/"false" lo desactivan (getenv != NULL no alcanza para un flag booleano).
	const char *scanout_env = getenv("GDTK_SCANOUT_DIRECT");
	s->scanout_enabled = scanout_env != NULL && strcmp(scanout_env, "0") != 0 && strcmp(scanout_env, "false") != 0;
	gdtk_scanout_set_enabled(s->scanout_enabled);
	// Recreacion del compositor: no dejar subsurfaces del host apuntando a ventanas viejas.
	gdtk_scanout_reset();
	gdtk_scanout_set_release_callback(scanout_on_release, s);

	s->display = wl_display_create();
	if (s->display == NULL) {
		goto fail;
	}
	s->loop = wl_display_get_event_loop(s->display);

	s->backend = wlr_headless_backend_create(s->loop);
	if (s->backend == NULL) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo crear el backend headless");
		goto fail;
	}

	// ponytail: sin renderer en wlroots (NULL); los clientes usan la GPU y
	// nosotros leemos el buffer. wl_shm explicito con los dos formatos que
	// sabemos convertir.
	s->compositor = wlr_compositor_create(s->display, 5, NULL);
	s->subcompositor = wlr_subcompositor_create(s->display);
	s->data_device_manager = wlr_data_device_manager_create(s->display);
	s->xdg_shell = wlr_xdg_shell_create(s->display, 3);

	// xdg-foreign v1 (GTK3: Firefox, xdg-desktop-portal-gtk) y v2 (GTK4): el
	// selector de archivos del portal es otro cliente y sin esto no puede
	// hacerse transient de la ventana que lo pidió; quedaría huérfano.
	s->foreign_registry = wlr_xdg_foreign_registry_create(s->display);
	if (s->foreign_registry != NULL) {
		s->foreign_v1 = wlr_xdg_foreign_v1_create(s->display, s->foreign_registry);
		s->foreign_v2 = wlr_xdg_foreign_v2_create(s->display, s->foreign_registry);
	} else {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_xdg_foreign_registry_create");
	}

	// Un wl_output del tamaño de la vista: GTK3 (Firefox) limita los popups al área del
	// monitor, y sin ningún output los configuraba a 1x1 y los descartaba.
	// Ahora es la salida "primary" de una colección explícita de salidas lógicas;
	// el comportamiento observable para un único output es el mismo.
	s->output_layout = wlr_output_layout_create(s->display);
	s->creating = true;
	int primary_id = wl_server_output_add(s, "primary", 0, 0, s->default_w, s->default_h, 1, 1);
	s->creating = false;
	if (primary_id > 0 && s->output_layout != NULL) {
		wlr_xdg_output_manager_v1_create(s->display, s->output_layout);
	}
	if (s->compositor == NULL || s->subcompositor == NULL ||
			s->data_device_manager == NULL || s->xdg_shell == NULL) {
		wlr_log(WLR_ERROR, "wl_server: fallo al crear globals de wlroots");
		goto fail;
	}

	static const uint32_t shm_formats[] = {
		DRM_FORMAT_ARGB8888,
		DRM_FORMAT_XRGB8888,
	};
	if (wlr_shm_create(s->display, 2, shm_formats, 2) == NULL) {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_shm_create");
		goto fail;
	}

	s->seat = wlr_seat_create(s->display, "seat0");
	if (s->seat == NULL) {
		goto fail;
	}

	static const struct wlr_keyboard_impl keyboard_impl = {
		.name = "gdtk-virtual-keyboard",
		.led_update = NULL,
	};
	wlr_keyboard_init(&s->keyboard, &keyboard_impl, "gdtk-virtual-keyboard");
	struct xkb_context *xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	struct xkb_keymap *keymap = NULL;
	if (xkb_ctx != NULL) {
		keymap = xkb_keymap_new_from_names(xkb_ctx, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
	}
	if (keymap != NULL) {
		wlr_keyboard_set_keymap(&s->keyboard, keymap);
		xkb_keymap_unref(keymap);
	} else {
		wlr_log(WLR_ERROR, "wl_server: no se pudo compilar el keymap xkb");
	}
	if (xkb_ctx != NULL) {
		xkb_context_unref(xkb_ctx);
	}
	wlr_seat_set_keyboard(s->seat, &s->keyboard);
	wlr_seat_set_capabilities(s->seat,
			WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD);

	// Pointer lock de clientes alojados: los emuladores/juegos SDL piden
	// zwp_locked_pointer_v1 junto con el relative pointer para capturar el mouse.
	// Sin ambos globals SDL_SetRelativeMouseMode falla (Wayland_input_lock_pointer).
	s->pointer_constraints = wlr_pointer_constraints_v1_create(s->display);
	if (s->pointer_constraints != NULL) {
		s->new_constraint.notify = handle_new_constraint;
		wl_signal_add(&s->pointer_constraints->events.new_constraint, &s->new_constraint);
	} else {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_pointer_constraints_v1_create");
	}
	s->relative_pointer_manager = wlr_relative_pointer_manager_v1_create(s->display);
	if (s->relative_pointer_manager == NULL) {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_relative_pointer_manager_v1_create");
	}

	// Gestos de puntero (pinch): global zwp_pointer_gesture_pinch_v1. El shell
	// reenvía el pinch como pasos begin/update/end (wl_server_gesture_pinch) y
	// wlroots lo entrega al cliente con foco del puntero.
	s->pointer_gestures = wlr_pointer_gestures_v1_create(s->display);
	if (s->pointer_gestures == NULL) {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_pointer_gestures_v1_create");
	}

	// IME (K14): text-input-v3 para los clientes y input-method-v2 para el motor.
	// Si no hay motor conectado, text-input queda anunciado pero inactivo.
	s->text_input_manager = wlr_text_input_manager_v3_create(s->display);
	if (s->text_input_manager != NULL) {
		s->new_text_input.notify = handle_new_text_input;
		wl_signal_add(&s->text_input_manager->events.new_text_input, &s->new_text_input);
	} else {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_text_input_manager_v3_create");
	}
	s->input_method_manager = wlr_input_method_manager_v2_create(s->display);
	if (s->input_method_manager != NULL) {
		s->new_input_method.notify = handle_new_input_method;
		wl_signal_add(&s->input_method_manager->events.new_input_method, &s->new_input_method);
	} else {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_input_method_manager_v2_create");
	}

	s->new_toplevel.notify = handle_new_toplevel;
	wl_signal_add(&s->xdg_shell->events.new_toplevel, &s->new_toplevel);
	s->new_popup.notify = handle_new_popup;
	wl_signal_add(&s->xdg_shell->events.new_popup, &s->new_popup);

	struct wlr_xdg_decoration_manager_v1 *deco_mgr = wlr_xdg_decoration_manager_v1_create(s->display);
	if (deco_mgr != NULL) {
		s->new_decoration.notify = handle_new_decoration;
		wl_signal_add(&deco_mgr->events.new_toplevel_decoration, &s->new_decoration);
	}
	struct wlr_layer_shell_v1 *layer_shell = wlr_layer_shell_v1_create(s->display, 4);
	if (layer_shell != NULL) {
		s->new_layer.notify = handle_new_layer;
		wl_signal_add(&layer_shell->events.new_surface, &s->new_layer);
	}
	struct wlr_xdg_activation_v1 *activation = wlr_xdg_activation_v1_create(s->display);
	if (activation != NULL) {
		s->request_activate.notify = handle_request_activate;
		wl_signal_add(&activation->events.request_activate, &s->request_activate);
	}
	wlr_primary_selection_v1_device_manager_create(s->display);
	// Gestores de portapapeles sin ventana (wl-paste --watch): el historial del
	// applet Portapapeles lee la selección de las apps embebidas por acá.
	wlr_ext_data_control_manager_v1_create(s->display, 1);
	s->request_set_selection.notify = handle_request_set_selection;
	wl_signal_add(&s->seat->events.request_set_selection, &s->request_set_selection);
	s->request_set_primary_selection.notify = handle_request_set_primary_selection;
	wl_signal_add(&s->seat->events.request_set_primary_selection, &s->request_set_primary_selection);
	s->request_set_cursor.notify = handle_request_set_cursor;
	wl_signal_add(&s->seat->events.request_set_cursor, &s->request_set_cursor);
	struct wlr_cursor_shape_manager_v1 *cursor_shape = wlr_cursor_shape_manager_v1_create(s->display, 1);
	if (cursor_shape != NULL) {
		s->request_cursor_shape.notify = handle_request_cursor_shape;
		wl_signal_add(&cursor_shape->events.request_set_shape, &s->request_cursor_shape);
	}
	s->request_start_drag.notify = handle_request_start_drag;
	wl_signal_add(&s->seat->events.request_start_drag, &s->request_start_drag);
	s->start_drag.notify = handle_start_drag;
	wl_signal_add(&s->seat->events.start_drag, &s->start_drag);

	struct wlr_server_decoration_manager *kde_deco = wlr_server_decoration_manager_create(s->display);
	if (kde_deco != NULL) {
		wlr_server_decoration_manager_set_default_mode(kde_deco, WLR_SERVER_DECORATION_MANAGER_MODE_SERVER);
	}

	// GDTK_NO_XWAYLAND=1: sin X (las apps sólo X11 no abren).
	if (getenv("GDTK_NO_XWAYLAND") == NULL) {
		s->xwayland = wlr_xwayland_create(s->display, s->compositor, true);
		if (s->xwayland != NULL) {
			wlr_xwayland_set_seat(s->xwayland, s->seat);
			s->new_xsurface.notify = handle_new_xsurface;
			wl_signal_add(&s->xwayland->events.new_surface, &s->new_xsurface);
			wlr_log(WLR_INFO, "wl_server: Xwayland (perezoso) en %s", s->xwayland->display_name);
		}
	}

	s->socket_name = wl_display_add_socket_auto(s->display);
	if (s->socket_name == NULL) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo crear el socket wayland");
		goto fail;
	}

	if (!wlr_backend_start(s->backend)) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo arrancar el backend");
		goto fail;
	}

	setup_dmabuf(s);
	wlr_log(WLR_INFO, "wl_server: dmabuf %s", s->dmabuf_reason);

	return s;

fail:
	wl_server_destroy(s);
	return NULL;
}

const char *wl_server_xdisplay(wl_server *s) {
	return s != NULL && s->xwayland != NULL && s->xwayland->display_name != NULL ? s->xwayland->display_name : "";
}

const char *wl_server_socket(wl_server *s) {
	if (s == NULL || s->socket_name == NULL) {
		return "";
	}
	return s->socket_name;
}

void wl_server_dispatch(wl_server *s) {
	if (s == NULL) {
		return;
	}
	wl_event_loop_dispatch(s->loop, 0);
	wl_display_flush_clients(s->display);
	// Eventos del host (sway): release de los wl_buffers del puente de scanout.
	gdtk_scanout_dispatch();
}

static void send_frame_done_iter(struct wlr_surface *surface, int sx, int sy, void *data) {
	wlr_surface_send_frame_done(surface, data);
}

void wl_server_frame_done(wl_server *s) {
	if (s == NULL) {
		return;
	}
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if (t->mapped && (t->visible || !s->throttle)) {
			// Todo el árbol (subsurfaces y popups): un frame callback sin respuesta
			// en cualquiera de ellos congela el frame clock de GTK4.
			if (t->tl != NULL) {
				wlr_xdg_surface_for_each_surface(t->tl->base, send_frame_done_iter, &now);
			} else if (t->xs->surface != NULL) {
				wlr_surface_for_each_surface(t->xs->surface, send_frame_done_iter, &now);
			}
		}
	}
	layer_surf *l;
	wl_list_for_each(l, &s->layers, link) {
		if (l->mapped) {
			wlr_layer_surface_v1_for_each_surface(l->ls, send_frame_done_iter, &now);
		}
	}
	xor_surf *o;
	wl_list_for_each(o, &s->xors, link) {
		if (o->mapped && o->xs->surface != NULL) {
			wlr_surface_for_each_surface(o->xs->surface, send_frame_done_iter, &now);
		}
	}
}

void wl_server_set_visible(wl_server *s, const int *ids, int n) {
	if (s == NULL) {
		return;
	}
	s->throttle = true;
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		t->visible = false;
		for (int i = 0; i < n; i++) {
			if (ids[i] == t->id) {
				t->visible = true;
				break;
			}
		}
	}
	// La visibilidad cambio: una ventana en scanout pudo dejar de estar sola (otra
	// visible encima). Se aparta sin esperar a su proximo commit.
	if (s->scanout_enabled) {
		surface_state *st;
		wl_list_for_each(st, &s->surfaces, link) {
			if (st->scanout && !scanout_candidate(s, st)) {
				scanout_off_reimport(s, st);
			}
		}
	}
}

void wl_server_set_size(wl_server *s, int id, int w, int h) {
	if (s == NULL || w <= 0 || h <= 0) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->tl != NULL && t->tl->base->initialized) {
		wlr_xdg_toplevel_set_size(t->tl, w, h);
	} else if (t != NULL && t->xs != NULL) {
		wlr_xwayland_surface_configure(t->xs, 0, 0, (uint16_t)w, (uint16_t)h);
	}
}

// El shell fija el estado xdg "maximized" del cliente (bordes, sombra e ícono de
// restaurar que dibuja la app). Sin esto, una ventana que la app maximizó seguía
// viéndose maximizada al pasarla a flotante con Super+arrastre.
void wl_server_set_maximized(wl_server *s, int id, int maximized) {
	if (s == NULL) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->tl != NULL && t->tl->base->initialized) {
		wlr_xdg_toplevel_set_maximized(t->tl, maximized != 0);
	} else if (t != NULL && t->xs != NULL) {
		wlr_xwayland_surface_set_maximized(t->xs, maximized != 0, maximized != 0);
	}
}

// El shell sale/entra de fullscreen por su cuenta (p.ej. al abrir un selector de otra app):
// avisa al cliente por xdg_toplevel para que deje su UI de pantalla completa.
void wl_server_set_fullscreen(wl_server *s, int id, int fullscreen) {
	if (s == NULL) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->tl != NULL && t->tl->base->initialized) {
		wlr_xdg_toplevel_set_fullscreen(t->tl, fullscreen != 0);
	} else if (t != NULL && t->xs != NULL) {
		wlr_xwayland_surface_set_fullscreen(t->xs, fullscreen != 0);
	}
}

// Caja (coords de la surface raíz) donde deben quedar los popups de la ventana `id`:
// el shell manda la pantalla vista desde la ventana (una flotante corrida no está en 0,0).
void wl_server_set_popup_bounds(wl_server *s, int id, int x, int y, int w, int h) {
	if (s == NULL) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t == NULL) {
		return;
	}
	t->has_popup_bounds = w > 0 && h > 0;
	t->popup_bounds = (struct wlr_box){ x, y, w, h };
}

void wl_server_set_default_size(wl_server *s, int w, int h) {
	if (s == NULL) {
		return;
	}
	if (w > 0) {
		s->default_w = w;
	}
	if (h > 0) {
		s->default_h = h;
	}
	logical_output *primary = output_find(s, s->primary_output_id);
	if (primary != NULL && (primary->width != s->default_w || primary->height != s->default_h)) {
		output_set_size(s);
		layer_surf *l;
		wl_list_for_each(l, &s->layers, link) {
			if (l->ls->initialized) {
				layer_arrange(l, false);
			}
		}
	}
}

// --- Salidas logicas (multi-output) -----------------------------------------

int wl_server_output_add(wl_server *s, const char *name,
		int x, int y, int width, int height, int scale, int primary) {
	if (s == NULL || s->backend == NULL || width <= 0 || height <= 0) {
		return 0;
	}
	// La principal se crea una sola vez durante wl_server_create. Permitir otra
	// dejaría dos outputs marcados primary y ambos serían no removibles.
	if (primary != 0 && s->primary_output_id != 0) {
		return 0;
	}
	if (scale < 1) {
		scale = 1;
	}
	struct wlr_output *wo = wlr_headless_add_output(s->backend, width * scale, height * scale);
	if (wo == NULL) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo crear la salida %dx%d", width, height);
		return 0;
	}
	logical_output *o = calloc(1, sizeof(*o));
	if (o == NULL) {
		wlr_output_destroy(wo);
		return 0;
	}
	o->server = s;
	o->id = s->next_output_id++;
	o->output = wo;
	o->x = x;
	o->y = y;
	o->width = width;
	o->height = height;
	o->scale = scale;
	o->primary = primary != 0;
	o->enabled = true;
	if (name != NULL && name[0] != '\0') {
		o->name = strdup(name);
	}
	// wl_output.name debe ser unico y fijarse antes de anunciar el global.
	char fallback[32];
	snprintf(fallback, sizeof(fallback), "GDTK-%d", o->id);
	wlr_output_set_name(wo, o->name != NULL ? o->name : fallback);
	output_commit(o);
	wlr_output_create_global(wo, s->display);
	if (s->output_layout != NULL) {
		wlr_output_layout_add(s->output_layout, wo, x, y);
	}
	wl_list_insert(s->outputs.prev, &o->link);
	if (s->primary_output_id == 0 || o->primary) {
		s->primary_output_id = o->id;
	}
	if (s->output == NULL || o->primary) {
		s->output = wo;
	}
	if (!s->creating && s->cb.output_added != NULL) {
		s->cb.output_added(s->cb.ud, o->id);
	}
	return o->id;
}

int wl_server_output_configure(wl_server *s, int output_id,
		int x, int y, int width, int height, int scale) {
	logical_output *o = output_find(s, output_id);
	if (o == NULL || width <= 0 || height <= 0) {
		return 0;
	}
	if (scale < 1) {
		scale = 1;
	}
	o->x = x;
	o->y = y;
	o->width = width;
	o->height = height;
	o->scale = scale;
	output_commit(o);
	if (s->output_layout != NULL) {
		wlr_output_layout_add(s->output_layout, o->output, x, y);
	}
	if (s->cb.output_changed != NULL) {
		s->cb.output_changed(s->cb.ud, o->id);
	}
	return 1;
}

void wl_server_output_remove(wl_server *s, int output_id) {
	logical_output *o = output_find(s, output_id);
	if (o == NULL) {
		return;
	}
	if (o->primary) {
		wlr_log(WLR_ERROR, "wl_server: no se retira la salida principal %d", output_id);
		return;
	}
	// Reasignar las ventanas a la principal ANTES de destruir el output: reciben
	// leave/enter y nunca quedan invisibles ni huerfanas.
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if (t->output_id == o->id) {
			toplevel_assign_output(t, s->primary_output_id);
		}
	}
	int id = o->id;
	wl_list_remove(&o->link);
	if (s->output_layout != NULL) {
		wlr_output_layout_remove(s->output_layout, o->output);
	}
	// wlr_output_destroy destruye tambien el global (via wlr_output_finish).
	wlr_output_destroy(o->output);
	free(o->name);
	free(o);
	if (s->cb.output_removed != NULL) {
		s->cb.output_removed(s->cb.ud, id);
	}
}

void wl_server_toplevel_set_output(wl_server *s, int toplevel_id, int output_id) {
	toplevel *t = toplevel_find(s, toplevel_id);
	if (t == NULL) {
		return;
	}
	if (output_id == 0) {
		output_id = s->primary_output_id;
	}
	if (output_find(s, output_id) == NULL) {
		return;
	}
	toplevel_assign_output(t, output_id);
}

int wl_server_toplevel_output(wl_server *s, int toplevel_id) {
	toplevel *t = toplevel_find(s, toplevel_id);
	return t != NULL ? t->output_id : 0;
}

int wl_server_output_primary(wl_server *s) {
	return s != NULL ? s->primary_output_id : 0;
}

int wl_server_outputs(wl_server *s, int *ids, int max) {
	if (s == NULL) {
		return 0;
	}
	int n = 0;
	logical_output *o;
	wl_list_for_each(o, &s->outputs, link) {
		if (ids != NULL && n < max) {
			ids[n] = o->id;
		}
		n++;
	}
	return n;
}

int wl_server_output_get(wl_server *s, int output_id, wl_server_output_info *out) {
	logical_output *o = output_find(s, output_id);
	if (o == NULL || out == NULL) {
		return 0;
	}
	out->id = o->id;
	out->name = o->name;
	out->x = o->x;
	out->y = o->y;
	out->width = o->width;
	out->height = o->height;
	out->scale = o->scale;
	out->primary = o->primary ? 1 : 0;
	out->enabled = o->enabled ? 1 : 0;
	return 1;
}

void wl_server_close(wl_server *s, int id) {
	if (s == NULL) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->tl != NULL && t->tl->base->initialized) {
		wlr_xdg_toplevel_send_close(t->tl);
	} else if (t != NULL && t->xs != NULL) {
		wlr_xwayland_surface_close(t->xs);
	}
}

void wl_server_focus(wl_server *s, int id, int raise) {
	if (s == NULL) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t == NULL) {
		return;
	}
	t->want_focus = true;
	toplevel_apply_focus(t, raise != 0);
}

// --- Pointer lock de clientes alojados ---------------------------------------
// wlroots crea el objeto de zwp_pointer_constraints_v1 y avisa por new_constraint;
// el compositor decide cuándo activarlo (surface con foco de puntero). Cada
// restricción lleva un listener de destroy para soltar el lock si el cliente la
// destruye (SDL_SetRelativeMouseMode(false), cierre de la app).

struct constraint_watch {
	struct wl_listener destroy;
	struct wl_server *server;
};

static void notify_pointer_lock(struct wl_server *s, int locked) {
	if (s->pointer_locked == locked) {
		return;
	}
	s->pointer_locked = locked;
	if (s->cb.pointer_lock != NULL) {
		s->cb.pointer_lock(s->cb.ud, locked ? s->pointer_id : 0, locked);
	}
}

static void update_pointer_constraint(struct wl_server *s) {
	struct wlr_pointer_constraint_v1 *constraint = NULL;
	if (s->pointer_constraints != NULL && s->pointer_surface != NULL) {
		constraint = wlr_pointer_constraints_v1_constraint_for_surface(
				s->pointer_constraints, s->pointer_surface, s->seat);
	}
	if (constraint == s->active_constraint) {
		return;
	}
	struct wlr_pointer_constraint_v1 *old = s->active_constraint;
	// Fijar el nuevo antes de desactivar el viejo: send_deactivated puede
	// destruir una restricción oneshot y disparar su destroy (que no debe
	// volver a soltar el lock ya reemplazado).
	s->active_constraint = constraint;
	if (old != NULL) {
		wlr_pointer_constraint_v1_send_deactivated(old);
	}
	if (constraint != NULL) {
		wlr_pointer_constraint_v1_send_activated(constraint);
	}
	notify_pointer_lock(s, constraint != NULL &&
			constraint->type == WLR_POINTER_CONSTRAINT_V1_LOCKED);
}

static void handle_constraint_destroy(struct wl_listener *listener, void *data) {
	struct constraint_watch *w = wl_container_of(listener, w, destroy);
	struct wlr_pointer_constraint_v1 *constraint = data;
	wl_list_remove(&w->destroy.link);
	if (constraint->data == w) {
		constraint->data = NULL;
	}
	if (w->server->active_constraint == constraint) {
		w->server->active_constraint = NULL;
		notify_pointer_lock(w->server, 0);
	}
	free(w);
}

static void handle_new_constraint(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_constraint);
	struct wlr_pointer_constraint_v1 *constraint = data;
	struct constraint_watch *w = calloc(1, sizeof(*w));
	if (w == NULL) {
		return;
	}
	w->server = s;
	w->destroy.notify = handle_constraint_destroy;
	constraint->data = w;
	wl_signal_add(&constraint->events.destroy, &w->destroy);
	// Si la surface ya tiene el foco del puntero, el lock se activa ya.
	if (s->pointer_surface != NULL && constraint->surface == s->pointer_surface) {
		update_pointer_constraint(s);
	}
}

void wl_server_pointer_motion(wl_server *s, int id, double x, double y, uint32_t time_ms) {
	if (s == NULL) {
		return;
	}
	// El icono del drag puede haber aparecido o cambiado de surface desde la
	// ultima motion (set_icon del cliente): re-sincronizar aca garantiza que se
	// enganche sin depender de un evento que wlroots no expone.
	if (s->drag != NULL) {
		drag_icon_sync(s);
	}
	// Hit-test sobre todo el arbol (popups primero). x,y llegan relativos a la
	// raiz; sub_x,sub_y quedan en coords locales de la surface elegida.
	double sub_x = 0.0;
	double sub_y = 0.0;
	struct wlr_surface *surface = NULL;
	toplevel *t = toplevel_find(s, id);
	layer_surf *l = t == NULL ? layer_find(s, id) : NULL;
	if (t != NULL && t->tl != NULL) {
		surface = wlr_xdg_surface_surface_at(t->tl->base, x, y, &sub_x, &sub_y);
	} else if (t != NULL) {
		surface = xwayland_surface_at(t, x, y, &sub_x, &sub_y);
	} else if (l != NULL && l->mapped) {
		surface = wlr_layer_surface_v1_surface_at(l->ls, x, y, &sub_x, &sub_y);
	} else {
		return;
	}
	if (surface == NULL) {
		if (s->pointer_surface != NULL) {
			s->pointer_surface = NULL;
			s->pointer_id = 0;
			wlr_seat_pointer_notify_clear_focus(s->seat);
			client_cursor_reset(s);
			update_pointer_constraint(s);
		}
		return;
	}
	if (s->pointer_surface != surface) {
		int prev_id = s->pointer_id;
		s->pointer_surface = surface;
		s->pointer_id = id;
		// El cursor de wl_pointer es por cliente, no por surface: moverse entre
		// subsurfaces del MISMO toplevel no debe resetearlo. Si no, el set_cursor(NULL)
		// de un video fullscreen (Firefox renderiza en subsurface) se perdia al cruzar
		// root <-> subsurface y el cursor reaparecia. Reset solo al cambiar de
		// toplevel/cliente (o al limpiarse el foco, mas arriba).
		if (id != prev_id) {
			client_cursor_reset(s);
		}
		wlr_seat_pointer_notify_enter(s->seat, surface, sub_x, sub_y);
		update_pointer_constraint(s);
	}
	wlr_seat_pointer_notify_motion(s->seat, time_ms, sub_x, sub_y);
	wlr_seat_pointer_notify_frame(s->seat);
}

void wl_server_pointer_motion_relative(wl_server *s, double dx, double dy, uint32_t time_ms) {
	if (s == NULL || s->relative_pointer_manager == NULL) {
		return;
	}
	// El relative pointer comparte foco con wl_pointer. Si el lock esta activo,
	// caer a la surface de la restriccion: con el puntero capturado el shell deja
	// de mandar motion absoluto y alguna ruta pudo limpiar pointer_surface; sin
	// foco wlroots descarta el relativo y la camara del cliente no se mueve.
	if (s->pointer_surface == NULL && s->active_constraint != NULL
			&& s->active_constraint->surface != NULL) {
		struct wlr_surface *surf = s->active_constraint->surface;
		toplevel *t = toplevel_find_surface(s, surf);
		s->pointer_surface = surf;
		if (t != NULL) {
			s->pointer_id = t->id;
		}
		wlr_seat_pointer_notify_enter(s->seat, surf, 0.0, 0.0);
	}
	if (s->pointer_surface == NULL) {
		return;
	}
	// Tiempo en microsegundos (wl_pointer usa milisegundos). El relative pointer
	// comparte el foco del wl_pointer: llega sólo al cliente con lock activo.
	wlr_relative_pointer_manager_v1_send_relative_motion(s->relative_pointer_manager,
			s->seat, (uint64_t)time_ms * 1000ull, dx, dy, dx, dy);
}

void wl_server_pointer_clear_focus(wl_server *s) {
	if (s == NULL || s->pointer_surface == NULL) {
		return;
	}
	s->pointer_surface = NULL;
	s->pointer_id = 0;
	wlr_seat_pointer_notify_clear_focus(s->seat);
	client_cursor_reset(s);
	update_pointer_constraint(s);
}

// 1 si hay surface con foco de puntero: requisito de wl_server_pointer_motion_relative.
int wl_server_pointer_has_focus(wl_server *s) {
	return s != NULL && s->pointer_surface != NULL;
}

// 1 mientras el cliente con foco pidio ocultar el cursor (set_cursor surface NULL).
int wl_server_client_cursor_hidden(wl_server *s) {
	return s != NULL && s->client_cursor_hidden;
}

void wl_server_pointer_button(wl_server *s, uint32_t time_ms, uint32_t evdev_button, int pressed) {
	if (s == NULL) {
		return;
	}
	if (s->drag != NULL) {
		drag_icon_sync(s);
	}
	wlr_seat_pointer_notify_button(s->seat, time_ms, evdev_button,
			pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
	wlr_seat_pointer_notify_frame(s->seat);
}

void wl_server_pointer_axis(wl_server *s, uint32_t time_ms, double dy) {
	if (s == NULL) {
		return;
	}
	wlr_seat_pointer_notify_axis(s->seat, time_ms, WL_POINTER_AXIS_VERTICAL_SCROLL,
			dy, (int32_t)(dy * 10.0), WL_POINTER_AXIS_SOURCE_WHEEL,
			WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
	wlr_seat_pointer_notify_frame(s->seat);
}

// Eje horizontal (scroll de dos dedos hacia los lados: atrás/adelante en el
// navegador). Mismo contrato que el vertical pero con WL_POINTER_AXIS_HORIZONTAL_SCROLL.
void wl_server_pointer_axis_h(wl_server *s, uint32_t time_ms, double dx) {
	if (s == NULL) {
		return;
	}
	wlr_seat_pointer_notify_axis(s->seat, time_ms, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
			dx, (int32_t)(dx * 10.0), WL_POINTER_AXIS_SOURCE_WHEEL,
			WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
	wlr_seat_pointer_notify_frame(s->seat);
}

// Scroll de touchpad (dos dedos): source FINGER, valores continuos (px de superficie)
// por eje, sin discretos. Los navegadores lo usan para el gesto atrás/adelante.
void wl_server_pointer_axis_finger(wl_server *s, uint32_t time_ms, double dx, double dy) {
	if (s == NULL) {
		return;
	}
	if (dx != 0.0) {
		wlr_seat_pointer_notify_axis(s->seat, time_ms, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
				dx, 0, WL_POINTER_AXIS_SOURCE_FINGER,
				WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
	}
	if (dy != 0.0) {
		wlr_seat_pointer_notify_axis(s->seat, time_ms, WL_POINTER_AXIS_VERTICAL_SCROLL,
				dy, 0, WL_POINTER_AXIS_SOURCE_FINGER,
				WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
	}
	wlr_seat_pointer_notify_frame(s->seat);
}

// Dedos levantados: valor 0 con source FINGER = wl_pointer.axis_stop (wlroots) en ambos ejes.
void wl_server_pointer_axis_stop(wl_server *s, uint32_t time_ms) {
	if (s == NULL) {
		return;
	}
	wlr_seat_pointer_notify_axis(s->seat, time_ms, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
			0.0, 0, WL_POINTER_AXIS_SOURCE_FINGER, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
	wlr_seat_pointer_notify_axis(s->seat, time_ms, WL_POINTER_AXIS_VERTICAL_SCROLL,
			0.0, 0, WL_POINTER_AXIS_SOURCE_FINGER, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
	wlr_seat_pointer_notify_frame(s->seat);
}

// Pinch del touchpad hacia el cliente con foco. `phase`: 0 begin, 1 update,
// 2 end, 3 cancel. En update, `scale` >1 aleja los dedos (zoom in) y <1 los
// acerca (zoom out); dx/dy/rotation en unidades del protocolo. El shell arma el
// ciclo completo begin→update→end por cada pinch detectado por sway.
void wl_server_gesture_pinch(wl_server *s, uint32_t time_ms, int phase,
		uint32_t fingers, double dx, double dy, double scale, double rotation) {
	if (s == NULL || s->pointer_gestures == NULL) {
		return;
	}
	switch (phase) {
	case 0:
		wlr_pointer_gestures_v1_send_pinch_begin(s->pointer_gestures, s->seat,
				time_ms, fingers);
		break;
	case 1:
		wlr_pointer_gestures_v1_send_pinch_update(s->pointer_gestures, s->seat,
				time_ms, dx, dy, scale, rotation);
		break;
	case 3:
		wlr_pointer_gestures_v1_send_pinch_end(s->pointer_gestures, s->seat,
				time_ms, true);
		break;
	default:
		wlr_pointer_gestures_v1_send_pinch_end(s->pointer_gestures, s->seat,
				time_ms, false);
		break;
	}
}

void wl_server_key(wl_server *s, uint32_t time_ms, uint32_t evdev_key, int pressed) {
	if (s == NULL) {
		return;
	}
	struct wlr_keyboard_key_event ev = {
		.time_msec = time_ms,
		.keycode = evdev_key,
		.update_state = true,
		.state = pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED,
	};
	// IME (K14): con un grab activo el motor procesa la tecla (composicion) y
	// decide que reenviar; no llega directo al cliente. Sanity previo: un grab
	// sobreviviente (IME colgado / deactivate perdido) sin IME vivo o sin
	// text-input habilitado bajo el foco manda el teclado a un agujero negro; en
	// ese caso se suelta acá y la tecla toma el camino normal.
	if (s->keyboard_grab != NULL) {
		if (s->input_method == NULL || s->active_text_input == NULL) {
			release_stale_keyboard_grab(s);
		} else {
			wlr_keyboard_notify_key(&s->keyboard, &ev);
			wlr_input_method_keyboard_grab_v2_send_key(s->keyboard_grab, time_ms,
					evdev_key, ev.state);
			wlr_input_method_keyboard_grab_v2_send_modifiers(s->keyboard_grab,
					&s->keyboard.modifiers);
			return;
		}
	}
	wlr_keyboard_notify_key(&s->keyboard, &ev);
	wlr_seat_keyboard_notify_modifiers(s->seat, &s->keyboard.modifiers);
	wlr_seat_keyboard_notify_key(s->seat, time_ms, evdev_key, ev.state);
}

int wl_server_dmabuf_enabled(wl_server *s) {
	return s != NULL && s->dmabuf_enabled;
}

const char *wl_server_dmabuf_reason(wl_server *s) {
	if (s == NULL || s->dmabuf_reason == NULL) {
		return "sin servidor";
	}
	return s->dmabuf_reason;
}

const char *wl_server_syncobj_state(wl_server *s) {
	if (s == NULL) {
		return "sin servidor";
	}
	if (s->syncobj_enabled) {
		return "on";
	}
	return s->syncobj_reason != NULL ? s->syncobj_reason : "off";
}

// --- Layout por surface (todo el arbol del toplevel) ---

struct layer_data {
	wl_server_layer *out;
	int max;
	int count;
};

static void layer_iterator(struct wlr_surface *surface, int sx, int sy, void *data) {
	struct layer_data *d = data;
	if (d->count >= d->max) {
		return;
	}
	wl_server_layer *l = &d->out[d->count++];
	l->key = (uint64_t)(uintptr_t)surface;
	l->x = sx;
	l->y = sy;
	l->w = surface->current.width;
	l->h = surface->current.height;
}

int wl_server_geometry(wl_server *s, int id, int *x, int *y, int *w, int *h) {
	toplevel *t = s != NULL ? toplevel_find(s, id) : NULL;
	if (t != NULL && t->xs != NULL) {
		*x = 0;
		*y = 0;
		*w = t->xs->width;
		*h = t->xs->height;
		return t->xs->surface != NULL;
	}
	if (t == NULL || !t->tl->base->initialized) {
		return 0;
	}
	struct wlr_box *g = &t->tl->base->geometry;
	*x = g->x;
	*y = g->y;
	*w = g->width;
	*h = g->height;
	return 1;
}

int wl_server_parent(wl_server *s, int id) {
	if (s == NULL) {
		return 0;
	}
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->xs != NULL) {
		toplevel *p = t->xs->parent != NULL ? toplevel_find_xs(s, t->xs->parent) : NULL;
		return p != NULL ? p->id : 0;
	}
	if (t == NULL || t->tl->parent == NULL) {
		return 0;
	}
	// El parent puede ser un toplevel todavia vivo: se busca por su surface raiz.
	toplevel *p = toplevel_find_surface(s, t->tl->parent->base->surface);
	return p != NULL ? p->id : 0;
}

const char *wl_server_app_id(wl_server *s, int id) {
	if (s == NULL) {
		return "";
	}
	toplevel *t = toplevel_find(s, id);
	const char *app_id = t == NULL ? NULL : t->tl != NULL ? t->tl->app_id : t->xs->class;
	return app_id != NULL ? app_id : "";
}

// 1 si el cliente se decora solo (CSD). Xwayland siempre 0.
int wl_server_csd(wl_server *s, int id) {
	if (s == NULL) {
		return 0;
	}
	toplevel *t = toplevel_find(s, id);
	return (t != NULL && t->csd) ? 1 : 0;
}

int wl_server_layers(wl_server *s, int id, wl_server_layer *out, int max) {
	if (s == NULL || out == NULL || max <= 0) {
		return 0;
	}
	struct layer_data d = { out, max, 0 };
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->mapped && t->tl != NULL) {
		// Orden raiz -> hojas, que es el orden de dibujo de wlroots.
		wlr_xdg_surface_for_each_surface(t->tl->base, layer_iterator, &d);
		return d.count;
	}
	if (t != NULL && t->mapped && t->xs->surface != NULL) {
		wlr_surface_for_each_surface(t->xs->surface, layer_iterator, &d);
		// Menús/tooltips X encima, relativos a la ventana dueña.
		xor_surf *o;
		wl_list_for_each(o, &s->xors, link) {
			if (o->mapped && o->owner == id && o->xs->surface != NULL) {
				int base = d.count;
				wlr_surface_for_each_surface(o->xs->surface, layer_iterator, &d);
				for (int i = base; i < d.count; i++) {
					d.out[i].x += o->xs->x - t->xs->x;
					d.out[i].y += o->xs->y - t->xs->y;
				}
			}
		}
		return d.count;
	}
	layer_surf *l = t == NULL ? layer_find(s, id) : NULL;
	if (l != NULL && l->mapped) {
		wlr_layer_surface_v1_for_each_surface(l->ls, layer_iterator, &d);
	}
	return d.count;
}

int wl_server_layer_surfaces(wl_server *s, wl_server_layer_surface *out, int max) {
	if (s == NULL || out == NULL) {
		return 0;
	}
	int n = 0;
	for (int layer = 0; layer <= ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY; layer++) {
		layer_surf *l;
		wl_list_for_each(l, &s->layers, link) {
			if (n < max && l->mapped && (int)l->ls->current.layer == layer) {
				out[n++] = (wl_server_layer_surface){ l->id, layer, l->x, l->y, l->w, l->h };
			}
		}
	}
	return n;
}

void wl_server_bind_dmabuf(wl_server *s, uint64_t key, unsigned int texid) {
	if (s == NULL || !s->dmabuf_enabled || s->egl_dpy == EGL_NO_DISPLAY) {
		return;
	}
	surface_state *st = surface_state_find_key(s, key);
	if (st == NULL || st->buffer == NULL) {
		return;
	}
	struct wlr_dmabuf_attributes attribs;
	if (!wlr_buffer_get_dmabuf(st->buffer, &attribs)) {
		return;
	}

	EGLint attrs[64];
	dmabuf_egl_attrs(&attribs, attrs);
	EGLImageKHR image = s->eglCreateImageKHR(s->egl_dpy, EGL_NO_CONTEXT,
			EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
	if (image == EGL_NO_IMAGE_KHR) {
		return;
	}

	GLint prev = 0;
	s->glGetIntegerv(GL_TEXTURE_BINDING_2D, &prev);
	s->glBindTexture(GL_TEXTURE_2D, (GLuint)texid);
	s->glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)image);
	// El camino shm recibe estos parametros en texture_set_data; al importar el
	// EGLImage hay que ponerlos a mano o el filtro minimo por defecto
	// (mipmap-incomplete, sin mipmaps) devuelve negro.
	s->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	s->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	s->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	s->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	s->glBindTexture(GL_TEXTURE_2D, (GLuint)prev);
	s->eglDestroyImageKHR(s->egl_dpy, image);
	// ponytail: sync implicita (Mesa/Intel); explicit sync (linux-drm-syncobj) si hay tearing.
}

int wl_server_scanout_enabled(wl_server *s) {
	return s != NULL && s->scanout_enabled;
}

const char *wl_server_scanout_state(wl_server *s) {
	(void)s;
	return gdtk_scanout_state();
}

void wl_server_scanout_set_suspended(wl_server *s, int suspended) {
	if (s == NULL) {
		return;
	}
	bool v = suspended != 0;
	if (s->scanout_suspended == v) {
		return;
	}
	s->scanout_suspended = v;
	if (!v) {
		// La reanudacion es implicita: el proximo commit dmabuf del cliente reengancha.
		return;
	}
	surface_state *st;
	wl_list_for_each(st, &s->surfaces, link) {
		if (st->scanout) {
			scanout_off_reimport(s, st);
		}
	}
}

int wl_server_scanout_suspended(wl_server *s) {
	return s != NULL && s->scanout_suspended;
}

const char *wl_server_scanout_reason(wl_server *s) {
	return (s != NULL && s->scanout_reason != NULL) ? s->scanout_reason : "?";
}

void wl_server_destroy(wl_server *s) {
	if (s == NULL) {
		return;
	}

	// Evitar callbacks hacia Godot mientras se desmonta la escena.
	memset(&s->cb, 0, sizeof(s->cb));
	// Cerrar el puente y el aviso de liberacion del host.
	gdtk_scanout_reset();
	gdtk_scanout_set_release_callback(NULL, NULL);

	if (s->new_toplevel.notify != NULL) {
		wl_list_remove(&s->new_toplevel.link);
	}
	if (s->new_popup.notify != NULL) {
		wl_list_remove(&s->new_popup.link);
	}
	if (s->new_decoration.notify != NULL) {
		wl_list_remove(&s->new_decoration.link);
	}
	struct wl_listener *extra[] = { &s->new_layer, &s->request_activate,
		&s->request_set_selection, &s->request_set_primary_selection, &s->new_xsurface,
		&s->new_text_input, &s->new_input_method, &s->new_constraint,
		&s->request_start_drag, &s->start_drag, &s->request_set_cursor,
		&s->request_cursor_shape };
	for (size_t i = 0; i < sizeof(extra) / sizeof(extra[0]); i++) {
		if (extra[i]->notify != NULL) {
			wl_list_remove(&extra[i]->link);
		}
	}
	cursor_surface_drop(s);

	// Pointer lock: quitar los watchers de destroy de cada restricción antes de
	// destruir clientes/display (wlroots asserts si quedan listeners propios).
	s->active_constraint = NULL;
	s->pointer_locked = 0;
	if (s->pointer_constraints != NULL) {
		struct wlr_pointer_constraint_v1 *c, *ctmp;
		wl_list_for_each_safe(c, ctmp, &s->pointer_constraints->constraints, link) {
			struct constraint_watch *w = c->data;
			if (w != NULL) {
				c->data = NULL;
				wl_list_remove(&w->destroy.link);
				free(w);
			}
		}
	}

	if (s->xwayland != NULL) {
		wlr_xwayland_destroy(s->xwayland);
		s->xwayland = NULL;
	}
	if (s->display != NULL) {
		wl_display_destroy_clients(s->display);
	}

	// Drag and drop: si un drag no llego a destruirse, liberar el watch del
	// icono (el listener drag_destroy se limpia solo en events.destroy del drag).
	s->drag = NULL;
	if (s->drag_icon != NULL) {
		wl_list_remove(&s->drag_icon->commit.link);
		wl_list_remove(&s->drag_icon->destroy.link);
		free(s->drag_icon);
		s->drag_icon = NULL;
	}

	// IME (K14): los text-input y el input-method normalmente ya murieron con
	// sus clientes (events.destroy). Red de seguridad.
	s->active_text_input = NULL;
	if (s->input_method != NULL) {
		wl_list_remove(&s->input_method_commit.link);
		wl_list_remove(&s->input_method_grab_keyboard.link);
		wl_list_remove(&s->input_method_destroy.link);
		s->input_method = NULL;
	}
	if (s->keyboard_grab != NULL) {
		wl_list_remove(&s->keyboard_grab_destroy.link);
		s->keyboard_grab = NULL;
	}
	text_input_relay *ti, *titmp;
	wl_list_for_each_safe(ti, titmp, &s->text_inputs, link) {
		wl_list_remove(&ti->enable.link);
		wl_list_remove(&ti->commit.link);
		wl_list_remove(&ti->disable.link);
		wl_list_remove(&ti->destroy.link);
		wl_list_remove(&ti->link);
		free(ti);
	}

	// Red de seguridad: los toplevels normalmente ya se liberaron en destroy.
	toplevel *t, *tmp;
	wl_list_for_each_safe(t, tmp, &s->toplevels, link) {
		toplevel_unlink(t);
		free(t);
	}
	xor_surf *o, *otmp;
	wl_list_for_each_safe(o, otmp, &s->xors, link) {
		xor_free(o);
	}

	layer_surf *l, *ltmp;
	wl_list_for_each_safe(l, ltmp, &s->layers, link) {
		layer_free(l);
	}

	// Red de seguridad: las surface_state normalmente ya se liberaron en
	// events.destroy al destruir los clientes.
	surface_state *st, *stmp;
	wl_list_for_each_safe(st, stmp, &s->surfaces, link) {
		wl_list_remove(&st->commit.link);
		wl_list_remove(&st->new_subsurface.link);
		wl_list_remove(&st->destroy.link);
		wl_list_remove(&st->link);
		surface_state_release_buffer(st);
		free(st);
	}

	// Salidas logicas: el backend destruye los wlr_output al destruirse; aca se
	// liberan solo los descriptores propios (nombre heap + entrada).
	logical_output *lo, *lotmp;
	wl_list_for_each_safe(lo, lotmp, &s->outputs, link) {
		wl_list_remove(&lo->link);
		free(lo->name);
		free(lo);
	}
	s->primary_output_id = 0;
	s->output = NULL;

	if (s->backend != NULL) {
		wlr_backend_destroy(s->backend);
	}
	if (s->display != NULL) {
		wl_display_destroy(s->display);
	}

	// Recién ahora (tras el display_destroy del manager) cerramos el DRM fd de syncobj.
	if (s->syncobj_enabled) {
		close(s->syncobj_drm_fd);
		s->syncobj_enabled = false;
	}

	free(s);
}
