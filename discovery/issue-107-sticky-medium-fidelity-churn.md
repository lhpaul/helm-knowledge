# Discovery: Review loop churns on sticky MEDIUM test-fidelity findings

- **Item**: [lhpaul/helm#107](https://github.com/lhpaul/helm/issues/107)
- **Date**: 2026-08-20
- **Owner**: Claude Code (agent), reviewed by LH
- **Status**: ready-for-spec

## Problem

When a single reviewer holds one MEDIUM finding that the remediator cannot
close, Helm's code-review loop has no cheap way to stop. It keeps spending
remediator passes on a finding whose real resolution is a human sentence, and
the only terminal state available is the `no_progress` escalation five cycles
later.

In product terms: the operator pays full remediation cost to reach a decision
that was available on cycle 1, and the item sits in `remediation` while that
happens.

## Evidence

Arriendo Fácil [LEA-246](https://linear.app/lh-paul/issue/LEA-246) /
[lhpaul/leasity-tenants#16](https://github.com/lhpaul/leasity-tenants/pull/16),
2026-08-20:

- `test-reviewer` filed a MEDIUM asking for real Expo Router runtime coverage
  and a Maestro end-to-end flow.
- `code-remediator` answered every cycle by rewriting the Vitest unit smoke that
  already satisfied the item's **closed** AC checklist.
- `code-reviewer` and `security-reviewer` were `APPROVED` for the whole run.
- The loop escalated `no_progress` after 5 cycles with `bestBlockerCount: 1`.
- Operator decision at the end: the unit smoke *is* the agreed coverage for this
  item; the Maestro flow is separate work.

Four gaps let it run that long:

1. `suppressFalsePositiveReviewerResults` only runs in `early-artifact` mode, so
   the product catalogue could not clear the finding at the code-review gate —
   even though `false-positives.md` documents `**Applies to:** code-review` as a
   supported scope.
2. Reworded asks (Expo Router → Maestro) fingerprint differently under ADR-038,
   so "sticky remaining" improved and the `no_progress` streak reset.
3. The remediator was never told which findings were sticky, so rewriting the
   unit smoke read as progress every cycle.
4. A human watching the PR had no way to dismiss one non-conflict finding.
   ADR-037's `<!-- helm:product-decision -->` marker requires an adjudicator
   conflict with declared options; LEA-246 had one reviewer and no opposition.

## Current workaround

Shipped for Arriendo Fácil as interim mitigation, and explicitly **not** a
replacement for the Helm fix:

- a `false-positives.md` entry for the unit-smoke-vs-Maestro pattern, and
- `product.yaml` remediator `extra_hints` steering away from the rewrite.

Both are soft: the catalogue entry does not reach the code-review gate at all,
and hints are advisory prose the agent may ignore. The operator's remaining
options are to wait out the stop rule, or intervene in the repo by hand.

## Smallest valuable version

The A-band of #107 — three changes that need no new operator protocol:

1. Let the catalogue suppress matched findings at the `code-review` gate.
2. Make reworded test-fidelity asks share one sticky fingerprint.
3. Show the remediator (and adjudicator) what is still sticky, and forbid the
   "rewrite a unit test to answer an end-to-end ask" move.

That alone converts LEA-246 from five wasted cycles into an escalation at cycle
2, or no escalation at all when the pattern is catalogued.

The B-band (operator accept-finding marker) is what removes the wait entirely,
and is worth the extra protocol surface because the human is usually already
watching the PR when this happens.

## Scope boundaries

Out of scope for this item:

- **lhpaul/helm#108** — external on-demand review / CodeRabbit cost. Related
  cost pressure on the same loop, tracked separately.
- Auto-accepting a sticky finding after N cycles. Removes the human from a
  shipping-quality decision; the escalation already asks the right person.
- Per-product configuration of sticky theme groups. A group id merges distinct
  findings, so it belongs in code review with evidence.
- Rewriting the reviewer fan-out, adjudication, or stop-rule machinery. All four
  changes attach to seams that already exist.

## Spec handoff notes

- **ADR-041 §4 says "No gate suppression on code PRs" and must be amended, not
  ignored.** [ADR-043](../decisions/043-sticky-fidelity-churn-controls.md) does
  that, capping code-PR suppression of internal reviewer findings at MEDIUM so
  ADR-041's actual fear — a heuristic match clearing a real security HIGH —
  stays addressed.
- The `Accepted` value in `AdvisoryDisposition` (ADR-036 §5) already exists and
  is never set. The accept path should populate it rather than inventing a
  fifth disposition.
- The operator marker should mirror ADR-037's product-decision trust boundary
  (GitHub write access, open impl PR, `helm/impl/*` head ref) rather than
  defining a second authorization model.
- Sticky state is per-lane (ADR-038 §3). Internal fingerprints and external
  `NormalizedFinding.id`s must not share a baseline anywhere in this work.
