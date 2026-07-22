# issue_78 — Implementation Plan

## Overview
Make external review deferable instead of escalatory when the provider says analysis is not ready. Helm should persist a durable pending-external-review intent for the exact product, external review identity, PR number, target revision, and provider; then resume the review loop automatically when the provider later reports readiness for that same revision. The review loop boundary should stay provider-agnostic, using a generic deferred state such as `deferred` with reason `analysis_pending`, while Haystack-specific triage, CLI flags, and readiness parsing remain inside the Haystack adapter.

## Implementation Steps
1. Define the external-review contract at the loop boundary and rename any Haystack-specific public surface to external-review terminology.
   - Add a normalized external-review result shape that can express `clean`, `blocked`, `deferred`, `skipped`, and `escalate` without exposing provider internals to the review loop.
   - Carry a machine-readable deferred reason such as `analysis_pending` so the orchestration layer can tell safe waiting apart from auth/provider failure.
   - Update any item/job/outbox naming that currently says Haystack when it really means external review, while leaving provider-specific adapter internals untouched.

2. Add durable storage for a pending external-review intent and make it the source of truth for deferred analysis.
   - Persist the intent with product, external ID, PR number, target revision, provider, timestamps, and whatever expiry or invalidation metadata the current workflow uses.
   - Make writes idempotent so repeated pending notifications for the same revision do not duplicate the intent row or overwrite a newer revision.
   - Clear the intent when the provider later reports success, when the intent expires, or when the recorded revision is no longer valid for the current PR state.

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
- `packages/orchestrator/src/review-loop/external-review.ts` - define the provider-agnostic normalized contract and deferred status handling.
- `packages/orchestrator/src/review-loop/external-review-loop.ts` - change the loop to persist pending intents, defer on analysis-pending, and resume on readiness.
- `packages/orchestrator/src/review-loop/pending-external-review-store.ts` - add durable storage, matching, expiry, and invalidation for pending intents.
- `packages/orchestrator/src/adapters/haystack-external-review-adapter.ts` - keep Haystack-specific triage parsing, deferred-state detection, and readiness mapping isolated.
- `packages/orchestrator/src/adapters/external-review-adapter.test.ts` - cover provider-agnostic contract behavior and deferred-state normalization.
- `packages/orchestrator/src/review-loop/external-review-loop.test.ts` - cover pending-to-deferred intent creation, resume behavior, wrong-revision ignores, and idempotency.
- `packages/orchestrator/src/review-loop/pending-external-review-store.test.ts` - cover persistence, expiry, clearing, and revision matching.
- `packages/orchestrator/src/adapters/haystack-external-review-adapter.test.ts` - cover Haystack-specific pending, ready, and failure parsing without leaking provider details upward.
- `apps/api/src/routes/webhooks.ts` - receive provider readiness signals and trigger the resume path.
- `apps/api/src/services/job-store.ts` - preserve orchestration-level dedupe so repeated readiness signals do not create duplicate fanout jobs.
- `apps/api/src/services/outbox.ts` - rename or extend outbox entries to external-review terminology where the public event surface is currently Haystack-specific.
- `apps/api/src/services/job-store.test.ts` - verify duplicate readiness notifications and resume attempts stay idempotent.
- `helm-knowledge/decisions/036-pr-review-loop-external-adapter.md` - add the ADR-036 addendum/cross-reference for deferred external review semantics.

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
