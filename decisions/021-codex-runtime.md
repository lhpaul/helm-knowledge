# ADR-021: CodexRuntime — Codex CLI as a sibling agent runtime

**Date:** 2026-05-29
**Status:** Accepted
**Context:** Session H1 — Codex runtime

---

## Context

Anthropic announced that one-shot headless `claude -p "…"` runs — the mode Helm's
`ClaudeCodeRuntime` uses (ADR-007) — are no longer covered by the Claude
subscription and are billed per API credit. Helm fans out ~5–10 agent spawns per
item (spec → plan → implementer → 3 reviewers → possible remediation), so at API
prices the marginal cost per item climbs fast.

The architecture anticipated this. `IAgentRuntime` (ADR-005) is deliberately
runtime-agnostic, and `SpecialistSchema.runtime` always carried a comment noting it
would be "extended to deepseek | anthropic_api | ollama in v1+". This session cashes
that cheque, starting with the **OpenAI Codex CLI**, which runs headless against a
ChatGPT subscription and therefore leaves the marginal cost at ~$0.

`CodexRuntime` is added as a **structural sibling** of `ClaudeCodeRuntime`. Claude
Code is not altered (beyond extracting shared subprocess helpers); both runtimes
coexist and each product selects one via `product.yaml`.

---

## Discovery — Codex CLI v0.133.0 (captured 2026-05-29)

Before implementing, the CLI was probed on a Mac with `codex` installed and logged
in via ChatGPT. Findings (also recorded in the header of `codex.ts`):

1. **Headless command.** `codex exec [PROMPT]` (alias `codex e`) is the
   non-interactive mode — the equivalent of Claude Code's `--print -p`.
2. **Auth.** `codex login status` → "Logged in using ChatGPT". The token lives on
   disk at `~/.codex/auth.json` (`CODEX_HOME`), not in an env var.
3. **Streaming format.** `--json` emits one JSON object per line (JSONL) on stdout.
   Observed event types:
   - `{"type":"thread.started","thread_id":"…"}` — informational
   - `{"type":"turn.started"}` — informational
   - `{"type":"item.started","item":{…}}` — an item begins
   - `{"type":"item.completed","item":{…}}` — an item finished
   - `{"type":"turn.completed","usage":{input_tokens,…}}` — **terminal success**
   - `{"type":"turn.failed","error":{"message":"…"}}` — **terminal error**
   - `{"type":"error","message":"…"}` — error detail (non-terminal)

   Item types acted on:
   - `{id,type:"agent_message",text}` → mapped to `role:'agent'`
   - `{id,type:"command_execution",command,exit_code,status}` → `role:'tool'`

   stderr carries non-JSON noise (`Reading additional input from stdin…`, an MCP
   transport `TokenRefreshFailed` warning from the user's local config, and
   `Shell cwd was reset …`). stdout is pure JSONL.
4. **Exit code is unreliable.** `codex exec` exits `0` even on a failed turn
   (confirmed with an invalid `--model`). The verdict therefore comes from the
   terminal event (`turn.completed` vs `turn.failed`), never the exit code.
5. **Permission / approval model — the critical finding.** `codex exec` is fully
   non-interactive: there are **no approval prompts**. Under
   `-s/--sandbox workspace-write` the agent autonomously ran `printf … > file`,
   `ls`, and `git status` with no prompt. This means the implementer (which must
   run bash) works without any interactive approval, so **no specialist needs to
   be excluded** — the scope-reduction escape hatch in the session brief was not
   triggered.
6. **Cost reporting.** The output reports token usage only
   (`turn.completed.usage`); no USD figure is emitted for subscription runs.
