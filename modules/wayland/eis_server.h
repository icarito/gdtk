#ifndef EIS_SERVER_H
#define EIS_SERVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Input remoto (libei) hacia el shell: servidor EIS + backend del portal
// org.freedesktop.impl.portal.RemoteDesktop en el bus de sesión. Deskflow, lan-mouse
// y demás clientes libei piden una sesión al portal, el shell la aprueba y reciben un
// fd de este EIS; sus eventos llegan por los callbacks (coords en píxeles de la ventana).
typedef struct eis_server eis_server;

typedef struct {
	void *ud;
	void (*motion)(void *ud, double x, double y, int absolute);
	void (*button)(void *ud, uint32_t evdev_button, int pressed);
	// discrete: dx,dy en 1/120 de muesca; si no, en píxeles lógicos.
	void (*scroll)(void *ud, double dx, double dy, int discrete);
	void (*key)(void *ud, uint32_t evdev_key, int pressed);
	// Un cliente pide control remoto (Start del portal): responder con eis_server_respond.
	// pid del proceso que pidió la sesión (0 si no se supo); app_id puede ser "".
	void (*request)(void *ud, int id, int pid, const char *app_id);
} eis_server_callbacks;

// keymap: texto XKB (el de la sesión) que se entrega a los clientes; w,h: región absoluta.
// test_socket: si no es NULL, además escucha en ese socket SIN pedir permiso (sólo pruebas).
eis_server *eis_server_create(eis_server_callbacks cb, const char *keymap, int w, int h, const char *test_socket);
// "" si todo bien; si no, por qué no hay portal (el EIS de prueba puede andar igual).
const char *eis_server_error(eis_server *s);
// 1 si la interfaz org.freedesktop.impl.portal.InputCapture quedó registrada en el
// bus de la sesión (RemoteDesktop puede andar y InputCapture no, y viceversa).
int eis_server_has_input_capture(eis_server *s);
// No bloquea: procesa lo que haya en el bus y en los sockets EIS.
void eis_server_dispatch(eis_server *s);
void eis_server_set_size(eis_server *s, int w, int h);
// Rangos porcentuales (0..100) por borde donde InputCapture puede ACTIVARSE, en el
// orden [left_lo,left_hi, right_lo,right_hi, top_lo,top_hi, bottom_lo,bottom_hi].
// El layout de Deskflow usa tramos parciales (p.ej. down(0,67)), pero Deskflow arma
// barreras de borde COMPLETO: sin este filtro gdtk captura también en el tramo sin
// vecino, Deskflow no cambia de pantalla y el puntero queda clavado. NULL = 0..100.
void eis_server_set_capture_ranges(eis_server *s, const double *ranges);
void eis_server_respond(eis_server *s, int id, int allow);
// InputCapture: el shell llama estas funciones con eventos FISICOS locales (los que
// llevan RemoteInput::DEVICE_ID no deben llegar acá). Al cruzar una barrera armada se
// activa la sesión y, mientras esté activa, el evento se reenvía a los clientes
// receiver por EIS (frame con `time`). `time` en ms monotónicos (OS.get_ticks_msec),
// 0 = usar el reloj actual. Devuelven 1 si la captura consumió el evento.
int eis_server_capture_motion(eis_server *s, double x, double y, double dx, double dy, uint64_t time);
int eis_server_capture_button(eis_server *s, uint32_t button, int pressed, uint64_t time);
int eis_server_capture_scroll(eis_server *s, double dx, double dy, uint64_t time);
int eis_server_capture_key(eis_server *s, uint32_t key, int pressed, uint64_t time);
// 1 si la petición `id` sigue esperando respuesta.
int eis_server_pending(eis_server *s, int id);
// Clientes EIS conectados ahora.
int eis_server_clients(eis_server *s);
void eis_server_destroy(eis_server *s);

#ifdef __cplusplus
}
#endif

#endif // EIS_SERVER_H
