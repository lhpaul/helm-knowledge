# issue_71 — Implementation Plan

## Overview
Add an opt-in early artifact review loop for `spec-draft` and `plan-draft` artifacts, controlled by `review.early_loop.enabled` in `product.yaml`. When enabled, Helm should route draft spec/plan artifacts through the existing ADR-036 review/remediation machinery so common sequencing false positives can be auto-dismissed before operator-authored remediation is required. The default remains off to preserve current behavior for existing products and repositories.

## Implementation Steps
1. Extend the shared product config schema to carry `review.early_loop.enabled` as a boolean feature flag with a default of `false`, and update any parsing helpers so omitted config remains backward-compatible.
2. Add resolver logic for the early loop flag in the orchestrator review-loop config layer so dispatch code can query a normalized `earlyLoopEnabled` value alongside the existing ADR-036 settings.
3. Reuse the ADR-036 review/remediation loop path for draft spec and plan artifacts when the flag is enabled, rather than adding a new orchestration mechanism. The implementation should attach the early loop at the dispatch/review boundary for `spec-draft` and `plan-draft` only.
4. Expand the machine-readable false-positive catalog to include Helm sequential-artifact cases, especially `pair-spec-and-plan-files` and related sequencing patterns, so automated review can classify them consistently during draft review.
5. Preserve the existing operator-triggered `spec-remediator` / `plan-remediator` flow when the early-loop flag is disabled, including the current requirement for explicit feedback.
6. Update product-facing documentation to describe the new flag as an opt-in capability with an off-by-default rollout posture.
7. Add tests that cover:
   - schema parsing and defaulting for `review.early_loop.enabled`;
   - enabled-vs-disabled behavior for draft spec/plan review routing;
   - automatic dismissal or routing of the common false-positive path;
   - regression coverage proving operator-triggered remediation is unchanged when the flag is off.

## Files to Touch
- `packages/shared/src/config/product-schema.ts` - add the `review.early_loop.enabled` product flag and defaulting rules.
- `packages/shared/src/config/product-schema.test.ts` - cover parsing, defaults, and validation for the new flag.
- `packages/orchestrator/src/review-loop/config.ts` - normalize the early-loop setting alongside the existing ADR-036 review config.
- `packages/orchestrator/src/review-loop/code-review-loop.ts` - attach the early loop to the existing remediation loop mechanics for draft artifacts.
- `packages/orchestrator/src/dispatcher.ts` - gate draft-artifact review routing on the new feature flag without changing the disabled path.
- `packages/orchestrator/src/review-loop/false-positives.ts` - ensure the catalog format can represent sequential-artifact false positives consistently.
- `packages/orchestrator/src/review-loop/false-positives.test.ts` - add coverage for the new sequential-artifact patterns.
- `packages/orchestrator/src/dispatcher.test.ts` - verify enabled and disabled draft-review behavior end to end.
- `packages/orchestrator/src/review-loop/code-review-loop.test.ts` - cover the early-loop behavior using the existing ADR-036 loop primitives.
- `CHANGELOG.md` - document the opt-in review capability and its default-off rollout posture.

## Test Strategy
- Unit tests for `ProductSchema` parsing and default values to confirm the new flag is absent-by-default and strictly boolean when present.
- Unit tests for review-loop config resolution and dispatcher branching to prove the enabled path uses the existing loop mechanics and the disabled path still routes to operator-triggered remediation.
- Catalog parsing tests that verify sequential-artifact false positives, including `pair-spec-and-plan-files`, are recognized as explicit machine-readable entries.
- End-to-end-style orchestrator tests that simulate draft spec/plan artifacts entering the system with the flag both on and off, asserting the resulting review/remediation behavior.
- Regression tests that confirm the legacy remediation workflow still requires operator feedback when `review.early_loop.enabled` is `false`.

## Risks / Open Questions
- The exact attachment point for the early loop may need to stay narrow so the broader workflow state machine remains unchanged; if the dispatcher boundary is insufficient, the review-loop entry point may need a small internal hook instead.
- The false-positive catalog shape may need a small extension if sequential-artifact cases require more than a title/pattern/rationale triple to disambiguate spec-vs-plan sequencing.
- The plan assumes the existing ADR-036 loop primitives are reusable for draft artifacts without introducing a second remediation contract; if that assumption fails, the implementation should stop and reconcile the contracts before expanding scope.
