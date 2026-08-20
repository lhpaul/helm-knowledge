# ADR-043: Sticky fidelity churn controls — bounded catalogue suppression, sticky themes, operator accept

**Date:** 2026-08-20
**Status:** Proposed
**Supersedes:** — (amends ADR-041 §4 "no gate suppression on code PRs"; amends
ADR-038 §2 fingerprint composition)
**Related:** ADR-025 (Remediation Covers All Reviewers), ADR-036 (PR Review
Loop), ADR-037 (Review Adjudicator), ADR-038 (Sticky Finding Progress),
ADR-040 (Early-Artifact Review Loop), ADR-041 (Reviewer Disagreement Policy),
ADR-042 (Cumulative Review-Loop Budget), lhpaul/helm#107,
LEA-246 / lhpaul/leasity-tenants#16

---

## Context

LEA-246 produced the first churn loop that no existing control could stop
**cheaply**. On `lhpaul/leasity-tenants#16`:

- `test-reviewer` held a MEDIUM asking for real Expo Router runtime coverage
  and a Maestro end-to-end flow.
- `code-remediator` responded each cycle by rewriting the Vitest unit smoke that
  already satisfied the item's closed AC checklist.
- `code-reviewer` and `security-reviewer` were `APPROVED` throughout.
- The loop ran to `no_progress` after 5 cycles with `bestBlockerCount: 1`, then
  escalated.

The escalation was correct but expensive: five remediator passes bought nothing,
and the human decision at the end ("the unit smoke is the agreed coverage") was
available on cycle 1. Four separate gaps kept the loop from reaching it sooner.

**1. The catalogue never reached the code-review gate.** ADR-041 §2 injects
`false-positives.md` into the adjudicator and remediator *prompts* on code PRs,
but ADR-041 §4 deliberately declined to let a catalogue match **demote** an
internal reviewer finding before `shouldRemediate()` in `code-review` mode. The
stated reason was that catalogue matching is heuristic token overlap and
silently clearing a genuine security HIGH is worse than one extra deferral
cycle. That reasoning holds for HIGH. It does not hold for a MEDIUM coverage
opinion, which is precisely the severity that drove LEA-246 — and the catalogue
format already advertises `**Applies to:** code-review` as a supported scope,
so the documented contract and the implemented behavior disagree.

**2. Reworded fidelity asks looked like new findings.** ADR-038 §2 composes a
fingerprint from theme ids **plus** path tokens **plus** a bag of significant
title tokens. A cycle-1 title naming Expo Router and a cycle-2 title naming
Maestro share a subject but no tokens, so they fingerprint differently. Sticky
remaining "improved", `nextNoProgressStreak` reset, and the loop bought another
cycle for a finding that had not moved.

**3. The remediator could not see what was sticky.** It received the current
cycle's review bodies and (optionally) the adjudicator's unified plan, but
nothing that said "this finding has been open since cycle 1 and your last two
attempts did not close it." Rewriting the unit smoke read to the agent as
progress every single time.

**4. A human could not dismiss one finding.** ADR-037 gives a maintainer a
`<!-- helm:product-decision -->` comment to settle an adjudicator **conflict**.
LEA-246 had no conflict — one reviewer, one finding, nobody opposing it. The
operator's only levers were to wait for the stop rule, edit `false-positives.md`
and wait for a re-dispatch, or intervene in the repo by hand. The `Accepted`
value in `AdvisoryDisposition` (ADR-036 §5) already names the missing outcome;
v1 simply never sets it.

---

## Decision

### 1. Catalogued suppression reaches `code-review`, capped at MEDIUM

`suppressFalsePositiveReviewerResults` and the reviewer comment transform run in
`code-review` mode, not only in `early-artifact` mode. A catalogued match
rewrites the finding line to `**INFO** · Catalogued false positive: <summary>`,
decrements the matched severity bucket, increments `info`, and re-derives the
review status from the recounted findings — the same transform ADR-040 already
runs on draft artifacts.

**On code PRs the transform applies only to findings at MEDIUM and below.**
CRITICAL and HIGH reviewer findings are never demoted by a catalogue match on a
code PR; they keep the ADR-041 §3 treatment (deferred in the unified plan,
cited by title, never reverted). In `early-artifact` mode the transform stays
uncapped, because a draft spec or plan carries no shipping code to protect.

