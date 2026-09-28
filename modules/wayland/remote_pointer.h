#ifndef REMOTE_POINTER_H
#define REMOTE_POINTER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Puntero remoto por el compositor anfitrión (sway, cage): inyecta con
// zwlr_virtual_pointer_v1, así se mueve el cursor NATIVO del host y el shell recibe
// los eventos como locales (mismo cursor, sin dibujar uno propio). Si el host no
// expone el protocolo, create() devuelve NULL y el módulo cae a la inyección interna.
typedef struct remote_pointer remote_pointer;

remote_pointer *remote_pointer_create(void);
int remote_pointer_ready(remote_pointer *p);
// x,y en píxeles de la ventana (0..w, 0..h).
void remote_pointer_motion_abs(remote_pointer *p, int x, int y, int w, int h);
// evdev_button: BTN_LEFT.. (el mismo código que recibe el EIS).
void remote_pointer_button(remote_pointer *p, uint32_t evdev_button, int pressed);
// dx,dy en muescas (positivo = abajo/derecha).
void remote_pointer_scroll(remote_pointer *p, double dx, double dy);
void remote_pointer_destroy(remote_pointer *p);

#ifdef __cplusplus
}
#endif

#endif // REMOTE_POINTER_H
