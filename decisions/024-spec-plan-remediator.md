# ADR-024: Early-stage remediators (spec / plan) + `remediation` → `code-remediator`

**Date:** 2026-06-01
**Status:** Accepted
**Context:** Session H2 — asymmetric-iteration gaps from the Arriendo Fácil pilot

---

## Context

Helm's later stages already support *structured iteration*: when a code review
finds problems, the `remediation` gate spawns a remediation agent that pushes
fixes back onto the open implementation PR (ADR-019). The early stages had no
equivalent.

`spec-draft` and `plan-draft` were **one-shot**: the spec-writer / plan-writer
produced an artifact, opened a PR, and that was the end of the automated path. If
an operator read the spec PR and wanted "split step 1 into a migration phase and a
backfill phase", their only options were:

- Merge the imperfect artifact and fix it downstream (pollutes the plan).
- Edit the PR by hand (defeats the point of an agentic SDLC).
- Re-run the writer from scratch (throws away everything that *was* right, and
  opens a *new* PR — losing the review thread).

This is the **asymmetric-iteration gap**: late stages iterate, early stages don't.
The pilot hit it repeatedly on plans, where a small structural change to one step
is common and re-generating the whole plan is wasteful.

A second, smaller irritant: the existing remediator's config key was `remediation`
— a noun that names the *stage*, not the specialist. With spec/plan remediators
arriving, three sibling specialists deserve a coherent `*-remediator` family.

---

## Decision

### 1. Two new specialists: `spec-remediator` and `plan-remediator`

They extend the remediation pattern to the early stages. Each one:

1. Resolves the **open artifact PR** for the item (GitHub is the source of truth —
   `gh pr list --head helm/spec/<id>` / `helm/plan/<id> --state open`). No open PR
   → fast error (`no open spec PR found for <id> on helm/spec/<id>`).
2. Clones the knowledge repo at that branch (`helm/spec/<id>` / `helm/plan/<id>`)
   and reads the current artifact (`specs/<id>.md` / `plans/<id>.md`).
3. Builds a prompt containing `## Product Context`, `## Task`, `## Current
   {Spec|Plan}`, `## Feedback` (the operator's instruction), and `## Hints`, then
   instructs the agent to **apply the feedback in place** — preserve everything the
   feedback doesn't touch, do **not** regenerate from scratch, do **not** open a new
   PR.
4. Spawns the runtime with `permissionMode: acceptEdits` and a 15-minute timeout
   (`EARLY_REMEDIATION_TIMEOUT_MS`).
5. Commits and **fast-forward pushes** the edits back to the same branch (no
   `--force` — single-pusher invariant; the artifact PR updates in place and the
   review thread is preserved).
6. Returns the **same `prUrl`**. The item is **not** transitioned: it stays in its
   draft stage until the operator merges the PR through the normal
   spec-ready / plan-ready flow.

Both are thin wrappers over a shared helper, `early-remediator.ts`
(`runEarlyRemediation` + `buildEarlyRemediatorPrompt` / `buildEarlyRemediatorParams`),
parameterised by `kind: 'spec' | 'plan'`.

### 2. Operator-triggered, never auto-dispatched

Unlike code-review remediation (driven by the `remediation` *stage* gate), the early
remediators have no stage of their own and are **not** in `STAGE_TO_SPECIALIST`.
They are reached only by an explicit dispatch naming the specialist, with operator
**feedback**:

```
POST /api/products/:slug/items/:externalId/dispatch
{ "specialistId": "spec-remediator", "feedback": "Split step 1 into …" }
```

The API requires non-empty `feedback` (1–10000 chars) whenever `specialistId` is a
remediator (Zod `superRefine`, 400 otherwise). The dispatcher re-validates
defense-in-depth, and also enforces the **stage invariant**: `spec-remediator`
requires `currentStage === 'spec-draft'`, `plan-remediator` requires `'plan-draft'`
— otherwise it errors (`spec-remediator requires currentStage 'spec-draft', got
'<actual>'`). A remediator only makes sense while its artifact PR is open and
unmerged.

> PR-comment triggers (a reviewer leaving "@helm split step 1" on the PR) are **out
> of scope** — Helm has no webhook ingestion yet. The dispatch endpoint is the
> trigger surface for v0.

### 3. `remediation` → `code-remediator` (breaking config rename)

`SpecialistsSchema` grows from seven to nine entries. The code-review remediator's
key is renamed `remediation` → `code-remediator` so all three remediators form a
`*-remediator` family. The `remediation` **workflow stage** is unchanged — only the
specialist config key moves. Legacy `remediation:` keys are detected before schema
validation and rejected with an actionable rename message (same mechanism as
ADR-022). See `operations/migrations/2026-06-01-remediator-naming.md`.

This is a **breaking change** to `product.yaml`: every config must add the two new
remediators and rename `remediation` → `code-remediator`. The "all specialists
share one runtime" `superRefine` now spans all nine.

---

## Consequences

- **Symmetric iteration.** Early-stage artifacts iterate like code does, without
  losing the PR/review thread or regenerating from scratch.
- **In-place, single-pusher edits.** Fast-forward pushes keep the artifact branch's
  history linear and the open PR stable — operators watch one PR evolve.
- **No state-machine churn.** Remediators don't transition the item, so a
  remediation that fails leaves the item exactly where it was (re-dispatchable).
- **Configs break loudly.** The parser names the `remediation` → `code-remediator`
  rename, and the nine-entry schema means a config missing the two new remediators
  fails validation rather than silently degrading.
- **Trigger is manual for now.** Operators dispatch remediators explicitly; there is
  no automatic "review comment → remediate" loop yet (future webhook work).

---

## Alternatives considered

- **Re-run the writer instead of a dedicated remediator.** Rejected: it discards the
  correct parts of the artifact and opens a new PR, losing the review thread. The
  whole value is *targeted* edits to the existing PR.
- **A new `spec-remediation` / `plan-remediation` stage + gate (mirroring the
  code-review gate exactly).** Rejected for v0: the code-review gate is automatic
  (driven by reviewer verdicts); early remediation is operator-judgement-driven and
  has no automatic signal to gate on. Adding stages would also force every product's
  `stages_enabled` to grow. An operator-triggered specialist with no stage is the
  smaller change.
- **Keep the `remediation` key (don't rename).** Rejected: with three remediators, a
  `*-remediator` family is clearer, and the one-time rename is mechanical (ADR-022
  set the precedent and the tooling).

---

## References

- `packages/orchestrator/src/specialists/early-remediator.ts` — shared helper
- `packages/orchestrator/src/specialists/spec-remediator.ts` / `plan-remediator.ts`
- `packages/orchestrator/src/specialists/pr-helpers.ts` — `findArtifactPRUrl`
- `packages/orchestrator/src/dispatcher.ts` — remediator routing + stage/feedback validation
- `apps/api/src/routes/dispatch.ts` — `feedback` field + `superRefine`
- `packages/shared/src/config/product-schema.ts` — nine-entry `SpecialistsSchema`
- `packages/shared/src/config/product-parser.ts` — `remediation` → `code-remediator` detection
- `operations/migrations/2026-06-01-remediator-naming.md` — migration script
- [ADR-019](019-remediation-gate.md) — the code-review remediation gate this extends
- [ADR-022](022-specialist-id-naming.md) — kebab-case specialist IDs
