# ADR-037: Review adjudicator before remediation

**Date:** 2026-07-09
**Status:** Accepted
**Supersedes:** —
**Related:** ADR-017 (Reviewer Fan-Out), ADR-019 (Remediation Gate), ADR-025 (Remediation Covers All Reviewers), ADR-036 (PR Review Loop — lhpaul/helm-knowledge#39)

---

## Context

The bounded review loop (ADR-036) runs `reviewer-fanout` and, when CRITICAL/HIGH
findings exist, passes raw review bodies directly to `code-remediator`. That
works when reviewers agree on direction, but fails when they conflict:

- **Code reviewer** vs **Haystack** on schema shape (e.g. 4-field vs 6-field
  `properties.address`).
- **Code reviewer** vs **test reviewer** on spec interpretation (e.g. literal
  vacancy on empty Core search vs defensive guard).
- **Remediation oscillation** — the remediator applies cycle *N* fixes, then
  cycle *N+1* reverts them because a different reviewer signal dominated.

The Arriendo Fácil pilot (LEA-192) showed both failure modes: a Helm remediation
commit reverted operator-approved fixes, and the loop required mid-run human
input for product decisions that should have escalated once, structurally.

ADR-036 stop-rules (`max_cycles`, `no_progress_cycles`) only count CRITICAL/HIGH
blockers. They do not detect **semantic conflict** or **regression after a
best-so-far improvement** (blocker count drops, then rises again).

---

## Decision

### 1. Insert `review-adjudicator` between fan-out and remediation

When internal blockers exist (or external review returns `needs_fixes`) and
adjudication is enabled, the loop runs **`review-adjudicator`** before
`code-remediator`:

```
reviewer-fanout (+ optional external blockers)
    ↓
review-adjudicator   ← comment-only; no push
    ↓
code-remediator      ← receives unified plan only
```

The adjudicator is **comment-only** (like security/test reviewers): it writes
`adjudication.md` outside the git clone; the orchestrator posts it as a PR
comment. It never pushes to the impl branch.

### 2. Canonical `adjudication.md` format

```markdown
# Review Adjudication: {externalId}

## Summary
<one paragraph>

## Conflicts
- **product_decision** · <title>
  <sources and recommended human options — omit section when none>
- **doc_conflict** · <title>
  <ADR/spec/CLAUDE hierarchy resolution or escalate>

## Unified remediation plan
- **AUTO** · <actionable fix aligned across sources>
- **DEFERRED** · <finding> — <reason>

## Status
AUTO_REMEDIATE | HUMAN_REQUIRED
```

- **`AUTO_REMEDIATE`** — no unresolved `product_decision` or `doc_conflict`
  entries; remediator may proceed with the unified plan only.
- **`HUMAN_REQUIRED`** — loop **escalates immediately** with a structured PR
  comment (`adjudication_conflict`); no remediation pass in that cycle.

Resolution hierarchy for `doc_conflict`:

1. Accepted ADR in the knowledge repo
2. Item spec
3. `CLAUDE.md` / project contract
4. Reviewer opinion (weakest)

### 3. Product configuration

Optional specialist (backward compatible — when absent, loop keeps the legacy
direct-to-remediator path):

```yaml
specialists:
  review-adjudicator:
    runtime: claude_code
    model: sonnet

review:
  loop:
    adjudication:
      enabled: true   # default true when specialist is configured
    max_cycles: 8
    stop_rule:
      no_progress_cycles: 3
```

`review.loop.adjudication.enabled: false` disables the step even if the
specialist is configured.

### 4. Stop-rule hardening (same release)

**Best-so-far blockers:** `no_progress` compares each cycle against the
*lowest* CRITICAL/HIGH count seen in the loop run, not only the immediately
prior cycle. This detects oscillation (e.g. 2 → 0 → 2 after a revert).

**Remediation retry:** one automatic retry when remediation fails after workspace
recovery to `code-review`, before the loop returns a terminal error.

### 5. Loop exit policy (operator intent)

The loop continues autonomously until:

| Outcome | Condition |
| -------- | ---------- |
| **Clean** | No CRITICAL/HIGH internal blockers; external review `clean` or skipped |
| **Escalated** | `max_cycles`, `no_progress`, external escalate, or `HUMAN_REQUIRED` adjudication |

Mid-loop remediation failures are retried once; they do not terminate the loop
unless recovery also fails.

---

## Consequences

- **Conflicts surface once** with structured options instead of silent
  remediation churn.
- **Remediator scope narrows** — it executes a unified plan, not contradictory
  raw reviews.
- **Optional specialist** — existing products without `review-adjudicator` behave
  as before until they opt in.
- **Extra cost/latency** — one agent spawn per remediation cycle when enabled;
  acceptable vs. multi-cycle oscillation and human firefighting.
- **New escalation reason** — `adjudication_conflict` on PRs and dispatch
  results for dashboard filtering.

---

## Alternatives considered

| Alternative | Why rejected |
| ----------- | ------------- |
| Merge conflicts inside `code-remediator` prompt only | Remediator still pushes code; no structured human checkpoint for product decisions |
| Human gate on every MEDIUM finding | Too noisy; MEDIUM stays advisory unless product config extends the gate later |
| Required specialist in schema | Breaks every existing `product.yaml` at load time; optional + opt-in is safer |
| Fingerprint-only stop rule without best-so-far | Harder to explain; best-so-far covers revert oscillation with simpler state |

---

## Revisit when

- Products routinely run multiple external reviewers (not one slot) — adjudicator
  may need a normalized external feed beyond Haystack blockers.
- Per-product policy wants MEDIUM findings to gate remediation — extend
  `shouldRemediate` and adjudicator input, not bypass adjudicator.
- Adjudicator false-positive rate is high — add `review.loop.adjudication.skip_on_clean_fanout` or a confidence score.
