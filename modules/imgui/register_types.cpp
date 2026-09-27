#include "register_types.h"

#include "debug_log.h"
#include "imgui_canvas.h"

#include "core/class_db.h"
#include "core/engine.h"
#include "core/os/os.h"

// OS::add_logger es protected. El spec pide registrarlo sin parchear el motor:
// se expone via una subclase auxiliar (nunca instanciada) y se llama por
// puntero a miembro.
struct OSAccess : public OS {
	using OS::add_logger;
};

static DebugLogger *debug_logger = nullptr;

void register_imgui_types() {
	ClassDB::register_class<ImGuiCanvas>();
	ClassDB::register_class<DebugLog>();

	DebugLog::create();
	Engine::get_singleton()->add_singleton(Engine::Singleton("DebugLog", DebugLog::get_singleton()));

	debug_logger = memnew(DebugLogger);
	auto add_logger_fn = &OSAccess::add_logger;
	(OS::get_singleton()->*add_logger_fn)(debug_logger);
}

void unregister_imgui_types() {
	// El Logger no se desregistra a mano: lo libera OS (su CompositeLogger).
	// DebugLog se deja vivo por si quedan logs de apagado.
}
