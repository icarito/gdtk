/*
 * GdtkFileWatch: vigilante de directorios por inotify del kernel, sin sondeo.
 *
 * Una clase nativa (Object) que vigila uno o varios directorios y emite la señal
 * `changed` (vía call_deferred, así corre en el hilo principal) cuando el kernel
 * reporta alta/baja/cambio de entradas. El consumidor GDScript reescanea sólo
 * cuando llega la señal; no hay recorrido periódico del filesystem.
 *
 * Un hilo bloqueado en poll() sobre el fd de inotify (y un self-pipe para salir)
 * drena los eventos y coalesce: varias ráfagas seguidas producen, como mucho, un
 * aviso por vuelta del bucle. Si el directorio pedido no existe, se vigila su
 * padre para detectar su creación.
 *
 * Linux únicamente (sys/inotify.h). Ver shell/apps.gd (auto-rescan de apps).
 */

#ifndef GDTK_INOTIFY_H
#define GDTK_INOTIFY_H

#include "core/object.h"
#include "core/os/mutex.h"
#include "core/os/thread.h"

class GdtkFileWatch : public Object {
	GDCLASS(GdtkFileWatch, Object);

	int ifd = -1;
	int stop_pipe[2];
	int wds = 0;
	Thread *thread = nullptr;
	mutable Mutex mutex;
	bool running = false;
	bool stop_flag = false;

	static void _thread_func(void *p_ud);
	void _run();
	void _add_watch(const String &p_dir);

protected:
	static void _bind_methods();

public:
	bool watch(const String &p_dir);
	void start();
	void stop();
	bool is_watching() const;
	int watch_count() const;

	GdtkFileWatch();
	~GdtkFileWatch();
};

#endif // GDTK_INOTIFY_H
