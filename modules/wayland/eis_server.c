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
#include <sys/mman.h>
#include <unistd.h>

#define BUS_NAME "org.freedesktop.impl.portal.desktop.gdtk"
#define FRONTEND_NAME "org.freedesktop.portal.Desktop"
#define OBJ_PATH "/org/freedesktop/portal/desktop"
#define DEVICE_TYPES 3 // KEYBOARD | POINTER

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
	uint32_t caps; // lo que el cliente pidió en el bind
	struct client *next;
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
	struct session *next;
};

struct eis_server {
	eis_server_callbacks cb;
	sd_bus *bus;
	sd_bus_slot *slot, *sc_slot;
	struct eis *test;
	struct session *sessions;
	struct client *clients;
	int keymap_fd;
	size_t keymap_size;
	int w, h, next_id;
	// Propiedades del backend (las lee sd-bus por offset).
	uint32_t device_types, version;
	uint32_t sc_sources, sc_cursors, sc_version;
	char error[160];
};

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
}

static void client_free(struct eis_server *s, struct client *c) {
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
}

static void handle_eis(struct eis_server *s, struct eis *ctx) {
	eis_dispatch(ctx);
	struct eis_event *e;
	while ((e = eis_get_event(ctx)) != NULL) {
		struct eis_client *ec = eis_event_get_client(e);
		struct client *c = ec ? eis_client_get_user_data(ec) : NULL;
		void *ud = s->cb.ud;
		switch (eis_event_get_type(e)) {
			case EIS_EVENT_CLIENT_CONNECT:
				// Sólo clientes que mandan input (sender); un receiver no tiene nada que hacer acá.
				if (!eis_client_is_sender(ec)) {
					eis_client_disconnect(ec);
					break;
				}
				c = calloc(1, sizeof(*c));
				c->ctx = ctx;
				c->client = eis_client_ref(ec);
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
	struct session *se = calloc(1, sizeof(*se));
	se->s = s;
	se->path = strdup(path);
	se->version = 1;
	se->pid = session_pid(s->bus, path);
	r = sd_bus_add_object_vtable(s->bus, &se->slot, path, "org.freedesktop.impl.portal.Session", session_vtable, se);
	if (r < 0) {
		free(se->path);
		free(se);
		return r;
	}
	se->next = s->sessions;
	s->sessions = se;
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
	struct session *se = session_find(s, path);
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
	sd_bus_slot_unref(se->slot);
	free(se->path);
	free(se);
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
		r = sd_bus_request_name(s->bus, BUS_NAME, 0);
	}
	if (r < 0) {
		snprintf(s->error, sizeof(s->error), "sin portal RemoteDesktop (%s: %s)", BUS_NAME, strerror(-r));
		s->slot = sd_bus_slot_unref(s->slot);
		s->sc_slot = sd_bus_slot_unref(s->sc_slot);
		s->bus = sd_bus_flush_close_unref(s->bus);
	}
	return s;
}

const char *eis_server_error(eis_server *s) {
	return s->error;
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
			handle_eis(s, se->eis);
		}
		p = &se->next;
	}
	if (s->test) {
		handle_eis(s, s->test);
	}
}

void eis_server_set_size(eis_server *s, int w, int h) {
	if (w <= 0 || h <= 0 || (w == s->w && h == s->h)) {
		return;
	}
	s->w = w;
	s->h = h;
	// La región no se puede cambiar: dispositivo nuevo con la región nueva.
	for (struct client *c = s->clients; c; c = c->next) {
		if (c->device) {
			device_update(s, c);
		}
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
	sd_bus_flush_close_unref(s->bus);
	if (s->keymap_fd >= 0) {
		close(s->keymap_fd);
	}
	free(s);
}
