# ADR-019: Remediation Gate

**Date:** 2026-05-28
**Status:** Accepted
**Supersedes:** —
**Related:** ADR-018 (Real Reviewer Prompts and Code-Reviewer Push), ADR-017 (Reviewer Fan-Out Foundation), ADR-014 (Implementer Self-Verification)

---

## Context

Session 19a (ADR-017) delivered the reviewer fan-out: three isolated workspaces,
parallel agent spawn, orchestrator-owned PR comments. Session 19b (ADR-018) gave the
reviewers real, domain-focused prompts producing a canonical `review.md` with
`**SEVERITY** ·` tags, and let the code-reviewer push mechanical fixes directly.

After 19b, an item in `code-review` always stayed in `code-review` regardless of what
the reviewers found — it then waited for a human to merge the PR. High-severity findings
from the security and test reviewers (which are comment-only by design) had no automated
follow-up: a CRITICAL SQL-injection finding sat in a comment until a human read it.

Session 19c closes that gap with a **remediation gate**: parse the severity findings, and
when the security or test reviewer reports a CRITICAL or HIGH finding, run a remediation
agent that applies mechanical fixes and pushes them before the item waits for human merge.

---

## Decision

### 1. The gate keys on security/test findings only — not code

`shouldRemediate(results)` returns true iff a `security` **or** `test` reviewer carries
`findings.critical > 0 || findings.high > 0`. The code-reviewer is deliberately excluded.

**Why exclude the code-reviewer:**

- The code-reviewer already applies its own mechanical fixes and pushes them within the
  fan-out (ADR-018, single-pusher). Its findings are *already remediated* by the time
  `handleReviewerResult` returns — gating on them would re-run a fix for work that is done.
- Security and test reviewers are comment-only by design (ADR-017/018 single-pusher
  invariant). They are precisely the reviewers whose high-severity findings have no
  automated follow-up. The remediation agent is the follow-up.
- Keeping the trigger to two reviewer kinds keeps the gate predictable: the remediation
  agent's job is "fix what the analytical reviewers flagged", not "redo the code-reviewer".

### 2. Gated severities are CRITICAL and HIGH only

MEDIUM, LOW, and INFO findings never trigger remediation.

**Why:**

- CRITICAL/HIGH map to issues that should block a merge (injection, auth bypass, missing
  coverage of a core acceptance criterion). MEDIUM and below are quality nits that a human
  reviewer can weigh against shipping — automating fixes for them risks unwanted churn on
  the PR and noise in the commit history.
- This mirrors the `APPROVED` threshold in `REVIEW_MD_FORMAT` (ADR-018): "APPROVED only if
  there are no findings of severity MEDIUM or above" is a *human* gate; the *automated*
  remediation gate is intentionally stricter (CRITICAL/HIGH) so it acts only on the issues
  least defensible to ship.

### 3. Findings parsing reuses the 19b format

`parseFindings(reviewBody)` counts `**SEVERITY** ·` tags per level and returns
`Findings = { critical, high, medium, low, info }`. `ReviewerResult` gains `findings?` and
`commentBody?`, both populated only when a comment was posted.

**Why store both on the result:**

- `findings` lets the dispatcher gate without re-reading the comment from GitHub.
- `commentBody` is the exact review text. The remediation agent is fed the *original*
  security/test review bodies (not a re-summary), so it sees the reviewer's own wording,
  impacted files, and suggested fixes — no lossy round-trip.
- Bare bold without the `·` separator is not counted, avoiding false positives from prose
  that happens to bold a severity word.

### 4. Composite dispatch in a single Job

When the gate fires, the dispatcher does everything in the *same* `reviewer-fanout`
dispatch: `code-review → remediation` transition, provision a fresh workspace on the impl
branch, build `findingsByKind` from the security/test `commentBody`s, spawn the remediation
agent, handle its result, then `remediation → code-review` on success. Cost is **summed**
across fan-out + remediation; duration is the **max** (the fan-out is parallel wall-clock,
remediation is one more agent).

