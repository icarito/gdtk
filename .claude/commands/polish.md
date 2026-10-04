---
description: "Pulido iterativo de gdtk: el usuario suelta observaciones de a una; se consolidan en plan, se delega a Kilo y se prueba en bastion/tengu/cupid"
---

# /polish — Pulido iterativo (iterative-list-hacking)

Fuente canónica: `.claude/skills/iterative-list-hacking/SKILL.md`. Leerla completa antes de actuar.
Reglas del repo: `AGENTS.md` (prevalecen). Sesión de continuidad en `docs/agents/sessions/`
(estado en disco, no en el chat).

Regla de oro: cada mensaje puede traer 1..N items sin relación. No implementar al bote: plan numerado,
anclado a `archivo:línea`, preguntar sólo lo que bloquea, repartir a Kilo con archivos disjuntos,
verificar con los tests de AGENTS.md, cerrar cada tanda con "qué probar" (host, acción, esperado).
