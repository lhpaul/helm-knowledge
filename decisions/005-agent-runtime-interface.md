# ADR-005: IAgentRuntime — uniform interface for AI agent sessions

**Date:** 2026-05-19
**Status:** Accepted
**Context:** Session 9 — Orchestrator mock and dispatch endpoint

---

## Context

Session 9 introduces the `@helm/orchestrator` package, which is responsible for mapping workflow
items to AI specialists (spec-writer, plan-writer, etc.), spawning agent sessions, and handling
post-completion logic (file verification, stage transitions).

Helm is designed to support multiple agent backends over time:

- **v0:** Claude Code CLI spawned as a child process (Session 10)
- **v1+:** Anthropic API streaming, local Ollama, deepseek, etc.

The orchestrator must be testable without a live Claude Code installation or Anthropic API key.
A concrete coupling to Claude Code in the dispatcher would force every unit test to mock at the
process-spawn level, which is fragile and environment-dependent.

---

## Decision

Define `IAgentRuntime` as the single abstraction between the orchestrator and any concrete agent
backend. All specialist invocations go through this interface; the dispatcher never imports
Claude Code SDK, `execa`, or any runtime-specific module directly.

```typescript
interface IAgentRuntime {
  spawn(params: SpawnParams): Promise<AgentSession>;
}

interface AgentSession {
  readonly id: string;
  readonly status: AgentStatus;
  onMessage(handler: (m: AgentMessage) => void): void;
  send(instruction: string): Promise<void>;
  cancel(): Promise<void>;
  wait(): Promise<AgentResult>;
}
```

For v0 (Session 9), the only concrete implementation is `MockAgentRuntime` — a fully
in-memory scriptable runtime that:

1. Accepts a `MockScript` with canned messages, optional outcome override, optional `finalOutput`,
   and an optional `sideEffects` callback that runs against the real filesystem before resolving.
2. Always yields at least one `setTimeout(0)` tick before emitting messages, guaranteeing the
   caller can register `onMessage` handlers after `await spawn()` returns.
3. Supports `cancel()` mid-flight and `send()` (emits a `system`-role message).

The dispatch endpoint (`POST /api/products/:slug/items/:externalId/dispatch`) constructs a
`MockAgentRuntime` inline (v0 behaviour). Session 10 swaps this for `ClaudeCodeRuntime` without
touching the dispatcher or specialist logic.

---

## Consequences

**Positive:**
- Dispatcher and specialist tests run in < 50 ms with zero external dependencies.
- `sideEffects` callback lets mock tests exercise the full post-completion file-verification
  path (`handleSpecWriterResult`) against real temp directories.
- Swapping in `ClaudeCodeRuntime` in Session 10 requires no changes to `dispatchStageHandler`
  or any specialist.
- The interface is backend-agnostic: the same `IAgentRuntime` contract works for Claude Code,
  Anthropic API streaming, or any future model provider.

**Negative / trade-offs:**
- `onMessage` uses a push-based callback rather than `AsyncIterator`. This means the runtime
  must buffer or replay messages if a handler is registered after messages are already emitted.
  `MockAgentRuntime` handles this via the always-yield guarantee; real runtimes must implement
  their own buffering strategy.
- `send()` is a best-effort mid-flight injection. The mock echoes instructions as `system`
  messages; real runtimes may or may not support mid-flight input (Claude Code does via stdin).
- `wait()` returns a single `AgentResult` with no way to stream the output to the caller.
  Callers that need streaming must use `onMessage`. This is intentional — `wait()` is the
  simple path for specialists that only care about the terminal state.

---

## Alternatives considered

**1. Concrete `ClaudeCodeRuntime` from day one**
Rejected: would require a live Claude Code installation and ANTHROPIC_API_KEY in every test run,
making CI environment-dependent and expensive.

**2. `AsyncIterator<AgentMessage>` instead of callback**
Rejected: iterators are pull-based, which makes it awkward to multiplex a single stream to
multiple consumers and to handle mid-flight `send()`. The callback model also allows buffering
messages before any consumer attaches.

**3. Single `run()` function returning `Promise<AgentResult>` (no streaming)**
Rejected: specialists like the future code-reviewer need to inspect intermediate messages
(e.g., to detect early failure and cancel). The session object keeps this extensible without
breaking existing call sites.
