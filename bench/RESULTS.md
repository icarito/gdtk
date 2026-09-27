# Benchmark ImGui vs controles de Godot

Generado por `bench/run_ui_bench.sh` con el binario FRT de gdtk, bajo
cage anidado, vsync off, 120 frames de calentamiento y 600 medidos.

## Tabla

| driver | ui | modo | N | frame ms (media) | frame ms (p95) | process ms (media) | draw calls | 2D items | 2D draws | mem MB | nodos |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| GLES2 | godot | dynamic | 20 | 0.57 | 0.92 | 0.000 | 0.0 | 2.0 | 109.0 | 19.4 | 85 |
| GLES2 | godot | dynamic | 100 | 1.29 | 2.38 | 1.001 | 0.0 | 2.0 | 162.0 | 20.9 | 405 |
| GLES2 | godot | dynamic | 400 | 4.07 | 4.92 | 5.894 | 0.0 | 2.0 | 162.0 | 26.2 | 1605 |
| GLES2 | godot | static | 20 | 0.20 | 0.27 | 0.000 | 0.0 | 2.0 | 89.0 | 19.4 | 85 |
| GLES2 | godot | static | 100 | 0.23 | 0.31 | 0.000 | 0.0 | 2.0 | 132.0 | 20.8 | 405 |
| GLES2 | godot | static | 400 | 0.24 | 0.33 | 0.000 | 0.0 | 2.0 | 132.0 | 26.1 | 1605 |
| GLES2 | imgui | dynamic | 20 | 0.37 | 0.56 | 0.000 | 0.0 | 5.0 | 5.0 | 19.2 | 3 |
| GLES2 | imgui | dynamic | 100 | 0.53 | 0.76 | 0.000 | 0.0 | 1.0 | 1.0 | 19.2 | 3 |
| GLES2 | imgui | dynamic | 400 | 1.66 | 2.84 | 2.070 | 0.0 | 1.0 | 1.0 | 19.2 | 3 |
| GLES2 | imgui | static | 20 | 0.37 | 0.59 | 0.000 | 0.0 | 5.0 | 5.0 | 19.2 | 3 |
| GLES2 | imgui | static | 100 | 0.47 | 0.61 | 0.000 | 0.0 | 1.0 | 1.0 | 19.2 | 3 |
| GLES2 | imgui | static | 400 | 1.57 | 2.82 | 1.920 | 0.0 | 1.0 | 1.0 | 19.2 | 3 |
| GLES3 | godot | dynamic | 20 | 0.50 | 0.65 | 0.000 | 0.0 | 2.0 | 109.0 | 18.2 | 85 |
| GLES3 | godot | dynamic | 100 | 1.24 | 1.91 | 0.602 | 0.0 | 2.0 | 162.0 | 19.6 | 405 |
| GLES3 | godot | dynamic | 400 | 4.16 | 5.15 | 6.739 | 0.0 | 2.0 | 162.0 | 25.0 | 1605 |
| GLES3 | godot | static | 20 | 0.19 | 0.26 | 0.000 | 0.0 | 2.0 | 89.0 | 18.2 | 85 |
| GLES3 | godot | static | 100 | 0.22 | 0.28 | 0.000 | 0.0 | 2.0 | 132.0 | 19.6 | 405 |
| GLES3 | godot | static | 400 | 0.23 | 0.30 | 0.000 | 0.0 | 2.0 | 132.0 | 24.9 | 1605 |
| GLES3 | imgui | dynamic | 20 | 0.39 | 0.58 | 0.000 | 0.0 | 5.0 | 5.0 | 18.0 | 3 |
| GLES3 | imgui | dynamic | 100 | 0.63 | 1.00 | 0.000 | 0.0 | 1.0 | 1.0 | 18.0 | 3 |
| GLES3 | imgui | dynamic | 400 | 1.71 | 2.93 | 2.017 | 0.0 | 1.0 | 1.0 | 18.0 | 3 |
| GLES3 | imgui | static | 20 | 0.38 | 0.60 | 0.000 | 0.0 | 5.0 | 5.0 | 18.0 | 3 |
| GLES3 | imgui | static | 100 | 0.49 | 0.71 | 0.000 | 0.0 | 1.0 | 1.0 | 18.0 | 3 |
| GLES3 | imgui | static | 400 | 1.58 | 2.81 | 1.835 | 0.0 | 1.0 | 1.0 | 18.0 | 3 |

## Conclusiones medidas

- GLES2 static N=400: gana Godot (0.24 ms de frame vs 1.57 ms, 85% menos).
- GLES3 static N=400: gana Godot (0.23 ms de frame vs 1.58 ms, 85% menos).
- GLES2 dynamic N=400: gana ImGui (1.66 ms de frame vs 4.07 ms, 59% menos).
- GLES3 dynamic N=400: gana ImGui (1.71 ms de frame vs 4.16 ms, 59% menos).
- GLES2 dynamic N=400 draw calls: Godot 0 vs ImGui 0; 2D items: Godot 2 vs ImGui 1.