This is the narrowest amendment that answers ADR-041 §4. That section's
rejection rationale was explicitly about "silently clearing a real security
HIGH"; the cap preserves it exactly while unblocking the severity band where
churn actually happens. The asymmetry with
`suppressFalsePositiveExternalFindings` — which already suppresses external
blockers at any severity on code PRs — is intentional: external findings arrive
with adapter-assigned stable ids and structured fields, while internal findings
are matched heuristically against free reviewer prose.

An operator who wants a catalogued CRITICAL/HIGH cleared on a code PR uses
§4 (accept finding), which is authenticated and audited, rather than a
heuristic pattern match.

### 2. Sticky theme groups key the fingerprint alone

ADR-038 §2 stands, with one addition. A small set of **sticky theme groups**
describes subjects where reviewers habitually re-word the same ask. When a
finding title matches any member pattern of a group, its fingerprint is the
**group id alone** — no path tokens, no title tokens.

The first group is `test-fidelity`, with members:

| Member id | Matches, roughly |
| --------- | ---------------- |
| `e2e-coverage` | end-to-end / e2e coverage asks |
| `expo-router` | Expo Router runtime rendering asks |
| `maestro` | Maestro flow asks |
| `unit-smoke` | unit-smoke-is-not-enough asks |

Consequence, stated plainly: **every test-fidelity finding on a PR collapses
onto one fingerprint.** That deliberately over-merges. Under ADR-038 §2's own
rule — "under-counting sticky remaining is safer than false progress" — merging
is the safe direction: it can only make `no_progress` fire *earlier*, never
later, and firing earlier is the entire point. Ordinary (non-group) themes are
unchanged and still compose with paths and tokens.

Groups are Helm built-ins, not product configuration. A product that needs a
different group proposes it as a code change with the churn evidence attached,
the same bar an ADR entry gets.

### 3. Unresolved sticky findings are injected into both prompts

A finding observed at gate severity in **two or more cycles of the same lane**
is *unresolved sticky*. Each remediation cycle renders the unresolved sticky set
into the `code-remediator` and `review-adjudicator` prompts as a data-only
block, with the same JSON-inside-opaque-delimiters treatment ADR-041 §2 gives
catalogue entries: fingerprint, last-seen title, severity, and the number of
cycles it has survived.

The attached policy is:

- A sticky finding that a prior cycle already claimed as **Applied** was not
  actually applied. Do not re-apply the same shape of change.
- Rewriting or expanding an artifact the finding says is *the wrong kind of
  artifact* is not a fix. Naming LEA-246 directly: when the sticky ask is for
  end-to-end coverage, another unit-test rewrite is **not** a valid `Applied`
  line — it belongs under `Deferred` with the reason.
- If the finding cannot be closed by a mechanical change, defer it explicitly
  and say why, so the stop rule and the human both get a real signal.

Sticky state is per-lane (ADR-038 §3): internal fan-out fingerprints and
external `NormalizedFinding.id`s are counted and rendered separately and never
share a baseline.

### 4. Operator `accept-finding` marker

A maintainer with write access can accept a single non-conflict finding by
commenting on the impl PR:

```markdown
<!-- helm:accept-finding -->
**Finding title:** Unit smoke does not exercise Expo Router navigation
**Severity:** MEDIUM
**Rationale:** AC #4 closed on the Vitest smoke; Maestro is tracked separately.
```

Semantics:

- **Authority.** Same trust boundary as ADR-037 product decisions: GitHub write
  access on the code repo, an open impl PR, and a `helm/impl/*` head ref. An
  unauthorized or unmatched comment is ignored, not errored.
- **Severity ceiling.** Only MEDIUM and below can be accepted. CRITICAL and HIGH
  stay on the adjudication/escalation path, where a human decision is recorded
  against a named conflict rather than a single reviewer's title.
- **Identity.** The accepted finding is keyed by the ADR-038 fingerprint of its
  title, so an accept covers the reworded restatements of the same ask — for a
  sticky theme group that is the whole group, which is the intended reach.
- **Effect.** Matching findings are demoted to `**INFO** · Accepted by
  operator: <summary>` before `shouldRemediate()`, exactly like a catalogue
  match, and matching external blockers are moved to advisories with
  disposition `Accepted` (ADR-036 §5) rather than `Deferred`. The loop then
  re-dispatches `reviewer-fanout` at the current head, the same way a recorded
  product decision does.
