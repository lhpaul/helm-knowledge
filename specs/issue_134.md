# issue_134 — Specification

## Context
With `review.external.provider: local-ai-reviewer`, the ADF companion reports why it stopped through stdout (`RESULT=escalate`, `REASON=<slug>`, exit 2), and sometimes writes no evidence file (preflight failures such as a missing `REVIEW.md`). Helm's adapter discards stderr, throws when the evidence file is absent, and maps every such case to `skipped:unavailable` with provider reason `execution_unavailable`. The external stop rule then retries once and escalates `external_repeated_skip` with the real cause hidden. On a knowledge repo without `REVIEW.md` the companion reported `review_contract_missing`; Helm retried, masked the reason, and the item stalled for days.

## Acceptance Criteria
- When the companion reports a `REASON`, the adapter propagates it instead of `execution_unavailable` (also when no evidence file was written).
- Deterministic reasons are not retried: the adapter returns `status: 'escalate'` with the companion reason and the stop rule escalates immediately (`external_escalate`). Deterministic set: `review_contract_missing`, `invalid_backend`, `missing_command`, `invalid_repo_root`, `repo_root_mismatch`, `missing_credentials`, `missing_model_access`, plus Helm's own `review_md_missing` preflight (same root cause as `review_contract_missing`).
- Transient or real execution failures (timeout, spawn failure, `quota_exhausted`, `head_mismatch`, `diff_unavailable`, `malformed_output`, `waiting_on_reviewer`, unknown reasons) stay `skipped:unavailable`, now carrying the companion reason as `providerReason`, and keep the current retry budget.
- Companion stderr is captured, bounded (tail only) and redacted; together with `RESULT`/`REASON`/exit code it is logged server-side for diagnosis. It is never put in PR comments or escalation messages.
- Tests cover the deterministic path (missing `REVIEW.md`, missing evidence file, no retry) and the transient path (retried).

## Out of Scope
- Changing the companion (ADF) or its exit-code contract.
- Changing stop-rule budgets, deferral, or other providers.
- Creating `REVIEW.md` in reviewed repos.

## Technical Notes
- Only a slug-shaped `REASON` (`[a-z][a-z0-9_-]{0,63}`) is propagated; anything else becomes `no_terminal_verdict`.
- Deterministic escalation requires `RESULT=escalate` and exit 2, so a malformed or contradictory output cannot escalate by accident; it falls back to the retryable path.
- Pass verdicts (`clean`, `needs_fixes`) keep the existing evidence and head checks unchanged.
- Public types do not change. Behavior change: `review_md_missing` moves from `skipped:unavailable` to `escalate` (documented).
