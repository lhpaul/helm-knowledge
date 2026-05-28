# ADR-017: Reviewer Fan-Out Foundation

**Date:** 2026-05-28
**Status:** Accepted
**Supersedes:** —
**Related:** ADR-013 (Implementer Execution Foundation), ADR-014 (Implementer Self-Verification)

---

## Context

Session 18 (ADR-016) completed the release loop: an item can now travel from `discovery`
all the way to `released` when the implementation PR is merged. However, there was no
automated quality layer between the implementer finishing (`code-review` stage) and a
human merging the PR. This means:

1. Security vulnerabilities could reach `released` undetected.
2. Test coverage gaps are only caught by human review.
3. Code quality issues (style, architecture, complexity) are not surfaced automatically.

The pipeline needed a `code-review` specialist that could run concurrently across three
review dimensions — code quality, security, and test coverage — and post structured
findings as PR comments before any human reviewer looks at the PR.

### Constraints going into this session (19a)

- Three reviewer "roles" are needed: `code`, `security`, `test`.
- All three review the **same** PR at the **same** pipeline stage (`code-review`).
- The implementation PR is already open in the code repo (opened by the implementer).
- The GITHUB_TOKEN must never reach an agent subprocess (established in ADR-013).
- Workspaces must be isolated per reviewer to avoid race conditions.
- Reviewer prompts are stubs in 19a; real prompts come in 19b.

---

## Decision

### 1. Composite specialist `reviewer-fanout` instead of three separate stage mappings

We map `STAGE_TO_SPECIALIST['code-review'] = 'reviewer-fanout'` as a **composite
specialist** that internally spawns all three reviewers in parallel.

**Why not three separate stages?**  
All three reviewers operate on the same item at the same stage. Introducing three
intermediate stages (`code-review-code`, `code-review-security`, `code-review-test`)
would:
- Require three separate dispatch cycles (each with its own orchestrator wake-up).
- Complicate the state machine with stages that have no user-visible meaning.
- Serialize reviewers that should run in parallel (the whole point of fan-out).
- Introduce partial-completion states that are hard to reason about.

The composite specialist keeps the state machine clean: the item enters `code-review`
and exits to `remediation` or awaits human merge. The internal parallelism is an
implementation detail of the specialist.

### 2. `Promise.allSettled` for spawn+wait fan-out

We use `Promise.allSettled` (not `Promise.all`) for both workspace provisioning and
the spawn+wait cycle. This means:
- A single reviewer failure does not cancel or mask results from the other two.
- All three review comments are posted even if one reviewer fails.
- The aggregated `status` is `'error'` if **any** reviewer fails or any comment fails
  to post — callers can surface this to operators without losing the partial results.

### 3. PR resolved via `gh pr list` (not stored in ItemState)

We query `gh pr list --head helm/impl/{externalId} --state open` at dispatch time
rather than storing the PR URL in `ItemState` when the implementer opens it.

**Why GitHub is the source of truth:**
- The implementer already stores `prUrl` in `DispatchResult` (surfaced to operators)
  but the `ItemState` type has no `prUrl` field.
- Adding a `prUrl` field to `ItemState` would require a schema migration and a
  storage layer change for a value that can always be re-derived from GitHub.
- If the implementer re-opens the PR (after a force-push), the stored URL could be
  stale. Querying GitHub at dispatch time is always fresh.
- This is the same principle used for task ingestion (ADR-015): the tracker is the
  source of truth for task content, not a cached copy in `ItemState`.

### 4. Orchestrator posts PR comments (not agents)

The `handleReviewerResult` function reads `review.md` from the reviewer's workspace
and calls `postPRComment` from the orchestrator process. The agent itself does not
have the GITHUB_TOKEN and cannot post comments directly.

**Why this matters:**
- The GITHUB_TOKEN scrubbing established in ADR-013 is preserved end-to-end.
- An agent with `bypassPermissions` (needed for test runners) cannot accidentally
  leak credentials by calling `gh pr comment` directly.
- The orchestrator controls the comment format and can enforce structure (e.g.
  future: add severity tags, sign comments as `[helm-bot]`).

### 5. Single-pusher invariant

Only the `code-reviewer` may commit and push patches to the impl branch. Security
and test reviewers are **comment-only** by design. The `handleReviewerResult` function
has a TODO (19b) placeholder for the code-reviewer push path; the other two reviewer
kinds have no push path at all.

**Why a single pusher:**
- Multiple agents pushing to the same branch concurrently would cause conflicts and
  non-deterministic push ordering.
- The code-reviewer is best positioned to apply fixes (it reviews code quality);
  security and test reviewers surface findings for human or remediation action.
