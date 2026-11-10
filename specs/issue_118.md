# issue_118 — Specification

## Context
Specialists running on the `claude_code` runtime (notably spec-writer and plan-writer) are spawned with the runtime default timeout of 5 minutes. Long specs and plans get killed mid-run with a `[timeout]` result, interrupting the specialist before it finishes. Some specialists (implementer, remediators, reviewers) hardcode their own timeout constants, and none of them can be tuned per product.

## Acceptance Criteria
- `product.yaml` accepts an optional `timeout_sec` on each entry under `specialists:` (positive integer seconds, max 7200). Invalid values (zero, negative, non-integer, above the cap, strings) fail schema validation.
- When set, Helm passes it as the per-spawn timeout for that specialist, overriding the runtime default and the specialist's built-in constant. This covers spec-writer and plan-writer and the same mechanism for implementer, the three remediators, the three reviewers and review-adjudicator.
- When not set, behaviour is unchanged: writers use the runtime default (5 min `claude_code`, 10 min `codex`); other specialists keep their existing constants. These defaults are documented in `docs/product-config.md`.
- A spec or plan run can therefore exceed 5 minutes when the product configures a larger `timeout_sec`.

## Technical Notes
- Per-specialist only. All specialists of a product share one runtime (ADR-021), so a separate per-runtime setting would be redundant.
- Implemented in the `SpawnParams` builders via a small `resolveSpecialistTimeoutMs(product, id, fallbackMs?)` helper; runtimes already honour `SpawnParams.timeoutMs`.
- Backwards compatible: the field is optional and the schema stays `.strict()`.
