# ADR-009: Publish spec to knowledge repo as a PR

**Date:** 2026-05-24
**Status:** Accepted
**Context:** Session 12 — product context injection + spec publish step

---

## Context

After the spec-writer agent writes a spec to `workdir/specs/{externalId}.md`, the
file lives only in the ephemeral dispatch workdir and is never visible to the team
outside of the server filesystem.  We want the spec to be reviewed and stored in the
knowledge repo so that:

1. The team can review and comment on the spec before implementation begins.
2. The knowledge repo accumulates a history of accepted specs.
3. The transition to `spec-draft` is tied to an artifact that is actually visible
   (a PR), not just a file on disk.

Additionally, the spec-writer agent produces better output when it knows about the
product — its README, coding conventions, and workflow stages — before it starts.
We want to inject this context into the agent prompt without requiring a full clone
of the code repo (expensive, risky for large repos).

---

## Decisions

### A — Product context injection (Part A)

**Fetch README + AGENT.md from `raw.githubusercontent.com`** using `GITHUB_TOKEN`.

The primary code repo's default branch is used.  The response is:

- **README.md** — product overview, architecture, conventions.
- **AGENT.md** (falling back to **CLAUDE.md**) — agent-specific coding instructions.

Both files are fetched concurrently.  A 404 or non-2xx response is treated as "file
absent" — the field is omitted from context rather than causing an error.  Content is
truncated to 2000 characters to keep the prompt token budget bounded.

The context is fetched once per dispatch run, before the agent is invoked.  A fetch
error is non-fatal: the dispatch continues without context rather than failing.

The `fetchProductContext(product, token, fetchFn?)` function accepts an injectable
`fetchFn` for testing without network calls.

**Prompt section format:**

```markdown
## Product Context

**Product slug:** my-product
**Workflow:** discovery → spec-draft → released

### README

...truncated README content...

### Agent Instructions

...AGENT.md content...
```

### B — Publish spec to knowledge repo (Part B)

**After** the spec file is verified in the workdir, `publishSpecToPR()`:

1. **Clones the knowledge repo** to a fresh isolated temporary directory
   (see §C — Publish isolation).
2. **Creates or resets the spec branch**: `git checkout -B helm/spec/{externalId}
   origin/{defaultBranch}`.
3. **Copies the spec file** into `specs/{externalId}.md` inside the clone.
4. **Commits** with author/committer set to `helm-bot`.
5. **Force-pushes** the branch via token-authenticated HTTPS (token injected as
   `GIT_HTTP_EXTRAHEADER`, never embedded in the remote URL).
6. **Opens a PR** via `gh pr create` — or reuses an existing open PR for the same
   branch (idempotency: `gh pr list --head helm/spec/{externalId} --state open`
   before creating).

The `prUrl` is stored in `DispatchResult` and included in the stage-transition note,
so the item history records the PR link.

**Ordering:** publish happens *before* the `discovery → spec-draft` transition.
A publish failure blocks the transition — the stage change should reflect the reality
that a reviewable artifact exists.

**Injectable runners:** `RunGit` and `RunGh` are function-type parameters with
real defaults (`git` / `gh` resolved from `PATH`).  Tests inject mocks that operate
on the real filesystem without spawning child processes.

### C — Publish isolation: temp-clone-per-call

**Problem — race condition across items of the same product.**

An earlier design cloned the knowledge repo once per product to
`data/knowledge-repos/{productSlug}/` and reused that checkout for every publish.
When two items of the same product were dispatched concurrently, their `publishSpecToPR`
calls shared a single git working tree.  The git operations
(`checkout -B`, `add`, `commit`, `push`) could interleave:

- Item A's commit could silently include item B's staged file.
- A force-push from item B could overwrite item A's branch with incorrect content.
- The resulting PRs would contain mixed or missing spec changes.

The per-item path guard (`knowledge-repos/{productSlug}/{externalId}/`) added at the
dispatcher call-site narrowed the window to a single item, but `publishSpecToPR` itself
had no isolation guarantee — the race was still possible if the same item was
re-dispatched concurrently.

**Decision: each `publishSpecToPR` call clones to its own fresh temp directory.**

```
tmpdir()/helm-publish-{externalId}-{uuid}/   ← isolated per call
```

Alternatives considered:

| Option | Verdict |
|--------|---------|
| In-memory mutex keyed by product | Rejected — only safe within a single process; a future multi-worker deployment would reintroduce the race. |
| `git worktree add` against a cached base clone | Attractive for clone efficiency but requires coordinating access to the shared base clone during `git fetch`. Adds complexity with limited benefit given current dispatch volume. |
| **Temp clone per call** (chosen) | Simple, correct, single-process or multi-process safe. Each call is fully self-contained. The isolation directory is always removed in `finally` regardless of success or failure. |

**API impact:**

- `knowledgeRepoLocalPath` has been **removed** from `PublishSpecOpts` and
  `SpecPublishOptions`.  The publish function manages its own working directory
  internally; callers no longer need to provide or manage one.
- `DispatchOptions.dataRoot` is retained for future specialists but is no longer
  required by the spec-writer publish step.
- The publish step is triggered whenever `githubToken` is present (the `dataRoot`
  guard was dropped along with `knowledgeRepoLocalPath`).

---

## Consequences

### Positive

- Spec is visible to the team via a GitHub PR as soon as the agent finishes.
- Stage transition is gated on a real, reviewable artifact.
- Agent prompt includes product-specific context → better spec quality.
- Publish step is idempotent: re-dispatching the same item doesn't create duplicate PRs.
- Concurrent publishes for any combination of items are safe — no shared state.
- Full test coverage without network calls: `fetchFn` and `RunGit`/`RunGh` are injectable.
- Auth token never appears in remote URLs or git error messages (via `GIT_HTTP_EXTRAHEADER`).

### Negative / Trade-offs

- `GITHUB_TOKEN` must be present at dispatch time for both context fetch and publish.
  If the token is absent, context fetch is skipped (non-fatal) and publish is skipped
  (no PR is created, item still transitions to `spec-draft`).
- **Full clone on every publish.**  Each call clones the entire knowledge repo from
  GitHub rather than reusing a cached local copy.  For large knowledge repos this adds
  latency per dispatch.  Mitigation: knowledge repos tend to be small (docs only);
  a `git clone --depth 1` optimisation is deferred to a future session.
- Temp directories accumulate on unexpected process kill (the `finally` block is
  bypassed by `SIGKILL`).  They live under `os.tmpdir()` with a `helm-publish-`
  prefix and are cleaned up by OS temp-dir housekeeping.

### Known limitations

- **Merge detection is not implemented.**  The system cannot detect when a spec PR is
  merged and does not advance the item to `spec-ready` automatically.  That transition
  remains a future scope item (planned: webhook from knowledge repo → Helm API).
- **Single token scope.**  `GITHUB_TOKEN` is used for both the context fetch (read
  access to the code repo) and the spec publish (write access to the knowledge repo).
  If the two repos belong to different organizations, a single token may not have
  sufficient scope.
- **SSH knowledge repo URLs are not supported.**  `GIT_HTTP_EXTRAHEADER` only applies
  to HTTPS transport.  Configuring a `git@github.com:...` or `ssh://...` URL for the
  knowledge repo causes an early validation error with a message directing the operator
  to use an HTTPS URL instead.
