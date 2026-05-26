# ADR-013: Implementer Execution Foundation

**Status:** Accepted  
**Date:** 2026-05-26  
**Session:** 16a

---

## Context

After the plan-writer specialist publishes an approved plan to the knowledge repo and the plan PR is merged, the item transitions to `plan-ready`. The next step in the Helm workflow is to actually implement the changes: write production code, tests, and any supporting files, then open a code review PR.

This ADR documents the foundational design decisions for the implementer specialist — the component that bridges the `plan-ready → code-review` workflow gap.

---

## Decisions

### 1. Two-phase transition: `plan-ready → in-development → code-review`

The implementer performs two item transitions, not one:

1. **`plan-ready → in-development`** before the agent starts — signals that work has begun so that duplicate webhook deliveries or re-dispatch attempts see the item has already moved.
2. **`in-development → code-review`** after the PR is opened — gates on a successful PR existing before advancing the item.

**Alternatives considered:**
- **Single transition on completion** — risks losing the "work in progress" signal if the implementation takes a long time and an operator inspects the board.
- **Three phases with a `pr-open` intermediate stage** — over-engineered for v0; `code-review` already implies a PR is open.

### 2. Shallow clone (`--depth 1`) into isolated temp directory

The implementer shallow-clones the product's primary code repo (`code_repos[0]`) into `os.tmpdir()/helm-impl-{externalId}-{uuid}`. The dispatcher always deletes this directory in a `finally` block.

**Rationale:**
- Full history is not needed for code generation.
- `--depth 1` cuts clone time from seconds to sub-second on typical repos.
- UUID in the path ensures parallel runs for the same item don't collide.

### 3. Agent runs with `bypassPermissions`

The implementer uses `permissionMode: 'bypassPermissions'` when spawning the Claude Code agent. Spec-writer and plan-writer use `acceptEdits` (file writes allowed, Bash blocked).

**Rationale:** An implementer needs to run tests (`npm test`, `cargo test`, etc.), install dependencies, and execute build commands to verify its own output. `acceptEdits` would block every shell call, making the agent unable to verify code it just wrote.

**Security mitigation:** GITHUB_TOKEN and GH_TOKEN are scrubbed from the subprocess environment (see decision 4). The agent cannot use the host token to push branches or access private resources directly.

### 4. GITHUB_TOKEN scrubbed from agent subprocess env

`buildSubprocessEnv()` in `ClaudeCodeRuntime` builds the subprocess environment from `process.env`, deletes `GITHUB_TOKEN` and `GH_TOKEN`, then merges any caller-provided extras. All `spawn()` calls now receive this sanitized env.

**Why this matters:** The orchestrator holds the GitHub token to clone the repo and open PRs. If the token were present in the subprocess env, a compromised agent could push to arbitrary repositories via `git` tool calls, read private package registry credentials, or exfiltrate the token via `curl`.

**Token lifecycle:**
- Token → orchestrator only
- Orchestrator → `provisionCodeWorkspace` (clone + branch)
- Orchestrator → `openCodePR` (stage + commit + push + PR)
- Agent subprocess → no token

### 5. `git-helpers.ts` — shared auth/sanitization module

`buildAuthenticatedUrl`, `sanitizeToken`, `RunGit`, `RunGh`, `defaultRunGit`, `defaultRunGh` were extracted from `spec-publisher.ts` into a new `git-helpers.ts` module. `spec-publisher.ts` re-exports the types for backward compatibility.

**Why now:** `code-workspace.ts` needed the same token-embedding and sanitization logic. Duplicating it would risk divergence. Extracting to a shared module is the minimal-duplication choice.

### 6. `provisionCodeWorkspace` + `openCodePR` as separate functions

The workspace provisioning (clone + branch) and PR opening (stage + commit + push + PR) are two distinct functions with different lifetimes:

- `provisionCodeWorkspace` runs before the agent; its output is the workspace path the agent receives as `workdir`.
- `openCodePR` runs after the agent finishes, operates on the same workspace path, and is responsible for committing whatever the agent wrote.

**Alternative: single function wrapping both + agent spawn** — rejected because it would prevent the dispatcher from inserting the agent invocation between them, and would make each step harder to test independently.

### 7. 15-minute timeout for the implementer

`buildImplementerParams` sets `timeoutMs: 15 * 60 * 1000` (15 min), overriding the runtime-level 5-minute default. Implementations (especially with test runs) realistically take 5–15 minutes.

The `SpawnParams.timeoutMs` override introduced in Session 16a makes this per-spawn rather than requiring a separate `ClaudeCodeRuntime` instance.

### 8. `IMPL_BRANCH_PREFIX = 'helm/impl/'` in `@helm/shared`

Implementation branches follow the same naming convention as spec and plan branches. `implBranchName(externalId)` returns `helm/impl/{externalId}`. This prefix is *not* added to `parseArtifactBranch` — implementation branches live in the code repo, not the knowledge repo, so there is no webhook-based merge detection yet.

---

## Consequences

**Positive:**
- The full `plan-ready → in-development → code-review` transition chain is automated.
- Token isolation prevents a compromised agent from pushing to arbitrary repos.
- Per-spawn `permissionMode` and `timeoutMs` allow different specialists to have different runtime characteristics without needing separate runtime instances.
- Shared `git-helpers.ts` eliminates token-handling duplication between the publisher and workspace provisioner.

**Negative / Open Questions:**
- Shallow clone depth: if the agent needs to read git history (e.g., for blame or rebase), `--depth 1` will fail. This is acceptable for v0 (agents are expected to read files, not git history).
- `git add -A` stages everything, including generated files that may not belong in the PR (e.g., `node_modules` if `.gitignore` is misconfigured). This is the repository's responsibility to guard against via `.gitignore`.
- The implementer transition to `in-development` happens before the workspace is provisioned. A clone failure leaves the item stuck in `in-development` until manual intervention. A remediation/rollback mechanism is tracked for a future session.
