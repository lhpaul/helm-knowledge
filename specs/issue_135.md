# issue_135 — Specification

Tracks [lhpaul/helm#135](https://github.com/lhpaul/helm/issues/135). Pays down TD-002 (`operations/tech-debt.md`).

## Context
An external review provider (Bugbot, CodeRabbit, Codex on GitHub) signals completion with a GitHub webhook (`external_review_ready`). Helm resumes a deferred review from that webhook only when it finds a `pending_external_review` intent for the exact revision.

helm#112 moved the intent write earlier: the review loop now parks a provisional intent before its first provider poll (`onExternalReviewPending`), and `onExternalReviewDeferred` upserts the same outbox slot. That closed the window between the poll and the defer write.

One window is still open. The provider starts its analysis when a commit is pushed (implementer or remediation push, PR opened). Helm cannot write an intent for that revision before the push, and the loop runs its internal reviewer fan-out before it parks. A fast provider can deliver readiness during that time. The webhook then finds no intent, logs `external review readiness ignored — no pending intent for revision` (or `did not resume … No matching pending external review` when the payload has a head ref) and drops the signal. If the loop's later poll still reports `analysis_pending` (for example, GitHub API reads lag behind the webhook), the loop defers and exits. Nothing resumes it until another webhook arrives or the intent expires.

## Acceptance Criteria
- A provisional pending intent is persisted as soon as the loop enters the external-review wait, before the first poll; the defer callback upserts it. (Already true since helm#112; kept and covered by tests.)
- Within the external-review wait, the intent is persisted before any Helm action that could produce readiness for that revision. Readiness caused by earlier actions (the push itself) is handled by the next criterion, because no intent can exist for a revision before it is pushed.
- Readiness without a matching intent is no longer a silent no-op. Helm records a short-lived readiness note for the revision, logs it, and re-checks once for an intent written in the meantime.
- When the loop defers on a revision that already has a readiness note, the defer callback consumes the note and replays the readiness through the existing resume path (the running job holds the revision, so a `review_dispatch` intent is parked and the post-job replay schedules the review). When the loop's poll sees completion instead, the note is cleared.
- Regression test: readiness fires before the intent is written ("about to defer" → readiness → "intent written"); the resume still happens after the job exits.
- The in-loop poll still recovers the flow when no webhook arrives or the note expires.
- TD-002 is marked Resolved after this work is merged, in a separate step. This item does not mark it Resolved (not in this spec, not in a knowledge PR).

## Out of Scope
- Changing provider adapters, webhook parsing or trust rules.
- Changing stop-rule budgets, `max_defer_sec`, or the orchestrator review loop.
- The `local-ai-reviewer` provider: Helm runs it synchronously and it sends no readiness webhook, so it is not affected.
- Marking TD-002 Resolved.

## Technical Notes
- The readiness note is a new, additive file: `data/external-review-readiness/<productSlug>/<provider>.<targetRevision>.json` with `productSlug`, `provider`, `targetRevision`, `owner`, `repo`, optional `prNumber` and `headRef`, `receivedAt`, `expiresAt`. It lives outside `review-dispatch-outbox/`, so the existing outbox format, readers and expiry sweep do not change. No migration; old data roots simply have no notes.
- Note lifetime is `review.external.max_defer_sec` (default 30 minutes), the same bound as a pending intent. Expired notes are ignored and swept on the dispatch hot path.
- Consumption validates the note against the intent: same product, provider and revision; repository always (code repo for `reviewer-fanout`, knowledge repo for draft reviewers; readiness without repository identity is not recorded, matching the direct webhook path); PR number and head ref artifact identity when the note has them. A mismatch leaves the note alone.
- Both sides use write-then-check, so at least one of them sees the other when the webhook and the defer write interleave. A double resume is harmless: the second schedule attempt is a duplicate revision or upserts the same `review_dispatch` slot.
- Webhook contract: the HTTP response does not change (`{ processed: true }`). Only logs change.
- No public API or config change.
