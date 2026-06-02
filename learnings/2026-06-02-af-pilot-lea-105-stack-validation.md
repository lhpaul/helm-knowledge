---
title: "LEA-105 stack validation — 0 §4-driven batches, additive vs substitutive drift"
category: "agent-behavior"
date: "2026-06-02"
source:
  type: "session"
  ref: "piloto AF LEA-105 (Drizzle core mirror — 6 core_* tables, service-role only, no RLS)"
tags: ["pilot", "code-review", "schema", "contract-drift", "stack-validation", "haystack"]
---

# LEA-105 stack validation — 0 §4-driven batches, additive vs substitutive drift

## Context

LEA-105 fue el primer item schema-touching corrido **post-#53** (el stack
H2 remediator + H3 finalOutput + H4 extra_hints + ADR-027 code-reviewer §4
validation). Es el comparativo empírico directo contra LEA-104 (pre-#53),
que había tomado 5 batches por §4-drift que el `reviewer-fanout` no pescó.

Scope: 6 tablas espejo del core (`core_*`), service-role only, **sin RLS**.
Contrato canónico en §4.3 del `CLAUDE.md` del producto. PR de código:
`lhpaul/leasity-tenants#4`.

### Side-by-side (LEA-104 pre-#53 vs LEA-105 post-#53)

| Métrica | LEA-104 (pre-#53) | LEA-105 (post-#53) |
| ------- | ----------------- | ------------------ |
| Batches §4-driven | 3 dedicados (A enum, B estructural, C naming) + #1 | **0 dedicados** — 1 batch de hardening (correctness/sec/coverage), no §4 |
| Haystack rounds | 5 | 2 |
| reviewer-fanout `HIGH·Contract drift §4` | 0 (pero *missed* drift pervasivo) | 0 — y reviewer **validó §4 explícito + APPROVED** |
| ¿Haystack pescó §4-drift que el reviewer no? | Sí, pervasivo (substitutivo) | 1 caso menor (additive — ver abajo) |
| Codex cost | ~$5-8 | $0 reportado (sub), ~16 min |

El implementer produjo column names §4.3 **verbatim** (cero renames). El
spec y el plan también pasaron Haystack-clean (5/5) de una — aunque el plan
necesitó 1 ronda de plan-remediator por gaps de §4-fidelity que pescó el
cross-check del operador, no Haystack (ver Evidence #1).

## Learning

### Forecast confirmado

El retro de LEA-104 ([[2026-06-02-af-pilot-lea-104-arc]]) predijo "1-2 batches
post-#53". El actual fue **0 batches §4-driven** — mejor que lo predicho. El
único batch de LEA-105 fue hardening (XSS en URLs, percent non-negative,
typed-error en upsert, UTC en date ingest), **no** §4-drift.

### Additive vs substitutive drift — la distinción clave

El stack §4 captura el drift **substitutivo** (column renames, enum values
cambiados) de forma limpia: la validación de ADR-027 hace match verbatim de
column-name vs §4, y el implementer ni siquiera filtró drift substitutivo.

Pero hubo **1 drift additivo** que el code-reviewer dejó pasar: un unique
index extra en `core_contacts.core_contract_id` que §4.3 lista como plain
nullable bigint (sin unique). El code-reviewer aprobó §4 como "consistent".

**Hipótesis del por qué:** el phrasing del prompt #53 sesga hacia *"¿lo que
está, está en §4?"* (verbatim presence check) en vez de *"¿lo que está + nada
extra?"* (exhaustive equality check). Drift substitutivo viola el primer
check (un nombre que no está en §4); drift additivo no (todo lo de §4 está
presente — solo hay algo de más), así que se cuela.

### Evidence points (acumulando para la decisión de afinar #53)

- **Evidence #1 (plan-time):** gaps de §4-fidelity en el plan PR (que era
  Haystack-clean 5/5) los pescó el cross-check del operador, no Haystack ni
  ningún reviewer agent. Ya registrado en memoria del piloto. ADR-027 difiere
  la validación §4 a spec/plan-writer con criterio "revisit when evidence".
- **Evidence #2 (code-time, additive):** el unique index additivo lo flageó
  **Haystack** (framed como issue de "1:1", no etiquetado §4) + el cross-check
  del operador lo confirmó como §4.3 additive drift. El **code-reviewer
  ADR-027 no lo pescó**.

### Conclusión

El stack funciona como fue diseñado **para drift substitutivo** — la evidencia
de LEA-104→LEA-105 es clara (5 batches → 0). El gap abierto es **additive
drift**: constraints/columnas que §4.3 no demanda pueden pasar la validación
§4 del code-reviewer.

**Watch item:** LEA-109 (Better Auth setup) es el próximo item schema-touching
y el evidence point decisivo. Si el additive-drift se repite ahí, abre un
follow-up para afinar el prompt #53 hacia *"any divergence including additive
constraints"* (exhaustive equality, no presence-only). Si no se repite, este
queda como caso aislado de un solo data point.

(LEA-106 — HTTP client al Leasity Core — no toca schema, así que no ejerce
presión sobre el stack §4.)