**Why one Job, not a separate dispatch per stage:**

- The remediation decision depends on in-memory `reviewerResults` (the parsed findings and
  comment bodies). Splitting into a second Job would mean re-querying GitHub for the
  comments and re-parsing them — re-deriving state we already hold.
- A single Job keeps the cost/duration accounting honest: the operator sees the full
  fan-out-plus-remediation spend as one number against the item.
- The state machine already allows `code-review → remediation → code-review`, so the
  composite path is expressible without schema changes.

### 5. Reviewers are NOT re-run after remediation

After the remediation agent pushes, the item returns to `code-review` and waits for human
merge. The reviewers do not run a second time to confirm the fixes.

**Why no re-run:**

- A re-run would risk an unbounded loop (review → remediate → review → remediate …) for
  any finding the agent can't fully resolve. Bounding that loop needs round tracking and a
  give-up policy — explicitly out of scope for 19c.
- The human merge step is still the final gate. The remediation commit is visible on the PR
  with its `chore(remediation):` message and SHA footer; a human (or a future re-review
  feature) confirms it. Remediation raises the floor; it does not replace human judgement.
- Keeping the loop single-pass keeps cost bounded and the dispatch deterministic.

### 6. Remediation reuses `pushReviewerPatches` with a custom commit message

`pushReviewerPatches` gained an optional `commitMessage`. Remediation passes
`chore(remediation): apply fixes for {externalId}`; the code-reviewer keeps its default
`chore(review): apply code-reviewer patches for {externalId}`.

**Why reuse the push helper:**

- The push mechanics are identical: stage, commit as `helm-bot`, fast-forward push to
  `helm/impl/{externalId}`, token sanitized from errors, `{ pushed: false }` on a clean
  tree. Duplicating that into remediation would fork a security-sensitive code path
  (token handling) for no behavioural difference.
- Only the commit message differs, so a single optional parameter is the minimal seam.
  Distinct messages keep the PR history legible — a reader can tell a code-reviewer fix
  from a remediation fix at a glance.

**Token isolation (unchanged from ADR-014/018):** the GitHub token never enters the
remediation agent subprocess. The orchestrator owns all git/gh operations; the agent only
reads findings and writes files. `REMEDIATION_TIMEOUT_MS` is 15 min — between the reviewer
timeout (10 min) and the implementer timeout (20 min), reflecting that remediation is
mechanical and narrower than a full implementation.

### 7. Failure handling leaves the item where it can be re-dispatched

- Fan-out wholly failed (no reviewer results) → return error, no gate, no transition; item
  stays in `code-review`.
- Gate inactive (no CRITICAL/HIGH from sec/test) → no transition; item stays in
  `code-review` and waits for human merge, exactly as in 19b.
- Workspace provisioning fails after the `→ remediation` transition → item stays in
  `remediation` (re-dispatchable), workspace cleaned up.
- Remediation agent errors, or the push/comment fails → status `error`, no return
  transition; item stays in `remediation`.

**Why leave it in `remediation` on failure:** the same redispatch principle as ADR-014's
provisioning-before-transition — an item should fail into a stage from which retrying makes
sense, never into a dead end. A failed remediation is retried by re-dispatching
`remediation`, not by manually reseting the stage.

---

## Alternatives Considered

### A — Gate on code-reviewer findings too

Include the code-reviewer in `shouldRemediate`.

**Rejected:** the code-reviewer already pushed its fixes inside the fan-out (ADR-018). Its
findings are remediated by the time the gate runs; including them would trigger a redundant
agent to "fix" already-fixed work. The analytical (comment-only) reviewers are the ones
with no follow-up — they are the entire reason the gate exists.

### B — Separate Job per stage transition

Dispatch remediation as its own Job after the fan-out Job completes.

**Rejected:** the gate decision and the remediation prompt both consume the in-memory
`reviewerResults` (parsed findings + original comment bodies). A second Job would re-query
GitHub and re-parse comments to reconstruct state we already hold, adding network calls and
a parsing round-trip for no benefit. A single composite Job also gives honest unified
cost/duration accounting.

