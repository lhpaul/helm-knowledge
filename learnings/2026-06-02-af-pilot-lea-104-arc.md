---
title: "LEA-104 arc — schema item con 5 batches y validación del stop-rule"
category: "agent-behavior"
date: "2026-06-02"
source:
  type: "session"
  ref: "piloto AF LEA-104 (Drizzle schema base — 4 domain tables + RLS)"
tags: ["pilot", "code-review", "schema", "contract-drift", "stop-rule", "haystack"]
---

# LEA-104 arc — schema item con 5 batches y validación del stop-rule

## Context

LEA-104 fue el segundo item del piloto Arriendo Fácil (después de LEA-103
monorepo bootstrap). Scope reducido: 4 tablas de dominio en Drizzle + RLS
+ helper `withTenantContext`. Contrato canónico documentado en §4.2 del
`CLAUDE.md` del producto.

Esperábamos un item simple — terminó tomando **5 batches de fixes a lo
largo de 5+ rondas**, con el `reviewer-fanout` de Helm (code + security +
test, 6 rondas en total) dejando pasar 13+ findings de contract drift que
Haystack capturó al primer triage post-merge-ready.

El arco completo del PR `lhpaul/leasity-tenants#3`:

| Batch | Commit | Qué resolvió | Caught by |
| ----- | ------ | ------------ | --------- |
| A | `fdb8e7d` | 6 enum vocab §4.2 + USD references + snapshot drift + CLP bigint | Haystack triage 1 |
| B | `a2167c1` | core_* columns, utility tenant_id+RLS, amount_clp, status enum, latest_billed_currency, parking/storage JSONB | Haystack triage 2 |
| Fix #1 | `6f313a9` | select schemas heredando `.default('active')` de insert schemas | Haystack triage 2 (re-run) |
| C | `89edf15` | naming §4.2: `provider→company`, `latest_billed_amount→last_amount_clp`, `status→last_status`, `lease_start_date/end_date→started_at/ended_at`, drop `vacated_at`, `core_voucher_id` typed as number | Haystack triage 3 |

Total findings over time: 13 → 9 → 6 → 9 → 5 (rating 2/5 → 3/5 → 2/5 →
3/5 final). El re-triage final quedó solo con 3 advisories ticketed +
1 false-positive (fixture creds testcontainers) + 1 doc inconsistency
out-of-scope.

## Learning

**Tres aprendizajes accionables:**

### 1. El reviewer-fanout de Helm es ciego al contrato §4

El code-reviewer (junto con security + test) corre 3 rondas en paralelo
sobre el PR, pero el prompt actual le pide validar "code quality against
repository conventions (check AGENT.md, CLAUDE.md, README.md if present)"
— una instrucción genérica que el reviewer interpreta como "code style +
patterns generales". **No valida nombres de columnas, tipos, enums o
RLS contra §4 de CLAUDE.md column-by-column.**

Tipos de drift que dejó pasar en LEA-104:

| Categoría | Ejemplo concreto |
| --------- | ---------------- |
| Naming | `provider` vs canonical `company`; `latest_billed_amount` vs `last_amount_clp` |
| Temporal | `lease_start_date` vs `started_at`; columna nueva `vacated_at` (canonical: usar `status='vacated'` + `ended_at`) |
| Type precision | `core_voucher_id` typed as string vs documented as bigint/number |
| Enum vocabulary | Enum values pre-existentes en canonical no enumerados en código |
| Default inheritance | `.default('active')` heredándose de insert→select schema |

Todo esto Haystack lo agarró con análisis adversarial. La conclusión es
**estructural**: el code-reviewer LLM, sin instrucción explícita de
comparar diff vs §4, prefiere validar code quality general.

Captured como issue #53 en cerebro-LH/tareas. Diseño + prompt entregados
2026-06-02 (ver session prompt `sesion-code-reviewer-contract-validation.md`
en `cerebro-LH/prompts`). ADR-027 documenta la decisión.

### 2. Haystack es no-determinístico — necesita stop-rule explícito

Haystack samplea un subconjunto de findings en cada corrida y reporta
distinto cada vez incluso sobre el mismo SHA. LEA-104 osciló
13→9→6→9→5 entre triages sin converger a cero. **Perseguirlo a cero es
un pozo sin fondo.**

