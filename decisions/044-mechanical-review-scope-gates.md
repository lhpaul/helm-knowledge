# ADR-044: Mechanical review-scope gates (computed §4 skip + subsequent-pass freeze)

**Date:** 2026-08-21
**Status:** Accepted
**Amends:** ADR-027 (contract-drift validation), ADR-037 (adjudicator), ADR-043 (sticky fidelity)
**Related:** LEA-110 / lhpaul/leasity-tenants#18

---

## Context

LEA-110's impl PR never touched schema or migrations. The code-reviewer prompt
already said "only validate §4 if the diff includes schema files." The agent
still opened `CLAUDE.md` §4 and emitted `**HIGH** · Contract drift §4` on
`core_common_expenses_snapshots.pending_amount_clp`. That HIGH restarted
remediation after a clean triple APPROVED and escalated the loop
(`no_progress`).

The same PR also showed a second failure mode: each fan-out invented a **new**
MEDIUM quality theme (logout variants, storage adapter, OTP swallow) instead of
re-checking the previous blocker. AF's `remediate_severity: medium_and_above`
then remediates every new nit. Extra hints ("do not reopen", "do not invent
nits") are prose on a fresh agent instance; they lost.

ADR-043's catalogue can demote MEDIUM and below. It **cannot** demote a HIGH
on a code PR. A heuristic catalogue match must not clear a real security HIGH.
A *computed* "this PR has zero schema files" fact is not a heuristic — it can
safely suppress `Contract drift §4` at HIGH.

## Decision

### 1. Orchestrator computes the schema-file list

Before spawning reviewers, fan-out lists the PR changed paths (GitHub API) and
filters them with a narrow glob (`/schema/`, `/migration(s)/`, `*.sql`).

- **Empty list** — the code-reviewer prompt gets a hard skip: "Schema files in
  this diff: none. Do not emit Contract drift §4."
- **Non-empty** — the prompt lists those paths; §4 validation is allowed only
  against them.
- **Uncomputable** — keep ADR-027's prose gate (no silent skip).

### 2. Mechanical HIGH suppress for off-diff contract drift

When the computed list is empty, any `Contract drift §4` finding in the review
body is rewritten to `**INFO** · Off-diff contract drift (suppressed):` **before**
the comment is posted and before `shouldRemediate()`. This is not a catalogue
match and is not capped at MEDIUM.

### 3. Subsequent-pass freeze

A pass is *subsequent* when `cyclesTotal > 0` or `cycle > 1` (covers a new
dispatch after a previous review of the same item).

On a subsequent pass:

- Code reviewer: new HIGH/MEDIUM must be a regression of the last remediator
  commit or a previously open blocker. A brand-new quality theme is LOW/INFO.
- Adjudicator: a newly invented MEDIUM/HIGH that is neither a regression nor
  an open blocker is **DEFERRED**, not AUTO_REMEDIATE.

The first pass of a new item is unchanged: full review, AUTO on aligned in-diff
findings.

## Consequences

- Auth/session PRs like LEA-110 cannot escalate on pre-existing §4 drift.
- Reviewers still catch real schema PRs (LEA-104 shape) because those diffs
  include `/schema/` or `/migrations/` files.
- Catalogue entries remain useful for restated MEDIUM fidelity asks; they are
  complementary, not a substitute for the computed skip.

## Tests

- `contract-validation-scope.test.ts` — globs, PR URL parse, prompt blocks,
  HIGH demotion when the list is empty.
- `reviewer-fanout.test.ts` — computed skip / listed files / subsequent-pass
  freeze injected into the code-reviewer prompt only.
- `review-adjudicator.test.ts` — subsequent-pass DEFER instruction.

## References

- LEA-110 operator decision 2026-08-21 (Option A: merge; schema follow-up LEA-275)
- ADR-027 — why §4 HIGH exists
- ADR-043 — why catalogue cannot demote HIGH on code PRs
