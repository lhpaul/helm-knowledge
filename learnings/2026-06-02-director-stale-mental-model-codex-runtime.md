---
title: "Director stale mental model on CodexRuntime — caught by helm-session-driver intake protocol"
category: "workflow-process"
date: "2026-06-02"
source:
  type: "session"
  ref: "Codex CLI 0.136.x runtime update session (helm#41 + helm-knowledge#30 / ADR-028)"
tags: ["pilot", "session-brief", "intake-protocol", "meta", "codex-runtime", "director"]
---

# Director stale mental model on CodexRuntime — caught by helm-session-driver intake protocol

## Context

The Arriendo Fácil pilot was blocked at LEA-109 (Better Auth setup). The
implementer dispatch had failed turn 1 under Codex CLI 0.133.0 with
`image_generation_user_error: gpt-image-2 does not exist`. After the
operator upgraded Codex CLI to 0.136.0 (which fixed that bug), a smoke
test against the new CLI revealed that the **CLI surface had changed**:
the `--print` flag was removed, replaced by a `codex exec` subcommand;
`-p` no longer meant prompt; `--output-format stream-json` had become
`--json`.

The director wrote a Helm session brief titled
`sesion-codex-cli-0136-runtime-update.md` whose central premise was
that Helm's `CodexRuntime` still used the old
`codex --print -p "<prompt>" --output-format stream-json --verbose`
shape, and that LEA-109's dispatch was now failing because of the CLI
breaking change. The brief proposed a migration to the new subcommand
shape, with mapping tables, ADR template, and an "image-generation bug
is fixed; CLI needs migration" framing.

**That premise was wrong.** The migration to `codex exec --json` had
already landed in **ADR-021** back in May 2026, during the original
CodexRuntime session (H1). The current code at
`packages/orchestrator/src/runtimes/codex.ts:355-369` already built
`['codex', 'exec', '--json', '--skip-git-repo-check', ...]` with the
prompt as a positional argument. There was no `--print` to migrate
away from. The director never verified by reading the file before
writing the brief; the assumption came from extrapolating
[`agent-hq`](https://github.com/mome-cl/agent-hq)'s Claude CLI pattern
(`claude --print -p {prompt}`) to Helm's Codex runtime without
checking.

## Learning

The Helm coder, following the **intake protocol** in
`helm-session-driver.md` ("read the code first, form a mental model of
the current state"), opened `codex.ts` before writing anything and
immediately surfaced the contradiction. They paused the session and
reported back with:

- Direct quote of the existing argv builder showing it was already on
  `codex exec --json`.
- A smoke test against the live 0.136.0 binary confirming the JSONL
  schema is byte-compatible with the checked-in fixtures.
- A re-scoped proposal that turned the session into a **hardening
  pass** (apply `-C <workdir>` for the cwd-resolution quirk, switch
  prompt to stdin to dodge ARG_MAX) and **explicitly rejected** a
  third proposed delta — unconditional `--dangerously-bypass-…` —
  because it would have regressed ADR-021's deliberate permission
  mapping.

Result: instead of shipping a regression (rewriting working code, then
breaking the safety mapping), the session shipped **ADR-028 +
helm#41**, a clean hardening pass with two real improvements and an
honest record of the misdiagnosis.

The mechanism that caught this was not a reviewer, not a test, and not
Haystack. It was a worker following its intake protocol against a bad
brief. The intake protocol is therefore a **first-class safety net**,
not just a documentation step.

## Why it matters

This is a different failure class from the three evidence points
documented in earlier AF pilot retros:

| Evidence point | Where the gap is | Caught by |
| -------------- | ---------------- | --------- |
| EP#1 (LEA-105) | Plan-writer omits canonical-doc invariants | Operator cross-check |
| EP#2 (LEA-105) | Code-reviewer misses additive drift | Haystack |
| EP#3 (LEA-109) | Plan-writer worktree lacks `CLAUDE.md` | Plan-writer's own Risks section |
| **EP#4 (LEA-109)** | **Director-side stale mental model in the session brief** | **Coder intake protocol** |

EP#1–EP#3 are all about agents (or their workspaces) missing
information. EP#4 is about the **director**: the person writing the
session brief based on outdated assumptions about Helm's internals.
The earlier evidence points motivate sharpening the agents; EP#4
motivates sharpening the director's discipline and trusting the
worker's push-back.

Stale director mental models are an ongoing risk because:

- The director (operating Cowork-style) extrapolates patterns from
  neighbouring codebases (`agent-hq` for Claude runtime, products for
  schema conventions) without re-verifying against Helm itself.
- Helm's internals evolve through ADRs the director may not have
  re-read recently. ADR-021 specifically had already done the
  migration the brief was asking for.
- Coders cannot rely solely on the brief — they must verify the
  premise. Helm's helm-session-driver makes this an explicit rule,
  not a vibe.

## Apply when

For the **director** writing a Helm session brief:

1. If the brief references Helm runtime internals
   (`CodexRuntime`, `ClaudeCodeRuntime`, `dispatcher`,
   `fetch-product-context`, the workflow state machine, any
   specialist prompt builder), **read the file first** before writing
   the brief. Do not extrapolate from `agent-hq`, the playground
   product, or memory.
2. If the brief proposes a "migration" of any kind, **list `decisions/`
   in `helm-knowledge`** and grep for the target subsystem name before
   claiming the migration is needed. A prior ADR may have already done
   it.
3. If the brief includes a "before/after" mapping table or an "old
   shape → new shape" diff, **paste the current shape verbatim** from
   the source file rather than reconstructing from memory.

For the **coder** receiving a Helm session brief:

1. The intake protocol's "read code first" step is non-negotiable. If
   what the brief claims about current state contradicts what the code
   says, **stop and surface the contradiction**. Do not try to
   reconcile or work around.
2. When a brief proposes a change that would regress a prior ADR (here
   ADR-021's safety mapping), default to **pushing back** and citing
   the prior ADR. The director will reconcile or sharpen scope.
3. When the brief turns out to be wrong on premise, the session is not
   wasted: re-scope to **what is actually true and useful**, capture
   the discovery in an ADR honestly, and ship that. ADR-028 is the
   model — it documents the misdiagnosis explicitly in the Context
   section.

## Related artifacts

- `decisions/021-codex-runtime.md` (ADR-021) — the prior migration
  that the brief mistakenly proposed re-doing.
- `decisions/028-codex-cli-runtime-update.md` (ADR-028) — the
  resulting hardening + honest record of what was/wasn't true in the
  brief.
- helm#41 — the hardening PR (`-C <workdir>`, stdin prompt, mapping
  preserved).
- `~/Documents/Empresa/Proyectos/Helm/prompts/helm-session-driver.md` —
  the intake protocol that caught the error (sections "Session intake
  protocol" and "How to receive your first task").
- `~/Documents/Empresa/Proyectos/Helm/prompts/sesion-codex-cli-0136-runtime-update.md` —
  the brief whose premise was stale (kept as historical reference).
- `learnings/2026-06-02-af-pilot-lea-104-arc.md` and
  `learnings/2026-06-02-af-pilot-lea-105-stack-validation.md` — the
  pilot evidence points EP#1–EP#2 this one complements.
