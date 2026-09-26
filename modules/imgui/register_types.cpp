#include "register_types.h"

#include "imgui_canvas.h"

#include "core/class_db.h"

void register_imgui_types() {
	ClassDB::register_class<ImGuiCanvas>();
}

void unregister_imgui_types() {
}
