---
title: "LEA-194: local Helm needs manual transitions and review re-dispatch"
category: "workflow-process"
date: "2026-07-13"
source:
  type: "session"
  ref: "LEA-194 / lhpaul/leasity-tenants#14"
tags: [review-loop, adjudication, webhooks, arriendo-facil]
---

# LEA-194: local Helm needs manual transitions and review re-dispatch

## Context

LEA-194 ran end-to-end on Helm (spec → plan → impl → review loop) against a
**local** Helm API. The item shipped, but operators repeatedly:

1. Hand-rolled `POST /api/items/:id/transitions` after knowledge/impl merges
   (local instance often misses GitHub merge webhooks).
2. Hand-rolled `POST …/dispatch` after implementer reached `code-review` and
   after each HUMAN_REQUIRED adjudication decision on the PR.
3. Answered two `product_decision` escalations (payment CTA allowlist; UF-only
   debt visibility) before a clean review cycle.

## Learning

- Treat **merge→transition** and **decision→re-dispatch** as first-class Helm
  automation gaps when the API is local — not one-off operator error.
- Adjudication `product_decision`s that are standing product doctrine (trust
  allowlists, currency-agnostic pending flags) should live in the **product
  knowledge repo**; Helm should prefer secure defaults and not re-ask settled
  fingerprints.
- Early artifact review ([ADR-040](../decisions/040-early-artifact-review-loop.md))
  is decided, but its **implementation/automation is still missing** — spec/plan
  still need operator remediator prompts + Haystack FP dismissals for sequential
  Helm artifact PRs.

## Why it matters

Without these fixes, every AF (and any product) item on local Helm burns
human time on babysitting the tracker instead of product decisions. Cycle
counters also reset per dispatch (see helm#65), masking non-convergence.

## Apply when

- Running Helm API locally against GitHub-hosted product repos
- Review loop escalates `adjudication_conflict` / `product_decision`
- Spec/plan Haystack flags `pair-spec-and-plan-files` on `helm/spec/*` or
  `helm/plan/*` branches

## Related artifacts

- Backlog (Helm):
  [#69](https://github.com/lhpaul/helm/issues/69) webhooks/transitions,
  [#70](https://github.com/lhpaul/helm/issues/70) auto re-dispatch,
  [#71](https://github.com/lhpaul/helm/issues/71) ADR-040 implementation,
  [#72](https://github.com/lhpaul/helm/issues/72) persist product_decision,
  [#73](https://github.com/lhpaul/helm/issues/73) secure-default adjudicator;
  existing [#65](https://github.com/lhpaul/helm/issues/65)
- Backlog (Leasity):
  [LEA-204](https://linear.app/lh-paul/issue/LEA-204) payment allowlist doctrine,
  [LEA-205](https://linear.app/lh-paul/issue/LEA-205) UF pending doctrine
- [ADR-040](../decisions/040-early-artifact-review-loop.md) early artifact review loop
- Impl PR: https://github.com/lhpaul/leasity-tenants/pull/14
