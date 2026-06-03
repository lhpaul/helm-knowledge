# ADR-029: Implementer rollback on agent failure

**Date:** 2026-06-02
**Status:** Accepted
**Context:** Bloque I — readiness/hardening; gap surfaced by the Arriendo Fácil pilot (LEA-104, LEA-109)

---

## Context

When the implementer specialist's agent fails **before any meaningful work**
(Codex CLI crashes, image-tool defects, environmental wedges, network errors),
the item is left stuck in `in-development`. The state machine's
`VALID_TRANSITIONS` map only allows forward edges from `in-development` (to
`code-review`); there is no reverse path back to `plan-ready`.

In the AF pilot this gap was hit on LEA-104 (early Codex environment issues) and
again **twice on one item**, LEA-109 (Better Auth setup):

1. Codex CLI 0.133.0 `image_generation_user_error: gpt-image-2 does not exist` —
   the implementer failed on turn 1 at $0 cost, leaving the item in
   `in-development`.
2. A Docker Desktop wedge during the same item's later retry — the
   testcontainers integration suite couldn't run, and the implementer would have
   needed a rollback again if dispatched.

Each time, the workaround documented in `piloto-arriendo-facil-driver.md`'s
gotchas table was: manually edit `<helm-data>/items/<item>.json`, change
`currentStage` from `in-development` to `plan-ready`, and append a history entry
by hand. That works but is error-prone (typos, inconsistent reasons, no
concurrency guard against an in-flight job) and creates audit gaps. LEA-109 is
the second schema-touching item to hit it — enough evidence to formalize.

## Decision

Add an explicit operator rollback endpoint:

```
POST /api/items/:externalId/rollback
{ "fromStage": "in-development", "toStage": "plan-ready", "reason": "<string>" }
```

The state machine `VALID_TRANSITIONS` map is **not** modified. The rollback
endpoint enforces its own single-pair allow-list **at the schema boundary** (a
strict Zod object with `fromStage`/`toStage` literals) and calls a new sibling
`ItemStore.forceTransition(...)` that bypasses `validateTransition`. This
preserves the state machine as a clean codification of the happy-path workflow;
the rollback is an explicit escape valve, documented as such.

Locked design forks (resolved with the operator during session intake):

- **Trigger: manual only.** No auto-classified rollback. Classifying "env
  failure vs implementer logic failure" is risky (false positives would roll
  back legitimate failures); manual is safer until a high-confidence classifier
  exists.
- **Scope: single pair (`in-development → plan-ready`).** No generalized
  reverse-transition system. The allow-list is one pair, pinned by strict
  literals; a future pair (e.g. `code-review → plan-ready`) requires an explicit
  schema change, which forces deliberate review.
- **Audit trail: history entry only.** No new "rollbacks" table, no separate job
  records. The appended `WorkflowEvent` carries `triggeredBy: 'manual:rollback'`
  and the operator-supplied `reason` (1–500 chars) in the existing **`note`**
  field. Reusing `note` avoids bloating the shared `WorkflowEvent` type with a
  dedicated field that every other history entry would leave undefined; the
  endpoint still makes the reason **required** at the API boundary even though
  `note` is optional in the type.
- **Concurrency: rejected if a job is running** for the item. A new read-only
  `JobStore.getRunningJobForItem(slug, externalId)` wraps the existing
  `listJobsForItem` (job creation with the atomic in-memory lock stays in
  `createJobIfNoRunning`). A running job → `409 { error, runningJobId }`.
- **State machine: untouched.** Rollback bypasses `validateTransition` via
  `forceTransition`, which still asserts `currentStage === fromStage` to guard
  against races (the item moved since the operator read its state) →
  `StageMismatchError` → `400`.

### Bypass mechanism: `forceTransition` sibling, not a `bypassValidation` flag

The item store gains a dedicated `forceTransition(input)` method rather than an
optional `bypassValidation: boolean` on `transition()`. A named method keeps one
method to one purpose, keeps `transition()`'s signature and all its callers
byte-identical, and — because `forceTransition` callers are security-sensitive
(they bypass the state machine) — makes them greppable and auditable. The two
public methods share their internals (history append + atomic persist) via a
private `applyTransition` helper; only the `validateTransition` call differs.

