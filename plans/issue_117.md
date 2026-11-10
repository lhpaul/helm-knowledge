# issue_117 — Implementation Plan

## Overview
Make the external-review step of `runCodeReviewLoop` head-aware so a push during the dispatch never escalates by itself.

## Implementation Steps
1. Add `resolveCurrentHeadRevision(params)` in `review-loop/code-review-loop.ts`: `gh pr view <prUrl> --json headRefOid` via the injectable `runGh`; returns a 40-hex SHA or `undefined` on any failure (best effort).
2. Track `currentRevision` across cycles in `runCodeReviewLoop` (starts at `params.targetRevision`); before each external pass refresh it from the resolved head.
3. In `runExternalReviewWithStopRule`, after each attempt re-resolve the head; if it differs from the reviewed revision, retry on the new head without incrementing the skip counter (bounded by `MAX_HEAD_CHANGE_RETRIES = 3`, no backoff). Return the revision actually used.
4. Re-key the pending intent: clear the provisional intent for a superseded SHA; the deferred intent uses the returned revision.
5. CHANGELOG `[Unreleased]` entry.

## Files to Touch
- `packages/orchestrator/src/review-loop/code-review-loop.ts`
- `packages/orchestrator/src/review-loop/code-review-loop.test.ts`
- `CHANGELOG.md` (helm repo)

## Test Strategy
Unit tests in `code-review-loop.test.ts` with mocked `runGh` and `runExternalReviewIfConfigured` for each acceptance criterion.

## Risks / Open Questions
- One extra `gh` call per external pass; failure falls back to the recorded SHA.
- A head that keeps moving is bounded; after the bound the existing escalation applies.
