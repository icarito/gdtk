// Servidor EIS (libeis) + backend org.freedesktop.impl.portal.RemoteDesktop (sd-bus).
// Todo corre en el hilo del shell: eis_server_dispatch no bloquea y se llama por vuelta
// del loop (una lectura sin datos por socket; nada despierta al loop por su cuenta).
#define _GNU_SOURCE
#include "eis_server.h"

#include <libeis.h>
#include <systemd/sd-bus.h>

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define BUS_NAME "org.freedesktop.impl.portal.desktop.gdtk"
#define FRONTEND_NAME "org.freedesktop.portal.Desktop"
#define OBJ_PATH "/org/freedesktop/portal/desktop"
#define DEVICE_TYPES 3 // KEYBOARD | POINTER
#define SESSION_RD 1
#define SESSION_IC 2

static const enum eis_device_capability CAPS[] = {
	EIS_DEVICE_CAP_POINTER,
	EIS_DEVICE_CAP_POINTER_ABSOLUTE,
	EIS_DEVICE_CAP_KEYBOARD,
	EIS_DEVICE_CAP_BUTTON,
	EIS_DEVICE_CAP_SCROLL,
};
#define NCAPS (sizeof(CAPS) / sizeof(CAPS[0]))

struct client {
	struct eis *ctx;
	struct eis_client *client;
	struct eis_seat *seat;
	struct eis_device *device;
	struct session *session;
	uint32_t caps; // lo que el cliente pidió en el bind
	struct client *next;
};

struct capture_barrier {
	uint32_t id;
	int x1, y1, x2, y2;
};

// Sesión del portal: su propio contexto EIS, así cerrarla corta a su cliente.
struct session {
	struct eis_server *s;
	char *path;
	int pid, started, closed;
	uint32_t version;
	sd_bus_slot *slot;
	sd_bus_message *pending; // Start esperando la respuesta del usuario
	int req_id;
	struct eis *eis;
	int kind, enabled, active;
	uint32_t capabilities, activation_id;
	struct capture_barrier *barriers;
	size_t nbarriers;
	uint32_t active_barrier;
	double cursor_x, cursor_y;
	// Tras Release/Disable el puntero queda pegado al borde: ignorar ese borde
	// hasta que el usuario vuelva a mover hacia dentro. 0=nada, 1=izq, 2=der,
	// 3=arriba, 4=abajo.
	uint32_t released_edge;
	// µs monotónicos de la última activación. Deskflow, en su primer motion tras
	// Activated, llama Release() SIN cursor_position (EiScreen::onMotionEvent con
	// m_isOnScreen todavía true) justo cuando el mismo motion dispara el switch al
	// equipo vecino. Obedecerlo desactivaba la captura y obligaba a re-activar en
	// bucle; se ignora si llega pegadísimo a la activación (ver m_ic_release).
	uint64_t activated_at;
	// Release ignorado por llegar pegado a la activación: queda pendiente hasta saber si
	// Deskflow cruzó. Si el mouse vuelve hacia adentro (se aleja del borde) sin haberse
	// adentrado en el vecino, no cruzó (tramo sin vínculo) y se aplica; si se adentra o
	// pasa RELEASE_PENDING_US, se descarta. Antes la captura quedaba trabada.
	int release_pending;
	double pend_in, pend_out;
	// Tras activar, Deskflow entra a la pantalla vecina justo EN el borde y un jitter
	// contrario (p. ej. y=-2) la abandona al instante. Durante esta ventana se anula el
	// delta contrario a la dirección de cruce para que el puntero remoto se adentre.
	uint32_t kick_edge;
	uint64_t kick_until;
	// Nudge de arranque: al conectar el cliente IC, Deskflow a veces arma sus barreras
	// antes de tener listo su layout. Se difiere un ZonesChanged (ver dispatch) y sólo
	// se emite si el cliente NO llegó a armar barreras: emitirlo después de que ya las
	// armó lo hacía rearmar sin volver a Enable y dejaba la sesión suspendida.
	// µs monotónicos; 0 = sin nudge pendiente.
	uint64_t zones_nudge_at;
	struct session *next;
};

struct eis_server {
	eis_server_callbacks cb;
	sd_bus *bus;
	sd_bus_slot *slot, *sc_slot, *ic_slot;
	struct eis *test;
	struct session *sessions;
	struct client *clients;
	int keymap_fd;
	size_t keymap_size;
	int w, h, next_id;
	// Rangos % por borde (índice 1..4 = izq/der/arriba/abajo) donde InputCapture
	// puede activarse. Ver eis_server_set_capture_ranges.
	double capture_lo[5], capture_hi[5];
	// Propiedades del backend (las lee sd-bus por offset).
	uint32_t device_types, version;
	uint32_t sc_sources, sc_cursors, sc_version;
	uint32_t ic_caps, ic_version, zone_set;
	char error[160];
};

static const sd_bus_vtable session_vtable[];
static int ic_emit_capture(struct session *se, const char *name, int include_activation);
static int capture_ready(struct eis_server *s, struct session *se);
static void capture_deactivate(struct eis_server *s, struct session *se);

// --- EIS ---

static void device_update(struct eis_server *s, struct client *c) {
	if (c->device) {
		eis_device_remove(c->device);
		eis_device_unref(c->device);
		c->device = NULL;
	}
	if (!c->caps) {
		return;
	}
	struct eis_device *d = eis_seat_new_device(c->seat);
	eis_device_configure_name(d, "gdtk");
	eis_device_configure_type(d, EIS_DEVICE_TYPE_VIRTUAL);
	for (size_t i = 0; i < NCAPS; i++) {
		if (c->caps & CAPS[i]) {
			eis_device_configure_capability(d, CAPS[i]);
		}
	}
	if (c->caps & EIS_DEVICE_CAP_POINTER_ABSOLUTE) {
		// Una región = la ventana del shell (Deskflow toma de acá el tamaño de la pantalla).
		struct eis_region *r = eis_device_new_region(d);
		eis_region_set_offset(r, 0, 0);
		eis_region_set_size(r, s->w, s->h);
		eis_region_set_physical_scale(r, 1.0);
		eis_region_add(r);
		eis_region_unref(r);
	}
	if ((c->caps & EIS_DEVICE_CAP_KEYBOARD) && s->keymap_fd >= 0) {
		struct eis_keymap *k = eis_device_new_keymap(d, EIS_KEYMAP_TYPE_XKB, s->keymap_fd, s->keymap_size);
		if (k) {
			eis_keymap_add(k);
			eis_keymap_unref(k);
		}
	}
	eis_device_add(d);
	eis_device_resume(d);
	c->device = d;
	if (c->session && c->session->kind == SESSION_IC && c->session->active && !eis_client_is_sender(c->client)) {
		eis_device_start_emulating(d, c->session->activation_id);
	}
}

static void client_free(struct eis_server *s, struct client *c) {
	struct session *se = c->session;
	for (struct client **p = &s->clients; *p; p = &(*p)->next) {
		if (*p == c) {
			*p = c->next;
			break;
		}
	}
	eis_client_set_user_data(c->client, NULL);
	if (c->device) {
		eis_device_unref(c->device);
	}
	eis_seat_unref(c->seat);
	eis_client_unref(c->client);
	free(c);
	// Si se va el último receptor de una sesión InputCapture activa (libei corta
	// por violación de protocolo o desconexión), hay que soltar la captura. Si no,
	// se->active queda 1, el shell sigue con pointer lock y el puntero queda
	// clavado/duplicado al reconectar (Deskflow #8503).
	if (se && se->kind == SESSION_IC && se->active && !capture_ready(s, se)) {
		capture_deactivate(s, se);
	}
}

