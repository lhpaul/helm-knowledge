# ADR-016 — Close the Release Loop

**Status:** Accepted  
**Date:** 2026-05-27  
**Session:** 18

---

## Context

After Session 16b the Helm pipeline could take an item from `discovery` through `plan-ready`, spawn the implementer, and open a code PR. However, the pipeline could never complete:

1. **`released` was unreachable.** The `code-review` stage only listed `in-development` and `remediation` as valid next stages in the state-machine transition map. There was no automated path to `released`.
2. **`parseArtifactBranch` did not recognise `helm/impl/` branches.** The webhook handler already had a `pull_request_merged` path that advanced items on branch merge, but it only handled `helm/spec/` and `helm/plan/` refs. `helm/impl/` merges were silently ignored.
3. **The webhook handler's two-way conditional was not exhaustive.** `parsed.kind === 'spec' ? 'spec-ready' : 'plan-ready'` would produce incorrect results for any new branch kind added later, with no compile-time signal that a case was missing.
4. **The implementer PR body was misleading.** It told reviewers that merging would advance the item to `code-review`, which was the wrong stage.

---

## Decision

### 1. State machine — add `code-review → released`

Added `'released'` to `VALID_TRANSITIONS['code-review']`:

```typescript
'code-review': ['in-development', 'remediation', 'released'],
//              minor changes    CRITICAL/HIGH   approved
```

`released` remains terminal (`released: []`). The comment on the transition-map diagram was updated accordingly.

### 2. `ArtifactBranchKind` — extend to `'spec' | 'plan' | 'impl'`

`ArtifactBranchKind` in `@helm/shared` was extended from `'spec' | 'plan'` to `'spec' | 'plan' | 'impl'`. `parseArtifactBranch` gained a third `IMPL_BRANCH_PREFIX` case with the same `VALID_EXTERNAL_ID` anti-traversal guard applied to spec and plan branches.

`IMPL_BRANCH_PREFIX` and `implBranchName` already existed in `@helm/shared` from Session 16a; this change wires the prefix into the generic parser for the first time.

### 3. Webhook handler — exhaustive `Record` mapping

The two-way conditional was replaced with two module-level `Record<ArtifactBranchKind, …>` constants:

```typescript
const ARTIFACT_STAGE_MAP: Record<ArtifactBranchKind, WorkflowStage> = {
  spec: 'spec-ready',
  plan: 'plan-ready',
  impl: 'released',
};

const ARTIFACT_TRIGGERED_BY_MAP: Record<ArtifactBranchKind, string> = {
  spec: 'webhook:knowledge-repo',
  plan: 'webhook:knowledge-repo',
  impl: 'webhook:code-repo',
};
```

TypeScript enforces that both records cover every member of `ArtifactBranchKind` — adding a new kind without updating the maps is a compile error.

The `triggeredBy` distinction (`webhook:knowledge-repo` vs `webhook:code-repo`) preserves audit clarity: spec/plan merges originate in the knowledge repo; impl merges originate in the code repo.

### 4. Implementer PR body — corrected wording

```diff
- `Review and merge to advance the item to **code-review**.`
+ `Review and merge to advance the item to **released**.`
```

---

## Alternatives Considered

### A — Manual `released` transition via GitHub Projects field

Require operators to manually drag the item to `released` in the tracker UI after the code PR is merged. Rejected: the whole point of Helm is to eliminate manual stage management. The webhook-driven approach is already proven for spec and plan merges.

### B — Separate webhook endpoint for code-repo events

Register a distinct `/api/webhooks/code-repo` endpoint rather than routing impl merges through the existing `/api/webhooks/github` handler. Rejected: GitHub webhooks allow per-repo routing at the payload level (`repository.full_name`). A single endpoint with branch-prefix dispatch is simpler to operate and already handles the authentication/signature-verification boilerplate.

### C — Leave `released` reachable only from the GitHub Projects tracker field

Allow `code-review → released` as a manual Projects field update (existing `item_updated` path) but not from a branch merge. Rejected: inconsistent with how spec-ready and plan-ready are advanced. All three "artifact approved" signals should follow the same merge-loop pattern.

---

## Consequences

**Positive:**
- As of this implementation, the pipeline is end-to-end completable without operator intervention when all three artifact branch prefixes are wired to the webhook handler.
- `Record<ArtifactBranchKind, WorkflowStage>` enforces exhaustiveness under the current type definition — adding a new branch kind without updating the maps produces a compile error.
- The `triggeredBy` audit trail correctly identifies whether a stage change came from the knowledge repo or the code repo under the current single-repo-per-product configuration.

**Negative / Trade-offs:**
- All three webhook-driven transitions (`spec-ready`, `plan-ready`, `released`) now share the same `pull_request_merged` handler. If Helm needs to support multiple knowledge repos or code repos per product in the future, the routing logic will need to be more sophisticated (e.g., validate `repository.full_name` against the product config).
- The `impl` case in `ARTIFACT_STAGE_MAP` hardcodes `released` as the next stage after `code-review` under the current workflow configuration. If the workflow is extended (e.g., a QA gate after code review), this mapping will need to be updated. The `qa_gate` and `designer_gate` fields in the product config are already reserved for this purpose.

---

## Revisit when

- **QA or designer gate is activated:** if `qa_gate` or `designer_gate` is changed from `'skip'` to an active value in a product config, the `impl → released` mapping in `ARTIFACT_STAGE_MAP` will bypass those gates. Reassess whether the merge-loop transition should target an intermediate stage instead of `released`.
- **Multiple code repos per product:** if a product config gains a second `code_repos` entry, the single-endpoint webhook routing will not distinguish which repo a `helm/impl/` merge came from. Reassess `repository.full_name` validation before this configuration is supported.
- **New artifact branch kinds are added:** any new `ArtifactBranchKind` value added to `@helm/shared` must also be reflected in `ARTIFACT_STAGE_MAP` and `ARTIFACT_TRIGGERED_BY_MAP`. TypeScript will catch the omission at compile time, but the correct target stage and triggeredBy value require human judgment.
- **Webhook delivery reliability requirements change:** the current idempotency strategy (log + 200 on `WorkflowTransitionError` / `ItemNotFoundError`) is appropriate for a single-instance deployment. If Helm moves to a multi-instance or event-sourced architecture, duplicate-delivery handling should be reconsidered.

---

## Files Changed

| File | Change |
|------|--------|
| `packages/workflow/src/state-machine.ts` | Add `released` to `code-review` valid transitions |
| `packages/shared/src/spec-branch.ts` | Extend `ArtifactBranchKind`; add `impl` case in `parseArtifactBranch` |
| `apps/api/src/routes/webhooks.ts` | Replace conditional with exhaustive `Record` maps (hoisted to module scope) |
| `packages/orchestrator/src/specialists/implementer.ts` | Fix PR body wording |
| `packages/workflow/src/state-machine.test.ts` | Add `code-review → released` test; update `getValidNextStages` |
| `packages/shared/src/spec-branch.test.ts` | Add impl branch parsing, traversal guards, inverse property tests |
| `apps/api/src/routes/webhooks.test.ts` | Add impl merge block (4 tests) + impl dot-traversal guard test |
| `CHANGELOG.md` | Session 18 entry |
