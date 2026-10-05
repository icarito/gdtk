#ifndef WL_SERVER_H
#define WL_SERVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wl_server wl_server;

// Una capa del arbol de un toplevel: la surface raiz, una subsurface o un
// popup. `key` es la identidad estable de la surface (su puntero). x,y son
// relativos a la raiz y w,h el tamano logico de la surface, en orden de dibujo.
typedef struct {
	uint64_t key;
	int x, y, w, h;
} wl_server_layer;

typedef struct {
	void *ud;
	void (*added)(void *ud, int id);
	void (*removed)(void *ud, int id);
	// pixels del buffer shm en el FourCC DRM `format` con `stride` bytes por
	// linea. Apuntan a la memoria del cliente: validos SOLO durante la llamada.
	void (*frame)(void *ud, int id, uint64_t key, const unsigned char *data, int w, int h, uint32_t format, int stride);
	// la surface `key` tiene un buffer dmabuf: C++ asegura la ImageTexture del
	// tamano dado y llama wl_server_bind_dmabuf con su texid.
	void (*dmabuf)(void *ud, int id, uint64_t key, int w, int h);
	void (*title)(void *ud, int id, const char *title);
	// Superficie layer-shell `id`: 1 mapeada, 0 desmapeada, -1 destruida.
	void (*layer)(void *ud, int id, int state);
	// xdg-activation: el toplevel `id` pide pasar al frente.
	void (*activate)(void *ud, int id);
	// El cliente pide minimizarse (xdg_toplevel.set_minimized o iconify X11).
	void (*minimize)(void *ud, int id);
	// El cliente pide maximizar/desmaximizar (xdg_toplevel.set_maximized). `maximized`
	// es el estado pedido (1/0); el borde ya lo confirmo en el configure y el shell
	// decide como acomodar la ventana en su workspace.
	void (*maximize)(void *ud, int id, int maximized);
	// El cliente pide pantalla completa (xdg_toplevel.set_fullscreen o X11
	// _NET_WM_STATE_FULLSCREEN). `fullscreen` es el estado pedido (1/0).
	void (*fullscreen)(void *ud, int id, int fullscreen);
	// El cliente pide mover su ventana (arrastre de su propia barra/CSD). El shell
	// implementa el arrastre interactivo (no hay movimiento embebido en el compositor).
	void (*move)(void *ud, int id);
	// El cliente pide redimensionar por uno o más bordes (bitfield WLR_EDGE_*, 1=top
	// 2=bottom 4=left 8=right).
	void (*resize)(void *ud, int id, int edges);
	// Algo del árbol de `id` desapareció sin commit (menú X o popup cerrado): redibujar.
	void (*damage)(void *ud, int id);
	// El cliente enfocado pidió bloquear el puntero (zwp_locked_pointer_v1: SDL lo usa
	// para el modo relativo de emuladores/juegos). `locked`=1 mientras dura el lock;
	// el shell debe capturar el puntero del host y mandar movimiento relativo por
	// wl_server_pointer_motion_relative. `id` es el toplevel enfocado (0 al soltar).
	void (*pointer_lock)(void *ud, int id, int locked);
	// Icono de drag and drop (wl_data_device.set_icon): buffer shm del cliente con
	// el mismo (w,h,format,stride) que `frame`, valido SOLO durante la llamada.
	// `dx`/`dy` son el hotspot (offset del attach/offset del surface): el top-left
	// del icono va en puntero+(dx,dy). El shell lo dibuja. `data`==NULL al terminar
	// el drag o al reemplazarse el icono.
	void (*drag_icon)(void *ud, const unsigned char *data, int w, int h, uint32_t format, int stride, int dx, int dy);
	// Drag and drop activo (1) o terminado (0), aunque no haya icono. El shell lo
	// usa para seguir reenviando boton/limpiando foco aunque el puntero salga de
	// toda ventana (cancelar el drop sobre el escritorio).
	void (*drag_state)(void *ud, int active);
	// El cliente con foco pidio un cursor (wl_pointer.set_cursor). `hidden`=1
	// cuando mando surface NULL (cursor oculto; p.ej. juego con pointer lock) y
	// el shell debe ocultar su cursor dibujado; 0 cuando mando una surface.
	void (*cursor_hidden)(void *ud, int hidden);
	// Forma de cursor pedida por el cliente con foco (wp_cursor_shape_v1), ya como
	// Input::CursorShape de Godot. 0 (ARROW) tambien al cambiar/perder el foco.
	void (*cursor_shape)(void *ud, int shape);
	// Cursor por surface (wl_pointer.set_cursor con surface): buffer shm del cliente
	// (mismo formato que `frame`, valido SOLO durante la llamada) y hotspot en px.
	void (*cursor_image)(void *ud, const unsigned char *data, int w, int h, uint32_t format, int stride, int hx, int hy);
	// Salidas logicas (multi-output): se avisa al agregar, reconfigurar y quitar
	// una salida. La principal creada en wl_server_create NO emite output_added
	// (el nodo Godot todavia no tiene el puntero al server en ese momento); el
	// shell la consulta con wl_server_output_primary/get.
	void (*output_added)(void *ud, int id);
	void (*output_changed)(void *ud, int id);
	void (*output_removed)(void *ud, int id);
	// Una ventana cambio de salida (asignacion explicita o reasignacion al
	// retirar una salida). `output_id` es la nueva salida.
	void (*toplevel_output_changed)(void *ud, int toplevel_id, int output_id);
} wl_server_callbacks;

