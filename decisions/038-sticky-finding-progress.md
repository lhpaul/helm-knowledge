# ADR-038: Sticky finding progress for medium_and_above review loops

**Date:** 2026-07-12
**Status:** Accepted
**Supersedes:** — (amends ADR-036 §6 stop-rule signal; complements ADR-037)
**Related:** ADR-036 (PR Review Loop), ADR-037 (Review Adjudicator), LEA-193 pilot

---

## Context

With `review.loop.remediate_severity: medium_and_above`, the bounded review loop
treats MEDIUM findings as blockers. The LEA-193 pilot showed that this gate is
correct but unstable when:

1. **Remediator under-delivers** — AUTO plan items (especially sticky test gaps
   like RLS on summary/list) are left untouched while the agent pushes partial
   commits.
2. **Finding churn** — reviewers restate the same gap with new wording each
   cycle, so the raw blocker *count* stays flat and `no_progress` fires even
   when (or after) mechanical progress should have been measurable.
3. **Misleading escalation copy** — the `no_progress` message used
   `cyclesCompleted` instead of `no_progress_cycles`, which looked like a
   threshold bug.

ADR-036 already requires stable finding `id`s for *external* normalized
findings. Internal fan-out still counted only severity tallies.

---

## Decision

### 1. Remediator checklist contract

`code-remediator` prompts must require an Applied/Deferred checklist for every
AUTO item (or every gate-severity finding when no adjudication plan exists).
Partial commits that leave sticky AUTO items untouched without a Deferred note
are out of policy.

### 2. Sticky fingerprints for internal findings

Parse `**SEVERITY** · <title>` lines from reviewer `commentBody` values and
derive a stable fingerprint from:

- known theme ids (e.g. `tenant-isolation`, `empty-state`) when title text
  matches synonym patterns,
- file-path tokens when present,
- a short bag of significant title tokens (not the full free-form summary).

Do **not** hash free-form summary prose alone (same rule as ADR-036 external
ids).

### 3. Progress signal

`no_progress` streak resets when either:

- gate-severity blocker **count** improves against best-so-far, or
- **sticky remaining** (baseline fingerprints still present) improves against
  best-so-far.

Baseline sticky set is captured on the first cycle that enters remediation.

External `needs_fixes` continues to use `NormalizedFinding.id` as the sticky
key (already stable per ADR-036).

### 4. Escalation message

`no_progress` messages report the configured `no_progress_cycles` threshold and
separately note `cyclesCompleted`.

---

## Consequences

- `medium_and_above` loops can still escalate, but progress is less fooled by
  title churn.
- Remediator prompts push agents to close sticky AUTO items or explicitly defer.
- Theme synonym lists are heuristic and may need expansion per product; prefer
  path tokens when reviewers cite files.

## Alternatives considered

- **Count-only stop-rule (status quo):** rejected — LEA-193 churned for 7 cycles.
- **Require adjudicator-issued UUIDs in AUTO lines:** deferred — better long-term,
  higher prompt/parser coupling; fingerprints reuse existing review.md dialect.
- **Lower default severity back to critical_high:** rejected as the product
  remedy — severity is a product choice; the loop must be viable at MEDIUM.
