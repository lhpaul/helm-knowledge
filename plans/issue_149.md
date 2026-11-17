# issue_149 — Implementation Plan

## Overview
Make the reviewer-fanout cleanup assertions in `dispatcher.test.ts` independent of the shared `os.tmpdir()` contents.

## Implementation Steps
1. In the `dispatchStageHandler > reviewer-fanout` suite, keep a per-test `clonedWorkspaces` list (reset in `beforeEach`); `makeProvisionRunGit` and the failing-clone mock push the clone destination they receive.
2. Replace `listReviewWorkspaces()` (prefix scan of `os.tmpdir()`) and the before/after comparisons with `expectProvisionedWorkspacesRemoved()`, which asserts at least one workspace was provisioned and that each one and its `-artifacts` sibling no longer exist.
3. Add a CHANGELOG `[Unreleased]` → Fixed entry.
4. Open follow-up #152 for the non-reproducible missing-exports signature.

## Files to Touch
- helm: `packages/orchestrator/src/dispatcher.test.ts`, `CHANGELOG.md`.
- helm-knowledge: `specs/issue_149.md`, `plans/issue_149.md`.

## Test Strategy
- Reproduce before the fix: 5 rounds × 4 concurrent `vitest run` of `@helm/orchestrator` with 12 CPU burners.
- Same stress after the fix, plus heavier stress (6 concurrent × 4 rounds, 24 burners) and full `pnpm test --force` runs concurrent with extra orchestrator runs.
- Mutation check: disable the review-loop `rm` cleanup and confirm the rewritten tests fail.
- Gate: `pnpm install --frozen-lockfile && pnpm lint && pnpm test`, then 5 consecutive full `pnpm test --force` runs (the last two under load).

## Risks
Low. Test-only change. Rollback: revert the commit.
