# ADR-042: Cumulative cross-dispatch review-loop budget

**Date:** 2026-08-13
**Status:** Accepted
**Supersedes:** — (extends ADR-036 §6 stop rule)
**Related:** ADR-036 (PR Review Loop), ADR-037 (Review Adjudicator),
ADR-038 (Sticky Finding Progress), ADR-040 (Early Artifact Review Loop),
ADR-041 (Reviewer Disagreement Policy), lhpaul/helm#65,
LEA-192 / LEA-194 retrospective

---

## Context

ADR-036 §6 bounds the review loop with `max_cycles` (default 5) and a
`no_progress_cycles` streak (default 2). Both counters live **in the loop run**:
they are initialized when `runCodeReviewLoop` starts and thrown away when it
returns.

Every dispatch is a new loop run. A manual re-dispatch — an operator retry, a
webhook on PR `synchronize`, a resumed deferred external review — therefore
restarts `cycle` at 1 and the no-progress streak at 0.

The consequence observed in the AF pilot (LEA-192, over several days): an item
ran dozens of review/remediation cycles and **never escalated**. Each dispatch
stopped short of `max_cycles`, so the stop rule never fired, and nothing in the
system could see that the item was not converging. The per-dispatch budget
measures burst cost; nobody was measuring the lifetime.

`no_progress` has the same hole and it is the worse one: the streak is the
signal that remediation is going in circles, and it was reset by exactly the
action an operator takes when remediation appears to be going in circles.

---

## Decision

### 1. A durable per-item review-loop ledger

Persist review-loop counters on the item (`data/items/{externalId}.json`,
`ItemState.reviewLoopLedger`) so they survive the end of a dispatch:

```ts
type ReviewLoopLedgerEntry = {
  cyclesTotal: number;          // remediation passes completed, all dispatches
  noProgressStreak: number;     // ADR-038 streak, carried across dispatches
  bestBlockerCount?: number;    // lowest blocker count seen so far
  escalatedAt?: string;         // ISO 8601 — last escalation for this lane
  escalationReason?: StopRuleEscalationReason;
  updatedAt: string;
};
```

`cyclesTotal` increments when a remediation pass **completes**. A pass the stop
rule refused never ran and is never counted.

### 2. Lanes, not one budget per item

The ledger is keyed by **lane**: `code-review`, `spec-draft`, `plan-draft` — the
workflow stage the loop runs in.

A draft-artifact loop (ADR-040) and the implementation-PR loop review different
artifacts at different times. Sharing one counter would let a chatty spec review
pre-escalate the item's later code review, which is a false signal about the
implementation. Lanes are independent budgets.

### 3. `review.loop.max_cycles_cumulative`

New optional product config, validated as `>= max_cycles`:

```yaml
review:
  loop:
    max_cycles: 5              # per-dispatch burst limit (ADR-036, unchanged)
    max_cycles_cumulative: 15  # lifetime budget for one item+lane
```

Omitted → derived as `max_cycles * 3`. The multiplier is headroom for legitimate
multi-dispatch work (a rebase, a follow-up review round after a real code
change) before non-convergence is called.

Both limits stay in force. `max_cycles` is a cost guard on a single run;
`max_cycles_cumulative` is a convergence guard on the item.

### 4. Stop rule

`evaluateStopRule` gains `max_cycles_cumulative` as an escalation reason,
checked **before** `max_cycles`: once the lifetime budget is gone, "this
dispatch also hit its burst limit" is the less useful of the two facts, and
`cycle` restarting at 1 is precisely what the new rule exists to catch.

**Probe order — where the rule runs.** The stop rule is evaluated inside the
loop, *after* a reviewer fan-out has reported blockers and *before* the
remediation pass that would answer them — the same position ADR-036 gave it. It
is never evaluated at dispatch start. So a re-dispatch of an item whose budget
is already spent still runs one fan-out; that fan-out is a **probe**, not a
remediation pass, and never increments `cyclesTotal`. A clean probe exits the
loop normally (§7); a probe that still finds blockers escalates before spending
another pass.

Cross-dispatch **no-progress keeps the existing `no_progress` reason**. Seeding
the streak (and `bestBlockerCount`, without which the first cycle of every
dispatch has no baseline and resets the streak to 0) is the whole mechanism; it
is not a separate outcome and does not deserve a separate reason code. The
escalation message says when the streak spanned dispatches.

### 5. Escalation is visible on the PR

Every stop-rule escalation now posts the ADR-036 escalation comment on the PR,
not just the external-provider and adjudication ones. A lifetime budget that
only shows up in a job record is not an escalation an operator will see.

Escalations also append one item-history event. Ordinary cycle ticks do not —
a long loop must not bloat item history.

