# ADR-030 — Plan-writer / spec-writer product-context materialization

Date: 2026-06-02
Status: Accepted
Related: ADR-021 (CodexRuntime), ADR-026 (product-readiness gate; shared
`AGENT_INSTRUCTION_FILES` constant), ADR-024 (spec/plan remediators), AF pilot
LEA-105 and LEA-109 retros (Evidence Point #3)

## Context

The plan-writer and spec-writer specialists receive product context (README +
agent instruction file) as a truncated 2000-char string injected into their
prompt via `fetchProductContext()` (the `## Product Context` section). Their
worktree (`data/worktrees/<slug>/<id>/`) is otherwise an empty directory — no
git clone, no materialized files. So the agent's own working directory contains
nothing it can read with file tools (`cat`, `grep`, line references).

The AF pilot plan-writer surfaced this gap in its own Risks section across two
consecutive items:

- LEA-105 plan PR: *"The worktree provided here does not include CLAUDE.md, so
  any repo-specific notes from that file must be verified in the main branch
  before implementation."*
- LEA-109 plan PR: same wording, captured as Evidence Point #3 in the LEA-109
  retro alongside the §4-validation, additive-drift, and
  director-stale-mental-model evidence points.

The pattern is consistent: the agent can see only the first ~5% of the real
`CLAUDE.md` (~35 KB / 2000 chars ≈ 5%), and cannot `grep`/`cat` specific
sections from disk. The implementer does not have this gap because
`provisionCodeWorkspace()` shallow-clones the code repo, which brings
`CLAUDE.md` along.

## Decision

Add a new `materializeProductContext(workdir, product, token, fetchFn?)` sibling
function in `fetch-product-context.ts`. It writes the README and the winning
agent instruction file (per the existing `AGENT_INSTRUCTION_FILES` preference
order) to the spec-writer / plan-writer worktree, with no 2000-char truncation.
The existing `fetchProductContext()` function is untouched; the new function is
an additive opt-in for the dispatcher to call right before spawning the agent.

It returns a `MaterializedProductContext { readme, agentInstructions: { path,
filename, bytes }, missingFiles[] }`. The agent instruction file is written
under its real winning variant name (`AGENTS.md` / `AGENT.md` / `CLAUDE.md`) —
no rename. A 404 yields a `null` entry plus a `missingFiles` entry (the worktree
simply lacks that file); a non-404 HTTP error propagates so the caller can log
it.

Locked design forks:

- **Materialization scope:** README + winning agent instruction file (filename
  preserved — `CLAUDE.md` / `AGENT.md` / `AGENTS.md`).
- **Approach:** new sibling function, not a flag on the existing function.
  Cleaner separation; existing prompt-injection callers unaffected.
- **Callers updated:** spec-writer and plan-writer dispatch paths in
  `dispatcher.ts`. The spec-writer call is token-gated and best-effort (its
  token is optional, mirroring the existing `fetchProductContext` Part A); the
  plan-writer call runs unconditionally (its token is asserted earlier in the
  dispatch flow). Both are wrapped best-effort: a materialization failure logs
  and continues — it never fails the dispatch. Implementer untouched.
- **No truncation on disk.** Prompt injection stays truncated at 2000 chars
  (context-window economy); the full file is on disk for the agent's file tools.
- **Single-product v0.** Same `workdir` the dispatcher already passes; no new
  directory abstractions.

## Alternatives considered

- **Shallow-clone the code repo for spec-writer / plan-writer** (mirror the
  implementer's `provisionCodeWorkspace()`). Rejected: too much surface change
  for the evidence we have. Spec/plan-writers don't compile, run, or commit
  code; they read `CLAUDE.md`.
- **Drop the 2000-char truncation entirely.** Rejected: increases
  context-window cost for every dispatch even when the agent doesn't need the
  full file. The truncated prompt section is the cheap quick reference; the
  materialized file is the deep dive when the agent asks for it.
- **Add a `materializeToWorktree?: string` option to the existing
  `fetchProductContext`.** Rejected: muddies the function's contract. A sibling
  function is clearer.
- **Make materialization opt-in per product via `product.yaml`.** Rejected:
  default-on across all products that use spec-writer or plan-writer is simpler.
  If a product needs to opt out, open a follow-up.

## Consequences

- Plan-writer and spec-writer agents can `cat`/`grep`/reference specific line
  numbers in `CLAUDE.md` and README — the EP#3 gap closes.
- Token cost during dispatch is unchanged (the materialized files don't enter
  the prompt; only the truncated section does).
- Disk usage in the worktree increases by ~README size + ~agent-instructions
  size. For AF that's ~35 KB total. Negligible.
- The `## Product Context` prompt section stays as-is — agents still get the
  truncated quick reference for orientation; the on-disk file is the source of
  truth for details.
- Best-effort posture means a fetch failure (or a missing file) leaves the
  worktree empty and the agent proceeds with whatever prompt-injected context it
  has — matching the existing `fetchProductContext` call-site behavior.

## Tests

- Unit tests for the new function: verbatim/no-truncation write, agent
  instruction preference order (`AGENTS.md` wins; `AGENT.md` variant preserved),
  README absent, both absent, non-404 HTTP error propagation, no-repo, auth
  header.
- Dispatcher tests confirm the function is invoked for spec-writer and
  plan-writer (files land in the worktree), NOT for implementer (the scratch
  worktree stays clean), and is skipped for the spec-writer when no token is
  supplied.
- Regression: existing `fetchProductContext` tests unchanged.

## Revisit when

- A product needs to opt out (`product.yaml` flag becomes valuable).
- A spec-writer or plan-writer use case emerges that needs more than README +
  agent instructions (e.g. wants ADRs from the knowledge repo, or wants
  `.helm/product.yaml`). Then the materialization surface grows under a separate
  ADR.
- The implementer ever stops shallow-cloning the code repo (e.g. remote build
  workers). Then materialization may need to extend to the implementer too.

## References

- AF pilot LEA-105 plan PR Risks section.
- LEA-109 retro, Evidence Point #3.
- `fetch-product-context.ts` — current implementation that this ADR extends.
- `provisionCodeWorkspace` in `code-workspace.ts` — the implementer's
  materialization precedent.
