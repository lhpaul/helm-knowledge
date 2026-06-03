# ADR-028: Codex CLI runtime hardening for 0.136.x

**Date:** 2026-06-02
**Status:** Accepted
**Related:** ADR-005 (`IAgentRuntime` contract), ADR-021 (`CodexRuntime`, original `codex exec` implementation), ADR-027 (most recent), #47 (`finalOutput` propagation, validated by this change)

---

## Context

`CodexRuntime` (ADR-021) runs specialists via the OpenAI Codex CLI in headless
mode so a product can run against the ChatGPT subscription instead of metered
API billing. It was implemented and discovered against **Codex CLI v0.133.0**.

The Arriendo Fácil pilot was blocked at LEA-109 (Better Auth setup). The
implementer dispatch had failed under Codex CLI **0.133.0** with:

```text
[turn.failed] image_generation_user_error:
"The model 'gpt-image-2' does not exist." (param: tools, status 400)
```

Root cause was a **Codex-side bug**: the 0.133 CLI auto-registered an
`image_generation` tool pointed at a non-existent model. This was a defect in
the CLI, not in Helm's code. The operator upgraded the host's Codex CLI to
**0.136.0** (latest at the time), which fixes the image-generation bug.

The session that produced this ADR was originally scoped on the assumption that
the runtime still used a removed `codex --print -p "<prompt>" --output-format
stream-json --verbose` shape and would need a migration to the `exec`
subcommand. **That assumption was wrong.** Reading the code first
(`packages/orchestrator/src/runtimes/codex.ts`) showed the runtime already used
`codex exec --json --skip-git-repo-check` — the `exec` migration had already
landed in ADR-021. A smoke test against the live 0.136.0 binary confirmed:

- The existing invocation shape works unchanged on 0.136.0.
- The `--json` JSONL event schema is **byte-compatible** with the checked-in
  fixtures for the events the parser acts on (`thread.started`, `turn.started`,
  `item.completed` → `agent_message`/`command_execution`, `turn.completed`,
  `turn.failed`). 0.136 additively introduces a `file_change` item type and
  `aggregated_output`/`status` fields on `command_execution`, which the parser
  ignores.