### C — Re-run reviewers after remediation to confirm fixes

Loop back through the fan-out once the remediation agent pushes.

**Rejected (deferred):** without round tracking and a give-up policy this risks an unbounded
review/remediate loop. The human merge step remains the final gate, and the remediation
commit is visible on the PR. Bounded re-review is a candidate for a future session, not 19c.

### D — Gate on MEDIUM and above

Lower the trigger threshold to match the `CHANGES_REQUESTED` / non-`APPROVED` line.

**Rejected:** MEDIUM findings are quality nits where a human can reasonably choose to ship.
Auto-remediating them produces churn and commit noise on PRs that were fine to merge. The
automated gate is intentionally stricter than the human-review threshold.

---

## Consequences

### Positive

- **High-severity sec/test findings get an automated fix pass.** A CRITICAL injection
  finding now produces a remediation commit in the same cycle, not just a comment waiting
  for a human.
- **No state-machine or schema changes.** The composite path uses the existing
  `code-review ↔ remediation` transitions.
- **Honest accounting.** Cost summed, duration max — the operator sees the full spend of
  fan-out + remediation as one figure.
- **Security-sensitive push path stays single-sourced.** Remediation reuses
  `pushReviewerPatches`; token handling is not forked.
- **Deterministic, bounded.** Single-pass remediation with no reviewer re-run keeps cost
  bounded and dispatch deterministic.

### Trade-offs / Known Limitations

- **No confirmation that fixes resolved the findings.** Reviewers don't re-run; a human
  merge is still the final gate. Remediation raises the floor, not the ceiling.
- **No remediation round tracking.** A single pass per `code-review` entry. If a finding
  recurs, there's no automated escalation — deferred by design.
- **Single code repo assumed.** Like the fan-out, remediation operates on
  `product.code_repos[0]`; multi-repo support is deferred (see ADR-017).
- **Duration is max, not sum.** Remediation runs *after* the parallel fan-out, so the true
  wall-clock is closer to fan-out + remediation. Reporting max under-counts the sequential
  tail; this follows the established fan-out aggregation convention (ADR-017) and is
  acceptable for coarse operator-facing accounting.
- **Mechanical scope only.** The remediation agent applies mechanical fixes and writes
  `remediation.md` with Applied/Deferred sections; it is not expected to redesign code.
  Findings needing judgement land in Deferred and await a human.

---

## Revisit When

- **Remediation loops or recurring findings appear in production:** introduce round
  tracking and bounded re-review (Alternative C), with a give-up policy.
- **Multi-repo products become common:** remediation and fan-out should iterate code repos
  rather than using `code_repos[0]`.
- **The MEDIUM threshold proves too lax/strict:** revisit the gated severity set in
  `shouldRemediate` if operators report either missed issues or excessive churn.
- **Cost/duration accounting needs precision:** if the max-duration convention misleads
  operators once remediation is a material fraction of run time, switch to summing the
  sequential remediation tail onto the parallel fan-out wall-clock.

---

## References

- ADR-018: Real Reviewer Prompts and Code-Reviewer Push — `REVIEW_MD_FORMAT`,
  `**SEVERITY** ·` tags, `pushReviewerPatches`, single-pusher invariant.
- ADR-017: Reviewer Fan-Out Foundation — workspace provisioning, parallel spawn,
  comment posting, cost/duration aggregation.
- ADR-014: Implementer Self-Verification — `helm-bot` identity, token isolation,
  provisioning-before-transition, fail-into-redispatchable-stage principle.
- Session 19c implementation:
  `packages/orchestrator/src/specialists/reviewer-fanout.ts` (`parseFindings`,
  `shouldRemediate`, `Findings`),
  `packages/orchestrator/src/specialists/remediation.ts`,
  `packages/orchestrator/src/specialists/code-workspace.ts` (`commitMessage`),
  `packages/orchestrator/src/dispatcher.ts` (gate integration).
