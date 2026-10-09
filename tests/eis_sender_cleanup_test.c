// Transporte real libei/libeis, sin portal ni sesión viva.
// Compilar con libei-1.0, libeis-1.0 y libsystemd (pkg-config).
#include "../modules/wayland/eis_server.c"
#include <libei.h>
#include <assert.h>

struct test_client {
	struct ei *ctx;
	struct ei_device *device;
};
static int stopped, pressed;
static void stopped_cb(void *ud) { (void)ud; stopped++; }
static void button_cb(void *ud, uint32_t button, int down) {
	(void)ud;
	assert(button == 0x110);
	pressed += down;
}
static void pump(struct eis_server *s, struct eis *ctx, struct test_client *clients, int n) {
	for (int round = 0; round < 40; round++) {
		handle_eis(s, NULL, ctx);
		for (int i = 0; i < n; i++) {
			if (!clients[i].ctx) continue;
			ei_dispatch(clients[i].ctx);
			struct ei_event *e;
			while ((e = ei_get_event(clients[i].ctx))) {
				if (ei_event_get_type(e) == EI_EVENT_SEAT_ADDED) {
					ei_seat_bind_capabilities(ei_event_get_seat(e), EI_DEVICE_CAP_BUTTON, NULL);
				} else if (ei_event_get_type(e) == EI_EVENT_DEVICE_ADDED) {
					clients[i].device = ei_device_ref(ei_event_get_device(e));
				}
				ei_event_unref(e);
			}
		}
	}
}
static void connect_client(struct eis *ctx, struct test_client *c, int sender) {
	c->ctx = sender ? ei_new_sender(NULL) : ei_new_receiver(NULL);
	assert(c->ctx);
	ei_configure_name(c->ctx, sender ? "cleanup-sender" : "cleanup-receiver");
	assert(ei_setup_backend_fd(c->ctx, eis_backend_fd_add_client(ctx)) == 0);
}
static void close_client(struct test_client *c) {
	if (c->device) ei_device_unref(c->device);
	ei_unref(c->ctx);
	c->ctx = NULL;
	c->device = NULL;
}
int main(void) {
	uint64_t before = capture_time(0);
	uint64_t supplied = capture_time(1); // Godot's process-relative ms must not leak.
	uint64_t after = capture_time(0);
	assert(supplied >= before && supplied <= after);
	puts("ok: capture timestamps use CLOCK_MONOTONIC regardless of Godot ticks");
	struct eis_server s = {0};
	s.w = 1280; s.h = 720; s.keymap_fd = -1;
	s.cb.stop_emulating = stopped_cb;
	s.cb.button = button_cb;
	struct eis *ctx = eis_new(&s);
	assert(ctx && eis_setup_backend_fd(ctx) == 0);
	struct test_client clients[3] = {0};
	connect_client(ctx, &clients[0], 0); // Receiver remains connected throughout.
	connect_client(ctx, &clients[1], 1);
	connect_client(ctx, &clients[2], 1); // Inactive sender must not reset owner.
	pump(&s, ctx, clients, 3);
	assert(eis_server_clients(&s) == 3 && clients[1].device);
	ei_device_start_emulating(clients[1].device, 1);
	ei_device_button_button(clients[1].device, 0x110, true);
	ei_device_frame(clients[1].device, ei_now(clients[1].ctx));
	pump(&s, ctx, clients, 3);
	assert(pressed == 1 && s.input_owner && stopped == 0);
	close_client(&clients[2]);
	pump(&s, ctx, clients, 3);
	assert(eis_server_clients(&s) == 2 && stopped == 0 && s.input_owner);
	puts("ok: inactive sender disconnect does not reset active input");
	close_client(&clients[1]);
	pump(&s, ctx, clients, 3);
	assert(eis_server_clients(&s) == 1 && stopped == 1 && !s.input_owner);
	puts("ok: active sender disconnect resets input while receiver stays connected");
	connect_client(ctx, &clients[1], 1);
	pump(&s, ctx, clients, 3);
	assert(clients[1].device);
	ei_device_start_emulating(clients[1].device, 1);
	ei_device_button_button(clients[1].device, 0x110, true);
	ei_device_frame(clients[1].device, ei_now(clients[1].ctx));
	pump(&s, ctx, clients, 3);
	assert(pressed == 2 && stopped == 1 && s.input_owner);
	ei_device_stop_emulating(clients[1].device);
	pump(&s, ctx, clients, 3);
	assert(stopped == 2 && !s.input_owner);
	close_client(&clients[1]);
	pump(&s, ctx, clients, 3);
	assert(stopped == 2);
	puts("ok: stopping emulation resets once; later disconnect does not reset again");
	close_client(&clients[0]);
	pump(&s, ctx, clients, 3);
	assert(stopped == 2 && eis_server_clients(&s) == 0);
	eis_unref(ctx);
	return 0;
}
