extends Node

# Puente mínimo que sigue recibiendo hardware mientras el ImGuiCanvas del shell
# tiene su _input apagado. Evita que ImGui encole clics locales durante una sesión
# InputCapture, sin cortar el envío de esos mismos eventos hacia Deskflow/EIS.
# También reenvía el mouse al cliente alojado con pointer lock (SDL relativo).
var shell = null


func _input(event):
	if shell == null or not is_instance_valid(shell):
		return
	if shell.client_pointer_locked:
		shell._forward_client_pointer(event)
		return
	if not shell.mouse_locked:
		return
	shell._capture_remote_input_event(event)
