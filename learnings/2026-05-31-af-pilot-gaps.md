---
title: "Gaps de iteración y readiness expuestos por el piloto Arriendo Fácil"
category: "workflow-process"
date: "2026-05-31"
source:
  type: "session"
  ref: "piloto AF LEA-103 (Helm contra leasity-tenants)"
tags: ["pilot", "iteration", "product-context", "specialists"]
---

# Gaps de iteración y readiness expuestos por el piloto Arriendo Fácil

## Context

Durante el primer ciclo end-to-end de Helm contra un producto real
(`leasity-tenants` con tracker Linear, runtime Codex, item LEA-103 "Setup monorepo"),
salieron a la luz patrones que en el playground no se notaban porque el contexto
era controlado.

El piloto cazó tres bugs operacionales (`dispatch.ts` con adapter hardcoded a
GitHub, Turbo 2.x strict mode filtrando env vars, naming `snake_case` vs `kebab-case`
entre `product.yaml` y `dispatcher.ts`) — esos están parchados in-place y van a
PRs formales. Pero más importante: expusieron tres **gaps de diseño** del workflow
que aplican a cualquier producto futuro.

## Learning

Helm tiene **iteración asimétrica** entre stages:

- `code-review` itera con humano (vía code-reviewer y remediation-agent).
- `spec-draft` y `plan-draft` son **one-shot**: si el output del specialist
  falta algo, no hay loop estructurado para pedirle "amendá X". El humano
  termina editando el PR a mano o regenerando desde cero, perdiendo el
  contexto previo.

Y un problema relacionado: **no hay gate de readiness del producto**. Helm
dispatchea aunque el code-repo no tenga `README.md`, `AGENT.md` ni `CLAUDE.md`.
El spec-writer entonces "inventa" en lugar de fallar ruidosamente — en el piloto,
con `CLAUDE.md` inexistente referenciado por el issue body, el primer spec
generado fue completamente inventado (sobre una vista de status del arrendatario,
no sobre el setup del monorepo).

## Why it matters

Si Helm tiene que escalar a múltiples productos y muchos items por día:

- Sin loop de iteración temprana, cada gap detectado por el humano fuerza un
  ciclo manual (editar PR a mano, o cerrar+regenerar). Eso no escala.
- Sin gate de readiness, los outputs malos se propagan: un spec malo lleva a un
  plan malo que lleva a un implementer haciendo el trabajo equivocado. El daño
  se detecta solo en el code-review (caro de revertir).
- Sin hints persistentes por producto, los patrones que sabemos que el specialist
  olvida (ej. pinear versiones) se redescubren item por item.

## Apply when

Antes de pilotar Helm contra un producto nuevo:

1. Verificá que el code-repo tenga `README.md` con stack + estructura mínima, y
   `AGENT.md` o `CLAUDE.md` con convenciones y decisiones cerradas. Sin eso, el
   spec-writer va a inventar.
2. No confíes en que el issue body referenciado a "§X del CLAUDE.md" sea
   suficiente — si `CLAUDE.md` no existe en el repo, esa referencia es vacía
   para el specialist.
3. Si vas a corregir el output de un spec/plan, considerá si lo correcto es
   amendar a mano (mientras no exista el remediator) o si vale la pena pausar
   el piloto e implementar el remediator primero. Para piloto crítico, amendar.

Y como roadmap del propio Helm, las siguientes sesiones cubren los gaps:

- **H2** — Spec/plan remediator (extensión del patrón remediation-agent).
- **H3** — Product-readiness gate (pre-condición de dispatch).
- **H4** — `extra_hints` por specialist en `product.yaml`.

## Related artifacts

- `11-ESTADO-Y-ROADMAP-RECONCILIADO.md` (cerebro LH) — sección "Gaps identificados
  durante el piloto Arriendo Fácil".
- `decisions/005-agent-runtime-interface.md` — ADR original del runtime, base
  sobre la que apoyamos los remediators.
- `decisions/019-reviewers-and-remediation.md` (ADR-019) — patrón del
  remediation-agent del code-review, modelo a espejar para H2.
- Linear LEA-103 (`https://linear.app/lh-paul/issue/LEA-103`) — primer item piloto.
