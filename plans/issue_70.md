# issue_70 — Implementation Plan

## Overview
Add automatic review-loop re-dispatch in two places: when the implementer finishes successfully and transitions an item into `code-review`, and when a newly created structured `issue_comment` on the configured implementation PR resolves a `HUMAN_REQUIRED` adjudication. Both paths will route through the existing dispatch machinery, but with a revision-aware dedupe key so repeated webhooks, duplicate comments, or retries do not create duplicate concurrent review jobs. The webhook path must fail closed for non-matching repos/PR numbers, and the implementer-completion handoff must persist a recoverable pending dispatch intent if the immediate enqueue cannot complete.

## Implementation Steps
1. Extend the GitHub webhook parsing path so PR comments can be distinguished from ordinary issue comments.
   - Keep `issue_comment` on tracker issues as a no-op / tracker comment path.
   - Emit a PR-comment-specific normalized event only when the payload contains a pull request and the webhook action is `created`.
   - Explicitly ignore `edited` and `deleted` actions, even if the body still contains the Helm decision marker.
   - Add parser coverage for created comments, ignored free-form comments without the Helm decision marker, edited comments that must not enqueue review, and payloads that do not match the structured decision format.

2. Add a small GitHub PR metadata lookup helper in `apps/api` that resolves the current PR head at dispatch time.
   - Resolve repo owner/name from the configured code repo URL.
   - Fetch the open PR by number and read its current head ref and head SHA.
   - Reuse the helper from both the implementer-completion trigger and the human-resolution trigger so both paths dispatch from the latest available HEAD.
   - Require the webhook repository and PR number to match the item's configured open implementation PR before validating the decision or resolving HEAD.

3. Make the dispatch scheduler and job store revision-aware.
   - Extend the job record with `targetRevision` metadata.
   - Teach `scheduleItemDispatch` / `createJobIfNoRunning` to short-circuit when an equivalent job already exists for the same product, item, and target revision.
   - Make same-target dedupe atomic with a conflict-safe insert, unique constraint, or equivalent transaction keyed by `(productSlug, externalId, targetRevision)`.
   - Preserve the existing running-job guard so the review loop still behaves as a single active pipeline for the item.
   - If a newer eligible revision arrives while an older review job is still running, record the newer revision as the next pending review-dispatch intent and replay it after the active job finishes; do not start a second concurrent pipeline.
   - Keep only the freshest pending revision for a given item/PR so repeated newer deliveries converge on the latest HEAD rather than stacking multiple deferred dispatches.
   - Keep trigger-source metadata out of the dedupe key; it should remain logging-only.

4. Wire the implementer completion path to auto-schedule reviewer fan-out after the item reaches `code-review`.
   - Use the existing implementer result flow in the API dispatch layer, where the stage transition already happens.
   - After a successful transition to `code-review`, resolve the implementation PR head SHA and enqueue the review-loop dispatch if no equivalent job is already running.
   - If the transition succeeds but PR lookup or job creation fails, persist a durable pending review-dispatch intent/outbox entry so the item can be reconciled back into the review loop instead of remaining stuck in `code-review`.
   - If a newer target revision is discovered while an older revision is still under review, persist the newer revision as pending rather than dropping it; the outbox replay should dispatch the newest eligible HEAD after the active job completes.
   - Ensure the hook only fires for the implementer completion path, not for remediation recovery or unrelated `code-review` transitions.

5. Wire the human-resolution webhook path to re-dispatch review from the current PR HEAD.
   - Accept structured `issue_comment` webhooks only on the configured implementation PR and only for `created` actions, regardless of issue-tracker provider.
   - Enforce an explicit commenter authorization check before scheduling: require the author to have write permission on the code repository or equivalent push access, and ignore unauthorized marker-bearing comments with a structured log entry.
   - Require the `<!-- helm:product-decision -->` marker and parse the conflict kind, conflict title, and chosen option.
   - Validate the structured decision against the adjudication context before scheduling.
   - Resolve the PR's current head SHA at dispatch time and enqueue the review loop only when the item is still eligible and no equivalent job already exists.

6. Keep the scheduling path idempotent and conservative.
   - Ignore duplicate comments, webhook retries, and repeated state transitions when they point at the same target revision.
   - If a newer HEAD arrives while the same item is already being reviewed, retain it as pending and replay it after the current pipeline completes.
   - Do not schedule when the item is already actively being reviewed for the same target.
   - Preserve the current review target semantics by always using the freshest known PR HEAD for the dispatch attempt.

