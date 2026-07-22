# issue_71 — Specification

## Context
Helm currently depends on operator-triggered remediation for draft artifacts. Spec and plan PRs require manual `spec-remediator` / `plan-remediator` feedback, and common false-positive dismissals such as `pair-spec-and-plan-files` still depend on human intervention. ADR-040 defines an early artifact review loop that should run before operator involvement for draft spec and plan artifacts.

This item adds an opt-in review path controlled by `review.early_loop.enabled` in `product.yaml`. When enabled, Helm should automatically review and remediate `spec-draft` and `plan-draft` artifacts using the same loop-oriented patterns already used in ADR-036 where applicable, while keeping the default behavior unchanged until rollout is complete.

## Acceptance Criteria
- `review.early_loop.enabled` exists in product configuration and defaults to `false`.
- When `review.early_loop.enabled` is `true`, newly created or updated `spec-draft` and `plan-draft` artifacts enter an automated review/remediation loop without requiring operator-authored remediator feedback for the common false-positive class covered by `pair-spec-and-plan-files`.
- The early loop reuses the established ADR-036 review/remediation loop mechanics where they apply, rather than introducing a separate incompatible flow.
- The false-positive catalog includes entries for Helm sequential artifact branches, including `pair-spec-and-plan-files` and sequencing-related cases, so the loop can auto-dismiss or route them consistently.
- When `review.early_loop.enabled` is `false`, existing operator-triggered `spec-remediator` / `plan-remediator` behavior remains unchanged.
- The behavior is documented as an opt-in product capability and the default remains off.
- The implementation is covered by tests that demonstrate both enabled and disabled behavior, including the common false-positive path.

## Technical Notes
- Keep the change scoped to draft artifact review behavior; do not alter the broader spec/plan workflow state machine beyond what is required to attach the early loop.
- Reuse existing review loop primitives and event handling from ADR-036 rather than duplicating orchestration logic.
- Treat `review.early_loop.enabled` as a product-level feature flag so rollout can be controlled without code changes.
- The false-positive catalog should be explicit and machine-readable so artifact sequencing cases can be recognized consistently across spec/plan drafts.
- Preserve backward compatibility for existing repositories and workflows by leaving the default configuration off.
- The implementation should be designed so later rollout can expand the enabled scope without changing the underlying artifact review contract.
