# SPEC — Continuidad del teclado y mouse compartidos

## Contratos

- Un anuncio mDNS distinto (familia, interfaz, orden o ausencia transitoria) no
  autoriza cortar una conexión Deskflow sana. Cambiar el endpoint automáticamente
  requiere evidencia reciente de que el cliente perdió al servidor. Desconocido
  no equivale a desconectado. Una recarga de UI conserva el proceso y endpoint
  transferidos; no es un cambio de configuración.
- El vigía consume un snapshot del worker, con TTL. Reconoce tanto `switch` como
  `jump`; una reconexión invalida la caída anterior. Sólo rescata por evidencia
  posterior a la captura o todavía no consumida, nunca repetidamente por la misma
  línea antigua. Los warnings no representan una transición del protocolo.
- Al salir, detenerse o perderse el sender EIS que posee el input, se liberan todas
  sus teclas y botones, incluidos modificadores y laterales, aunque permanezcan
  clientes InputCapture u otros senders inactivos. La desconexión de un cliente
  ajeno no puede liberar el input del dueño activo.
- Los frames EIS llevan microsegundos de `CLOCK_MONOTONIC` absoluto. Los ticks
  relativos al arranque de Godot no son timestamps válidos de libei.

## Evidencia y activación

El diagnóstico del 2026-10-08 observó clientes alternando entre la IPv4 del mesh y
el hostname mDNS, con PIDs nuevos y reconexiones de ~10 s. El vigía además repetía
rescates sobre una caída anterior e ignoraba el `jump` de recuperación del server.
Las correcciones de scripts pueden entrar por recarga transaccional; la liberación
nativa y el reloj EIS requieren motor nuevo en los tres hosts y corte controlado.
