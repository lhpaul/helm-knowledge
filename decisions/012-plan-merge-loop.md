# ADR-012: Plan merge loop via webhook

**Date:** 2026-05-26
**Status:** Accepted
**Context:** Session 15 — plan merge loop (plan-draft → plan-ready)

---

## Context

ADR-011 left a known gap: after the plan-writer agent generates a plan and opens a PR
on the knowledge repo (`helm/plan/{externalId}`), Helm had no mechanism to advance the
item from `plan-draft` to `plan-ready` when that PR was merged.  The item stayed stuck
in `plan-draft` until a human manually triggered the transition.

The pattern for closing this kind of loop was already established in ADR-010 (spec
merge loop: `spec-draft → spec-ready`).  This ADR documents the plan merge loop as its
direct counterpart and the design decision to generalize the branch parser rather than
duplicating it.

---

## Decisions

### 1. Reuse the existing `pull_request_merged` webhook path

The webhook endpoint `/api/webhooks/github` already receives `pull_request_merged`
events (introduced in ADR-010).  The adapter emits the raw `headRef`; the route
interprets it.  No new events, no new secrets, no new endpoints are needed.

### 2. Replace `parseSpecBranch` with `parseArtifactBranch`

Rather than adding a parallel `parsePlanBranch` function (mirroring `parseSpecBranch`),
the two parsing functions are consolidated into a single generic helper:

```typescript
export function parseArtifactBranch(
  ref: string,
): { kind: 'spec' | 'plan'; externalId: string } | null
```

`parseArtifactBranch` tests `SPEC_BRANCH_PREFIX` first, then `PLAN_BRANCH_PREFIX`.  On
a match it validates the suffix with the same `VALID_EXTERNAL_ID` regex used elsewhere
(blocks leading dots, slashes, spaces — preventing path traversal).

`parseSpecBranch` is removed; it had a single consumer (the webhook route) and is fully
superseded.  The export is dropped from `@helm/shared/index.ts`.

**Why not keep `parseSpecBranch` as a thin wrapper?**  It had no other consumers; a
wrapper would exist only to avoid a tiny diff.  The cost (dead code, two functions to
maintain, risk of divergence) exceeds the benefit.

### 3. Route derives target stage from `parsed.kind`

```typescript
const toStage = parsed.kind === 'spec' ? 'spec-ready' : 'plan-ready';
```

The idempotent error-handling pattern (WorkflowTransitionError | ItemNotFoundError →
log + 200; unexpected errors → 500) is unchanged and applies to both artifact kinds.

---

## Consequences

- The plan-draft → plan-ready transition is now automated end-to-end.
- `@helm/shared` no longer exports `parseSpecBranch`; callers should use
  `parseArtifactBranch` and check `.kind`.
- Adding a third artifact kind in the future (e.g. `helm/review/`) requires:
  1. A new `PREFIX` constant and `branchName` function in `spec-branch.ts`.
  2. A new `kind` literal in `ArtifactBranchKind`.
  3. One new `if` branch in `parseArtifactBranch`.
  4. One new `toStage` case in the route.
  No structural changes needed.

---

## Alternatives considered

### Keep `parsePlanBranch` as a separate function

Symmetric with `parseSpecBranch` — easy to add.  Rejected because it duplicates the
validation regex and the branch-parsing logic.  Any future fix (e.g. a new disallowed
character) would need to be applied in two (or more) places.  The `ARTIFACT_CONFIG`
lookup table precedent from ADR-011 (publisher generalization) makes the generic
approach the natural choice here too.

### Validate `repository.full_name` in the webhook

The webhook currently accepts `pull_request_merged` events from any repository.
Multi-product validation was deferred in ADR-010 and remains deferred here.  The risk
is that a branch named `helm/plan/some-id` in an unrelated repo could trigger an
unintended transition.  This is a hardening item (ADR-010 "Known limitations") but does
not block the current scope.

---

## Revisit when

- A third artifact kind is introduced (e.g. `helm/review/`, `helm/test/`): evaluate
  whether a data-driven config table is preferable to extending the `if`-chain.
- Multi-product webhook validation is implemented: `repository.full_name` should be
  compared against the product's `knowledge_repo.url` before dispatching.
