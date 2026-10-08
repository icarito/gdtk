#include "register_types.h"

#include "gdtk_inotify.h"

#include "core/class_db.h"

void register_inotify_types() {
	ClassDB::register_class<GdtkFileWatch>();
}

void unregister_inotify_types() {
}