### HTTP contract

| Status | When |
|---|---|
| `200` | success — `{ externalId, currentStage: 'plan-ready', historyEntry }` |
| `400` | invalid body, invalid externalId, or `currentStage` ≠ `fromStage` |
| `404` | item does not exist for the resolved product |
| `409` | a dispatch job is currently running — `{ error, runningJobId }` |
| `500` | unexpected failure (logged, generic message) |

## Alternatives considered

- **Modify the state machine to allow `in-development → plan-ready`
  unconditionally.** Rejected: it pollutes the happy-path codification with what
  is fundamentally an exceptional escape valve. Future readers would interpret
  the edge as a normal workflow transition and might wire automation onto it.
- **Auto-rollback on classified failures** (e.g. classify Codex `[turn.failed]`
  content as env-vs-logic). Rejected for this session: classification confidence
  is low; false positives would roll back legitimate failures. Open as a
  separate session if/when a high-confidence classifier emerges — it can sit
  behind the same endpoint.
- **A generalized reverse-transition API** allowing any reverse edge with
  operator approval. Rejected for now: single-pair evidence doesn't justify the
  surface. YAGNI until other pairs hit with their own evidence.
- **A dedicated `reason` field on `WorkflowEvent`.** Rejected: it expands a
  shared type for one escape-valve use case; the existing `note` field is
  semantically the right home for free-text operator context.

## Consequences

- Operators roll back via an API call; the manual JSON-edit pattern in the AF
  driver gotchas table becomes **obsolete** (LH updates that driver doc
  separately — it lives outside the Helm repos).
- The state machine stays a clean happy-path codification; rollback is an
  explicit, documented escape valve.
- Forward-only callers of `transition()` continue to enjoy the strict
  `validateTransition` guard, unchanged.
- The single-pair allow-list at the schema boundary is intentional friction: any
  future pair requires an explicit schema change and review.
- A new bypass method (`forceTransition`) now exists on the item store. It is
  security-sensitive; today its only caller is the rollback route, which pins the
  pair via strict literals. If it gains other legitimate callers it should be
  promoted to a first-class API with its own ADR.

## Tests

- Route (`rollback.test.ts`, integration against the real app): happy path
  (item reaches `plan-ready`, history entry has `triggeredBy: 'manual:rollback'`
  + reason in `note`, store reflects the new state), current stage ≠ `fromStage`
  (400), unallowed `fromStage`/`toStage` via the schema literals (400), running
  job present (409 + `runningJobId`), missing reason (400), reason > 500 chars
  (400), unknown body field (400, strict), invalid externalId (400), item not
  found (404).
- Store (`item-store.test.ts`): `forceTransition` applies the
  `in-development → plan-ready` edge that `transition()` rejects; **regression**
  that `transition()` still rejects the same edge (the bypass isn't accidental);
  `StageMismatchError` leaves the file unchanged; `ItemNotFoundError` when the
  item is absent.

## Revisit when

- A second rollback pair surfaces with concrete pilot evidence (e.g.
  `code-review → plan-ready` after a reviewer-fanout dead end).
- A classifier with high confidence for env-vs-logic failures becomes available —
  then auto-rollback might be added behind the same endpoint.
- `forceTransition` gains other legitimate callers — then it should be promoted
  to a first-class API with its own ADR.

## References

- AF pilot retros: LEA-104 arc, LEA-105 stack-validation, LEA-109
  stack-validation (the latter captures the LEA-109 double-hit).
- [ADR-021](021-codex-runtime.md) — CodexRuntime (the runtime whose failures
  expose this gap most often).
- [ADR-025](025-remediation-covers-all-reviewers.md) — remediation gate (the
  late-stage rework path this complements at the early stage).
- [ADR-026](026-product-readiness-gate.md) — product-readiness gate (sibling
  pre-dispatch hardening from the same pilot evidence).
- `piloto-arriendo-facil-driver.md` gotchas table — currently documents the
  manual JSON-edit workaround this endpoint replaces.
