# ADR-007: ClaudeCodeRuntime — subprocess-based agent execution

**Date:** 2026-05-20
**Status:** Accepted
**Context:** Session 10 — ClaudeCodeRuntime real

---

## Context

Session 9 introduced `IAgentRuntime` and `MockAgentRuntime` to decouple the
dispatcher and spec-writer specialist from any concrete execution backend. Session 10
implements the first real backend: **Claude Code CLI** running in headless mode.

Before building, two real transcripts were captured and analysed
(`write-success.jsonl` and `permission-denied.jsonl`). They revealed three
critical design constraints documented below.

---

## Decisions

### 1. Permission mode: `--permission-mode acceptEdits`

**Options considered:**

| Flag | What it allows | Risk |
|------|---------------|------|
| `permissionMode: default` (no flag) | Nothing without user confirmation | Unusable in headless mode — all file writes are denied |
| `--permission-mode acceptEdits` | Auto-accepts Write/Edit/Create file ops; still prompts for Bash | Minimal surface: spec-writer only writes files |
| `--permission-mode bypassPermissions` | Accepts everything including arbitrary Bash | Larger attack surface; appropriate for trusted dev environments only |
| `--dangerously-skip-permissions` | Same as bypass + suppresses warnings | Explicitly unsafe flag; signals wrong intent for production |

**Decision:** `--permission-mode acceptEdits`.

The spec-writer specialist only needs to create and write markdown files. Accepting
file edits without also granting arbitrary Bash execution is the minimum viable
permission set that lets the specialist complete its task while limiting the blast
radius if a prompt-injection attack were to craft malicious tool calls.

The permission-denied transcript (`permission-denied.jsonl`) was captured with
`permissionMode: default` and shows the exact failure mode we must avoid: the Write
tool call is blocked, the agent reports the failure, and the session ends with
`permission_denials: [{tool_name: "Write", ...}]` in the result.

---

### 2. Execution mode: one-shot `--print -p` (not interactive)

**Options considered:**

- **One-shot `--print -p`**: sends the full prompt once, waits for the agent to
  complete, collects output via `--output-format stream-json --verbose`. Simple,
  stateless, easy to kill/timeout.
- **Interactive mode with file-polling** (agent-hq style): opens a persistent
  session, writes instructions to a file, polls for responses. Supports mid-flight
  corrections and multi-turn interactions.

**Decision:** One-shot `--print -p` for v0.

Spec-writing is a single-shot task: the prompt contains everything the agent needs
(product context, item id, workdir, output format). There is no need for mid-flight
steering in the first implementation. One-shot mode is simpler to implement, test,
and reason about. `AgentSession.send()` throws a clear error in one-shot mode;
interactive mode is deferred to a future session and noted in the interface contract.

---

### 3. Success determination: `permission_denials`, not `result.subtype`

**Critical finding from fixtures:**

The `result` line (last line of stdout) has identical shape in both the success and
permission-denied transcripts:

```jsonl
// write-success.jsonl — actual success
{"type":"result","subtype":"success","is_error":false,...,"permission_denials":[],...}

// permission-denied.jsonl — permission blocked (agent could not write the file)
{"type":"result","subtype":"success","is_error":false,...,"permission_denials":[{...}],...}
```

Both show `subtype: "success"` and `is_error: false`. **These fields cannot be used
to determine whether the specialist's task actually succeeded.**

**Decision:** success requires all of:

1. `result.is_error === false` — no API-level error
2. `result.permission_denials.length === 0` — no tool calls were blocked
3. The output artifact exists on disk — verified by `handleSpecWriterResult` via `fs.access(specPath)`

The third check was already in place from Session 9. This ADR adds the
`permission_denials` check as an additional layer in `ClaudeCodeRuntime`'s result
handler, so the runtime itself reports `status: 'error'` when permissions are denied
rather than returning a misleading `'done'` that causes `handleSpecWriterResult` to
fail on the filesystem check.

---

### 4. Cost source: `result.total_cost_usd`

The `result` line includes `total_cost_usd` which is the authoritative cost figure
computed by the Claude Code CLI after all turns. We use this value directly as
`AgentResult.totalCostUsd` without replicating per-model pricing tables in Helm.

---

## Consequences

**Positive:**
- Helm can orchestrate real Claude Code runs end-to-end without any changes to the
  dispatcher or spec-writer specialist — the `IAgentRuntime` interface is working as
  designed.
- `ClaudeCodeRuntime` tests run in < 20 ms (fixture-backed, no network calls, no
  real subprocess).
- The `acceptEdits` permission mode is auditable: the `permission_denials` array in
  the result reveals exactly which tool calls were blocked if the flag is misconfigured.

**Negative / trade-offs:**
- One-shot mode means the agent cannot be steered after the initial prompt. Complex
  multi-step workflows (e.g., iterative plan refinement) will require interactive mode
  in a future session.
- `ClaudeCodeRuntime` requires the Bun runtime — it is not portable to Node. The
  `SpawnFn` injection point allows future runtimes (Anthropic API direct, Ollama) to
  implement the same `IAgentRuntime` interface without Bun.
- `--permission-mode acceptEdits` does not prevent the agent from reading arbitrary
  files in the workdir. This is acceptable because the workdir is scoped to a single
  item (`data/worktrees/{slug}/{externalId}`).

---

## Alternatives not pursued

**Anthropic API direct (without Claude Code CLI):** Would avoid the subprocess overhead
and give finer control over the model invocation. Deferred because Claude Code CLI
provides a richer tool ecosystem (Read, Write, Edit, Grep, etc.) that the spec-writer
uses, and because the `IAgentRuntime` interface allows swapping in an API-direct runtime
later without touching specialist or dispatcher code.