7. **Credential env vars.** Extracted from the native binary:
   `OPENAI_API_KEY`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN` (plus org/project
   identifiers). These are the env-borne credentials to scrub.

---

## Decisions

### 1. Execution mode: one-shot `codex exec --json`

Mirrors ADR-007's one-shot decision. Spec/plan/review/implementer prompts contain
everything the agent needs; mid-flight steering is out of scope. `--json` gives a
structured stream we parse line-by-line exactly like `ClaudeCodeSession`.
`--skip-git-repo-check` is passed so non-git workdirs (e.g. a spec workspace) don't
abort. `AgentSession.send()` throws in one-shot mode, same as Claude Code.

### 2. Permission mapping (`permissionMode` → sandbox flag)

| `SpawnParams.permissionMode` | Codex flag | Rationale |
|------|------|------|
| `acceptEdits` (default) | `--sandbox workspace-write` | Writes scoped to the workspace; commands run sandboxed but with **no** interactive prompts. Minimum viable set for file-writing specialists. |
| `bypassPermissions` | `--dangerously-bypass-approvals-and-sandbox` | Full access, no sandbox — needed by the implementer to run builds/tests/git. Equivalent to Claude Code's `bypassPermissions`. |

Because `codex exec` never prompts, the practical difference from Claude Code is
that Codex enforces a sandbox boundary rather than a per-tool approval gate. The
two `permissionMode` values map cleanly onto the two relevant sandbox postures.

### 3. Success determination: terminal turn event, not exit code

`turn.completed` → `status:'done'`; `turn.failed` → `status:'error'` (with the
error message in `finalOutput`). If the process exits with no terminal event, the
runtime settles `error` and includes captured stderr for diagnostics. As in
ADR-007, the runtime reports only hard protocol failure — whether the *task*
succeeded (artifact exists) remains the specialist handler's concern.

### 4. Cost: `totalCostUsd: 0` means "subscription-covered"

Subscription runs emit no USD figure, so `AgentResult.totalCostUsd` is `0`. This is
documented explicitly in code and here: **zero means the run was covered by the
ChatGPT subscription, not that it was free in absolute terms.** Token usage from
`turn.completed.usage` is not currently surfaced (the `AgentResult` contract has no
field for it); a cost/usage table is out of scope for H1 (bloque D).

### 5. Credential scrubbing + shared `_env.ts`

`OPENAI_API_KEY`, `CODEX_API_KEY`, and `CODEX_ACCESS_TOKEN` are scrubbed from the
subprocess env, alongside the `GITHUB_TOKEN`/`GH_TOKEN` already stripped by
`ClaudeCodeRuntime`. Stripping the OpenAI keys (a) prevents a compromised agent from
exfiltrating them via a tool call and (b) forces Codex to use on-disk subscription
auth rather than metered API billing — which is the entire point. The on-disk token
(`CODEX_HOME` → `auth.json`) is intentionally **not** scrubbed; it is how
subscription auth works.

To avoid duplicating the spawn/scrub logic, `buildSubprocessEnv`, `SubprocessLike`,
`SpawnFn`, and `defaultSpawn` were extracted from `claude-code.ts` into
`runtimes/_env.ts`. `buildSubprocessEnv` now takes a parameterized scrub-key list
(default = git tokens). `claude-code.ts` re-exports them for backward compatibility,
so no test or import outside the runtimes folder changed.

### 6. Runtime selection is per-product (H1 constraint)

The dispatcher creates **one** runtime per dispatch via
`createRuntimeForProduct`, reading `specialists.spec_writer.runtime` as the
product-wide selector, and reuses it for every specialist. For H1, this means all
specialists in a product must share the same runtime (all `claude_code` or all
`codex`). A hybrid setup (e.g. `claude_code` spec-writer + `codex` implementer)
would require moving runtime creation to per-spawn — **deferred to H3.** The schema
enum permits mixing, but the factory wiring does not exercise it yet; this is
documented in both the factory and here.

---

## Consequences

**Positive:**
- A product can switch to ~$0 marginal-cost runs by flipping `runtime: codex` in
  `product.yaml`; no other change required (`IAgentRuntime` working as designed).
- `CodexRuntime` tests are fixture-backed (no real `codex` binary, no network) and
  run alongside the existing Claude Code suite.
- The implementer is supported on Codex — discovery confirmed bash runs without
  interactive approval, so the feared scope reduction did not materialize.

**Negative / trade-offs:**
- One-shot mode means no mid-flight steering (same as ADR-007).
- `CodexRuntime` requires the Bun runtime (shares `defaultSpawn`); the `SpawnFn`
  injection point keeps it testable and leaves room for non-Bun backends.
- No per-run USD cost is available for subscription runs, so cost dashboards can't
  attribute spend to Codex items yet (deferred).
- Per-product (not per-specialist) runtime selection limits H1 to homogeneous
  products; hybrid runtimes wait for H3.
- The sandbox boundary differs from Claude Code's per-tool approval model. Under
  `workspace-write`, network access and writes outside the workspace are blocked,
  which may surface as task failures for specialists that expect broader access;
  such specialists should run with `bypassPermissions`.

---

## Alternatives considered

1. **Stay on `ClaudeCodeRuntime` and absorb the metered API cost.** Rejected: Helm
   fans out ~5–10 spawns per item, so at per-credit API prices the marginal cost
   per item climbs fast — eliminating that cost is the entire motivation. Claude
   Code remains available as a sibling for products that prefer it.

2. **Build a raw Anthropic/OpenAI/DeepSeek API runtime instead of wrapping a CLI.**
   Rejected for H1: a raw-API runtime must implement its own tool-use loop
   (read/edit/bash dispatch, turn management), which is a large surface and would
   not use the ChatGPT subscription. The Codex CLI already ships that loop and
   authenticates headless against the subscription, so wrapping it is far cheaper
   to build and operate. Raw-API runtimes are deferred (see Out of scope).

3. **Extend `ClaudeCodeRuntime` to multiplex several backends.** Rejected:
   `IAgentRuntime` (ADR-005) is already runtime-agnostic, so a structural sibling
   class keeps Claude Code untouched (beyond the `_env.ts` extract), avoids a
   conditional-laden god-class, and lets each product select one runtime cleanly.

4. **Per-specialist (hybrid) runtime selection now** — e.g. `claude_code` spec-writer
   + `codex` implementer. Rejected for H1: the dispatcher creates one runtime per
   dispatch, so hybrid selection requires moving runtime creation to per-spawn.
   Deferred to H3; the schema rejects mixed runtimes in the meantime.

5. **Wait for `AiderRuntime` (H2) instead of Codex.** Rejected: Codex runs headless
   against an existing subscription today with no extra credentials, and discovery
   confirmed the implementer works under `codex exec` without interactive approval,
   so there was no reason to block on Aider.

---

## Revisit when

- Anthropic restores subscription coverage for headless `claude -p` runs — the cost
  driver behind this ADR disappears and Claude Code may become the default again.
- A specialist needs mid-flight steering: one-shot `codex exec` cannot supply it
  (same limitation as ADR-007), so a session/REPL mode would need designing.
- Hybrid per-specialist runtimes are required (H3): revisit the per-product factory
  constraint and the schema's mixed-runtime rejection.
- The Codex CLI changes its JSONL event schema, terminal-event names, or exit-code
  semantics — the parser relies on `turn.completed`/`turn.failed` and ignores the
  exit code (see Discovery, captured at v0.133.0).
- A non-Bun deployment target is needed: `defaultSpawn` depends on `Bun.spawn`; the
  `SpawnFn` injection point exists to swap it, but no alternative backend is wired.

---

## Out of scope (this session)

- AiderRuntime (H2); hybrid per-specialist runtime (H3); raw-API runtimes
  (DeepSeek/Anthropic/OpenAI API, which need an internal tool-use loop); cost
  tracking UI / pricing tables (bloque D). No changes to specialists, dispatcher,
  state machine, or adapters beyond the factory routing and the `_env.ts` extract.

---

## References

- ADR-005 — `IAgentRuntime` interface (runtime-agnostic contract).
- ADR-007 — `ClaudeCodeRuntime` (the structural mirror; one-shot mode, permission
  modes, artifact-existence success determination).