## Files to Touch
- `apps/api/src/services/dispatch-scheduler.ts` - add revision-aware scheduling, same-target dedupe, and the implementer-completion follow-up enqueue.
- `apps/api/src/services/job-store.ts` - persist `targetRevision` and use it in the running-job / equivalence checks.
- `apps/api/src/services/dispatch-scheduler.test.ts` - cover revision-aware scheduling, implementer follow-up behavior, and duplicate suppression.
- `apps/api/src/services/job-store.test.ts` - cover the revised job identity and no-double-run cases.
- `apps/api/src/services/github-pr.ts` - new helper for resolving PR metadata at dispatch time.
- `apps/api/src/services/github-pr.test.ts` - verify PR lookup, head SHA extraction, and failure handling.
- `apps/api/src/services/review-dispatch-outbox.ts` - persist and replay the pending review-dispatch intent for failed implementer-completion handoffs.
- `apps/api/src/routes/webhooks.ts` - handle structured PR decision comments and route them into the scheduler.
- `apps/api/src/routes/webhooks.test.ts` - cover the PR comment trigger, ignored free-form comments, and duplicate/no-op cases.
- `packages/adapters/src/types.ts` - add a PR-comment normalized event shape.
- `packages/adapters/src/github-projects/webhook-parser.ts` - distinguish PR comments from issue comments.
- `packages/adapters/src/github-projects/webhook-parser.test.ts` - verify the new PR-comment parsing behavior.

## Rollout
- Persist `targetRevision` in the job JSON with backward-compatible reads: missing fields mean "unset" and must not match any revision-specific dedupe key.
- Keep the review-dispatch outbox on the filesystem as well, with a simple file-backed pending-intent format that can represent the item, product, configured implementation PR, and target revision.
- Ship reader tolerance before writer usage: first deploy code that accepts old job/outbox files, then enable writing the new `targetRevision` and pending-review entries.
- Use conflict-safe filesystem updates for job and outbox files so concurrent deliveries do not corrupt state; atomically replace files or otherwise serialize writes per item.
- No explicit backfill is required for in-flight jobs beyond tolerant reads; existing active jobs can complete under the old shape and will not be retroactively rewritten unless the scheduler touches them.

## Test Strategy
- Unit tests for the parser:
  - PR `issue_comment` with the Helm marker becomes the new PR-comment event only when `action=created`.
  - Free-form issue comments remain non-actionable.
  - Edited and deleted comments never enqueue review, even when the marker is present.

- Unit tests for the scheduler and job store:
  - Implementer completion schedules exactly one reviewer job for the resolved target revision.
  - A repeated webhook/comment for the same revision is ignored.
  - An already-running job for the same item prevents a duplicate dispatch.
  - A newer revision arriving while an older review job is running becomes pending and is dispatched after the older job finishes.
  - `targetRevision` is persisted and compared as part of dedupe.
  - Concurrent duplicate deliveries still produce only one job because the same-target insert is atomic.
  - A failed implementer-completion enqueue leaves a recoverable pending dispatch intent that can later be replayed.
  - An unauthorized commenter bearing the Helm marker is ignored and does not enqueue review.

- Route tests for `POST /api/webhooks/github`:
  - A valid human decision comment triggers review dispatch from the current PR HEAD only for a matching repository and PR number.
  - A malformed or unmarked comment is ignored.
  - A comment on the wrong repo or PR number is ignored.
  - An edited comment with a valid marker is ignored.
  - A marker-bearing comment from a user without write permission is ignored.
  - The path works for both tracker providers, since the trigger is a GitHub PR event.

- End-to-end style API tests where practical:
  - Simulate implementer completion flowing through the scheduler into a review-loop dispatch.
  - Simulate a retry / duplicate webhook and confirm no second job is created for the same target.
  - Simulate transition success plus PR lookup or enqueue failure, then recovery via the pending dispatch intent.
  - Simulate A running on SHA_A, B arriving on SHA_B, then A completing and B being dispatched from the pending outbox entry.

## Risks / Open Questions
- The exact shape of the structured human-decision parser may need one iteration if the adjudication comment format drifts from the example in the spec.
- The PR metadata lookup must fail closed if GitHub cannot resolve the PR head; that failure mode needs a deliberate test so the route does not silently enqueue against stale state.
- The commenter authorization policy must be enforced consistently for both open-source and dogfood deployments so a marker-bearing comment without write access cannot trigger review.
- The pending review-dispatch intent/outbox must be reconciled idempotently so a transient lookup or enqueue failure, or a newer HEAD arriving while an older job runs, does not strand the item in `code-review`.
- The filesystem-backed job/outbox update path must remain conflict-safe under retries and concurrent webhook deliveries.
- If the repo later wants different dedupe semantics for concurrent jobs across different heads on the same item, that would be a separate workflow decision; this item should stay focused on idempotent re-dispatch for the same target revision.
