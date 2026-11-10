# issue_125 — Implementation Plan

## Approach
1. `review-loop/adjudication.ts`: add `resolveHierarchyDocConflicts` (doc_conflict + `Resolved by: ADR|spec|CLAUDE.md` -> AUTO plan entry; status recomputed from the declared status, never lifting an explicit HUMAN_REQUIRED).
2. `specialists/review-adjudicator.ts`: draft-artifact prompt guidance; `handleReviewAdjudicatorResult` takes `{ artifactReview }` and applies the resolver after settled-decision suppression.
3. `code-review-loop.ts`: pass `artifactReview` when a draft artifact is under review.
4. Docs (`docs/product-config.md`), CHANGELOG `[Unreleased]`.

## Validation
Unit tests for the resolver (resolved, product_decision kept, no source, reviewer opinion, mixed, explicit HUMAN_REQUIRED), prompt guidance, and handler (artifact vs implementation). `pnpm lint && pnpm test`.

## Risks
Medium. Relies on the adjudicator emitting `Resolved by`; if it does not, behavior is as before (fail-safe escalation).
