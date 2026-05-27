# ADR-014: Implementer Self-Verification and Provisioning-Before-Transition

**Date:** 2026-05-27
**Status:** Accepted
**Supersedes:** —
**Related:** ADR-013 (Implementer Execution Foundation)

---

## Context

Session 16a (ADR-013) established the implementer specialist: it fetches the approved
plan, transitions `plan-ready → in-development`, shallow-clones the code repo, spawns a
Claude Code agent with `bypassPermissions`, commits the result, and opens a PR.

Two issues emerged during hardening review:

### Issue A — Transition order

The original implementation transitioned `plan-ready → in-development` **before**
provisioning the code workspace (clone + branch). If the clone failed due to a network
error or bad credentials, the item was left in `in-development` with no running agent and
no workspace. `in-development` has no specialist mapping, so the item could not be
re-dispatched without manual intervention.

### Issue B — No verification of code quality

The implementer agent produced code but was not instructed to verify it. There was no
guarantee that the implementation compiled, passed tests, or satisfied lint rules before
the orchestrator opened the PR. A reviewer would discover broken code only after reading
the PR — wasting review cycles.

---

## Decision

### A — Provision before transition

**The dispatcher now runs `provisionCodeWorkspace` before calling `transition`.**

```
BEFORE (16a):
  1. fetchPlan          (hard error if null)
  2. fetchContext       (best-effort)
  3. transition → in-development   ← fires here
  4. provisionCodeWorkspace        ← clone may fail

AFTER (16b):
  1. fetchPlan          (hard error if null)
  2. fetchContext       (best-effort)
  3. provisionCodeWorkspace        ← clone first
  4. transition → in-development   ← fires only on clone success
```

The `plan-ready → in-development` transition still fires **before the agent is spawned**
(after a successful clone), preserving the "work in progress" signal for downstream
observers.

All steps after provisioning run inside a `try/finally` block that cleans up the
workspace directory in every outcome, including a transition failure.

**Consequence accepted:** if provisioning succeeds but the `in-development` transition
subsequently fails (store unavailable, network error), the workspace is cleaned up and
the item stays in `plan-ready`. The next dispatch attempt will re-clone — a wasted
clone, but no stuck state.

### B — Auto-verification by prompt (deferral of orchestrator gate)

**We instruct the agent to self-verify via its prompt rather than building a gate in the
orchestrator.**

`buildImplementerPrompt` now includes a mandatory verification section:

1. **Locate** test and lint commands by reading `AGENT.md`, `CLAUDE.md`, `README.md`,
   `package.json` scripts, or `Makefile`.
2. **Run** the tests and linter.
3. **Fix** any failures introduced by the implementation (pre-existing failures need not
   be fixed, but must be distinguished and documented).
4. **Repeat** until the agent's own changes pass.
5. **Report explicitly** if green state is unachievable — what is failing, whether it
   is pre-existing, what was attempted. Do NOT claim success with failing tests.

The orchestrator does **not** run tests or lint independently after the agent finishes.
It checks only that `git status` is non-empty (the agent made file changes) before
committing and opening the PR.

#### Why prompt-only verification?

| Concern | Assessment |
|---------|-----------|
| An orchestrator gate would need to know *which* commands to run | Each repo has different commands; this knowledge lives in the repo itself (README, AGENT.md). The agent can discover it; the orchestrator cannot without scraping the same files. |
| Running tests in the orchestrator adds I/O overhead and coupling | The agent already has shell access (`bypassPermissions`) and the cloned workspace. Running a second shell subprocess from the orchestrator for the same workspace creates race conditions and adds latency. |
| The agent may claim success falsely | Accepted limitation. A future hardening session can add an orchestrator-level test-run gate (see below). |
| Test failures may be pre-existing | The agent is instructed to distinguish pre-existing failures and document them. Reviewers see this in the PR summary. |

#### Deferral — orchestrator-level verification gate

Building a gate in the orchestrator (parse `package.json`, run the test command, parse
the output, decide pass/fail) is **deferred to a future session**. The accepted
limitation is that a misbehaving agent that claims success despite failing tests will
open a PR with broken code; reviewers catch it during code review.

This deferral is intentional and explicitly recorded here so future sessions have the
context to pick it up.

---

## Alternatives considered

### A1 — Keep transition before provisioning, add re-dispatch support for in-development

Add `in-development` to the `STAGE_TO_SPECIALIST` mapping so stuck items can be
re-dispatched. Rejected: re-dispatching `in-development` is semantically wrong (the
specialist should only enter from `plan-ready`); it would require either a new code path
or re-using the implementer with ambiguous semantics.

### A2 — Manual recovery only

Document that provision failures require manual reset. Rejected: operational burden is
high; the fix (swap two blocks) is trivial and has no downside.

### B1 — Orchestrator-level test gate (immediate)

Run tests from the orchestrator after the agent finishes, before opening the PR.
Rejected for this session because: it requires per-repo command discovery, adds timeout
complexity, and the incremental value over the prompt instruction is modest given that
reviewers see the PR diff anyway. Deferred, not rejected permanently.

### B2 — No verification at all

Leave verification entirely to PR reviewers. Rejected: this shifts avoidable rework to
human reviewers; the prompt instruction is zero cost and catches the most common case.

---

## Consequences

- Items no longer get stuck in `in-development` due to clone failures.
- PRs opened by the implementer are expected to have passing tests and clean lint,
  based on the agent's self-report. Reviewers should treat test status as agent-reported,
  not orchestrator-verified.
- The orchestrator-level verification gate remains a future improvement item.
- `IMPLEMENTER_TIMEOUT_MS` is raised from 15 to 20 minutes to accommodate test runs
  within the implementation phase. Exported as a named constant so callers can override
  it per product if needed.