static void session_emulating(struct eis_server *s, struct session *se, int active) {
	for (struct client *c = s->clients; c; c = c->next) {
		if (c->session != se || eis_client_is_sender(c->client) || !c->device) {
			continue;
		}
		if (active) {
			eis_device_start_emulating(c->device, se->activation_id);
		} else {
			eis_device_stop_emulating(c->device);
		}
	}
}

// --- InputCapture: el compositor local reenvía el hardware físico al cliente EIS ---

// Borde de una barrera válida (mismo convenio que barrier_valid).
#define RELEASE_PENDING_US 1500000ULL
#define RELEASE_PENDING_IN_PX 24.0
#define RELEASE_PENDING_OUT_PX 40.0

static int barrier_edge(struct eis_server *s, const struct capture_barrier *b) {
	if (b->x1 == b->x2) {
		return b->x1 <= 0 ? 1 : (b->x1 >= s->w ? 2 : 0);
	}
	return b->y1 <= 0 ? 3 : (b->y1 >= s->h ? 4 : 0);
}

// ¿Hay dónde reenviar? Un cliente receptor (no sender) con dispositivo agregado.
static int capture_ready(struct eis_server *s, struct session *se) {
	for (struct client *c = s->clients; c; c = c->next) {
		if (c->session == se && c->device && !eis_client_is_sender(c->client)) {
			return 1;
		}
	}
	return 0;
}

static struct session *capture_active(struct eis_server *s) {
	for (struct session *se = s->sessions; se; se = se->next) {
		if (!se->closed && se->kind == SESSION_IC && se->enabled && se->active && capture_ready(s, se)) {
			return se;
		}
	}
	return NULL;
}

