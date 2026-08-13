# ADR-041: Reviewer disagreement policy — catalogued adjudications as tie-breaker

**Date:** 2026-08-13
**Status:** Accepted
**Supersedes:** — (extends ADR-037 §2 adjudication contract)
**Related:** ADR-025 (Remediation Covers All Reviewers), ADR-036 (PR Review Loop),
ADR-037 (Review Adjudicator), ADR-038 (Sticky Finding Progress),
lhpaul/helm#64, LEA-109 pilot (EP#8 / EP#9)

---

## Context

ADR-025 assumes reviewer CRITICAL/HIGH findings all point the same direction.
The LEA-109 pilot produced the first case where they did not:

- **security-reviewer (HIGH):** a shared database client runs the whole API on
  an RLS-bypassing role — split the connection (`BETTER_AUTH_DATABASE_URL`).
- **code-reviewer (HIGH):** a second auth connection URL violates the plan's
  "use the shared client / no separate auth database" wording.

`code-remediator` had no tie-breaker, so it **oscillated**: pass 1 introduced
the split, pass 2 reverted it (EP#8). `shouldRemediate()` kept dispatching
because the blocker count never dropped (EP#9). Resolution required director
adjudication plus a catalogue entry in `helm-knowledge/false-positives.md`, and
reviewer-fanout round 3 had to be skipped by hand.

ADR-037 added the adjudicator, which prevents *silent* churn — but an
already-adjudicated finding still arrives at the adjudicator as a fresh
conflict every cycle, so the best it could do was escalate again.

The catalogue (`false-positives.md`) already existed and was already fetched by
the loop, but it only fed two surfaces: external-adapter findings, and internal
reviewer comments in `spec-draft` / `plan-draft` (ADR-040) mode. It never
reached the adjudicator or the remediator on a code PR.

---

## Decision

### 1. `false-positives.md` is the adjudication catalogue

The product knowledge repo's `false-positives.md` is the **tie-breaker surface**
for LH-adjudicated findings. An entry there means: a human already decided this
finding is not actionable for this product. Entry format is unchanged
(`**Pattern:**`, `**Applies to:**`, `**Why it's a false positive:**`); the
optional `Applies to` field scopes an entry to specific workflow stages and
defaults to all stages.

### 2. The catalogue is injected into both prompts

Every remediation cycle passes the catalogue entries that apply to the current
stage to:

- **`review-adjudicator`** — as the tie-breaker for opposing findings, and
- **`code-remediator`** — as a do-not-touch list, so products that run without
  the adjudicator still get the policy.

Catalogue text is human-authored, so it is injected as **data, not
instructions**: JSON inside opaque `---BEGIN/END_CATALOGUED_ADJUDICATIONS---`
delimiters, with backticks and the closing delimiter neutralized (the same
treatment ADR-037 settled decisions receive).

### 3. Policy for opposing CRITICAL/HIGH findings

In priority order:

1. **One side is catalogued** → the catalogued side **loses**. The adjudicator
   marks it `**DEFERRED**` in the unified plan citing the catalogue title, and
   keeps the opposing fix as `**AUTO**`. It is not re-listed under Conflicts,
   so it does not re-escalate to a human who already decided it.
2. **Neither side is catalogued, and one is a generic secure default**
   (allowlist, fail closed, least privilege, strict validation, no open
   redirect) → prefer the safer option as `**AUTO**` (ADR-037 §secure defaults,
   lhpaul/helm#73). An explicit human override still wins.
3. **Otherwise** → record it **once** under Conflicts as a `product_decision`
   (`HUMAN_REQUIRED`). Alternating implementations across cycles is never a
   valid outcome.

The remediator's corresponding rule: never revert or weaken code that exists to
satisfy the other side of a catalogued entry, even when a reviewer asks for it —
report it under **Deferred** instead.

### 4. What this deliberately does not do

- **No gate suppression on code PRs.** Catalogued entries do not downgrade
  internal reviewer findings before `shouldRemediate()` in `code-review` mode.
  Catalogue matching is heuristic (token overlap); silently clearing a real
  security HIGH is a worse failure than one extra deferral cycle. A catalogued
  finding that keeps recurring converges on the ADR-038 sticky/`no_progress`
  stop rule, which escalates to a human — bounded, not oscillating.
- **No per-PR dispatch rate limit.** The cumulative iteration budget is tracked
  separately (lhpaul/helm#65).

---

## Consequences

- **Catalogued findings stop flipping the implementation.** The LEA-109 scenario
  now yields `AUTO` (keep the split) + `DEFERRED` (catalogued spec-wording
  finding) instead of revert/re-apply.
- **`false-positives.md` becomes load-bearing.** A wrong entry suppresses a real
  finding's ability to drive remediation, so entries need the same care as an
  ADR: pattern, rationale, and origin.
- **Prompt cost grows slightly** with catalogue size; stage scoping via
  `Applies to` keeps the injected set small.
- **Products without a knowledge-repo catalogue are unaffected** — the section
  is omitted entirely when nothing applies to the stage.

---

## Alternatives considered

| Alternative | Why rejected |
| ----------- | ------------- |
| Suppress catalogued reviewer findings at the remediation gate (as in `spec-draft`/`plan-draft` mode) | Heuristic matching against a code PR could clear a genuine security HIGH; deferral keeps a human in the loop |
| A new `product.yaml` adjudication block instead of `false-positives.md` | Splits one adjudication surface into two; the catalogue is already fetched, parsed, and stage-scoped |
| Rate-limit remediation dispatches per PR | Treats the symptom (churn), not the cause (no tie-breaker); tracked separately as lhpaul/helm#65 |
| Require all reviewers to ack a single direction before remediating | Needs a reviewer round-trip protocol Helm does not have; the adjudicator already owns synthesis |

---

## Revisit when

- Catalogue matching produces false deferrals — add explicit finding ids or a
  `blocks:` field to catalogue entries instead of loosening token overlap.
- Opposing findings recur *without* a catalogue entry often enough that
  `HUMAN_REQUIRED` becomes noisy — consider promoting recorded product decisions
  (ADR-037 settled decisions) into the catalogue automatically.
