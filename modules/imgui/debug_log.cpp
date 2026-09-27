#include "debug_log.h"

#include "core/class_db.h"
#include "core/os/os.h"

#include <stdio.h>

DebugLog *DebugLog::singleton = nullptr;

void DebugLog::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_entries", "since_id"), &DebugLog::get_entries, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("clear"), &DebugLog::clear);
	ClassDB::bind_method(D_METHOD("last_id"), &DebugLog::last_id);
}

DebugLog::DebugLog() {
	head = 0;
	count = 0;
	next_id = 1;
}

DebugLog::~DebugLog() {
}

void DebugLog::create() {
	ERR_FAIL_COND(singleton != nullptr);
	singleton = memnew(DebugLog);
}

void DebugLog::destroy() {
	if (singleton != nullptr) {
		memdelete(singleton);
		singleton = nullptr;
	}
}

void DebugLog::push(const String &p_text, bool p_error) {
	MutexLock lock(mutex);
	Entry &entry = entries[head];
	entry.id = next_id++;
	entry.time_ms = OS::get_singleton() != nullptr ? (uint64_t)OS::get_singleton()->get_ticks_msec() : 0;
	entry.text = p_text;
	entry.is_error = p_error;
	head = (head + 1) % MAX_ENTRIES;
	if (count < MAX_ENTRIES) {
		count++;
	}
}

Array DebugLog::get_entries(int p_since_id) {
	MutexLock lock(mutex);
	Array result;
	int start = (count < MAX_ENTRIES) ? 0 : head;
	for (int i = 0; i < count; i++) {
		const Entry &entry = entries[(start + i) % MAX_ENTRIES];
		if ((int64_t)entry.id <= (int64_t)p_since_id) {
			continue;
		}
		Dictionary dict;
		dict["id"] = (int64_t)entry.id;
		dict["time_ms"] = (int64_t)entry.time_ms;
		dict["text"] = entry.text;
		dict["is_error"] = entry.is_error;
		result.push_back(dict);
	}
	return result;
}

void DebugLog::clear() {
	MutexLock lock(mutex);
	head = 0;
	count = 0;
}

int DebugLog::last_id() {
	MutexLock lock(mutex);
	return next_id == 0 ? 0 : (int)(next_id - 1);
}

void DebugLogger::logv(const char *p_format, va_list p_list, bool p_err) {
	if (DebugLog::get_singleton() == nullptr) {
		return;
	}
	char buffer[4096];
	int written = vsnprintf(buffer, sizeof(buffer), p_format, p_list);
	if (written <= 0) {
		return;
	}
	if (written >= (int)sizeof(buffer)) {
		written = sizeof(buffer) - 1;
	}
	buffer[written] = 0;
	// No llamar a OS::print/printerr aqui: recursion. Solo se escribe el buffer.
	DebugLog::get_singleton()->push(String::utf8(buffer).strip_edges(false, true), p_err);
}

void DebugLogger::log_error(const char *p_function, const char *p_file, int p_line, const char *p_code, const char *p_rationale, ErrorType p_type) {
	if (DebugLog::get_singleton() == nullptr) {
		return;
	}
	String text = String::utf8(p_code != nullptr ? p_code : "");
	if (p_rationale != nullptr && *p_rationale) {
		text += " (" + String::utf8(p_rationale) + ")";
	}
	text += " at " + String::utf8(p_function != nullptr ? p_function : "?");
	if (p_file != nullptr) {
		text += " (" + String::utf8(p_file) + ":" + itos(p_line) + ")";
	}
	DebugLog::get_singleton()->push(text.strip_edges(false, true), true);
}

DebugLogger::~DebugLogger() {
}
