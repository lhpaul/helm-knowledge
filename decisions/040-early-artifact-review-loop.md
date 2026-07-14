# ADR-040: Early artifact review loop (spec / plan)

**Date:** 2026-07-12
**Status:** Accepted
**Supersedes:** — (amends ADR-024 auto-dispatch rule; reuses ADR-036 loop machinery)
**Related:** ADR-024 (spec/plan remediators), ADR-036 (PR review loop), ADR-037
(adjudicator), ADR-038 (sticky progress), LEA-194 pilot

---

## Context

Code PRs already run a bounded autonomous loop (ADR-036): internal reviewers →
optional adjudication → remediator → external adapter (Haystack) → stop rules →
human merge when clean.

Spec and plan PRs do **not**. After `spec-writer` / `plan-writer` opens a
knowledge PR, the item sits in `spec-draft` / `plan-draft` until a human reviews.
ADR-024 added `spec-remediator` / `plan-remediator`, but only when an operator
dispatches them with free-form `feedback`. That closes the "edit without
rewriting" gap; it does **not** close the "first review is always human" gap.

LEA-194's first spec PR showed the cost: Haystack surfaced real quality gaps
(negative invariants, unpinned paths) plus a Helm-workflow false positive
(`pair-spec-and-plan-files`). Without an early loop, the human is the first
filter and every iteration is operator-driven.

Product goal: humans should review artifact PRs when they are already **ok**
(or escalated), not act as the first reviewer.

---

## Decision

### 1. Bounded early review loop for `spec-draft` and `plan-draft`

After a successful writer publish (open PR + transition to draft stage), Helm
**auto-enters** an early review loop for that artifact. The loop mirrors
ADR-036 semantics with artifact-specific specialists:

```
1. Internal: spec-reviewer | plan-reviewer (single reviewer v1)
2. If gate-severity blockers → synthesize feedback → spec-remediator | plan-remediator
3. Repeat 1–2 until clean | max_cycles | no_progress
4. External: ExternalReviewAdapter (Haystack when configured)
5. If external blockers → remediator → back to 1
6. On clean: mark ready-for-human-review (label / notification); do NOT auto-merge
```

`clean` = zero **blocking** findings (ADR-036 §1). Advisories may remain.

Sticky progress (ADR-038) applies with **separate lanes** for internal vs
external identifiers.

### 2. New specialists: `spec-reviewer` and `plan-reviewer`

v1 uses **one internal reviewer per artifact kind** (not the code fan-out of
security/test/code). Rubrics differ from code review:

| Focus | Spec | Plan |
| ----- | ---- | ---- |
| Testable acceptance criteria | required | — |
| Positive + negative invariants | required | recommended |
| Exact paths / module targets | required | required |
| Out of scope / non-goals | required | required |
| Dependency / sequencing clarity | recommended | required |
| CLAUDE.md / ADR alignment | recommended | required |

Findings use the same `**SEVERITY** · title` dialect as code reviewers so
fingerprint + remediator machinery can be shared.

### 3. Amend ADR-024: AUTO remediation from findings

Keep operator-triggered `{ specialistId, feedback }` as today.

**Additionally**, the early loop may dispatch `spec-remediator` /
`plan-remediator` with **synthesized feedback** derived from normalized
blocking findings (same pattern as `code-remediator` consuming AUTO plans).
Human free-text feedback remains available for product decisions the loop
escalates.

Stage invariant unchanged: remediators only run while the item is in
`spec-draft` / `plan-draft` and an open artifact PR exists.

### 4. Knowledge-repo false-positive catalog

External adapters must support product (or Helm-global) false-positive rules
for knowledge PRs. First entry for Helm products:

- `pair-spec-and-plan-files` on branches `helm/spec/*` or `helm/plan/*` —
  **non-blocking**. Spec and plan ship as sequential PRs by design.

Additional catalog entries land as operations docs, not hard-coded one-offs.

### 5. Config surface

```yaml
review:
  loop:            # existing code loop (ADR-036+)
    …
  early_loop:      # new
    enabled: true  # default false until products opt in
    max_cycles: 4
    remediate_severity: medium_and_above
    stop_rule:
      no_progress_cycles: 2
```

When `early_loop.enabled` is false, behavior stays ADR-024 (writer → human /
manual remediator only).

`STAGE_TO_SPECIALIST` does **not** map draft stages to the loop. The writer
handlers chain into `runEarlyReviewLoop` (or the API schedules a follow-up
job) so dispatch of the loop is automatic after publish, not a second human
click.

### 6. Human gate preserved

The early loop **never** merges. On clean (or escalation), operators merge
via the existing `spec-ready` / `plan-ready` path. Success metric: human
touches are mostly approve/merge, not first-pass editing.

---

## Consequences

- Spec/plan quality gaps are fixed before human attention in the common case.
- ADR-024 remediators become dual-trigger (human feedback **or** loop AUTO).
- More agent cost/latency on every knowledge PR; bounded by `max_cycles` and
  stop rules.
- Haystack rules that assume monorepo "spec+plan same PR" must be catalogued
  or they will churn early loops (LEA-194 lesson).
- Products opt in via `early_loop.enabled` — no surprise cost for dogfood
  products that want to stay manual.

## Alternatives considered

| Alternative | Why rejected |
| ----------- | ------------ |
| Only improve Haystack + human | Still leaves human as first reviewer; no internal rubric. |
| Reuse code `reviewer-fanout` as-is | Wrong severity/rubric; security/test noise on markdown. |
| Auto-merge when clean | Too aggressive for product docs; human remains product gate. |
| New workflow stages (`spec-review`, …) | Extra state churn; draft + loop state in job is enough. |
| Template `/review-spec` only (no Helm API) | Breaks product dispatch model; Helm must own the loop. |

---

## Revisit when

- One reviewer per artifact is insufficient — add fan-out or adjudicator for
  early stages (ADR-037 pattern).
- Products want auto-merge of knowledge PRs after clean + CI green.
- External provider rules collide systematically with Helm branch conventions —
  expand false-positive catalog or provider profiles.
- Early loop `no_progress` rate rivals LEA-193 code loop — apply/extend sticky
  fingerprints and remediator checklist (ADR-038) with artifact-specific themes.
