# ADR-011: Plan-writer specialist and generalized artifact publisher

**Date:** 2026-05-26
**Status:** Accepted
**Context:** Session 14 — plan-writer specialist (spec-ready → plan-draft)

---

## Context

After ADR-010 closed the spec merge loop (spec-draft → spec-ready via webhook), the
next automation step is plan generation.  An item in `spec-ready` has an approved
specification in the knowledge repo; the plan-writer's job is to read that spec and
produce a structured implementation plan.

Two design questions arose alongside the feature work:

1. **Publisher generalization** — `spec-publisher.ts` contained all the git/gh
   mechanics.  A plan publisher would duplicate that code unless the core was
   parameterized.

2. **Token requirement** — the spec-writer treats `GITHUB_TOKEN` as optional (product
   context is a nice-to-have; missing token → continue without context).  For the
   plan-writer the token is mandatory: it must fetch the approved spec before it can
   do anything useful.  The same token is also needed to publish the plan PR.

---

## Decisions

### 1. Generic `publishArtifactToPR(kind)` core

`spec-publisher.ts` is refactored into a single `publishArtifactToPR` function
parameterized by `ArtifactKind = 'spec' | 'plan'`.  A static `ARTIFACT_CONFIG`
lookup table maps each kind to its branch-name function, destination subdirectory,
commit message, PR title, and PR body.

```
spec → branchNameFn: specBranchName, destSubDir: 'specs', errorTag: '[spec-publisher]'
plan → branchNameFn: planBranchName, destSubDir: 'plans', errorTag: '[plan-publisher]'
```

`publishSpecToPR` and `publishPlanToPR` are thin wrappers that map their kind-specific
option fields to `PublishArtifactOpts`.  This preserves backward compatibility — all
existing call sites are unaffected.

**Why not separate files?**  The core logic (clone, branch, copy, commit, push, PR) is
identical for both kinds.  Keeping it in one place ensures that security guarantees
(token sanitization, SSH guard, temp-clone isolation, path-traversal guard) are
maintained once and tested against both kinds without duplication.

### 2. `fetchSpecForPlan` as mandatory input

The plan-writer requires an approved spec before spawning the agent.  Fetching the spec
from the knowledge repo (`specs/{externalId}.md` on the default branch) is done in the
dispatcher, before the agent is spawned.  A `null` result (404) is a hard error — no
spec means no plan can be written, and spawning the agent without input would produce
garbage output.

This contrasts with `fetchProductContext` (README + AGENT.md), which remains a
best-effort fetch for both the spec-writer and plan-writer.  Missing context degrades
quality but does not block execution.

The distinction is captured explicitly in dispatcher routing:
- spec-writer: token optional, context optional
- plan-writer: token required, spec required, context optional

### 3. Token requirement is enforced in the dispatcher

Rather than letting the agent start and fail mid-run when the publish step reaches for
a missing token, the dispatcher returns an early error (`'plan-writer requires
GITHUB_TOKEN'`) before spawning the agent.  This avoids wasted compute and gives a
clear, actionable error message to operators.

### 4. `finalOutput` not returned to callers

The plan-writer agent is given the full spec content in its prompt.  If the agent
fails, its `finalOutput` may echo spec content back.  Following the same pattern as the
spec-writer, `finalOutput` is logged server-side via `console.error` for operator
diagnostics but is never included in the `PlanWriterResult.error` field returned to
callers.

### 5. `planBranchName` / `PLAN_BRANCH_PREFIX` in `@helm/shared`

Branch naming for plan PRs follows the same single-source-of-truth pattern established
in ADR-009 for spec branches.  `PLAN_BRANCH_PREFIX = 'helm/plan/'` and
`planBranchName(externalId)` are exported from `@helm/shared` so that both the
publisher and any future webhook handler (plan merge loop — ADR-012 candidate) import
from one place.

---

## Alternatives considered

### Separate `plan-publisher.ts`

A new file would have been simpler to write but would duplicate ~200 lines of
security-critical git/gh logic.  Any future bug fix (e.g. a new token-sanitization
edge case) would need to be applied in two places.  The `ARTIFACT_CONFIG` lookup table
adds ~30 lines but eliminates that maintenance burden permanently.

### Soft token requirement for plan-writer

Making the token optional for the plan-writer (skip publish if absent, allow agent to
run without the spec) was rejected because:
- A plan written without the spec is not useful — the agent would invent requirements.
- The publish step is not optional for the plan-writer's output to be useful (the plan
  needs to be in the knowledge repo for reviewers).

### Inline spec in workdir instead of fetching

An alternative is to require the spec to be present in the workdir (placed there by
the previous stage) rather than fetching it from the knowledge repo.  This was rejected
because the dispatcher is stateless per call — it does not carry state from previous
specialist runs.  The knowledge repo is already the canonical store for specs.

---

## Consequences

- The spec-ready → plan-draft transition is now automated end-to-end.
- A `GITHUB_TOKEN` is required in the environment for plan-writer runs (already
  required for spec-writer publish step; this strengthens the dependency).
- The knowledge repo gains a `plans/` subdirectory alongside `specs/`.
- Plan merge detection (plan-draft → plan-ready) is not yet implemented; it follows
  the same webhook pattern as ADR-010 and is a candidate for ADR-012.
