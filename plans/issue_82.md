# issue_82 — Implementation Plan

## Overview
Add Bugbot as a first-class external review provider behind the existing ADR-036 adapter contract, without rewriting the broader code-review loop. The implementation will keep Haystack supported for migration, move all Bugbot parsing and normalization into a dedicated adapter, and tighten deferred-resume handling so only explicit Bugbot completion signals can wake pending work.

## Implementation Steps
1. Inventory the current review boundary in the API codebase and identify the exact seams for provider selection, adapter instantiation, deferred-review resume, and webhook/event ingestion.
2. Extend product schema validation so `review.external.provider` accepts both `haystack` and `bugbot`, and add a `review.external.bugbot` subtree with strict validation for the provider-specific knobs required by the adapter.
3. Implement `BugbotExternalReviewAdapter` behind the ADR-036 `ExternalReviewAdapter` contract.
4. Keep all Bugbot-specific parsing inside the adapter:
   - normalize Bugbot outcomes into the existing review states (`clean`, `needs_fixes`, `deferred` / `analysis_pending`, `skipped`, `escalate`);
   - map Bugbot check-runs and review comments/threads into findings;
   - derive stable ledger IDs deterministically so repeated deliveries do not duplicate findings.
5. Wire the generic review entrypoint so `runExternalReviewIfConfigured` and the code-review loop treat Bugbot as just another provider at the boundary, while preserving the current internal reviewer fan-out flow and the existing Haystack path.
6. Harden deferred-resume logic so pending work resumes only when all of the following match:
   - provider is Bugbot;
   - PR number matches;
   - exact head SHA matches current-head evidence;
   - the signal comes from the explicit allowlist of Bugbot check names;
   - the emitting GitHub App identity matches the Cursor/Bugbot trust boundary.
7. Reject generic `status` traffic as a resume trigger unless it is explicitly covered by the Bugbot trust boundary and allowlist, and keep non-recoverable or out-of-policy states mapped to `skipped` or `escalate` instead of leaking provider-specific branches into the loop.
8. Add offline unit tests for the adapter and resume gate using recorded fixtures for Bugbot check-run payloads and review comment/thread samples, plus negative tests for unsupported config shapes and non-allowlisted signals.
9. Update the Helm pilot product configuration so the product can switch its external review provider from Haystack to Bugbot for a real smoke test, and record the Bugbot support/trust-boundary decision in the appropriate docs or ADR note.
10. Run the targeted API test suite in CI-friendly mode without any live Bugbot dependency, then confirm the Haystack path still works unchanged for migration.

## Files to Touch
- `apps/api/src/config/product-schema.ts` - accept `review.external.provider: bugbot` and validate `review.external.bugbot`.
- `apps/api/src/review/external/external-review-adapter.ts` - keep the shared ADR-036 contract surface aligned with the new provider.
- `apps/api/src/review/external/haystack-external-review-adapter.ts` - preserve the migration path and shared adapter boundaries.
- `apps/api/src/review/external/bugbot-external-review-adapter.ts` - new adapter for Bugbot parsing, normalization, and finding generation.
- `apps/api/src/review/run-external-review-if-configured.ts` - route provider selection through the generic boundary.
- `apps/api/src/review/code-review-loop.ts` - consume normalized external review outcomes without Bugbot-specific logic leaking in.
- `apps/api/src/review/deferred-resume.ts` - enforce the provider/PR/SHA/check-name/App-identity trust boundary for resume.
- `apps/api/src/review/webhooks/*.ts` - keep webhook handling generic and prevent generic status events from bypassing the Bugbot gate.
- `apps/api/test/fixtures/review/bugbot/*.json` - offline Bugbot check-run and review-thread fixtures.
- `apps/api/src/review/external/bugbot-external-review-adapter.test.ts` - adapter unit tests for normalization, ledger IDs, and config validation.
- `apps/api/src/review/deferred-resume.test.ts` - trust-boundary tests for matching and non-matching completion signals.
- `helm-knowledge/.helm/product.yaml` - pilot configuration switch from Haystack to Bugbot.
- `helm-knowledge/.helm/adrs/*` - ADR note documenting Bugbot support and the deferred-resume trust boundary.

## Test Strategy
- Unit test the Bugbot adapter with offline fixtures for check-runs, review comments, and thread payloads.
- Verify outcome normalization across success, neutral approval, blocking findings, pending analysis, unavailable/disabled states, and out-of-policy errors.
- Assert stable ledger-ID generation across duplicate deliveries and payload replays.
- Test product-schema validation for accepted Bugbot config shapes and rejected unsupported shapes.
- Exercise the resume path with positive and negative cases for provider, PR number, head SHA, allowlisted check name, and GitHub App identity.
- Confirm generic `status` events do not resume deferred work unless they satisfy the explicit Bugbot trust boundary.
- Run the relevant API unit test subset in CI without any live Bugbot service or network dependency.

## Risks / Open Questions
- The exact Bugbot check-name allowlist needs to match the real provider payloads that the adapter will see in production.
- The canonical GitHub App identity strings for Cursor/Bugbot must be confirmed before finalizing the trust boundary checks.
- It is still unclear whether all Bugbot outcomes will arrive as check-runs, review comments, or a mix of both, so the adapter should be tolerant of both offline fixture shapes.
- The existing review loop may already have a generic pending/resume abstraction; if so, the new code should extend it rather than duplicating a parallel path.
- The pilot product config needs to be updated in the same branch as the adapter work so the smoke test can exercise the new provider end to end.
