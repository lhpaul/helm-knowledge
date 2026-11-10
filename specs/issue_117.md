# issue_117 — Specification

## Context
With `review.external.provider: local-ai-reviewer` the external review is bound to one exact PR head (`REVIEWED_HEAD`). Inside a single code-review dispatch the loop reviews, remediates (the remediator pushes a new commit), then runs the external review again — but it keeps passing the head SHA captured when the dispatch started. The reviewer then sees a head that no longer matches, returns a non-verdict (`head_mismatch` / `execution_unavailable`), the skip budget is exhausted and the item escalates to HUMAN_REQUIRED (`external_repeated_skip`). The same happens when a push lands while the external review is running. Helm's own pushes do not re-dispatch (the orchestrator's `synchronize` webhooks are ignored), so nothing else picks the new head up.

## Acceptance Criteria
- The external review always targets the current PR head: the loop re-resolves the head before the external pass and uses that SHA.
- If the head changes while an external review is running (its result is a non-verdict, or a verdict for a superseded SHA), the review is retried on the new head without consuming the skip budget and without escalating solely for that reason.
- Head-change retries are bounded; when exhausted the existing stop-rule behaviour applies unchanged.
- The pending-external-review intent (provisional and deferred) is keyed by the head actually reviewed; an intent parked for a superseded SHA is cleared so a late readiness signal cannot resume it.
- Genuine reviewer failures (provider error, definitive timeout, `escalate`, findings needing a human) with an unchanged head still escalate/retry exactly as before.
- If the current head cannot be resolved, behaviour falls back to the recorded revision (no new failure mode).
- Tests cover: head advanced after remediation, head advanced mid-review, retries exhausted, unchanged head keeps escalating, head lookup failure, intent re-keying.

## Technical Notes
- Provider-agnostic: implemented at the review-loop boundary, not inside one adapter.
- Idempotency: one external pass per head SHA at a time; a retry replaces, never duplicates, the pending intent for the PR.
- Related: #78 (defer/resume when analysis is pending).