- **Durability.** Accepted findings are stored on the item
  (`acceptedFindings[]`, mirroring `resolvedProductDecisions[]`) with the
  author, PR, and timestamp, and are re-read per cycle so an accept posted
  mid-run takes effect on the next pass.
- **Not a catalogue entry.** An accept is scoped to one item. A pattern worth
  suppressing product-wide still belongs in `false-positives.md`, where it gets
  review.

### 5. Test-reviewer contract: cite the AC, cap the fidelity ask

The `test-reviewer` prompt requires that every finding either cite the
acceptance criterion it maps to, or be filed at **LOW or INFO**. Asking for a
higher-fidelity test artifact than the AC requires — a real-device run, an
end-to-end harness, a framework runtime — is a suggestion, not a blocker, and is
capped at LOW unless an AC names it.

This is the cheapest of the five controls and the only one that prevents the
finding from entering the gate at all. The other four bound the cost when it
does.

---

## Consequences

- **The LEA-246 shape terminates in one or two cycles instead of five.** A
  catalogued match clears it at the gate (§1); an un-catalogued restatement
  collapses onto one sticky fingerprint (§2) so `no_progress` fires on schedule;
  the remediator is told not to re-rewrite the unit smoke (§3); and an operator
  who is watching can end it immediately (§4).
- **`false-positives.md` gets more load-bearing, in a bounded band.** A wrong
  entry can now clear a MEDIUM on a code PR without a human seeing it. The
  severity cap is what keeps that from being a security problem; the entry-care
  bar from ADR-041 §Consequences still applies.
- **Sticky counts on test-fidelity findings become coarse.** Two genuinely
  distinct coverage gaps report as one sticky item. Accepted per §2.
- **A new authenticated write path into the loop.** §4 adds a second marker a
  maintainer can post on a PR. It carries the same authorization checks as
  ADR-037's, and its blast radius is one item and one fingerprint.
- **Prompt cost grows** by the unresolved-sticky block on cycles that have one.
  It is bounded by the gate-severity finding count and empty on cycle 1.
- **The `Accepted` disposition stops being dead code**, which makes ADR-036 §5's
  four-value vocabulary honest.

---

## Alternatives considered

| Alternative | Why rejected |
| ----------- | ------------- |
| Full catalogue suppression parity on code PRs (no severity cap) | Reopens exactly the failure ADR-041 §4 refused: a heuristic token match clearing a real security HIGH with no human in the loop |
| Leave ADR-041 §4 intact and rely on the stop rule alone | This *is* the status quo; LEA-246 shows it costs five remediator passes to reach a decision that was available on cycle 1 |
| Give each theme member its own fingerprint and require N members to co-occur | Needs cross-cycle member bookkeeping to detect a rewrite that swaps members; the group id gets the same signal with no state |
| Let a product define sticky theme groups in `product.yaml` | A group id silently merges distinct findings — that deserves code review with evidence, not per-product config |
| Extend `<!-- helm:product-decision -->` to cover single findings | Its contract is a *choice between declared options on a recorded conflict*; a single-finding accept has neither, and overloading it would weaken the adjudication match check |
| Let the operator accept any severity | An accepted HIGH leaves no adjudication record naming what was traded away; the conflict path already exists for that |
| Auto-accept a sticky MEDIUM after N cycles | Removes the human from a decision about shipping quality; the stop-rule escalation already asks the right person |

---

## Revisit when

- A second sticky theme group is proposed — if products keep needing new groups,
  reconsider adjudicator-issued stable finding ids (ADR-038's deferred
  alternative) instead of growing a built-in synonym list.
- Accepted findings accumulate on items in a pattern that repeats across items —
  that is the signal to promote them into `false-positives.md`, and possibly to
  automate the promotion.
- The MEDIUM cap in §1 proves too tight (catalogued HIGHs churning on code PRs)
  or too loose (a catalogued MEDIUM clearing something that mattered) — the cap
  is the tuning knob, and either direction is a small change here.
- External review cost pressure changes the picture — tracked separately as
  lhpaul/helm#108 (external on-demand / CodeRabbit cost), which is out of scope
  for this decision.
