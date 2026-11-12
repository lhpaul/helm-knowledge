# issue_135 — Implementation Plan

## Overview
Keep the provisional intent from helm#112 and close the remaining window, readiness that arrives before any intent exists. The webhook records a short-lived readiness note instead of dropping the signal and re-checks once. The review loop's defer callback consumes the note and replays it through the existing resume path. A settled wait clears the note.

## Implementation Steps
1. Add `apps/api/src/services/external-review-readiness.ts`: a small file store for readiness notes (`put`, `find`, `remove`, `removeExpired`) under `data/external-review-readiness/<productSlug>/<provider>.<sha>.json`. Validate every path segment with `isValidExternalId`.
2. `dispatch-scheduler.ts`:
   - `recordEarlyExternalReviewReadiness()`: write the note, log it, then re-check for a pending intent by revision. If one exists and matches the note, replay it.
   - `replayEarlyExternalReviewReadiness()` (internal): match the note against an intent (PR, repo, head ref), call `finalizePendingExternalReviewResume`, remove the note.
   - `onExternalReviewDeferred`: after the upsert, look for a note on that revision and replay it (best effort, logged).
   - `onExternalReviewSettled`: also drop the note for that revision.
   - Thread the dispatch `dataRoot` into `finalizePendingExternalReviewResume` so the in-job path writes to the same root as the outbox it read.
   - Sweep expired notes together with expired pending intents.
3. `routes/webhooks.ts`: on both no-intent branches (no revision match and no head ref; head ref path whose resume reports no matching intent), call `recordEarlyExternalReviewReadiness` instead of only logging.
4. Tests:
   - store unit tests (round trip, unsafe segments, expiry);
   - dispatch-scheduler regression test: readiness recorded before the intent, then the job parks and defers, and the post-job replay schedules the review; mismatch keeps the note; settle clears it; webhook-side re-check replays when the intent already exists;
   - webhook route tests for both no-intent branches.
5. Docs: `docs/product-config.md` (readiness before the pending intent), CHANGELOG `[Unreleased]` → Fixed.

## Files to Touch
- helm: `apps/api/src/services/{external-review-readiness.ts,external-review-readiness.test.ts,dispatch-scheduler.ts,dispatch-scheduler.test.ts}`, `apps/api/src/routes/{webhooks.ts,webhooks.test.ts}`, `docs/product-config.md`, `CHANGELOG.md`.
- helm-knowledge: `specs/issue_135.md`, `plans/issue_135.md`.

## Test Strategy
Unit and route tests above, then `pnpm install --frozen-lockfile && pnpm lint && pnpm test`.

## Risks
Medium. The change touches the resume path of the review loop, but only adds a new file type and a replay that reuses `finalizePendingExternalReviewResume`. Existing outbox data and webhook responses are unchanged. Worst case, a wrong match replays a review on a revision that already finished; the job store dedupes it as a duplicate target revision. Rollback: revert the PR; leftover note files are ignored and can be deleted.
