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

**Persistence:** the checklist is not a separate DB row. It is durable through
the same channels already used for remediator accountability:

- remediator run artifacts under the review workspace, and
- the remediator PR comment body (Applied/Deferred lines visible to humans and
  the next cycle's prompt context).

### 2. Sticky fingerprints for internal findings

Parse `**SEVERITY** · <title>` lines from reviewer `commentBody` values and
derive a stable fingerprint from:

- known theme ids (e.g. `tenant-isolation`, `empty-state`) when title text
  matches synonym patterns,
- file-path tokens when present,
- a short bag of significant title tokens (not the full free-form summary).

Do **not** hash free-form summary prose alone (same rule as ADR-036 external
ids).

**Canonicalization / collisions:** fingerprints are deterministic strings, not
cryptographic hashes. Distinct findings that share a theme and overlapping
tokens may collide onto one fingerprint — that is acceptable for stop-rule
progress (under-counting sticky remaining is safer than false progress). If a
product sees systematic false merges, expand theme patterns or path weight
rather than switching to free-form title hashes.

### 3. Separate sticky lanes (internal vs external)

Internal title fingerprints and external `NormalizedFinding.id` values live in
**different identifier spaces**. The loop keeps two sticky lanes:

- **internal** — fingerprints from fan-out `commentBody` titles
- **external** — Haystack (or other adapter) `finding.id`s

They must never share one baseline. Crossing them can produce false
"sticky cleared" progress when identifier sets are disjoint.

Shared across lanes: `noProgressStreak` and `bestBlockerCount` (count still
signals real progress regardless of source).

### 4. Progress signal

`no_progress` streak resets when either:

- gate-severity blocker **count** improves against best-so-far, or
- **sticky remaining** (baseline fingerprints still present) improves against
  best-so-far **within the lane that produced the blockers**.

Baseline sticky set for a lane is captured on the first cycle that enters
remediation for that lane.

External `needs_fixes` continues to use `NormalizedFinding.id` as the sticky
key (already stable per ADR-036).

### 5. Escalation message

`no_progress` messages report the configured `no_progress_cycles` threshold and
separately note `cyclesCompleted`.

---

## Consequences

- `medium_and_above` loops can still escalate, but progress is less fooled by
  title churn or by mixing internal/external id spaces.
- Remediator prompts push agents to close sticky AUTO items or explicitly defer;
  checklist evidence lives in artifacts + PR comments.
- Theme synonym lists are heuristic and may need expansion per product; prefer
  path tokens when reviewers cite files.
- Fingerprint collisions under-count sticky remaining rather than inventing
  progress.

## Alternatives considered

- **Count-only stop-rule (status quo):** rejected — LEA-193 churned for 7 cycles.
- **Require adjudicator-issued UUIDs in AUTO lines:** deferred — better long-term,
  higher prompt/parser coupling; fingerprints reuse existing review.md dialect.
- **Lower default severity back to critical_high:** rejected as the product
  remedy — severity is a product choice; the loop must be viable at MEDIUM.
- **Single shared sticky baseline for internal + external:** rejected — false
  progress when id spaces are disjoint (Haystack finding ids vs title themes).

---

## Revisit when

- Theme synonym lists drift per product and collisions become noisy — consider
  adjudicator-issued stable ids for AUTO items (deferred alternative above).
- Multiple external adapters run in one loop and need per-adapter sticky lanes
  beyond the current internal/external split.
- Checklist persistence needs machine-readable parse for stop-rule input (today
  it is human/prompt accountability only).
- Product data shows sticky remaining under-counting real unfinished work —
  tighten fingerprint cardinality (more path weight, fewer themes).
