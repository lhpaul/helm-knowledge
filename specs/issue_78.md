# issue_78 — Specification

## Context
The external review path in ADR-036 currently escalates the entire code-review loop when the configured provider reports `pending_timeout` or equivalent "analysis not ready" states. In dogfood, that behavior has been too aggressive: native reviewers and remediation can finish before the external analysis is ready, and the loop ends up demanding a human action even though the correct next step is simply to wait and resume.

This item makes external review deferable in a provider-agnostic way. Helm should be able to record that external analysis is pending for a specific revision, then resume the review loop automatically when the external provider later publishes readiness for that same revision. The contract must stay generic at the loop boundary so future external providers can plug in without changing the review loop semantics.

## Acceptance Criteria
- When the external review adapter reports an analysis-pending state, the review loop does not emit a human `external_escalate` solely for that reason.
- Helm persists a durable pending-external-review intent keyed by product, external ID, PR number, target revision, and provider.
- The pending intent is cleared when the external review completes successfully, expires, or becomes invalid for the recorded revision.
- When the provider later reports that analysis is ready for the recorded target revision, Helm resumes the review loop without requiring a manual `POST .../dispatch` in the happy path.
- Resume behavior is idempotent and does not create duplicate concurrent fanout jobs for the same revision.
- External review public APIs, outbox entries, and item/job state use external-review naming rather than Haystack-specific naming.
- Haystack is the only implemented provider in v1, and adding another provider remains an adapter plus config change without rewriting the review loop.
- Automated tests cover pending-to-deferred intent creation, ready-to-resume behavior, expiry handling, and ignoring readiness events for the wrong revision.
- The spec is documented or cross-referenced from ADR-036 addendum material, with the Haystack triage flow treated as a provider-specific implementation detail.

## Technical Notes
- The loop boundary should expose a generic deferred status such as `deferred` with a reason like `analysis_pending`, rather than encoding provider-specific states in the review orchestration layer.
- Persistent intent should capture enough information to safely match a later readiness signal against the original review target, including the target revision and provider identity.
- Resume should be driven by a provider signal when available, preferably a GitHub check_run or status update, with a bounded poller as fallback.
- The implementation should preserve the distinction between:
  - analysis still pending and safe to wait for
  - provider unavailable or auth failure, which may still require escalation or skip handling
  - readiness events that do not match the recorded target revision
- Idempotency should be enforced at the orchestration boundary so repeated readiness notifications do not fan out duplicate reviewer jobs for the same revision.
- Provider-specific CLI flags, check names, and triage parsing belong inside the Haystack adapter only; the loop should depend on the external-review adapter contract, not on Haystack internals.
- The semantics should align with the template model of waiting and resuming around platform review readiness, while keeping product-decision escalation rules unchanged.