// El shell manda milisegundos (OS.get_ticks_msec): libei espera CLOCK_MONOTONIC en µs.
static uint64_t capture_time(uint64_t time) {
	if (time > 0) {
		return time * 1000ULL;
	}
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

// Desactiva la captura recordando por qué borde salió (histéresis anti-rebote).
static void capture_deactivate(struct eis_server *s, struct session *se) {
	if (!se->active) {
		return;
	}
	for (size_t i = 0; i < se->nbarriers; i++) {
		if (se->barriers[i].id == se->active_barrier) {
			se->released_edge = (uint32_t)barrier_edge(s, &se->barriers[i]);
			break;
		}
	}
	session_emulating(s, se, 0);
	ic_emit_capture(se, "Deactivated", 1);
	se->active = 0;
	se->active_barrier = 0;
	se->kick_until = 0;
}

// Release del cliente InputCapture. Deskflow suelta la captura en su primer motion
// (EiScreen::onMotionEvent con isOnScreen) y espera que la misma orilla re-dispare
// con el puntero aún pegado: Release sin cursor_position no fija histéresis. El
// Release con posición es el regreso a la pantalla local: fija la orilla de esa
// posición para no re-disparar apenas queda el puntero pegado al volver.
static void capture_release(struct eis_server *s, struct session *se, double rx, double ry) {
	if (!se->active) {
		return;
	}
	int has_pos = rx >= 0.0 && ry >= 0.0;
	se->released_edge = 0;
	if (has_pos) {
		if (rx <= 0.0) {
			se->released_edge = 1; // izquierda
		} else if (rx >= (double)(s->w - 1)) {
			se->released_edge = 2; // derecha
		} else if (ry <= 0.0) {
			se->released_edge = 3; // arriba
		} else if (ry >= (double)(s->h - 1)) {
			se->released_edge = 4; // abajo
		}
	} else if (se->active_barrier != 0) {
		// Release sin posición (el "baile" de Deskflow): no dejar la orilla re-armada
		// al toque; el usuario tiene que mover hacia dentro para volver a dispararla.
		for (size_t i = 0; i < se->nbarriers; i++) {
			if (se->barriers[i].id == se->active_barrier) {
				se->released_edge = (uint32_t)barrier_edge(s, &se->barriers[i]);
				break;
			}
		}
	}
	if (has_pos) {
		// Deactivated.cursor_position debe ser la posición actual (la que sugirió
		// el cliente en Release). Antes quedaba el cursor_x/y del último físico
		// capturado y el puntero volvía a la zona equivocada.
		se->cursor_x = rx;
		se->cursor_y = ry;
	}
	session_emulating(s, se, 0);
	ic_emit_capture(se, "Deactivated", 1);
	se->active = 0;
	se->active_barrier = 0;
	se->kick_until = 0;
}

// Al volver hacia dentro, ese borde vuelve a habilitarse.
static void capture_update_released(struct session *se, double dx, double dy) {
	switch (se->released_edge) {
		case 1: if (dx > 0.0) se->released_edge = 0; break;
		case 2: if (dx < 0.0) se->released_edge = 0; break;
		case 3: if (dy > 0.0) se->released_edge = 0; break;
		case 4: if (dy < 0.0) se->released_edge = 0; break;
		default: break;
	}
}

static uint32_t barrier_crossed(struct eis_server *s, struct session *se, double x, double y, double dx, double dy) {
	for (size_t i = 0; i < se->nbarriers; i++) {
		const struct capture_barrier *b = &se->barriers[i];
		int edge = barrier_edge(s, b);
		if (edge == 0) {
			continue; // no está exactamente en un borde
		}
		if (se->released_edge != 0 && (uint32_t)edge == se->released_edge) {
			continue;
		}
		// El tramo debe caer dentro del rango del link (deskflow.conf down(0,67)):
		// Deskflow manda barreras de borde COMPLETO y filtra recién en su core; si
		// gdtk captura fuera del rango, Deskflow no cruza y el puntero queda clavado.
		// Eje del rango: izq/der -> y; arriba/abajo -> x.
		double pct = edge <= 2 ? 100.0 * y / (double)s->h : 100.0 * x / (double)s->w;
		if (pct < s->capture_lo[edge] || pct > s->capture_hi[edge]) {
			continue;
		}
		if (b->x1 == b->x2) {
			if (b->x1 <= 0 && dx < 0.0 && x <= 0.0 && y >= b->y1 && y <= b->y2) return b->id;
			// Los píxeles de la ventana llegan 0..w-1 / 0..h-1: el borde lógico se
			// dispara en el último píxel con delta saliente.
			if (b->x1 >= s->w && dx > 0.0 && x >= (double)(s->w - 1) && y >= b->y1 && y <= b->y2) return b->id;
		} else {
			if (b->y1 <= 0 && dy < 0.0 && y <= 0.0 && x >= b->x1 && x <= b->x2) return b->id;
			if (b->y1 >= s->h && dy > 0.0 && y >= (double)(s->h - 1) && x >= b->x1 && x <= b->x2) return b->id;
		}
	}
	return 0;
}

static void handle_eis(struct eis_server *s, struct session *se, struct eis *ctx) {
	eis_dispatch(ctx);
	struct eis_event *e;
	while ((e = eis_get_event(ctx)) != NULL) {
		struct eis_client *ec = eis_event_get_client(e);
		struct client *c = ec ? eis_client_get_user_data(ec) : NULL;
		void *ud = s->cb.ud;
		switch (eis_event_get_type(e)) {
			case EIS_EVENT_CLIENT_CONNECT:
				c = calloc(1, sizeof(*c));
				c->ctx = ctx;
				c->client = eis_client_ref(ec);
				c->session = se;
				c->next = s->clients;
				s->clients = c;
				eis_client_set_user_data(ec, c);
				eis_client_connect(ec);
				c->seat = eis_client_new_seat(ec, "gdtk");
				for (size_t i = 0; i < NCAPS; i++) {
					eis_seat_configure_capability(c->seat, CAPS[i]);
				}
				eis_seat_add(c->seat);
				fprintf(stderr, "eis: cliente '%s' conectado\n", eis_client_get_name(ec));
				if (se && se->kind == SESSION_IC) {
					// Deskflow a veces arma sus barreras antes de que su config fije
					// activeSides (quedaba "no input capture pointer barriers found").
					// No emitir ZonesChanged ahora: si llega tarde, cuando el cliente ya
					// armó y habilitó, lo hace rearmar sin Enable y la sesión queda
					// suspendida. Se difiere y sólo se emite si no armó barreras.
					se->zones_nudge_at = capture_time(0) + 400000ULL;
				}
				break;
			case EIS_EVENT_CLIENT_DISCONNECT:
				if (c) {
					fprintf(stderr, "eis: cliente '%s' desconectado\n", eis_client_get_name(ec));
					client_free(s, c);
				}
				break;
			case EIS_EVENT_SEAT_BIND:
				if (c) {
					c->caps = 0;
					for (size_t i = 0; i < NCAPS; i++) {
						if (eis_event_seat_has_capability(e, CAPS[i])) {
							c->caps |= CAPS[i];
						}
					}
					device_update(s, c);
				}
				break;
			case EIS_EVENT_POINTER_MOTION:
				s->cb.motion(ud, eis_event_pointer_get_dx(e), eis_event_pointer_get_dy(e), 0);
				break;
			case EIS_EVENT_POINTER_MOTION_ABSOLUTE:
				s->cb.motion(ud, eis_event_pointer_get_absolute_x(e), eis_event_pointer_get_absolute_y(e), 1);
				break;
			case EIS_EVENT_BUTTON_BUTTON:
				s->cb.button(ud, eis_event_button_get_button(e), eis_event_button_get_is_press(e));
				break;
			case EIS_EVENT_SCROLL_DELTA:
				s->cb.scroll(ud, eis_event_scroll_get_dx(e), eis_event_scroll_get_dy(e), 0);
				break;
			case EIS_EVENT_SCROLL_DISCRETE:
				s->cb.scroll(ud, eis_event_scroll_get_discrete_dx(e), eis_event_scroll_get_discrete_dy(e), 1);
				break;
			case EIS_EVENT_KEYBOARD_KEY:
				s->cb.key(ud, eis_event_keyboard_get_key(e), eis_event_keyboard_get_key_is_press(e));
				break;
			case EIS_EVENT_DEVICE_STOP_EMULATING:
				if (s->cb.stop_emulating != NULL) {
					s->cb.stop_emulating(ud);
				}
				break;
			default:
				break;
		}
		eis_event_unref(e);
	}
}

// Cierra el contexto y olvida sus clientes (eis_unref no avisa de las desconexiones).
static void eis_close(struct eis_server *s, struct eis *ctx) {
	struct client *c = s->clients;
	while (c) {
		struct client *next = c->next;
		if (c->ctx == ctx) {
			eis_client_disconnect(c->client);
			client_free(s, c);
		}
		c = next;
	}
	eis_unref(ctx);
}

// --- Portal ---

// Sólo el frontend (xdg-desktop-portal) habla con el backend: si no, cualquier proceso
// podría inventar un session_handle y saltarse la pregunta.
static int from_frontend(sd_bus_message *m, sd_bus_error *err) {
	sd_bus_creds *creds = NULL;
	const char *owner = NULL;
	int ok = sd_bus_get_name_creds(sd_bus_message_get_bus(m), FRONTEND_NAME, SD_BUS_CREDS_UNIQUE_NAME, &creds) >= 0 &&
			sd_bus_creds_get_unique_name(creds, &owner) >= 0 && owner &&
			strcmp(owner, sd_bus_message_get_sender(m)) == 0;
	sd_bus_creds_unref(creds);
	if (!ok) {
		sd_bus_error_set(err, SD_BUS_ERROR_ACCESS_DENIED, "sólo xdg-desktop-portal");
	}
	return ok;
}

// El frontend arma el session_handle con el nombre único del cliente:
// /org/freedesktop/portal/desktop/session/1_42/<token> -> :1.42 -> su pid.
static int session_pid(sd_bus *bus, const char *path) {
	const char *p = strstr(path, "/session/");
	if (!p) {
		return 0;
	}
	p += strlen("/session/");
	char name[64] = ":";
	size_t n = 1;
	while (*p && *p != '/' && n < sizeof(name) - 1) {
		name[n++] = *p == '_' ? '.' : *p;
		p++;
	}
	name[n] = 0;
	sd_bus_creds *creds = NULL;
	pid_t pid = 0;
	if (sd_bus_get_name_creds(bus, name, SD_BUS_CREDS_PID, &creds) >= 0) {
		sd_bus_creds_get_pid(creds, &pid);
	}
	sd_bus_creds_unref(creds);
	return (int)pid;
}

static struct session *session_find(struct eis_server *s, const char *path) {
	for (struct session *se = s->sessions; se; se = se->next) {
		if (!se->closed && strcmp(se->path, path) == 0) {
			return se;
		}
	}
	return NULL;
}

static struct session *session_find_kind(struct eis_server *s, const char *path, int kind) {
	struct session *se = session_find(s, path);
	return se && se->kind == kind ? se : NULL;
}

static int session_add(struct eis_server *s, const char *path, int kind, struct session **out) {
	struct session *se = calloc(1, sizeof(*se));
	if (!se) {
		return -ENOMEM;
	}
	se->s = s;
	se->path = strdup(path);
	se->version = 1;
	se->kind = kind;
	se->capabilities = DEVICE_TYPES;
	se->activation_id = 1;
	se->pid = session_pid(s->bus, path);
	int r = sd_bus_add_object_vtable(s->bus, &se->slot, path, "org.freedesktop.impl.portal.Session", session_vtable, se);
	if (r < 0) {
		free(se->path);
		free(se);
		return r;
	}
	se->next = s->sessions;
	s->sessions = se;
	if (out) {
		*out = se;
	}
	return 0;
}

static void reply_start(struct session *se, int allow) {
	if (allow) {
		sd_bus_reply_method_return(se->pending, "ua{sv}", 0, 2, "devices", "u", DEVICE_TYPES, "clipboard_enabled", "b", 0);
		se->started = 1;
	} else {
		sd_bus_reply_method_return(se->pending, "ua{sv}", se->closed ? 2 : 1, 0);
	}
	se->pending = sd_bus_message_unref(se->pending);
}

static int m_session_close(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct session *se = ud;
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	se->closed = 1; // se libera en dispatch, fuera de este callback
	if (se->pending) {
		reply_start(se, 0);
	}
	if (se->kind == SESSION_IC) {
		capture_deactivate(se->s, se);
		ic_emit_capture(se, "Disabled", 0);
	}
	return sd_bus_reply_method_return(m, "");
}

static const sd_bus_vtable session_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_METHOD("Close", "", "", m_session_close, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_SIGNAL("Closed", "", 0),
	SD_BUS_PROPERTY("version", "u", NULL, offsetof(struct session, version), SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_VTABLE_END,
};

static int m_create_session(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct eis_server *s = ud;
	const char *handle, *path, *app_id;
	int r = sd_bus_message_read(m, "oos", &handle, &path, &app_id);
	if (r < 0) {
		return r;
	}
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	struct session *se = NULL;
	r = session_add(s, path, SESSION_RD, &se);
	if (r < 0) {
		return r;
	}
	return sd_bus_reply_method_return(m, "ua{sv}", 0, 0);
}

static int m_select_devices(sd_bus_message *m, void *ud, sd_bus_error *err) {
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	// Se ofrece siempre teclado + puntero (lo que haya pedido, eso o menos, lo elige el bind).
	return sd_bus_reply_method_return(m, "ua{sv}", 0, 0);
}

static int m_start(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct eis_server *s = ud;
	const char *handle, *path, *app_id, *parent;
	int r = sd_bus_message_read(m, "ooss", &handle, &path, &app_id, &parent);
	if (r < 0) {
		return r;
	}
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	struct session *se = session_find_kind(s, path, SESSION_RD);
	if (!se || se->pending || se->started) {
		return sd_bus_error_set(err, SD_BUS_ERROR_INVALID_ARGS, "sesión inválida");
	}
	// Respuesta diferida: la da eis_server_respond cuando el shell decide.
	se->pending = sd_bus_message_ref(m);
	se->req_id = ++s->next_id;
	s->cb.request(s->cb.ud, se->req_id, se->pid, app_id);
	return 1;
}

static int m_connect_to_eis(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct eis_server *s = ud;
	const char *path;
	int r = sd_bus_message_read(m, "o", &path);
	if (r < 0) {
		return r;
	}
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	struct session *se = session_find(s, path);
	if (!se || !se->started) {
		return sd_bus_error_set(err, SD_BUS_ERROR_ACCESS_DENIED, "sesión no iniciada");
	}
	if (!se->eis) {
		se->eis = eis_new(s);
		if (eis_setup_backend_fd(se->eis) < 0) {
			se->eis = eis_unref(se->eis);
			return sd_bus_error_set(err, SD_BUS_ERROR_FAILED, "eis");
		}
	}
	int fd = eis_backend_fd_add_client(se->eis);
	if (fd < 0) {
		return sd_bus_error_set_errno(err, -fd);
	}
	r = sd_bus_reply_method_return(m, "h", fd); // sd-bus duplica el fd
	close(fd);
	return r;
}

static int m_ic_create_session(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct eis_server *s = ud;
	const char *handle, *path, *app_id, *parent;
	int r = sd_bus_message_read(m, "ooss", &handle, &path, &app_id, &parent);
	if (r < 0) {
		return r;
	}
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	struct session *se = NULL;
	r = session_add(s, path, SESSION_IC, &se);
	if (r < 0) {
		return r;
	}
	se->started = 1;
	return sd_bus_reply_method_return(m, "ua{sv}", 0, 2,
			"session_id", "s", "gdtk",
			"capabilities", "u", s->ic_caps);
}

static int m_ic_create_session2(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct eis_server *s = ud;
	const char *path, *app_id;
	int r = sd_bus_message_read(m, "os", &path, &app_id);
	if (r < 0) {
		return r;
	}
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	r = session_add(s, path, SESSION_IC, NULL);
	if (r < 0) {
		return r;
	}
	return sd_bus_reply_method_return(m, "a{sv}", 0);
}

static int m_ic_start(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct eis_server *s = ud;
	const char *handle, *path, *app_id, *parent;
	int r = sd_bus_message_read(m, "ooss", &handle, &path, &app_id, &parent);
	if (r < 0) {
		return r;
	}
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	struct session *se = session_find_kind(s, path, SESSION_IC);
	if (!se || se->started) {
		return sd_bus_error_set(err, SD_BUS_ERROR_INVALID_ARGS, "sesión inválida");
	}
	se->started = 1;
	se->capabilities = s->ic_caps;
	return sd_bus_reply_method_return(m, "ua{sv}", 0, 2,
			"capabilities", "u", se->capabilities,
			"clipboard_enabled", "b", 0);
}

static int reply_zones(sd_bus_message *m, struct eis_server *s) {
	sd_bus_message *reply = NULL;
	int r = sd_bus_message_new_method_return(m, &reply);
	if (r < 0) {
		return r;
	}
	r = sd_bus_message_append(reply, "u", 0);
	if (r >= 0) r = sd_bus_message_open_container(reply, 'a', "{sv}");
	if (r >= 0) r = sd_bus_message_open_container(reply, 'e', "sv");
	if (r >= 0) r = sd_bus_message_append(reply, "s", "zones");
	if (r >= 0) r = sd_bus_message_open_container(reply, 'v', "a(uuii)");
	if (r >= 0) r = sd_bus_message_open_container(reply, 'a', "(uuii)");
	if (r >= 0) r = sd_bus_message_append(reply, "(uuii)", (uint32_t)s->w, (uint32_t)s->h, 0, 0);
	if (r >= 0) r = sd_bus_message_close_container(reply);
	if (r >= 0) r = sd_bus_message_close_container(reply);
	if (r >= 0) r = sd_bus_message_close_container(reply);
	if (r >= 0) r = sd_bus_message_open_container(reply, 'e', "sv");
	if (r >= 0) r = sd_bus_message_append(reply, "s", "zone_set");
	if (r >= 0) r = sd_bus_message_open_container(reply, 'v', "u");
	if (r >= 0) r = sd_bus_message_append(reply, "u", s->zone_set);
	if (r >= 0) r = sd_bus_message_close_container(reply);
	if (r >= 0) r = sd_bus_message_close_container(reply);
	if (r >= 0) r = sd_bus_message_close_container(reply);
	if (r >= 0) r = sd_bus_send(sd_bus_message_get_bus(m), reply, NULL);
	sd_bus_message_unref(reply);
	return r;
}

static int m_ic_get_zones(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct eis_server *s = ud;
	const char *handle, *path, *app_id;
	int r = sd_bus_message_read(m, "oos", &handle, &path, &app_id);
	if (r < 0) {
		return r;
	}
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	if (!session_find_kind(s, path, SESSION_IC)) {
		return sd_bus_error_set(err, SD_BUS_ERROR_INVALID_ARGS, "sesión inválida");
	}
	return reply_zones(m, s);
}

static int reply_failed_barriers(sd_bus_message *m, const uint32_t *failed, size_t nfailed) {
	sd_bus_message *reply = NULL;
	int r = sd_bus_message_new_method_return(m, &reply);
	if (r < 0) {
		return r;
	}
	r = sd_bus_message_append(reply, "u", 0);
	if (r >= 0) r = sd_bus_message_open_container(reply, 'a', "{sv}");
	if (r >= 0) r = sd_bus_message_open_container(reply, 'e', "sv");
	if (r >= 0) r = sd_bus_message_append(reply, "s", "failed_barriers");
	if (r >= 0) r = sd_bus_message_open_container(reply, 'v', "au");
	if (r >= 0) r = sd_bus_message_open_container(reply, 'a', "u");
	for (size_t i = 0; r >= 0 && i < nfailed; i++) r = sd_bus_message_append(reply, "u", failed[i]);
	if (r >= 0) r = sd_bus_message_close_container(reply);
	if (r >= 0) r = sd_bus_message_close_container(reply);
	if (r >= 0) r = sd_bus_message_close_container(reply);
	if (r >= 0) r = sd_bus_message_close_container(reply);
	if (r >= 0) r = sd_bus_send(sd_bus_message_get_bus(m), reply, NULL);
	sd_bus_message_unref(reply);
	return r;
}

static int barrier_valid(const struct eis_server *s, const struct capture_barrier *b) {
	if (b->id == 0 || (b->x1 != b->x2 && b->y1 != b->y2)) return 0;
	if (b->x1 == b->x2) {
		return (b->x1 == 0 || b->x1 == s->w) && b->y1 >= 0 && b->y2 >= b->y1 && b->y2 < s->h;
	}
	return (b->y1 == 0 || b->y1 == s->h) && b->x1 >= 0 && b->x2 >= b->x1 && b->x2 < s->w;
}

static int parse_barrier(sd_bus_message *m, struct capture_barrier *out) {
	int r = sd_bus_message_enter_container(m, 'a', "{sv}");
	if (r <= 0) return r < 0 ? r : -EINVAL;
	memset(out, 0, sizeof(*out));
	while ((r = sd_bus_message_enter_container(m, 'e', "sv")) > 0) {
		const char *key = NULL, *sig = NULL;
		r = sd_bus_message_read(m, "s", &key);
		if (r >= 0) r = sd_bus_message_peek_type(m, NULL, &sig);
		if (r >= 0) r = sd_bus_message_enter_container(m, 'v', sig);
		if (r >= 0 && strcmp(key, "barrier_id") == 0 && strcmp(sig, "u") == 0) {
			r = sd_bus_message_read(m, "u", &out->id);
		} else if (r >= 0 && strcmp(key, "position") == 0 && strcmp(sig, "(iiii)") == 0) {
			r = sd_bus_message_read(m, "(iiii)", &out->x1, &out->y1, &out->x2, &out->y2);
		} else if (r >= 0) {
			r = sd_bus_message_skip(m, sig);
		}
		if (r >= 0) r = sd_bus_message_exit_container(m);
		if (r >= 0) r = sd_bus_message_exit_container(m);
		if (r < 0) return r;
	}
	if (r < 0) return r;
	return sd_bus_message_exit_container(m);
}

static int ic_emit_capture(struct session *se, const char *name, int include_activation) {
	sd_bus_message *sig = NULL;
	int r = sd_bus_message_new_signal(se->s->bus, &sig, OBJ_PATH,
			"org.freedesktop.impl.portal.InputCapture", name);
	if (r < 0) {
		return r;
	}
	r = sd_bus_message_append(sig, "o", se->path);
	if (r >= 0) r = sd_bus_message_open_container(sig, 'a', "{sv}");
	if (include_activation) {
		if (r >= 0) r = sd_bus_message_open_container(sig, 'e', "sv");
		if (r >= 0) r = sd_bus_message_append(sig, "s", "activation_id");
		if (r >= 0) r = sd_bus_message_open_container(sig, 'v', "u");
		if (r >= 0) r = sd_bus_message_append(sig, "u", se->activation_id);
		if (r >= 0) r = sd_bus_message_close_container(sig);
		if (r >= 0) r = sd_bus_message_close_container(sig);
		if (r >= 0) r = sd_bus_message_open_container(sig, 'e', "sv");
		if (r >= 0) r = sd_bus_message_append(sig, "s", "cursor_position");
		if (r >= 0) r = sd_bus_message_open_container(sig, 'v', "(dd)");
		if (r >= 0) r = sd_bus_message_append(sig, "(dd)", se->cursor_x, se->cursor_y);
		if (r >= 0) r = sd_bus_message_close_container(sig);
		if (r >= 0) r = sd_bus_message_close_container(sig);
		if (r >= 0 && strcmp(name, "Activated") == 0) {
			r = sd_bus_message_open_container(sig, 'e', "sv");
			if (r >= 0) r = sd_bus_message_append(sig, "s", "barrier_id");
			if (r >= 0) r = sd_bus_message_open_container(sig, 'v', "u");
			if (r >= 0) r = sd_bus_message_append(sig, "u", se->active_barrier);
			if (r >= 0) r = sd_bus_message_close_container(sig);
			if (r >= 0) r = sd_bus_message_close_container(sig);
		}
	}
	if (r >= 0) r = sd_bus_message_close_container(sig);
	if (r >= 0) r = sd_bus_send(se->s->bus, sig, NULL);
	sd_bus_message_unref(sig);
	return r;
}

static int m_ic_set_pointer_barriers(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct eis_server *s = ud;
	const char *handle, *path, *app_id;
	int r = sd_bus_message_read(m, "oos", &handle, &path, &app_id);
	if (r < 0) {
		return r;
	}
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	struct session *se = session_find_kind(s, path, SESSION_IC);
	if (!se) {
		return sd_bus_error_set(err, SD_BUS_ERROR_INVALID_ARGS, "sesión inválida");
	}
	if (sd_bus_message_skip(m, "a{sv}") < 0) return -EINVAL;
	if (sd_bus_message_enter_container(m, 'a', "a{sv}") < 0) return -EINVAL;
	struct capture_barrier *accepted = NULL;
	uint32_t *failed = NULL;
	size_t naccepted = 0, nfailed = 0;
	while ((r = sd_bus_message_at_end(m, 0)) == 0) {
		struct capture_barrier b;
		r = parse_barrier(m, &b);
		if (r < 0) break;
		if (barrier_valid(s, &b)) {
			struct capture_barrier *next = realloc(accepted, (naccepted + 1) * sizeof(*accepted));
			if (!next) { r = -ENOMEM; break; }
			accepted = next;
			accepted[naccepted++] = b;
		} else {
			uint32_t *next = realloc(failed, (nfailed + 1) * sizeof(*failed));
			if (!next) { r = -ENOMEM; break; }
			failed = next;
			failed[nfailed++] = b.id;
		}
	}
	if (r >= 0) r = sd_bus_message_exit_container(m);
	uint32_t zone_set = 0;
	if (r >= 0) r = sd_bus_message_read(m, "u", &zone_set);
	if (r < 0 || zone_set != s->zone_set) {
		free(accepted);
		free(failed);
		return r < 0 ? r : sd_bus_error_set(err, SD_BUS_ERROR_INVALID_ARGS, "zone_set inválido");
	}
	// Spec: SetPointerBarriers suspende la sesión; hay que volver a llamar Enable().
	se->enabled = 0;
	capture_deactivate(s, se);
	free(se->barriers);
	se->barriers = accepted;
	se->nbarriers = naccepted;
	r = reply_failed_barriers(m, failed, nfailed);
	free(failed);
	return r;
}

static int m_ic_enable(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct eis_server *s = ud;
	const char *path, *app_id;
	int r = sd_bus_message_read(m, "os", &path, &app_id);
	if (r < 0) {
		return r;
	}
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	struct session *se = session_find_kind(s, path, SESSION_IC);
	if (!se || !se->started) {
		return sd_bus_error_set(err, SD_BUS_ERROR_INVALID_ARGS, "sesión inválida");
	}
	se->enabled = 1;
	se->released_edge = 0;
	return sd_bus_reply_method_return(m, "ua{sv}", 0, 0);
}

static int m_ic_disable(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct eis_server *s = ud;
	const char *path, *app_id;
	int r = sd_bus_message_read(m, "os", &path, &app_id);
	if (r < 0) {
		return r;
	}
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	struct session *se = session_find_kind(s, path, SESSION_IC);
	if (!se) {
		return sd_bus_error_set(err, SD_BUS_ERROR_INVALID_ARGS, "sesión inválida");
	}
	se->enabled = 0;
	capture_deactivate(s, se);
	ic_emit_capture(se, "Disabled", 0);
	return sd_bus_reply_method_return(m, "ua{sv}", 0, 0);
}

static int m_ic_release(sd_bus_message *m, void *ud, sd_bus_error *err) {
	struct eis_server *s = ud;
	const char *path, *app_id;
	int r = sd_bus_message_read(m, "os", &path, &app_id);
	if (r < 0) {
		return r;
	}
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	struct session *se = session_find_kind(s, path, SESSION_IC);
	if (!se) {
		return sd_bus_error_set(err, SD_BUS_ERROR_INVALID_ARGS, "sesión inválida");
	}
	// options: sólo cursor_position "(dd)" interesa; -1,-1 = no vino (dance interno
	// de Deskflow: permitir que la misma orilla re-dispare, ver capture_release).
	double rx = -1.0, ry = -1.0;
	r = sd_bus_message_enter_container(m, SD_BUS_TYPE_ARRAY, "{sv}");
	if (r >= 0) {
		while (sd_bus_message_at_end(m, 0) == 0) {
			const char *key = NULL;
			r = sd_bus_message_enter_container(m, SD_BUS_TYPE_DICT_ENTRY, "sv");
			if (r < 0) {
				break;
			}
			if (sd_bus_message_read(m, "s", &key) < 0) {
				break;
			}
			if (key != NULL && strcmp(key, "cursor_position") == 0) {
				// El valor es siempre una variante; su cuerpo debería ser "(dd)".
				if (sd_bus_message_enter_container(m, SD_BUS_TYPE_VARIANT, NULL) >= 0) {
					if (sd_bus_message_read(m, "(dd)", &rx, &ry) < 0) {
						rx = ry = -1.0;
						sd_bus_message_skip(m, "*");
					}
					sd_bus_message_exit_container(m);
				}
			} else if (sd_bus_message_skip(m, "v") < 0) {
				break;
			}
			sd_bus_message_exit_container(m);
		}
		sd_bus_message_exit_container(m);
	}
	if (se->active) {
		int has_pos = rx >= 0.0 && ry >= 0.0;
		// Deskflow llama Release() sin posición en el primer motion tras Activated
		// (aún cree que el puntero está en la pantalla local) y en ese mismo motion
		// dispara el switch: si lo obedecemos, apagamos la captura y re-activamos en
		// bucle. Sólo en esa ventana pegada a la activación se ignora.
		if (!has_pos && (capture_time(0) - se->activated_at) < 250000ULL) {
			se->release_pending = 1;
			se->pend_in = 0.0;
			se->pend_out = 0.0;
			return sd_bus_reply_method_return(m, "ua{sv}", 0, 0);
		}
		capture_release(s, se, rx, ry);
	}
	return sd_bus_reply_method_return(m, "ua{sv}", 0, 0);
}

static const sd_bus_vtable rd_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_METHOD("CreateSession", "oosa{sv}", "ua{sv}", m_create_session, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("SelectDevices", "oosa{sv}", "ua{sv}", m_select_devices, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Start", "oossa{sv}", "ua{sv}", m_start, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("ConnectToEIS", "osa{sv}", "h", m_connect_to_eis, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_PROPERTY("AvailableDeviceTypes", "u", NULL, offsetof(struct eis_server, device_types), SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("version", "u", NULL, offsetof(struct eis_server, version), SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_VTABLE_END,
};
// ponytail: sin Notify* (input por D-Bus en vez de EIS); Deskflow y lan-mouse usan EIS.

static const sd_bus_vtable ic_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_METHOD("CreateSession", "oossa{sv}", "ua{sv}", m_ic_create_session, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("CreateSession2", "osa{sv}", "a{sv}", m_ic_create_session2, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Start", "oossa{sv}", "ua{sv}", m_ic_start, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("GetZones", "oosa{sv}", "ua{sv}", m_ic_get_zones, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("SetPointerBarriers", "oosa{sv}aa{sv}u", "ua{sv}", m_ic_set_pointer_barriers, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Enable", "osa{sv}", "ua{sv}", m_ic_enable, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Disable", "osa{sv}", "ua{sv}", m_ic_disable, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Release", "osa{sv}", "ua{sv}", m_ic_release, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("ConnectToEIS", "osa{sv}", "h", m_connect_to_eis, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_SIGNAL("Disabled", "oa{sv}", 0),
	SD_BUS_SIGNAL("Activated", "oa{sv}", 0),
	SD_BUS_SIGNAL("Deactivated", "oa{sv}", 0),
	SD_BUS_SIGNAL("ZonesChanged", "oa{sv}", 0),
	SD_BUS_PROPERTY("SupportedCapabilities", "u", NULL, offsetof(struct eis_server, ic_caps), SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("version", "u", NULL, offsetof(struct eis_server, ic_version), SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_VTABLE_END,
};

// ScreenCast vacío (sin fuentes; todo pedido se rechaza): libportal (Deskflow) lee la versión
// de org.freedesktop.portal.ScreenCast antes de crear una sesión RemoteDesktop, y el frontend
// sólo exporta esa interfaz si hay un backend que la implemente.
static int m_unsupported(sd_bus_message *m, void *ud, sd_bus_error *err) {
	if (!from_frontend(m, err)) {
		return -EACCES;
	}
	return sd_bus_reply_method_return(m, "ua{sv}", 2, 0);
}

static const sd_bus_vtable sc_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_METHOD("CreateSession", "oosa{sv}", "ua{sv}", m_unsupported, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("SelectSources", "oosa{sv}", "ua{sv}", m_unsupported, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_METHOD("Start", "oossa{sv}", "ua{sv}", m_unsupported, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_PROPERTY("AvailableSourceTypes", "u", NULL, offsetof(struct eis_server, sc_sources), SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("AvailableCursorModes", "u", NULL, offsetof(struct eis_server, sc_cursors), SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_PROPERTY("version", "u", NULL, offsetof(struct eis_server, sc_version), SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_VTABLE_END,
};

static void session_free(struct eis_server *s, struct session *se) {
	if (se->pending) {
		reply_start(se, 0);
	}
	if (se->eis) {
		eis_close(s, se->eis);
	}
	free(se->barriers);
	sd_bus_slot_unref(se->slot);
	free(se->path);
	free(se);
}

// --- InputCapture: eventos físicos locales ---
//
// El shell avisa por acá de cada evento FÍSICO local. Con una sesión armada y el
// puntero cruzando una barrera válida se activa la captura: Activated + emulación EIS.
// Mientras la sesión esté activa el evento se reenvía a sus clientes receiver (libei).
// Devuelven 1 si la captura consumió el evento y el shell no debe procesarlo localmente.

// Reenvía a los receiver de la sesión (cada uno cierra su frame timestamp).
static int capture_send_motion(struct session *se, double x, double y, double dx, double dy, uint64_t t) {
	int sent = 0;
	// Ventana anti-retorno: ver kick_edge/kick_until en struct session.
	if (se->kick_until != 0) {
		if (capture_time(0) < se->kick_until) {
			switch (se->kick_edge) {
				case 1: if (dx > 0.0) dx = 0.0; break; // salió por izquierda: no volver a la derecha
				case 2: if (dx < 0.0) dx = 0.0; break;
				case 3: if (dy > 0.0) dy = 0.0; break;
				case 4: if (dy < 0.0) dy = 0.0; break;
			}
		} else {
			se->kick_until = 0;
		}
	}
	for (struct client *c = se->s->clients; c; c = c->next) {
		if (c->session != se || eis_client_is_sender(c->client) || !c->device) {
			continue;
		}
		// Relativo PRIMERO: Deskflow (EiScreen::onMotionEvent) sólo procesa
		// EI_EVENT_POINTER_MOTION; su onAbsMotionEvent es un no-op. Como el
		// dispositivo también expone POINTER_ABSOLUTE (necesario para que Deskflow
		// calcule el tamaño de pantalla por la region), mandar absoluto dejaba el
		// cursor clavado: nunca cruzaba ni liberaba la captura.
		if (eis_device_has_capability(c->device, EIS_DEVICE_CAP_POINTER)) {
			eis_device_pointer_motion(c->device, dx, dy);
			eis_device_frame(c->device, t);
			sent = 1;
		} else if (eis_device_has_capability(c->device, EIS_DEVICE_CAP_POINTER_ABSOLUTE)) {
			eis_device_pointer_motion_absolute(c->device, x, y);
			eis_device_frame(c->device, t);
			sent = 1;
		}
	}
	return sent;
}

static void capture_send_button(struct session *se, uint32_t button, int pressed, uint64_t t) {
	for (struct client *c = se->s->clients; c; c = c->next) {
		if (c->session != se || eis_client_is_sender(c->client) || !c->device) continue;
		if (!eis_device_has_capability(c->device, EIS_DEVICE_CAP_BUTTON)) continue;
		eis_device_button_button(c->device, button, pressed != 0);
		eis_device_frame(c->device, t);
	}
}

static void capture_send_scroll(struct session *se, int32_t sx, int32_t sy, uint64_t t) {
	for (struct client *c = se->s->clients; c; c = c->next) {
		if (c->session != se || eis_client_is_sender(c->client) || !c->device) continue;
		if (!eis_device_has_capability(c->device, EIS_DEVICE_CAP_SCROLL)) continue;
		eis_device_scroll_discrete(c->device, sx, sy);
		eis_device_frame(c->device, t);
	}
}

static void capture_send_key(struct session *se, uint32_t key, int pressed, uint64_t t) {
	for (struct client *c = se->s->clients; c; c = c->next) {
		if (c->session != se || eis_client_is_sender(c->client) || !c->device) continue;
		if (!eis_device_has_capability(c->device, EIS_DEVICE_CAP_KEYBOARD)) continue;
		eis_device_keyboard_key(c->device, key, pressed != 0);
		eis_device_frame(c->device, t);
	}
}

int eis_server_capture_motion(eis_server *s, double x, double y, double dx, double dy, uint64_t time) {
	uint64_t t = capture_time(time);
	struct session *act = capture_active(s);
	if (act != NULL && act->release_pending) {
		if (capture_time(0) - act->activated_at > RELEASE_PENDING_US) {
			act->release_pending = 0;
		} else {
			// Componente hacia adentro de la pantalla local según el borde del cruce.
			double in = 0.0;
			switch (act->kick_edge) {
				case 1: in = dx; break;   // salió por la izquierda: adentro = +x
				case 2: in = -dx; break;  // derecha
				case 3: in = dy; break;   // arriba
				case 4: in = -dy; break;  // abajo
			}
			if (in > 0.0) {
				act->pend_in += in;
			} else {
				act->pend_out -= in;
			}
			if (act->pend_out > RELEASE_PENDING_OUT_PX) {
				act->release_pending = 0;  // se adentró en el vecino: Deskflow sí cruzó
			} else if (act->pend_in > RELEASE_PENDING_IN_PX) {
				act->release_pending = 0;
				capture_release(s, act, -1.0, -1.0);  // no cruzó: soltar ya
				return 0;  // este motion es local otra vez
			}
		}
	}
	if (act != NULL) {
		act->cursor_x = x;
		act->cursor_y = y;
		capture_send_motion(act, x, y, dx, dy, t);
		return 1;
	}
	int captured = 0;
	for (struct session *se = s->sessions; se; se = se->next) {
		if (se->closed || se->kind != SESSION_IC || !se->enabled || se->active || !capture_ready(s, se)) {
			continue;
		}
		// Sólo habilita el borde de salida cuando el usuario vuelve hacia adentro.
		capture_update_released(se, dx, dy);
		uint32_t id = barrier_crossed(s, se, x, y, dx, dy);
		if (id == 0) {
			continue;
		}
		// cursor_position puede quedar fuera de la zona (spec InputCapture::Activated:
		// así el cliente detecta que el puntero rebasó el borde), pero SÓLO en el eje
		// del cruce. Si además sobrepasamos el eje perpendicular (x+dx, y+dy), el core
		// de Deskflow calcula la fracción del borde con ese valor espurio
		// (Server::mapToFraction: Left/Right -> y; Top/Bottom -> x), cae fuera del rango
		// del link y NO cambia de pantalla: su cursor queda fuera de la pantalla
		// (fantasma invisible) y gdtk sigue capturando con pointer lock.
		se->active = 1;
		se->active_barrier = id;
		se->activated_at = capture_time(0);
		se->release_pending = 0;
		se->kick_edge = 0;
		for (size_t i = 0; i < se->nbarriers; i++) {
			if (se->barriers[i].id == id) {
				se->kick_edge = (uint32_t)barrier_edge(s, &se->barriers[i]);
				break;
			}
		}
		se->kick_until = se->kick_edge != 0 ? capture_time(0) + 300000ULL : 0;
		se->cursor_x = x;
		se->cursor_y = y;
		if (se->kick_edge == 1 || se->kick_edge == 2) {
			se->cursor_x = x + dx; // borde izq/der: sólo x sobrepasa
		} else if (se->kick_edge == 3 || se->kick_edge == 4) {
			se->cursor_y = y + dy; // borde arriba/abajo: sólo y sobrepasa
		}
		se->activation_id += 16; // salto amplio: detecta wrap del contador
		ic_emit_capture(se, "Activated", 1);
		session_emulating(s, se, 1);
		capture_send_motion(se, x, y, dx, dy, t);
		captured = 1;
	}
	return captured;
}

int eis_server_capture_button(eis_server *s, uint32_t button, int pressed, uint64_t time) {
	struct session *act = capture_active(s);
	if (act == NULL) {
		return 0;
	}
	capture_send_button(act, button, pressed, capture_time(time));
	return 1;
}

int eis_server_capture_scroll(eis_server *s, double dx, double dy, uint64_t time) {
	struct session *act = capture_active(s);
	if (act == NULL) {
		return 0;
	}
	// El shell manda muescas (±1); EIS discrete usa 1/120 de muesca por unidad.
	capture_send_scroll(act, (int32_t)(dx * 120.0), (int32_t)(dy * 120.0), capture_time(time));
	return 1;
}

int eis_server_capture_key(eis_server *s, uint32_t key, int pressed, uint64_t time) {
	struct session *act = capture_active(s);
	if (act == NULL) {
		return 0;
	}
	capture_send_key(act, key, pressed, capture_time(time));
	return 1;
}

// --- API ---

eis_server *eis_server_create(eis_server_callbacks cb, const char *keymap, int w, int h, const char *test_socket) {
	struct eis_server *s = calloc(1, sizeof(*s));
	s->cb = cb;
	s->w = w > 0 ? w : 1;
	s->h = h > 0 ? h : 1;
	s->device_types = DEVICE_TYPES;
	s->version = 2;
	s->sc_version = 5;
	s->ic_caps = DEVICE_TYPES;
	s->ic_version = 2;
	s->zone_set = 1;
	for (int i = 1; i <= 4; i++) {
		s->capture_lo[i] = 0.0;
		s->capture_hi[i] = 100.0;
	}
	s->keymap_fd = -1;
	if (keymap && *keymap) {
		// Con el '\0' final: los clientes lo mapean y lo leen como string.
		s->keymap_size = strlen(keymap) + 1;
		s->keymap_fd = memfd_create("gdtk-keymap", MFD_CLOEXEC);
		if (s->keymap_fd >= 0 && write(s->keymap_fd, keymap, s->keymap_size) != (ssize_t)s->keymap_size) {
			close(s->keymap_fd);
			s->keymap_fd = -1;
		}
	}
	if (test_socket && *test_socket) {
		s->test = eis_new(s);
		if (eis_setup_backend_socket(s->test, test_socket) < 0) {
			fprintf(stderr, "eis: no se pudo abrir el socket de prueba %s\n", test_socket);
			s->test = eis_unref(s->test);
		}
	}
	int r = sd_bus_open_user(&s->bus);
	if (r >= 0) {
		r = sd_bus_add_object_vtable(s->bus, &s->slot, OBJ_PATH, "org.freedesktop.impl.portal.RemoteDesktop", rd_vtable, s);
	}
	if (r >= 0) {
		r = sd_bus_add_object_vtable(s->bus, &s->sc_slot, OBJ_PATH, "org.freedesktop.impl.portal.ScreenCast", sc_vtable, s);
	}
	if (r >= 0) {
		r = sd_bus_add_object_vtable(s->bus, &s->ic_slot, OBJ_PATH, "org.freedesktop.impl.portal.InputCapture", ic_vtable, s);
	}
	if (r >= 0) {
		r = sd_bus_request_name(s->bus, BUS_NAME, 0);
	}
	if (r < 0) {
		snprintf(s->error, sizeof(s->error), "sin portal RemoteDesktop (%s: %s)", BUS_NAME, strerror(-r));
		s->slot = sd_bus_slot_unref(s->slot);
		s->sc_slot = sd_bus_slot_unref(s->sc_slot);
		s->ic_slot = sd_bus_slot_unref(s->ic_slot);
		s->bus = sd_bus_flush_close_unref(s->bus);
	}
	return s;
}

const char *eis_server_error(eis_server *s) {
	return s->error;
}

// 1 si el backend InputCapture quedó registrado en el bus (el gate del shell pregunta
// esto en vez de adivinar por el .portal: la interfaz es lo que atiende a Deskflow).
int eis_server_has_input_capture(eis_server *s) {
	return s && s->ic_slot != NULL;
}

int eis_server_is_capturing(eis_server *s) {
	return s != NULL && capture_active(s) != NULL;
}

// Suelta la captura activa por decisión del shell (red de seguridad): si el equipo
// destino se cayó y el cliente InputCapture (Deskflow) no pide Release, el puntero
// quedaba atrapado. Igual que un Release sin posición: Deactivated + histéresis del
// borde activo para no re-disparar en el acto. Devuelve 1 si había captura.
int eis_server_release_capture(eis_server *s) {
	if (s == NULL) {
		return 0;
	}
	struct session *se = capture_active(s);
	if (se == NULL) {
		return 0;
	}
	capture_release(s, se, -1.0, -1.0);
	return 1;
}

void eis_server_dispatch(eis_server *s) {
	if (s->bus) {
		while (sd_bus_process(s->bus, NULL) > 0) {
		}
	}
	for (struct session **p = &s->sessions; *p;) {
		struct session *se = *p;
		if (se->closed) {
			*p = se->next;
			session_free(s, se);
			continue;
		}
		if (se->eis) {
			handle_eis(s, se, se->eis);
		}
		p = &se->next;
	}
	// Nudge diferido de arranque (ver struct session): emitir ZonesChanged sólo si el
	// cliente IC todavía no armó barreras. Si ya armó/habilitó, emitirlo lo hace
	// rearmar sin Enable y la captura queda muerta.
	uint64_t now = capture_time(0);
	for (struct session *se = s->sessions; se; se = se->next) {
		if (se->kind != SESSION_IC || se->zones_nudge_at == 0 || now < se->zones_nudge_at) {
			continue;
		}
		se->zones_nudge_at = 0;
		if (se->nbarriers == 0) {
			ic_emit_capture(se, "ZonesChanged", 0);
		}
	}
	if (s->test) {
		handle_eis(s, NULL, s->test);
	}
}

void eis_server_set_size(eis_server *s, int w, int h) {
	if (w <= 0 || h <= 0 || (w == s->w && h == s->h)) {
		return;
	}
	s->w = w;
	s->h = h;
	// Las barreras apuntan a los bordes viejos: se invalidan (zone_set cambia) y
	// la captura se corta; el cliente debe pedir GetZones y SetPointerBarriers otra vez.
	s->zone_set++;
	for (struct session *se = s->sessions; se; se = se->next) {
		if (se->kind != SESSION_IC) {
			continue;
		}
		se->enabled = 0;
		capture_deactivate(s, se);
		free(se->barriers);
		se->barriers = NULL;
		se->nbarriers = 0;
		// Sin esto el cliente queda armado con el zone_set viejo y nunca rearme:
		// ZonesChanged lo manda a GetZones + SetPointerBarriers + Enable otra vez.
		ic_emit_capture(se, "ZonesChanged", 0);
	}
	// La región no se puede cambiar: dispositivo nuevo con la región nueva.
	for (struct client *c = s->clients; c; c = c->next) {
		if (c->device) {
			device_update(s, c);
		}
	}
}

void eis_server_set_capture_ranges(eis_server *s, const double *ranges) {
	if (!s) {
		return;
	}
	for (int e = 1; e <= 4; e++) {
		s->capture_lo[e] = 0.0;
		s->capture_hi[e] = 100.0;
	}
	if (!ranges) {
		return;
	}
	for (int e = 1; e <= 4; e++) {
		double lo = ranges[(e - 1) * 2 + 0];
		double hi = ranges[(e - 1) * 2 + 1];
		if (lo < 0.0) lo = 0.0;
		if (hi > 100.0) hi = 100.0;
		if (hi < lo) {
			lo = 0.0;
			hi = 100.0;
		}
		s->capture_lo[e] = lo;
		s->capture_hi[e] = hi;
	}
}

void eis_server_respond(eis_server *s, int id, int allow) {
	for (struct session *se = s->sessions; se; se = se->next) {
		if (se->pending && se->req_id == id) {
			reply_start(se, allow);
			return;
		}
	}
}

int eis_server_pending(eis_server *s, int id) {
	for (struct session *se = s->sessions; se; se = se->next) {
		if (se->pending && se->req_id == id) {
			return 1;
		}
	}
	return 0;
}

int eis_server_clients(eis_server *s) {
	int n = 0;
	for (struct client *c = s->clients; c; c = c->next) {
		n++;
	}
	return n;
}

void eis_server_destroy(eis_server *s) {
	while (s->sessions) {
		struct session *se = s->sessions;
		s->sessions = se->next;
		session_free(s, se);
	}
	if (s->test) {
		eis_close(s, s->test);
	}
	sd_bus_slot_unref(s->slot);
	sd_bus_slot_unref(s->sc_slot);
	sd_bus_slot_unref(s->ic_slot);
	sd_bus_flush_close_unref(s->bus);
	if (s->keymap_fd >= 0) {
		close(s->keymap_fd);
	}
	free(s);
}
