#include "gdtk_inotify.h"

#include "core/class_db.h"
#include "core/print_string.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

void GdtkFileWatch::_bind_methods() {
	ClassDB::bind_method(D_METHOD("watch", "dir"), &GdtkFileWatch::watch);
	ClassDB::bind_method(D_METHOD("start"), &GdtkFileWatch::start);
	ClassDB::bind_method(D_METHOD("stop"), &GdtkFileWatch::stop);
	ClassDB::bind_method(D_METHOD("is_watching"), &GdtkFileWatch::is_watching);
	ClassDB::bind_method(D_METHOD("watch_count"), &GdtkFileWatch::watch_count);
	ADD_SIGNAL(MethodInfo("changed"));
}

GdtkFileWatch::GdtkFileWatch() {
	stop_pipe[0] = -1;
	stop_pipe[1] = -1;
	ifd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	if (ifd < 0) {
		WARN_PRINT("GdtkFileWatch: inotify_init1 falló; sin auto-detección en vivo.");
		return;
	}
	if (pipe2(stop_pipe, O_NONBLOCK | O_CLOEXEC) != 0) {
		WARN_PRINT("GdtkFileWatch: pipe2 falló; sin auto-detección en vivo.");
		close(ifd);
		ifd = -1;
	}
}

GdtkFileWatch::~GdtkFileWatch() {
	stop();
	if (ifd >= 0) {
		close(ifd);
		ifd = -1;
	}
	if (stop_pipe[0] >= 0) {
		close(stop_pipe[0]);
		stop_pipe[0] = -1;
	}
	if (stop_pipe[1] >= 0) {
		close(stop_pipe[1]);
		stop_pipe[1] = -1;
	}
}

void GdtkFileWatch::_add_watch(const String &p_dir) {
	if (ifd < 0) {
		return;
	}
	// Si el directorio todavía no existe, se vigila el padre: así la creación del
	// subdirectorio (p. ej. ~/.local/share/applications) también avisa.
	String target = p_dir;
	struct stat st;
	if (stat(p_dir.utf8().get_data(), &st) != 0 || !S_ISDIR(st.st_mode)) {
		String parent = p_dir.get_base_dir();
		if (parent != "" && parent != p_dir) {
			target = parent;
		}
	}
	const uint32_t mask = IN_CREATE | IN_DELETE | IN_MOVED_TO | IN_MOVED_FROM |
			IN_CLOSE_WRITE | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF;
	int wd = inotify_add_watch(ifd, target.utf8().get_data(), mask);
	if (wd >= 0) {
		wds++;
	}
}

bool GdtkFileWatch::watch(const String &p_dir) {
	if (ifd < 0) {
		return false;
	}
	mutex.lock();
	int before = wds;
	_add_watch(p_dir);
	bool added = wds > before;
	mutex.unlock();
	return added;
}

void GdtkFileWatch::start() {
	if (ifd < 0) {
		return;
	}
	mutex.lock();
	if (running) {
		mutex.unlock();
		return;
	}
	stop_flag = false;
	running = true;
	mutex.unlock();
	thread = memnew(Thread);
	thread->start(_thread_func, this);
}

void GdtkFileWatch::stop() {
	mutex.lock();
	if (!running || thread == nullptr) {
		running = false;
		mutex.unlock();
		return;
	}
	stop_flag = true;
	mutex.unlock();
	if (stop_pipe[1] >= 0) {
		char b = 1;
		ssize_t ignored = ::write(stop_pipe[1], &b, 1);
		(void)ignored;
	}
	thread->wait_to_finish();
	memdelete(thread);
	thread = nullptr;
	mutex.lock();
	running = false;
	mutex.unlock();
}

bool GdtkFileWatch::is_watching() const {
	mutex.lock();
	bool r = ifd >= 0 && wds > 0;
	mutex.unlock();
	return r;
}

int GdtkFileWatch::watch_count() const {
	mutex.lock();
	int n = wds;
	mutex.unlock();
	return n;
}

void GdtkFileWatch::_thread_func(void *p_ud) {
	static_cast<GdtkFileWatch *>(p_ud)->_run();
}

void GdtkFileWatch::_run() {
	// inotify exige un buffer alineado al tamaño de struct inotify_event.
	char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
	while (true) {
		struct pollfd fds[2];
		fds[0].fd = ifd;
		fds[0].events = POLLIN;
		fds[0].revents = 0;
		fds[1].fd = stop_pipe[0];
		fds[1].events = POLLIN;
		fds[1].revents = 0;
		int pr = poll(fds, 2, -1);
		if (pr < 0) {
			if (errno == EINTR) {
				continue;
			}
			break;
		}
		if (fds[1].revents & POLLIN) {
			break;
		}
		if (fds[0].revents & POLLIN) {
			// Drena todo lo pendiente y avisa una sola vez (el consumidor reescanea
			// el conjunto completo; no hace falta distinguir el evento).
			while (true) {
				ssize_t n = ::read(ifd, buf, sizeof(buf));
				if (n <= 0) {
					break;
				}
			}
			call_deferred("emit_signal", "changed");
		}
	}
}