- The single-pusher invariant is enforced by design (no push code in security/test
  handlers) rather than by a runtime lock.

### 6. Item stays in `code-review` — no transition in the fan-out

`fanoutReviewers` returns without transitioning the item. The `DispatchResult` has no
`newStage` field in the reviewer-fanout branch.

**Why defer the transition:**
- In 19a the reviewer prompts are stubs. There are no severity ratings yet.
- The remediation gate (Session 19c) will decide: if any reviewer finds
  `CHANGES_REQUESTED` findings above a severity threshold, the item transitions to
  `remediation`; otherwise it awaits human merge in `code-review`.
- Deferring keeps the 19a change set small and testable in isolation.

### 7. Cost and duration aggregation

- `costUsd` = **sum** of all reviewer costs. All three ran in parallel and were paid
  for, so the total cost is additive.
- `durationMs` = **max** of reviewer durations. Parallel execution means wall-clock
  time is bounded by the slowest reviewer, not the sum.

---

## Alternatives Considered

### A — Sequential reviewers

Run code → security → test in sequence, each in the same workspace.

**Rejected:** Triples the total review time. With a 10-minute timeout per reviewer,
sequential execution could take up to 30 minutes. Parallel execution is bounded by
the slowest reviewer (~10 minutes).

### B — Agent posts own comments

Give each reviewer agent the GITHUB_TOKEN and let it call `gh pr comment` itself.

**Rejected:** Violates the GITHUB_TOKEN-scrubbing invariant established in ADR-013.
An agent with `bypassPermissions` and a live GITHUB_TOKEN could push to any repo the
token has access to, delete PRs, or take other destructive actions outside the
intended scope.

### C — Three separate dispatch stages

Map `code-review-code`, `code-review-security`, `code-review-test` as distinct stages,
each with its own specialist.

**Rejected:** See "Decision 1" above. This pollutes the state machine with
implementation-detail stages and forces sequential reviewer dispatch.

### D — Store prUrl in ItemState at implementer time

Have the implementer transition store `prUrl` alongside the `code-review` stage change,
then read it from `ItemState` in the reviewer-fanout dispatcher.

**Rejected:** Requires a schema migration, a storage layer change, and introduces a
staleness risk. Querying GitHub at dispatch time costs one API call but is always
correct.

---

## Consequences

### Positive

- **Parallel reviews:** All three reviewers run concurrently; total review time is
  bounded by the slowest reviewer.
- **Isolated workspaces:** Each reviewer gets a fresh shallow clone; no risk of
  cross-reviewer file contamination.
- **Token never in agent env:** GITHUB_TOKEN stays in the orchestrator process;
  `bypassPermissions` agents cannot access it.
- **Single-pusher enforced by design:** Security and test reviewers physically cannot
  push (no push code path, no token).
- **Partial results preserved:** If one reviewer fails, the other two still post their
  comments. Operators get partial review information rather than nothing.

### Trade-offs / Known Limitations

- **19a stub prompts:** The reviewer prompts are minimal stubs that produce a
  `review.md` skeleton. Real structured review prompts (with diff inspection,
  per-kind heuristics, severity ratings) come in 19b.
- **Single code repo assumed:** `fanoutReviewers` uses `product.code_repos[0]`. If a
  product has multiple code repos, only the first is reviewed. Multi-repo support is
  deferred.
- **Orchestrator bears comment-posting failures:** If `postPRComment` fails for one
  reviewer (e.g. GitHub rate limit), that reviewer's result is marked `error` and the
  overall fanout status is `error`. The review content is not retried — it exists only
  in the workspace (which is deleted). Future: consider writing reviews to the
  knowledge repo as a fallback.
- **No transition gate in 19a:** The item stays in `code-review` regardless of review
  findings. Severity-based routing to `remediation` comes in 19c.

---

## Revisit When

- QA gate is activated (Session 19c): needs severity ratings from reviewer output.
- Multiple code repos per product: `fanoutReviewers` needs to accept a `codeRepo`
  parameter or iterate over all repos.
- Reviewer prompts are tuned (19b): this ADR describes the infrastructure; prompt
  quality is a separate concern.

---

## References

- ADR-013: Implementer Execution Foundation — GITHUB_TOKEN scrubbing, workspace
  provisioning, `bypassPermissions` rationale.
- ADR-014: Implementer Self-Verification — single-pusher concept, workspace lifecycle.
- Session 19a implementation: `packages/orchestrator/src/specialists/pr-helpers.ts`,
  `packages/orchestrator/src/specialists/reviewer-fanout.ts`.
