# issue_78 — Implementation Plan

## Overview
Make external review deferable instead of escalatory when the provider says analysis is not ready. Helm should persist a durable pending-external-review intent for the exact product, external review identity, PR number, target revision, and provider; then resume the review loop automatically when the provider later reports readiness for that same revision. The review loop boundary should stay provider-agnostic, using a generic deferred state such as `deferred` with reason `analysis_pending`, while Haystack-specific triage, CLI flags, and readiness parsing remain inside the Haystack adapter.

## Implementation Steps
1. Extend the existing `ExternalReviewResult` contract (do not invent a parallel loop module).
   - Add `deferred` with reason `analysis_pending` alongside existing `clean` | `needs_fixes` | `skipped` | `escalate`.
   - Keep orchestration types free of Haystack names; provider-specific strings stay inside the Haystack adapter.
   - Prefer extending `ReviewDispatchIntent` / review-dispatch outbox over a brand-new store, unless a field shape clearly does not fit.

2. Persist pending-external-review intents via the existing review-dispatch outbox (or a thin extension of it).
   - Key by product, external ID, PR number, target revision, and provider; include createdAt / expiresAt (`max_defer_sec`).
   - Idempotent writes for the same revision; clear on success, expiry, or invalid revision.

3. Teach the review loop to defer instead of escalating when the adapter reports analysis is pending.
   - Replace the current `pending_timeout`-style escalation branch with a deferred return that records the pending intent and exits the loop without human escalation.
   - Preserve the distinction between safe-to-wait pending analysis, provider/auth failure, and readiness signals that do not match the recorded revision.
   - Keep the loop idempotent so repeated pending signals or retries do not create duplicate concurrent fanout jobs for the same revision.

4. Wire resume handling to provider readiness signals and a bounded poller fallback.
   - Prefer a GitHub `check_run` or status update when the provider can publish readiness for the recorded target revision.
   - Match the readiness event against the stored intent using provider identity, external ID, PR number, and target revision before resuming.
   - If the provider has no push signal available, use a bounded poller to re-check readiness and resume only when the stored intent still matches.
   - Treat readiness events for the wrong revision as no-ops so an older or stale update cannot wake the wrong review run.

5. Implement the Haystack adapter as the only v1 provider and keep provider-specific logic contained there.
   - Map Haystack triage output to the generic external-review contract, including deferred analysis states versus genuine escalations.
   - Keep Haystack CLI flags, check names, and parsing rules inside the adapter rather than in the review loop or API layer.
   - Ensure adding a future provider is an adapter plus config change, not a review-loop rewrite.

6. Update API routes, outbox handling, and job scheduling so deferred external review can resume automatically and safely.
   - Emit and consume external-review named events on the public API surface.
   - On a matching readiness signal, enqueue the resume path without requiring a manual `POST .../dispatch`.
   - Guard the resume path with the same orchestration-boundary idempotency checks used elsewhere so duplicate readiness notifications do not fan out duplicate reviewer jobs.
   - Clear or invalidate stale pending intents when the resume path determines the recorded revision is no longer current.

7. Add the documentation cross-reference required by ADR-036 addendum material.
   - Record the provider-agnostic deferred/resume semantics in the ADR-036 addendum or a linked decision note.
   - Keep the Haystack triage flow described as a provider-specific implementation detail, not the canonical loop contract.

## Files to Touch
Existing layout (do **not** invent parallel modules): extend the ADR-036 external-review package and the existing review-dispatch outbox.

- `packages/orchestrator/src/external-review/types.ts` — extend `ExternalReviewResult` with `deferred` / `analysis_pending` (keep existing `clean` | `needs_fixes` | `skipped` | `escalate`).
- `packages/orchestrator/src/external-review/run.ts` — route deferred results without provider leakage.
- `packages/orchestrator/src/external-review/haystack/adapter.ts` — map Haystack pending / budget-exhausted triage to generic `deferred` (not `escalate`).
- `packages/orchestrator/src/external-review/haystack/triage-poll.ts` — today maps budget exhaust → `pending_timeout` → escalate; change to deferred when configured.
- `packages/orchestrator/src/external-review/haystack/skip-evidence.ts` / `normalize.ts` — reuse readiness / check evidence for resume matching where useful.
- `packages/orchestrator/src/review-loop/external-stop-rule.ts` — add `defer` action distinct from `external_escalate`.
- `packages/orchestrator/src/review-loop/code-review-loop.ts` — on defer: persist pending intent callback / result without human escalation comment.
- `packages/orchestrator/src/dispatcher.ts` — surface a non-error deferred outcome (or equivalent) so jobs are not treated as hard failures.
- `packages/shared/src/config/product-schema.ts` — generic knobs under `review.external` (`defer_when_pending`, `resume_on_check_run`, `max_defer_sec`); keep poll/timeout under `haystack:`.
- `apps/api/src/services/review-dispatch-outbox.ts` — extend `ReviewDispatchIntent` (or sibling fields) for pending-external-review: provider, kind, expiresAt; reuse put/get/replay + revision matching.
- `apps/api/src/services/dispatch-scheduler.ts` — `persistReviewDispatchIntent` / `replayPendingReviewDispatch` when deferred; clear on success/expiry/wrong revision.
- `apps/api/src/routes/webhooks.ts` — handle GitHub `check_run` / status readiness and trigger idempotent `reviewer-fanout` resume for matching intents.
- Colocated tests: `external-stop-rule.test.ts`, `code-review-loop.test.ts`, haystack `adapter.test.ts` / `triage-poll` tests, `review-dispatch-outbox.test.ts`, `webhooks.test.ts`.
- `decisions/036-pr-review-loop-external-adapter.md` (this knowledge repo) — addendum for deferred/resume semantics (Haystack remains provider detail).

## Test Strategy
- Unit tests for the review loop:
  - analysis-pending returns `deferred` with reason `analysis_pending` instead of `external_escalate`
  - the pending intent is written with product, provider, external ID, PR number, and target revision
  - a later readiness signal for the same revision resumes the loop without manual dispatch
  - readiness for the wrong revision is ignored
  - repeated readiness notifications do not create duplicate concurrent fanout jobs

- Persistence tests for the pending-intent store:
  - duplicate pending writes for the same revision are idempotent
  - success, expiry, and invalid-revision cases clear the stored intent
  - matching is strict enough to avoid resuming against a stale PR state

- Adapter tests for Haystack:
  - Haystack pending states map to the generic deferred contract
  - Haystack readiness states map to the resume path
  - provider unavailable or auth failure stays distinct from safe-to-wait pending analysis

- Route / orchestration tests:
  - a readiness webhook or status event resumes the stored pending review automatically
  - duplicate readiness events remain no-ops
  - a bounded poller fallback resumes only when the stored intent still matches

## Risks / Open Questions
- The exact readiness signal source may vary by provider and GitHub integration path, so the implementation should keep the resume matcher abstract enough to accept either a check-run update or a status update.
- Expiry policy is not spelled out in the spec, so the implementation needs to reuse the existing review-timeout or lifecycle convention instead of inventing a new one.
- The current codebase may already have Haystack-specific naming in multiple layers; renaming the public surface without breaking internal adapter behavior may need a small compatibility shim during the transition.
- Wrong-revision matching needs to be strict. If the target revision cannot be proven, the safe behavior is to leave the intent pending or clear it, not to resume optimistically.
