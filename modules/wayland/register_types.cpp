#include "register_types.h"

#include "wayland_compositor.h"

#include "core/class_db.h"

void register_wayland_types() {
	ClassDB::register_class<WaylandCompositor>();
}

void unregister_wayland_types() {
}
