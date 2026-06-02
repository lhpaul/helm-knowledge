# ADR-027: Code-reviewer validates against the CLAUDE.md §4 contract

**Date:** 2026-06-02
**Status:** Accepted
**Related:** ADR-022 (kebab-case specialist IDs), ADR-025 (reviewer-remediation safety net), ADR-026 (product-readiness gate)

---

## Context

LEA-104 (the Arriendo Fácil schema baseline) shipped through Helm with 13+
contract-drift findings that the code-reviewer fan-out missed across six
rounds. Haystack caught them post-merge. The misses included column renames,
type mismatches, JSONB key types, and undocumented columns — all mechanical,
all detectable by comparing the diff to §4.2 of the target repo's `CLAUDE.md`.

Concrete examples (all real, all blocking, all §4-drift):

| Implementer wrote | Canonical §4.2 said |
| ----------------- | ------------------- |
| `utility_accounts.provider` | `utility_accounts.company` |
| `utility_accounts.latest_billed_amount` | `utility_accounts.last_amount_clp` |
| `utility_accounts.status` | `utility_accounts.last_status` |
| `properties.lease_start_date` / `lease_end_date` | `properties.started_at` / `ended_at` |
| `properties.vacated_at` (new column) | Vacancy = `status='vacated'` + `ended_at` |
| `payments.metadata.core_voucher_id` typed as `string` | Documented as `bigint`/number (example `99001`) |

Root cause: the code-reviewer prompt reads `CLAUDE.md` from the working
directory, but the instruction is generic ("check CLAUDE.md if present"). The
reviewer agent, lacking a directed comparison instruction, defaults to general
code-quality review.

LEA-105 (core mirror tables) builds on top of LEA-104, and LEA-109+ wires Better
Auth and endpoints. Every schema item that lands without this fix repeats the
five-batch remediation tax LEA-104 paid. Fixing it now is foundational.

## Decision

The code-reviewer prompt (`buildReviewerParams()`, kind=`code` branch) gains a
"Contract validation" subsection that:

- Activates when the diff touches schema / migration / entity-type files.
- Instructs the reviewer to open §4 of `CLAUDE.md` (or the matching section by
  heading — `## 4.`, `### 4.`, `## Data model`, `## Schema`, `## Domain model`)
  and compare every column / type / enum value / JSONB key / RLS clause to the
  diff.
- Emits a `HIGH` finding tagged `Contract drift §4` for every divergence, with a
  concrete fix proposal. The literal greppable prefix is
  `**HIGH** · Contract drift §4 · <table>.<column or convention>`.

HIGH severity is chosen because:

- It plugs into the existing post-ADR-025 `shouldRemediate()` flow, which already
  routes a HIGH from any reviewer to the code-remediator. No new wiring.
- It signals "blocking before merge" without elevating to CRITICAL (reserved for
  correctness blockers like failing tests).

This is a pure prompt change. No new `product.yaml` field, no structured schema
format, no changes to `fetch-product-context` or the remediation-gate wiring.
`REVIEW_MD_FORMAT` documents `Contract drift §4` as a recognised category so
reviewer agents emit it consistently; the parser regex is unchanged.

### Negative space — what the reviewer must NOT do

A `Contract drift §4` finding is **findings-only**: the code-reviewer must NOT
edit schema, migration, or entity-type files to apply the fix itself, however
mechanical the rename looks. The single-pusher mechanical-fix permission
(ADR-018) still applies to genuine low-risk edits in **non-schema** files
(typos, comments, lint nits), but it explicitly does not extend to contract
drift. Two reasons:

- **The remediation path is the point.** Routing drift to HIGH →
  `shouldRemediate()` → code-remediator is the entire design. If the reviewer
  can auto-apply and push a rename, it short-circuits that path and the HIGH
  finding never reaches the remediator/human — collapsing the safety net this
  ADR builds.
- **Migrations are immutable contracts post-apply.** Editing an
  already-committed migration file to rename a column is itself a contract
  violation — the correct fix is a new forward migration, which the reviewer is
  not positioned to author. Auto-fixing drift in a migration creates a worse bug
  than the drift it "fixes".

## Alternatives considered

- **Per-product `canonical_contracts: [paths]` in `product.yaml`.** Rejected for
  now: assumes products have multiple canonical docs, which none currently do.
  Reusing the existing `CLAUDE.md` load is cheaper. Reopen if evidence appears.
- **Structured `schema.yaml` per product.** Rejected for cost: requires a
  refactor of `CLAUDE.md` per product, a new parser, and a new contract format.
  A Markdown contract is good enough for the current pilot.
- **Apply the same validation to spec-writer and plan-writer.** Out of scope for
  this ADR. Evidence-driven — open a follow-up only when drift in spec/plan is
  observed.

## Consequences

- The code-reviewer runs slightly longer (loads + parses §4), but the token cost
  is marginal because `CLAUDE.md` is already in the working directory.
- The code-remediator picks up the new findings via existing routing — no
  additional surface to maintain.
- Products without a §4 / data-model section (e.g. the playground) are
  unaffected — the validation skips gracefully.
- Forward-looking only. PRs already in `code-review` state at merge time are not
  retroactively re-reviewed.

## Tests

- Unit tests in `reviewer-fanout.test.ts` cover: prompt composition (block
  present for kind=`code`, absent for `security`/`test`), the LEA-104 example
  diffs (5 HIGH `Contract drift §4` findings via the parser), graceful skip for a
  missing §4 section, and a no-op for a non-schema diff.
- `REVIEW_MD_FORMAT` documents the `Contract drift §4` category.

## Revisit when

- A real product PR after this lands has §4-drift that the reviewer still misses
  (signals the prompt needs sharpening, not the design).
- A product needs multiple canonical contract docs (open the
  `canonical_contracts` `product.yaml` field then).
- A product wants stricter severity (`CRITICAL`) — open a per-product override
  field then.

## References

- helm PR: lhpaul/helm#40 — `feat(code-reviewer): validate diff against CLAUDE.md §4 contract (HIGH severity)`
- ADR-025 — remediation covers all reviewers (the `shouldRemediate()` flow this
  reuses).
- LEA-104 — the AF schema baseline whose five-batch remediation tax motivated
  this change.
