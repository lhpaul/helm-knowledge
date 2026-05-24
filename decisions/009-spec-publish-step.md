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

1. **Ensures the knowledge repo is available locally** at
   `data/knowledge-repos/{productSlug}/`:
   - If not yet cloned → `git clone` with a token-embedded HTTPS URL
     (`https://x-access-token:{token}@github.com/...`).
   - If already cloned → `git fetch origin && git checkout {defaultBranch} &&
     git reset --hard origin/{defaultBranch}`.
2. **Creates or resets the spec branch**: `git checkout -B helm/spec/{externalId}
   origin/{defaultBranch}`.
3. **Copies the spec file** into `specs/{externalId}.md` inside the clone.
4. **Commits** with author/committer set to `helm-bot`.
5. **Force-pushes** the branch using the token-embedded URL.
6. **Opens a PR** via `gh pr create` — or reuses an existing open PR for the same
   branch (idempotency: `gh pr list --head helm/spec/{externalId} --state open`
   before creating).

The `prUrl` is stored in `DispatchResult` and included in the stage-transition note,
so the item history records the PR link.

**Ordering:** publish happens *before* the `discovery → spec-draft` transition.
A publish failure blocks the transition — the stage change should reflect the reality
that a reviewable artifact exists.

**Injectable runners:** `RunGit` and `RunGh` are function-type parameters with
real defaults (`/usr/bin/git` and `/opt/homebrew/bin/gh`).  Tests inject mocks that
operate on the real filesystem without spawning child processes.

### C — Knowledge repo local path

`DataPaths.knowledgeRepos` → `data/knowledge-repos/` is pre-created by
`ensureDataDir()`.  Each product gets its own subdirectory:
`data/knowledge-repos/{productSlug}/`.

---

## Consequences

### Positive

- Spec is visible to the team via a GitHub PR as soon as the agent finishes.
- Stage transition is gated on a real, reviewable artifact.
- Agent prompt includes product-specific context → better spec quality.
- Publish step is idempotent: re-dispatching the same item doesn't create duplicate PRs.
- Full test coverage without network calls: `fetchFn` and `RunGit`/`RunGh` are injectable.

### Negative / Trade-offs

- `GITHUB_TOKEN` must be present at dispatch time for both context fetch and publish.
  If the token is absent, context fetch is skipped (non-fatal) and publish is skipped
  (no PR is created, item still transitions to `spec-draft`).
- The knowledge repo clone is **not cleaned up** between runs.  Stale branches may
  accumulate in the local clone; the `git checkout -B ... origin/{defaultBranch}`
  ensures the working tree is always reset to the default branch before branching.
- `gh` binary path is hardcoded to `/opt/homebrew/bin/gh` in the default runner.
  This works on macOS with Homebrew but may need adjustment for Linux deployments.

### Known limitations

- **Merge detection is not implemented.**  The system cannot detect when a spec PR is
  merged and does not advance the item to `spec-ready` automatically.  That transition
  remains a future scope item (planned: webhook from knowledge repo → Helm API).
- **Single token scope.**  `GITHUB_TOKEN` is used for both the context fetch (read
  access to the code repo) and the spec publish (write access to the knowledge repo).
  If the two repos belong to different organizations, a single token may not have
  sufficient scope.
