# issue_82 — Specification

## Context
Helm currently hard-wires the external code-review integration to Haystack. That is no longer sustainable because Haystack is being retired, and the review loop needs a first-class Bugbot provider that can be selected through product configuration without changing the generic review workflow.

This item introduces Bugbot as a supported external review adapter for the code-review loop. The goal is to keep provider-specific behavior isolated inside the adapter layer while preserving the existing loop structure, deferred resume flow, and current-head validation model. Haystack must remain available for migration until products have switched.

## Acceptance Criteria
- `product-schema` accepts `review.external.provider: bugbot` and continues to accept `review.external.provider: haystack`.
- `review.external.bugbot` supports provider-specific configuration knobs required by the adapter and validation rejects unsupported shapes.
- A `BugbotExternalReviewAdapter` exists and implements the ADR-036 `ExternalReviewAdapter` contract.
- Bugbot outcomes are normalized to the existing review states:
  - `clean` for success and any approved neutral-policy outcome.
  - `needs_fixes` for failed checks and blocking review findings.
  - `deferred` or `analysis_pending` while analysis is still in progress when defer-on-pending is enabled.
  - `skipped` when Bugbot is disabled or unavailable under documented policy.
  - `escalate` for non-recoverable or out-of-policy states.
- The adapter maps Bugbot check-runs and review comments/threads into findings with stable ledger IDs.
- `runExternalReviewIfConfigured` and the code-review loop treat Bugbot as just another external provider at the generic boundary.
- No Bugbot-specific details leak into the loop, ledger, or tracker layers outside the adapter.
- Deferred pending work resumes only on a matching provider, PR number, exact head SHA, and allowlisted Bugbot completion signal.
- Generic `status` events do not resume deferred work unless they match the explicit Bugbot trust boundary.
- Unit tests cover the adapter with offline fixtures, including check-run payloads and review comment/thread samples.
- CI does not require a live Bugbot dependency to validate the adapter behavior.
- The Helm pilot configuration can switch the product review provider from Haystack to Bugbot.
- The spec or ADR notes record Bugbot as a supported provider and document the trust-boundary choice.

## Technical Notes
- Keep this as an adapter-only migration. Do not rewrite the broader review loop or replace the internal reviewer fan-out flow in the same change.
- Preserve Haystack support during migration so products can move incrementally.
- The Bugbot adapter should own all Bugbot-specific parsing, normalization, and check-name mapping.
- The deferred-resume path should require an explicit allowlist of Bugbot check names plus the Cursor/Bugbot GitHub App identity; avoid accepting generic check `status` traffic.
- Use current-head evidence when deciding whether to resume, fail, or keep a review pending.
- Prefer stable, deterministic identifiers for normalized findings so repeated deliveries do not duplicate ledger entries.
- Pilot configuration should live in the Helm product config and be documented clearly enough for a real PR smoke test.
- Documentation should cover Bugbot enablement, the trigger phrase used to request a review, and the exact check-name allowlist expected by the adapter.
