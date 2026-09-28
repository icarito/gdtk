#include "register_types.h"

#include "remote_input.h"
#include "wayland_compositor.h"

#include "core/class_db.h"

void register_wayland_types() {
	ClassDB::register_class<WaylandCompositor>();
	ClassDB::register_class<RemoteInput>();
}

void unregister_wayland_types() {
}