Stop-rule operacional escrita y validada en LEA-104 (ver
`prompts/piloto-arriendo-facil-driver.md` §"Haystack stop rule — when to
converge"):

**Bloqueante (no merge hasta resolver):**
- Logic error / Critical
- Security (excluyendo falsos positivos catalogados)
- **Contract drift §4** (column names, types, enums, RLS) — explícito
  porque es lo que Haystack pilla y reviewer-fanout no
- Categoría desconocida (conservador)

**Advisory (ticket follow-up + merge):**
- Major, Minor, Nitpick, Trivial, Weak coverage, Rules violation
- Test-infra que no afecta producción

**Convergencia:** máx 2 re-triages después del fix de blockers. Si solo
shuffle de advisories conocidas → STOP, ticketear, mergear. Si aparece
categoría nueva → reset del contador. Si aparece categoría desconocida →
PAUSE.

Validado empíricamente en LEA-104: re-triage 1 mostró 0 categorías
nuevas de §4-drift después de Batch C, así que el driver no quemó el 2°
re-triage. Ticketed los advisories, propuso merge.

### 3. Drift se propaga: fix temprano paga 10× menos

LEA-104 fue foundational. LEA-105 (core mirror tables) se construye
encima; LEA-109+ (Better Auth + endpoints) referencia los nombres de
columna en queries, types, RPC contracts, mobile. Renombrar una columna
después de que aterrizara LEA-104 → ~1 migration + N archivos. Renombrarla
después de LEA-109 → ~1 migration + queries + tests + types + endpoints +
mobile = ~10× el costo.

Por eso "schema funcional pero con nombres divergentes del contrato" no
es aceptable como advisory — es blocker. Hardearlo en el reviewer (#53)
y en hints preventivos en `product.yaml` (`implementer.extra_hints`
agregado 2026-06-02) son las dos capas defensivas correctas.

## Why it matters

- Si el 25-50% de los items piloto de un producto son schema-touching
  (típico al arrancar), y cada uno paga el peaje de 5 batches, eso es
  el cost driver dominante del piloto. Fix en el reviewer compone
  brutalmente.
- El stop-rule **es un patrón generalizable** — todo análisis adversarial
  externo (Haystack, futuros plugins) tiene la misma propiedad de
  no-convergencia a cero. Sirve para H4-onwards y para integraciones
  futuras tipo bloque J.
- La asimetría reviewer-LLM / análisis-estático identificada en LEA-103
  (gap analysis Helm vs Haystack) se replicó en LEA-104 con otro flavor:
  **LLM ciego al contrato semántico**, no solo a bugs runtime. Más
  evidencia para el roadmap del bloque J.

## Apply when

- **Antes de dispatchar el primer item schema-touching de un producto
  nuevo:** verificá que `CLAUDE.md` §4 (o equivalente) tenga columna,
  tipos, enums explícitos. Anotaciones tipo `(int)` y `numeric(5,2)`
  importan — si están ausentes, el reviewer y el implementer pueden
  drift sin que el contrato les diga "no".
- **Al primer ciclo de Haystack en un PR nuevo:** si encontrás ≥3
  findings de contract drift, **no asumas que el reviewer-fanout los
  pilló** — verificá manualmente que aparecen en el `review.md` del
  code-reviewer. Si no aparecen, es señal de que estás pisando el bug
  meta que motivó #53.
- **Al pelear convergencia con Haystack:** aplicá el stop-rule. Después
  del fix de los blockers reales, máx 2 re-triages. Más allá de eso
  es shuffle, no señal.

## Anexo — Real cost LEA-104

- **Tiempo total:** ~2 días calendario (dispersos, no full-time)
- **Rondas reviewer-fanout:** 6 (dispatcheadas, no efectivas)
- **Rondas Haystack:** 5 triages (incl. re-triages)
- **Batches de fixes:** 4 estructurales (A, B, Fix #1, C) + ~7 commits
  intermedios entre rondas
- **Linear issues generados como follow-up:** LEA-116..119 (Haystack
  round 1), LEA-120..122 (Haystack round 4)
- **False positives catalogados:** 2 (fixture creds testcontainers,
  §10.2 vs §10.3 doc consistency) — en
  `helm-knowledge/false-positives.md`
- **Costo runtime Codex (estimado):** ~$5-8 USD distribuidos entre los
  dispatches del implementer + remediator + reviewer-fanout
- **Estimación original (sin #53):** 1-2 rondas, ~$1-2 USD. Inflación 4-8×.

Si #53 hubiera estado vivo desde el principio: estimación corregida ~1-2
batches, costo similar al original.

## Related artifacts

- Session prompt para #53: `sesion-code-reviewer-contract-validation.md`
  (Helm prompts, cerebro-LH).
- ADR-027 — code-reviewer contract drift validation (pendiente, sesión
  Helm en curso al cierre de este learning).
- `helm-knowledge/false-positives.md` — catálogo iniciado en LEA-104.
- `learnings/2026-05-31-af-pilot-gaps.md` — learning anterior (LEA-103);
  identificó la asimetría reviewer-LLM vs Haystack al primer ciclo.
- `decisions/025-reviewer-remediation-safety-net.md` (ADR-025) — la red
  de seguridad que aseguró que las HIGH del code-reviewer fluyeran al
  code-remediator. Validada por primera vez con findings reales en
  LEA-104 round 2.
- Linear LEA-104: `https://linear.app/lh-paul/issue/LEA-104` — issue
  source.
- PR `lhpaul/leasity-tenants#3` — el PR que generó el arco.
- `prompts/piloto-arriendo-facil-driver.md` §"Haystack stop rule" — la
  regla operacional escrita post-LEA-104.