A still-blocked item re-escalates on every re-dispatch, so the history event
carries an idempotency key of `(lane, reason, cyclesTotal)`: a retry or duplicate
webhook at the same budget state is a no-op, while an escalation after more
cycles is recorded as the distinct event it is. `escalatedAt` alone is not a
stable dedup key and is not used as one.

The escalation **PR comment** is not yet deduplicated — `postPRComment` appends,
inherited from ADR-036, so repeated escalations post repeated comments. Making it
an upsert-by-marker (as the ADR-036 Review Loop Summary already is) changes the
shared escalation path for every reason code, so it is tracked separately rather
than folded into this ADR.

### 6. Monotonic writes

`cyclesTotal` is clamped with `max` and `bestBlockerCount` with `min` on write:
a stale or concurrent writer must never hand budget back, which is the reset
this ADR exists to prevent. `noProgressStreak` is last-writer-wins, because a
legitimate reset to 0 after real progress has to be able to lower it.

### 7. No automatic reset

The budget is a **lifetime** budget: nothing resets it while the item is open,
and re-dispatching an escalated item does not clear it. A re-dispatch after the
budget is spent still runs one fan-out — that is deliberate, because the fan-out
is how Helm learns the blockers are gone. If they are, the loop exits clean and
never reaches the stop rule. If they are not, it re-escalates immediately
instead of burning another remediation pass.

Operators who decide the item deserves more budget raise
`max_cycles_cumulative`, or clear the lane on the item state. That is a human
decision, which is the point of escalating.

---

## Alternatives considered

### A — Rate-limit dispatches per PR instead

**Rejected:** ADR-041 already considered and rejected a per-PR dispatch rate
limit. A rate limit throttles *when* work happens; it never answers whether the
item is converging. It would also block legitimate re-dispatches after a real
code change.

### B — Store the counters in the job record

**Rejected:** jobs are per-dispatch by construction. Reconstructing a lifetime
budget would mean scanning job history and guessing which jobs belong to the
same review effort — the item is the natural owner of item-scoped state, next
to `resolvedProductDecisions`.

### C — One budget per item, no lanes

**Rejected:** see §2. Cross-contamination between draft review and code review
produces escalations that point at the wrong artifact.

### D — Replace `max_cycles` with the cumulative budget

**Rejected** (and out of scope per lhpaul/helm#65): the per-dispatch limit is a
cost guard — it stops one run from spending 15 cycles of agent budget in a
single job. The two limits answer different questions.

### E — Persist sticky fingerprints across dispatches too

**Deferred:** ADR-038 sticky lanes re-baseline per run, so the first cycle of a
new dispatch compares on blocker count alone. Carrying the fingerprint sets
would sharpen cross-dispatch progress detection, at the cost of a much larger
durable payload. Revisit if count-based carry-over proves too coarse.

---

## Consequences

### Positive

- **Non-convergence becomes visible.** The LEA-192 pattern — dozens of cycles,
  no escalation — now escalates with `max_cycles_cumulative` and a PR comment.
- **Re-dispatch stops laundering the streak.** A carried `no_progress` streak
  escalates on the first flat cycle of the new dispatch.
- **Item state stays the single home for item-scoped ledgers**, alongside
  ADR-037 settled decisions.

### Trade-offs / known limitations

- **One extra fan-out per re-dispatch after escalation** (§7) — accepted as the
  price of letting a genuinely fixed item exit clean.
- **Ledger writes are retry-once, then best-effort.** A write that fails twice
  logs and continues rather than aborting a run that already pushed remediation
  commits. The cost is a budget that under-counts: because writes carry the
  running total (not a delta) and `cyclesTotal` is clamped with `max`, the next
  successful write restores the correct total — a dropped write costs accuracy
  only until then, not permanently. Blocking the next remediation pass on a
  durable write was rejected: a transient filesystem error would then halt
  review loops entirely, a worse failure than a temporarily loose budget.
- **Single-process serialization** — the ItemStore per-item lock is in-process
  (same v0 constraint as every other item write). The monotonic clamps are the
  durable defense.
- **Existing items start at zero.** The ledger is absent until an item's first
  post-upgrade remediation pass; in-flight items get a fresh lifetime budget.

---

## Revisit when

- Operators report the `max_cycles * 3` default is too tight or too loose.
- Cross-dispatch progress detection proves too coarse without sticky
  fingerprints (alternative E).
- Multi-repo remediation lands — the lane key may need a repo dimension.
- The escalation PR comment should upsert by marker instead of appending, so a
  repeatedly re-dispatched item does not accumulate identical comments (§5).

---

## References

- lhpaul/helm#65 (issue), LEA-194 retrospective finding #5.
- `helm/packages/orchestrator/src/review-loop/cumulative-ledger.ts`,
  `stop-rule.ts`, `code-review-loop.ts`.
- `helm/apps/api/src/services/item-store.ts` (`updateReviewLoopLedger`).
