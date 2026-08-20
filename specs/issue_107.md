# issue_107 — Specification

## Context

Helm's bounded code-review loop (ADR-036) can spend its whole remediation budget
on a single MEDIUM finding that no mechanical change will close. On Arriendo
Fácil LEA-246 / `lhpaul/leasity-tenants#16` a `test-reviewer` MEDIUM asked for
Expo Router runtime coverage and a Maestro end-to-end flow while the
`code-remediator` rewrote, five times, the Vitest unit smoke that already
satisfied the item's closed AC checklist. Code and security review were
`APPROVED` throughout. The loop terminated correctly — `no_progress` after 5
cycles at `bestBlockerCount: 1` — but only after burning the budget to reach a
decision a human could have made on cycle 1.

Discovery for this item is
[`discovery/issue-107-sticky-medium-fidelity-churn.md`](../discovery/issue-107-sticky-medium-fidelity-churn.md);
the decision record is
[ADR-043](../decisions/043-sticky-fidelity-churn-controls.md).

This item makes the durable Helm fix. The Arriendo Fácil interim mitigation
(a `false-positives.md` entry plus remediator `extra_hints`) already shipped and
does not replace it — the catalogue entry cannot reach the code-review gate at
all today, and hints are advisory prose.

Five controls are in scope, ranked. The first three bound the cost of the churn;
the fourth lets a watching human end it immediately; the fifth stops the finding
from entering the gate in the first place.

**Load-bearing constraint:** ADR-041 §4 currently states "No gate suppression on
code PRs". Control A1 amends it. ADR-043 §1 keeps ADR-041's rationale intact by
capping code-PR suppression of internal reviewer findings at MEDIUM — CRITICAL
and HIGH are never demoted by a heuristic catalogue match on a code PR.

## Acceptance Criteria

### A1 — Catalogued suppression at the code-review gate

- The reviewer-comment transform and `suppressFalsePositiveReviewerResults` run
  in `code-review` mode, not only in `early-artifact` mode.
- A matched finding is rewritten to `**INFO** · Catalogued false positive:
  <summary>`, its severity bucket is decremented, `info` is incremented, and the
  review status is re-derived from the recounted findings — the same transform
  ADR-040 already applies to draft artifacts.
- **On code PRs only findings at MEDIUM and below are transformed.** A
  catalogued CRITICAL or HIGH reviewer finding is left untouched and keeps its
  ADR-041 §3 treatment.
- In `early-artifact` mode the transform stays uncapped (behavior unchanged).
- When nothing matches, the reviewer-authored status is preserved verbatim — a
  `CHANGES_REQUESTED` review is never flipped to `APPROVED` as a side effect.
- Suppression happens before `shouldRemediate()` and before the blocker count
  and sticky fingerprints are computed, so a fully suppressed cycle neither
  dispatches the remediator nor consumes loop budget.

### A2 — Sticky theme groups for test fidelity

- A sticky theme group `test-fidelity` exists with members `e2e-coverage`,
  `expo-router`, `maestro`, and `unit-smoke`.
- When a finding title matches any member pattern, its fingerprint is the group
  id **alone** — no file paths and no title tokens are appended.
- Titles that name different members across cycles (Expo Router in cycle 1,
  Maestro in cycle 2) therefore produce one identical fingerprint, so sticky
  remaining does not "improve" and the `no_progress` streak does not reset.
- Non-group themes keep ADR-038 §2 composition (theme ids + paths + tokens)
  unchanged, and titles matching no group are unaffected.
- Member patterns do not match on bare generic words: `expo-router` requires the
  router, not any mention of Expo; `unit-smoke` requires the smoke-test phrasing,
  not the word "unit".

### A3 — Unresolved sticky findings injected into prompts

- A finding seen at gate severity in **two or more cycles of the same lane** is
  unresolved sticky. Cycle 1 has none by definition.
- Each remediation cycle renders the unresolved sticky set into the
  `code-remediator` and `review-adjudicator` prompts as a data-only block:
  fingerprint, last-seen title, severity, and cycles-seen count.
- The block uses the ADR-041 §2 injection treatment — JSON inside opaque
  `---BEGIN/END_...---` delimiters, with backticks and the closing delimiter
  neutralized — because reviewer titles are model-authored text.
