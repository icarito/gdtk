#ifndef DEBUG_LOG_H
#define DEBUG_LOG_H

#include "core/array.h"
#include "core/dictionary.h"
#include "core/io/logger.h"
#include "core/object.h"
#include "core/os/mutex.h"
#include "core/ustring.h"
#include "core/variant.h"

// Buffer circular de logs del motor, siempre vivo mientras el modulo imgui
// este cargado. El Logger propio (DebugLogger) escribe aqui desde cualquier
// hilo; `get_entries` lo lee desde el hilo principal (GDScript).
class DebugLog : public Object {
	GDCLASS(DebugLog, Object);

public:
	static const int MAX_ENTRIES = 2000;

private:
	struct Entry {
		uint64_t id;
		uint64_t time_ms;
		String text;
		bool is_error;
	};

	static DebugLog *singleton;

	Entry entries[MAX_ENTRIES];
	int head;
	int count;
	uint64_t next_id;
	Mutex mutex;

protected:
	static void _bind_methods();

public:
	static DebugLog *get_singleton() { return singleton; }
	static void create();
	static void destroy();

	void push(const String &p_text, bool p_error);

	Array get_entries(int p_since_id);
	void clear();
	int last_id();

	DebugLog();
	~DebugLog();
};

// Logger propio: no hereda de Object; lo posee OS a traves de su CompositeLogger.
class DebugLogger : public Logger {
public:
	virtual void logv(const char *p_format, va_list p_list, bool p_err) _PRINTF_FORMAT_ATTRIBUTE_2_0;
	virtual void log_error(const char *p_function, const char *p_file, int p_line, const char *p_code, const char *p_rationale, ErrorType p_type = ERR_ERROR);
	virtual ~DebugLogger();
};

#endif // DEBUG_LOG_H