// Superficie layer-shell mapeada: rect en coords del output (la vista), capa 0..3
// (background, bottom, top, overlay).
typedef struct {
	int id, layer;
	int x, y, w, h;
} wl_server_layer_surface;

// Descriptor de una salida logica (wrl_output headless + ubicacion en el layout
// global del compositor embebido). x,y,width,height son geometria LOGICA en
// coords globales; scale es el factor entero de escala. `name` apunta al alias
// estable guardado por el server (valido mientras la salida exista; no liberar).
typedef struct {
	int id;
	const char *name;
	int x, y, width, height;
	int scale;
	int primary;
	int enabled;
} wl_server_output_info;

wl_server *wl_server_create(wl_server_callbacks cb, int default_w, int default_h);
const char *wl_server_socket(wl_server *s);
// DISPLAY del Xwayland embebido ("" si no hay).
const char *wl_server_xdisplay(wl_server *s);
void wl_server_dispatch(wl_server *s);
void wl_server_frame_done(wl_server *s);
// Toplevels dibujados en el último frame: sólo ellos reciben frame callbacks desde ahora
// (las layer surfaces mapeadas, siempre).
void wl_server_set_visible(wl_server *s, const int *ids, int n);
void wl_server_set_size(wl_server *s, int id, int w, int h);
void wl_server_set_maximized(wl_server *s, int id, int maximized);
void wl_server_set_popup_bounds(wl_server *s, int id, int x, int y, int w, int h);
void wl_server_set_fullscreen(wl_server *s, int id, int fullscreen);
void wl_server_set_default_size(wl_server *s, int w, int h);
// --- Salidas logicas (multi-output) -----------------------------------------
// Crea una salida headless con nombre estable y geometria logica global.
// `scale` se normaliza a >=1. `primary` marca la principal del layout (solo la
// creacion desde wl_server_create la usa). Devuelve el id de la salida (>0) o 0
// si falla. No emite output_added si el server todavia se esta construyendo.
// `name` debe ser unico entre salidas (wl_output.name); vacio/NULL usa "GDTK-<id>".
int wl_server_output_add(wl_server *s, const char *name,
		int x, int y, int width, int height, int scale, int primary);
// Mueve/redimensiona/escala una salida existente. Devuelve 1 si existia.
int wl_server_output_configure(wl_server *s, int output_id,
		int x, int y, int width, int height, int scale);