- The attached policy states that a sticky finding previously claimed as
  `Applied` was not applied, that changing the wrong kind of artifact is not a
  fix (a unit-test rewrite does not answer an end-to-end ask), and that an
  uncloseable finding must be listed under `Deferred` with a reason.
- Internal and external lanes are rendered from separate baselines and never
  share fingerprints (ADR-038 §3).
- The block is omitted entirely when there is nothing sticky.

### B — Operator accept-finding path

- A comment on the impl PR carrying `<!-- helm:accept-finding -->` with a
  finding title, an optional severity, and a rationale is parsed into an
  accepted-finding record keyed by the ADR-038 fingerprint of the title.
- Authorization mirrors ADR-037 product decisions: GitHub write access on the
  code repo, an open PR whose head ref is `helm/impl/*`, repository match, and
  an item belonging to this product. A comment failing any check is ignored
  without error, and never acknowledged as accepted.
- Only MEDIUM and below can be accepted. A comment naming CRITICAL or HIGH is
  rejected and leaves the finding on the adjudication/escalation path.
- Accepted findings are stored on the item alongside `resolvedProductDecisions`,
  with author, PR number, and timestamp, and are idempotent by fingerprint.
- The loop re-reads accepted findings per cycle, so an accept posted while a job
  is running takes effect on the next pass.
- Matching internal findings are demoted to `**INFO** · Accepted by operator:
  <summary>` before `shouldRemediate()`, with the same recount and status
  rewrite as A1.
- Matching external blockers become advisories with disposition `Accepted`
  (ADR-036 §5) instead of `Deferred`, and stop counting as blockers.
- Recording an accept while the item is in `code-review` re-dispatches
  `reviewer-fanout` at the current head, exactly as a recorded product decision
  does; recording it at any other stage stores the record without dispatching.

### C — Test-reviewer prompt contract

- The `test-reviewer` prompt requires every finding to cite the acceptance
  criterion it maps to, or be filed at LOW or INFO.
- It states that asking for a higher-fidelity test artifact than the AC requires
  — a real-device run, an end-to-end harness, a framework runtime — is capped at
  LOW unless an AC names that artifact.
- Only the `test` reviewer prompt changes; `code` and `security` are untouched.

### Cross-cutting

- Unit tests cover: suppression on `code-review` including the MEDIUM cap and
  the CRITICAL/HIGH passthrough; sticky theme group matching and the
  cross-rewording fingerprint identity; the unresolved-sticky prompt block and
  its per-lane separation; accept-finding parsing, the severity ceiling, and
  gate demotion; and the webhook authorization path.
- No behavior changes for products with no catalogue, no accepted findings, and
  no test-fidelity findings.
- `CHANGELOG.md` records the change under `[Unreleased]`.

## Technical Notes

- All five controls attach to existing seams. Do not restructure the reviewer
  fan-out, the adjudicator, or the stop rule.
- A1 is a guard relaxation plus a severity predicate in
  `packages/orchestrator/src/review-loop/code-review-loop.ts`; the transform
  itself already exists and is shared with `early-artifact` mode.
- A2 belongs in `finding-fingerprint.ts`. Group matching must run before theme,
  path, and token composition and short-circuit it.
- A3 should follow `catalog-prompt.ts` rather than inventing a second injection
  style; the sticky-cycle counter belongs on the existing `StickyLane` so both
  lanes get it for free.
- B mirrors the `<!-- helm:product-decision -->` path end to end: parser in the
  orchestrator's review-loop module, storage on `ItemState` via an `ItemStore`
  upsert under the same item lock, plumbing through the dispatcher, and a branch
  in the GitHub PR-comment webhook handler. Reuse
  `authorHasWriteAccess` / `resolveOpenPrMetadata` / `parseArtifactBranch`; do
  not write a second authorization model.
- An accept is scoped to one item. A pattern worth suppressing product-wide
  still belongs in `false-positives.md`, which is reviewed.
- Externally-authored text (catalogue entries, reviewer titles, operator
  rationales) is injected as data, never as instructions.

## Out of scope

- **lhpaul/helm#108** — external on-demand review / CodeRabbit cost. Same loop,
  separate cost concern, tracked separately.
- Auto-accepting a sticky finding after N cycles.
- Per-product configuration of sticky theme groups.
- Promoting accepted findings into `false-positives.md` automatically.
