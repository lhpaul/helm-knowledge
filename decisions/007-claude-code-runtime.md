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

### 3. Success determination: artifact existence, not `permission_denials`

**Original fixture analysis (pre-smoke-test):**

Before the first real end-to-end run, fixture analysis suggested using
`permission_denials.length === 0` as a runtime-level success signal, because both the
success and permission-denied transcripts show `subtype:"success"` and `is_error:false`:

```jsonl
// write-success.jsonl
{"type":"result","subtype":"success","is_error":false,...,"permission_denials":[],...}

// permission-denied.jsonl (captured with permissionMode:default)
{"type":"result","subtype":"success","is_error":false,...,"permission_denials":[{...}],...}
```

**Correction from Session 10 smoke test:**

The first real end-to-end dispatch (Session 10, cost $0.0619) refuted the
`permission_denials` rule. The agent received a denial on one tool call yet completed
the task by routing around it — the spec file was written successfully and the
`permission_denials` array was non-empty. Treating non-empty `permission_denials` as
`status:'error'` would have reported a false failure.

**Decision (revised):**

| Signal | Layer | Meaning |
|--------|-------|---------|
| `result.is_error === true` | `ClaudeCodeRuntime` | Hard protocol/API error — always `status:'error'` |
| `result.permission_denials.length > 0` | `ClaudeCodeRuntime` | Diagnostic only — appended to `finalOutput` as `[note] N permission denial(s)...`; does **not** affect `status` |
| Artifact exists on disk | `handleSpecWriterResult` | **Ground truth** — `fs.access(specPath)` is the only success criterion for the spec-writer task |

The specialist handler already checked artifact existence (Session 9). The runtime's
role is limited to reporting hard protocol failures (`is_error`) and surfacing
diagnostic information (`permission_denials` → `finalOutput`). Whether the task
_succeeded_ is the specialist's concern, not the runtime's.

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
  the result is surfaced in `finalOutput` so operators can diagnose misconfigured
  permissions without the runtime crying wolf on tasks that still completed.
- The smoke test (Session 10) confirmed a real end-to-end dispatch: cost $0.0619,
  transition `discovery → spec-draft`, spec file written on disk.

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
- **Synchronous dispatch blocks the HTTP connection** for the full agent run duration.
  Bun's default `idleTimeout` (10 s) was raised to 255 s as a stopgap. Agent runs that
  exceed 255 s will still time out the connection. Proper fix: async dispatch with a
  job id + poll or WebSocket; tracked for Session 11.
- **Prompt does not inject product context.** In the Session 10 smoke test the agent
  confused "Helm Playground" (the product) with Helm (the Kubernetes package manager)
  and wrote a spec for the wrong domain. The spec-writer prompt needs to inject product
  context (product YAML, README, AGENT.md from the knowledge repo) before writing.
  Tracked as a follow-up for a future session — see "Follow-ups" below.

---

## Follow-ups

### Session 11: async dispatch (job id + poll/WebSocket)

The current synchronous dispatch holds the HTTP connection open for the entire agent
run. `idleTimeout: 255` is a stopgap; runs exceeding 255 s will disconnect. The
correct architecture:

1. `POST /dispatch` enqueues a job and immediately returns `202 Accepted` with a job id.
2. Client polls `GET /jobs/:id` (or subscribes via WebSocket) for status.
3. The agent runs in a background worker, no HTTP timeout pressure.

### Session 11+: inject product context into the spec-writer prompt

The Session 10 smoke test revealed that the current prompt lacks product context. The
agent confused "Helm Playground" with the Helm Kubernetes tool. Before writing a spec
the prompt should inject:

- `product.yaml` — product slug, name, workflow
- `README.md` from the product's knowledge repo
- `AGENT.md` from the knowledge repo (if present) — domain-specific guidance

This requires the spec-writer to load files from the knowledge repo checkout before
composing the Claude Code prompt.

---

## Alternatives not pursued

**Anthropic API direct (without Claude Code CLI):** Would avoid the subprocess overhead
and give finer control over the model invocation. Deferred because Claude Code CLI
provides a richer tool ecosystem (Read, Write, Edit, Grep, etc.) that the spec-writer
uses, and because the `IAgentRuntime` interface allows swapping in an API-direct runtime
later without touching specialist or dispatcher code.
