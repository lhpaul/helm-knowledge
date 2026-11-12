# issue_134 — Implementation Plan

## Overview
Make the local-ai-reviewer adapter read the companion's `RESULT`/`REASON` on non-pass outcomes, classify deterministic reasons as `escalate`, keep transient ones retryable with the real reason, and capture bounded, redacted stderr for server-side diagnosis.

## Implementation Steps
1. `executeLocalAiReview`: pipe stderr and keep only a bounded tail; when the evidence file does not exist (`ENOENT`) return `evidence: null` instead of throwing; attach the stderr tail to the timeout/spawn error.
2. `parseLocalAiReview`: after reading KV fields, if `RESULT` is present and not `clean`/`needs_fixes`, validate `REASON` as a slug; return `{ status: 'escalate', reason }` when `RESULT=escalate`, exit 2 and the reason is in the deterministic set; otherwise `skipped:unavailable` with `providerReason = reason` (fallback `no_terminal_verdict`). Pass verdicts keep current checks.
3. Adapter: `review_md_missing` preflight returns `escalate`; log `RESULT`, `REASON`, exit code and redacted stderr tail with `console.warn` on every non-pass outcome.
4. Stop rule: document that adapter `escalate` short-circuits the skip budget; add tests for a deterministic reason and for a transient reason that is retried and then escalated with the reason in the detail.
5. Update `docs/local-ai-reviewer.md` and CHANGELOG `[Unreleased]` (Fixed).

## Files to Touch
- helm: `packages/orchestrator/src/external-review/local-ai-reviewer/{adapter.ts,adapter.test.ts}`, `packages/orchestrator/src/review-loop/{external-stop-rule.ts,external-stop-rule.test.ts}`, `docs/local-ai-reviewer.md`, `CHANGELOG.md`.
- helm-knowledge: `specs/issue_134.md`, `plans/issue_134.md`.

## Test Strategy
Unit tests for parse/classification (deterministic, transient, unknown, malformed reason, missing evidence), for real command execution (missing evidence file returns parsed reason; stderr tail bounded), for the adapter (`review_md_missing` escalates, deterministic does not retry), and for the stop rule. Then `pnpm install --frozen-lockfile && pnpm lint && pnpm test`.

## Risks
Medium-low. Only non-pass outcomes change; pass verdict checks are untouched. A reason wrongly classified as deterministic would escalate early instead of retrying once, which is safe (human sees the real reason). Rollback: revert the PR.
