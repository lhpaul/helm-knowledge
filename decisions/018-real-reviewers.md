# ADR-018: Real Reviewer Prompts and Code-Reviewer Push

**Date:** 2026-05-28
**Status:** Accepted
**Supersedes:** —
**Related:** ADR-017 (Reviewer Fan-Out Foundation), ADR-015 (Task Ingestion), ADR-014 (Implementer Self-Verification)

---

## Context

Session 19a (ADR-017) delivered the reviewer fan-out infrastructure: three isolated
workspaces, parallel agent spawn via `Promise.allSettled`, and orchestrator-owned PR
comment posting. However, the reviewer prompts were stubs — each reviewer was only
instructed to write a minimal `review.md` with a heading and status line.

This session (19b) wires the real prompts and introduces two new behaviours:

1. **Structured findings format** — reviewers produce `review.md` using a canonical
   severity-tagged format that Session 19c can parse programmatically.
2. **Code-reviewer patch push** — the code-reviewer may apply mechanical fixes
   directly to the impl branch; other reviewers remain comment-only.

Additionally, the spec (if available) is injected into all three reviewer prompts so
reviewers can check the implementation against the stated acceptance criteria.

---

## Decision

### 1. `review.md` format with `**SEVERITY** ·` tags

All reviewers produce `review.md` using a canonical format defined by the exported
`REVIEW_MD_FORMAT` constant:

```markdown
# {Kind} Review: {externalId}

## Summary
<one-paragraph executive summary>

## Findings
- **CRITICAL** · <short finding title>
  <description, impacted files, suggested fix>
- **HIGH** · <…>
- **MEDIUM** · <…>
- **LOW** · <…>
- **INFO** · <…>

Omit severity levels with no findings — do NOT write "None" or "No findings".

## Status
APPROVED | CHANGES_REQUESTED

(Use APPROVED only if there are no findings of severity MEDIUM or above.)
```

**Why this format:**

- Session 19c parses reviewer comments with a regex matching `/\*\*(CRITICAL|HIGH)\*\* · /`
  to detect findings that gate the `remediation` transition. A fixed format is
  required for zero-ambiguity parsing.
- The `**SEVERITY** ·` tag convention matches the agent-hq severity-tag convention
  used in other Helm components — no translation layer needed.
- The `APPROVED` / `CHANGES_REQUESTED` status mirrors GitHub's PR review states,
  making the output legible to human reviewers as well as the orchestrator.
- Severity levels (`CRITICAL | HIGH | MEDIUM | LOW | INFO`) follow the industry-standard
  five-tier model, giving the remediation gate fine-grained control over thresholds.
- Omitting empty severity tiers avoids false-positive parsing of "No findings" text as
  a real finding.

### 2. Domain-focused prompts per reviewer kind

Each reviewer kind gets a distinct prompt focused on its review domain:

| Kind     | Domain focus                                                              | File modifications |
|----------|---------------------------------------------------------------------------|--------------------|
| code     | Code quality, conventions, anti-patterns, missing error handling, spec fit | Allowed (mechanical fixes only) |
| security | Injection, auth/authz, secrets, input validation, unsafe permissions       | Prohibited         |
| test     | Coverage vs spec ACs, edge cases, test quality, flakiness                  | Prohibited         |

**Why domain separation:**

- A single generic prompt would produce diluted findings across all three dimensions.
  A security reviewer optimised for injection patterns will miss code quality issues
  and vice versa.
- Explicit "Do not modify files" instructions in security and test prompts enforce the
  single-pusher invariant at the prompt level in addition to the code level.
- Each prompt includes the diff tip (`git fetch --depth 1 origin {default_branch}; git diff origin/{default_branch}...HEAD`) so the reviewer sees exactly what changed.

### 3. Spec injection best-effort

Before provisioning workspaces, `fanoutReviewers` calls `fetchSpecForPlan` — the same
helper used by the plan-writer (Session 14). If the spec is available, it is injected
into all three reviewer prompts as a `## Spec` section. If the fetch fails or returns
null, the reviewers run without spec context.

**Why best-effort:**

- The spec enables reviewers to check implementation against acceptance criteria,
  significantly improving finding quality. Without the spec, a test reviewer cannot
  know which edge cases were required.
- Spec absence is not a blocker: the implementation already passed the plan-writer and
  implementer pipeline stages. Blocking the review dispatch on a missing spec would be
  a regression from the 19a behaviour.
- The same best-effort pattern is used for task ingestion into the spec-writer
  (ADR-015) and for product context injection (README + AGENT.md). Consistency with
  the established pattern avoids a new error-handling precedent.
- If the spec is missing (e.g. spec file deleted, knowledge repo unreachable), the
  review still provides value — just without the acceptance criteria check.

**Implementation note:** `fetchSpecForPlan` throws on network errors and returns `null`
on 404. `fanoutReviewers` wraps the call in `try/catch` and logs a warning on any
error, then proceeds with `spec = undefined`.

### 4. Push path only for code-reviewer

`handleReviewerResult` calls `pushReviewerPatches` for `kind === 'code'` only.
Security and test reviewers have no push code path at all.

`pushReviewerPatches` implements a **fast-forward push** (no `--force`) to the
existing `helm/impl/{externalId}` remote branch. The impl branch was created and pushed
by the implementer; the code-reviewer appends a single mechanical-fix commit on top.