// Retira una salida y reasigna sus toplevels a la principal antes de destruirla.
// La principal no se puede retirar (no-op con log). No queda ninguna ventana
// huerfana ni invisible.
void wl_server_output_remove(wl_server *s, int output_id);
// Asigna el toplevel a una salida (0 = principal) y emite los wl_surface.enter/
// leave correspondientes. No-op si el toplevel o la salida no existen.
void wl_server_toplevel_set_output(wl_server *s, int toplevel_id, int output_id);
// Salida actual del toplevel (0 si el toplevel no existe).
int wl_server_toplevel_output(wl_server *s, int toplevel_id);
// Id de la salida principal (0 si no hay ninguna).
int wl_server_output_primary(wl_server *s);
// Escribe hasta `max` ids de salidas y devuelve cuantas hay (puede exceder max).
int wl_server_outputs(wl_server *s, int *ids, int max);
// Devuelve 1 y llena `out` si `output_id` existe; 0 si no.
int wl_server_output_get(wl_server *s, int output_id, wl_server_output_info *out);
void wl_server_close(wl_server *s, int id);
// Enfoca el teclado. `raise` controla por separado si una ventana XWayland se
// reordena arriba; el foco lazy del shell usa 0 para conservar el z-order.
void wl_server_focus(wl_server *s, int id, int raise);
void wl_server_pointer_motion(wl_server *s, int id, double x, double y, uint32_t time_ms);
// Movimiento relativo del puntero para el cliente enfocado con lock activo
// (zwp_relative_pointer_v1). El shell la llama con event.relative mientras captura.
void wl_server_pointer_motion_relative(wl_server *s, double dx, double dy, uint32_t time_ms);
// Quita el foco del puntero local (wl_pointer.leave). InputCapture debe llamarlo
// cuando el hardware pasa a otra pantalla para no dejar hover/clics en el cliente.
void wl_server_pointer_clear_focus(wl_server *s);
void wl_server_pointer_button(wl_server *s, uint32_t time_ms, uint32_t evdev_button, int pressed);
void wl_server_pointer_axis(wl_server *s, uint32_t time_ms, double dy);
// Eje horizontal (scroll lateral de dos dedos: atrás/adelante en el navegador).
void wl_server_pointer_axis_h(wl_server *s, uint32_t time_ms, double dx);
void wl_server_pointer_axis_finger(wl_server *s, uint32_t time_ms, double dx, double dy);
void wl_server_pointer_axis_stop(wl_server *s, uint32_t time_ms);
// Pinch del touchpad hacia el cliente con foco. `phase`: 0 begin, 1 update,
// 2 end, 3 cancel. En update, `scale`>1 aleja (zoom in), <1 acerca (zoom out).
void wl_server_gesture_pinch(wl_server *s, uint32_t time_ms, int phase,
		uint32_t fingers, double dx, double dy, double scale, double rotation);
void wl_server_key(wl_server *s, uint32_t time_ms, uint32_t evdev_key, int pressed);
// dmabuf: 1 si se anuncio linux-dmabuf con feedback propio; estado/motivo para el reporte.
int wl_server_dmabuf_enabled(wl_server *s);
const char *wl_server_dmabuf_reason(wl_server *s);
// Sincronizacion explicita: "on" o el motivo por el que quedo en implicit sync (Mesa).
const char *wl_server_syncobj_state(wl_server *s);
// Scanout directo (P4 opcion B): 1 si el flag GDTK_SCANOUT_DIRECT lo habilito, y el
// estado/motivo del puente hacia el host (sway) para diagnostico.
int wl_server_scanout_enabled(wl_server *s);
const char *wl_server_scanout_state(wl_server *s);
void wl_server_bind_dmabuf(wl_server *s, uint64_t key, unsigned int texid);
// Llena hasta `max` capas del arbol del toplevel (o layer surface) `id` en orden de dibujo;
// devuelve cuantas escribio (0 si el id no existe o no esta mapeado).
int wl_server_layers(wl_server *s, int id, wl_server_layer *out, int max);
// Geometría de la ventana (contenido sin sombras CSD) relativa a la surface raíz; 0 si no hay.
int wl_server_geometry(wl_server *s, int id, int *x, int *y, int *w, int *h);
// id del toplevel que es `parent` del toplevel `id` (0 si no tiene).
int wl_server_parent(wl_server *s, int id);
// app_id del toplevel `id` ("" si no tiene).
const char *wl_server_app_id(wl_server *s, int id);
// 1 si el toplevel `id` usa decoración propia (CSD; p. ej. GTK4). 0 si es server-side
// (el shell dibuja el chrome) o Xwayland.
int wl_server_csd(wl_server *s, int id);
// Layer surfaces mapeadas, de la capa mas baja a la mas alta; devuelve cuantas.
int wl_server_layer_surfaces(wl_server *s, wl_server_layer_surface *out, int max);
// 1 si hay surface con foco de puntero: requisito de wl_server_pointer_motion_relative.
int wl_server_pointer_has_focus(wl_server *s);
// 1 mientras el cliente con foco pidio ocultar el cursor (set_cursor surface NULL).
int wl_server_client_cursor_hidden(wl_server *s);
void wl_server_destroy(wl_server *s);

#ifdef __cplusplus
}
#endif

#endif // WL_SERVER_H