- `turn.failed` events still carry an `error.message` (now a JSON-stringified
  nested payload), so the `finalOutput` error-propagation patch (#47) survives.

So no migration was needed. What the review **did** surface were two latent
robustness gaps in the already-working invocation, plus one proposed change that
would have been a regression.

## Decision

Keep the `codex exec --json` invocation (no migration), re-verify it against
Codex CLI 0.136.0, and apply two robustness deltas. The runtime now invokes:

```bash
codex exec --json --skip-git-repo-check -C <workdir> \
  [--sandbox workspace-write | --dangerously-bypass-approvals-and-sandbox] \
  [--model <model>]
# prompt fed over stdin (no positional argument)
```

**Delta 1 — pin the working root with `-C <workdir>`.** Previously the runtime
relied on the spawn `cwd`. Verified empirically that `codex exec` resolves its
working root from the enclosing Git repo and can ignore the process `cwd`
(observed `Shell cwd was reset to …` with `pwd` running outside the intended
directory). `-C <dir>` is authoritative: a test with `cwd=A, -C B` ran in `B`.
We pass **both** `-C` and the spawn `cwd` — `-C` wins, `cwd` is the fallback if
a future CLI drops the flag.

**Delta 2 — feed the prompt over stdin, not as a positional argument.**
Specialist prompts can be large (the spec-writer pulls README +
AGENTS.md/CLAUDE.md), risking the OS `ARG_MAX` limit when passed on the command
line. `codex exec` with no positional prompt reads its instructions from stdin
until EOF. The shared `defaultSpawn`/`SpawnFn` primitive gained an optional
`stdin` byte buffer; `CodexRuntime` passes the prompt bytes, Bun writes them and
closes the pipe (EOF). `ClaudeCodeRuntime` leaves `stdin` unset and keeps
`stdin: 'ignore'` (its prompt stays on the argv) — the change is Codex-only.

**Explicitly rejected — unconditionally passing
`--dangerously-bypass-approvals-and-sandbox`.** The session brief proposed
always bypassing the sandbox. This would regress the ADR-021 permission mapping
(`acceptEdits → --sandbox workspace-write`, `bypassPermissions →
--dangerously-bypass-approvals-and-sandbox`), which is a deliberate safety
boundary: only the implementer (which runs builds/tests/git) gets full access;
reviewers and writers stay sandboxed. The mapping is **preserved**.

No `product.yaml` schema change. No `extra_args`. No backward compatibility with
the removed `--print` shape. Helm now requires Codex CLI ≥ 0.136.0 on the host.

## Consequences

- **Host requirement:** any deployment using `runtime: codex` must run Codex CLI
  **≥ 0.136.0**. Documented in `operations/onboarding-product.md`. This is a
  breaking host/config requirement for installs pinned to an older CLI.
- The `-C <workdir>` flag makes the working root explicit and robust against the
  CLI's Git-root resolution.
- Large prompts no longer risk `ARG_MAX` failures.
- The ADR-021 sandbox mapping is intact — no reduction in the per-specialist
  permission boundary.
- The 0.136 JSONL schema is locked by real-capture fixtures
  (`__fixtures__/codex/exec-success-0.136.jsonl`,
  `__fixtures__/codex/turn-failed-0.136.jsonl`). The parser tolerates the new
  `file_change` item type and the added `command_execution` fields additively;
  if Codex makes one of these load-bearing, the fixtures will flag it.
- The `--dangerously-bypass-approvals-and-sandbox` flag remains loud on purpose;
  anyone reading the source sees it, and this ADR justifies the bypass for the
  implementer's vetted, ephemeral-worktree sandbox.

## Alternatives considered

- **Downgrade Codex to 0.132.x** (pre-image-tool-bug, pre-redesign). Rejected:
  pins Codex to an abandoned version; the CLI moves fast and tracking current is
  cheaper than pinning. 0.132 also still carries no fix for the image-tool bug.
- **Dual-mode runtime (detect old vs new CLI and branch).** Rejected: pure
  complexity, no operational benefit — operators that update Codex update the
  whole host.
- **Keep the prompt as a positional argument.** Rejected: works for small
  prompts but is a latent `ARG_MAX` failure for the largest specialist prompts;
  stdin is unconditionally safe.
- **Pass only `-C` and drop the spawn `cwd`.** Rejected: keeping `cwd` as a
  redundant fallback costs nothing and guards against a future CLI dropping the
  flag.

## Validation

- Updated unit tests for spawn args (`-C <workdir>` present; prompt absent from
  argv; prompt delivered via the stdin buffer; sandbox mapping and `--model`
  unchanged).
- New parser tests over the real 0.136 fixtures: success run settles `done`
  with the last `agent_message` as `finalOutput`; the `file_change` item
  produces no spurious message; a real `turn.failed` propagates `[turn.failed]
  …` into `finalOutput` (#47 patch survives).
- Manual end-to-end smoke against the live Codex CLI 0.136.0 (Bun spawn path):
  a long prompt fed over stdin, `-C` pinning the workdir — the agent created the
  target file inside the workdir and the runtime parsed `status: done` with the
  expected `finalOutput`.
- `pnpm turbo run lint test build` green.

## Revisit when

- Codex CLI introduces another breaking change. If the cadence stays this fast,
  consider a versioned adapter strategy or a startup version-check gate (out of
  scope here).
- A second runtime needs the same stdin / `-C` pattern — factor it out of
  `_env.ts` further.
- Per-product `extra_args` (`--add-dir`, `--enable <feature>`, profile via `-p`)
  becomes valuable — separate ADR and a `product.yaml` schema change.

---

## References

- ADR-005 — `IAgentRuntime` interface (runtime-agnostic contract).
- ADR-021 — `CodexRuntime` (original `codex exec` implementation, permission
  mapping, JSONL parser, `_env.ts` extract).
- #47 — `finalOutput` propagation on agent failure (validated against the 0.136
  `turn.failed` fixture).