**Why single-pusher:**

- The single-pusher invariant was established in ADR-017 and rationale is unchanged:
  multiple concurrent pushers on the same branch cause conflicts.
- The code-reviewer is the only reviewer kind that applies changes to the working
  directory (mechanical fixes — typos, formatting, dead-code removal). Security and
  test reviewers are explicitly instructed not to modify files.
- The push path is physically absent from security and test reviewer handling — not
  guarded by a runtime flag. This is intentional: the invariant is enforced by design,
  not configuration.

**Push failure handling:**

If the push fails (e.g. network error, remote rejection), the failure is non-fatal:

1. `pushReviewerPatches` throws; the error is caught and logged.
2. The review comment is still posted (with no push-notice appended).
3. `handleReviewerResult` returns `status: 'error'` with `commentPosted: true` and
   `error: 'Comment posted but push failed: ...'`.

This means partial success is surfaced to operators without losing the review findings.

---

## Alternatives Considered

### A — Per-reviewer push vs single-pusher

Allow all three reviewers to push to the impl branch if they modify files.

**Rejected:** Concurrent push race conditions. All three reviewer agents run in
`Promise.allSettled` in parallel. If security and test reviewers could also push, three
simultaneous pushes to the same branch would require locking, retry logic, or a
serialisation layer — significantly increasing complexity. The code-reviewer is the
only reviewer kind whose task naturally includes file modifications; the others are
purely analytical.

### B — Strict spec (fail dispatch without spec) vs best-effort

Require the spec to be present before dispatching reviewers; return an error if the
spec is unavailable.

**Rejected:** The review stage is a quality gate, not a spec-parsing stage. The
implementation has already been accepted by the plan-writer and implementer; blocking
reviews on a missing spec would be a false dependency. Best-effort spec injection
provides context when available without becoming a new failure mode.

### C — Shared review format string vs per-kind format

Give each reviewer kind a distinct `review.md` heading format rather than a shared
`REVIEW_MD_FORMAT` constant.

**Rejected:** The `{Kind}` placeholder in `REVIEW_MD_FORMAT` is replaced at call time.
A shared constant means a single place to update the format when 19c's parsing regex
changes. Divergent per-kind formats would require updating four places (three reviewers
+ the 19c parser) for any format change.

---

## Consequences

### Positive

- **Real reviewable findings:** Reviewer agents now produce structured, severity-tagged
  findings that are immediately useful to human reviewers and parseable by the
  orchestrator.
- **19c can gate on CRITICAL/HIGH:** The `**SEVERITY** ·` format allows Session 19c
  to detect high-severity findings with a simple regex and route the item to
  `remediation` rather than awaiting human merge.
- **Mechanical fixes applied automatically:** The code-reviewer can correct low-risk
  issues (typos, formatting, dead code) in the same pipeline cycle as the review,
  reducing round-trips.
- **Spec context for reviewers:** Acceptance criteria from the spec are available to
  reviewers, enabling targeted coverage and spec-compliance checks.
- **Push failure non-fatal:** A push failure surfaces the review findings as a PR
  comment and marks the reviewer result as `error`, giving operators a clear signal
  without losing the review content.

### Trade-offs / Known Limitations

- **Prompt quality is a starting point:** The domain-focused prompts in 19b are
  solid but will require tuning as real workloads exercise them. Prompt revision does
  not require an ADR update.
- **Single code repo assumed:** `fanoutReviewers` uses `product.code_repos[0]`. If a
  product has multiple code repos, only the first is reviewed. Multi-repo support is
  deferred (see ADR-017 trade-offs).
- **No transition gate in 19b:** The item stays in `code-review` regardless of review
  findings. Severity-based routing to `remediation` comes in 19c.
- **Spec injected into all three prompts:** The spec could be large (up to 32,000 chars
  after truncation). All three reviewer agents receive the same spec content in their
  prompts, tripling the spec token cost. This is acceptable given the value of
  acceptance-criteria-aware reviews.

---

## Revisit When

- **Session 19c complete:** Remediation gate parses `**CRITICAL** ·` and `**HIGH** ·`
  findings. If the parsing logic requires format changes, update `REVIEW_MD_FORMAT`
  and re-tune prompts.
- **Reviewer prompts need tuning:** After production workloads expose prompt
  weaknesses (e.g. too many false positives, findings too vague), revise the prompts
  in `buildReviewerParams`. No ADR required for prompt tuning.
- **Multi-repo support:** When products with multiple code repos become common,
  `fanoutReviewers` should accept a `codeRepo` parameter or iterate all repos. This
  may warrant a new ADR if the workspace provisioning model changes.

---

## References

- ADR-017: Reviewer Fan-Out Foundation — workspace provisioning, parallel spawn,
  comment-posting, single-pusher invariant.
- ADR-015: Task Ingestion into Spec-Writer — best-effort fetch pattern, graceful
  fallback, injected fetch function.
- ADR-014: Implementer Self-Verification — single-pusher concept, `helm-bot` identity,
  workspace lifecycle.
- Session 19b implementation:
  `packages/orchestrator/src/specialists/reviewer-fanout.ts`,
  `packages/orchestrator/src/specialists/code-workspace.ts`.
