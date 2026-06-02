# ADR-025: Remediation covers all reviewers + scratch artifacts leave the workspace

**Date:** 2026-06-02
**Status:** Accepted
**Context:** Post-pilot fix — reviewer-remediation gap found on Arriendo Fácil item LEA-104

---

## Context

While reviewing the implementation PR for LEA-104 (`lhpaul/leasity-tenants#3`),
the human reviewer found that **two HIGH findings reported by the code-reviewer
were never addressed**, even though the item had gone through
`code-review → remediation → code-review` and looked done.

Two coupled bugs caused it.

### Bug 1 — code-review findings had no remediation safety net

The reviewer fan-out (ADR-017/018) gives the **code-reviewer** the first chance
to self-apply its mechanical fixes: it runs in a writable workspace and the
orchestrator pushes whatever source it changed via `pushReviewerPatches`. The
security and test reviewers are comment-only; their CRITICAL/HIGH findings are
caught later by the **remediation gate** (ADR-019), which spawns a remediator
that applies the fixes.

But the remediation gate only ever ingested **security and test** findings:

```ts
// shouldRemediate — reviewer-fanout.ts
(r.kind === 'security' || r.kind === 'test') && (r.findings.high > 0 || ...)
// buildRemediationParams — remediation.ts
for (const kind of ['security', 'test'] as const) { ... }
```

So when the code-reviewer surfaced a HIGH but **did not self-apply** it (it wrote
only its `review.md` summary, with no source edits), nothing picked up the slack.
The code-reviewer was assumed to be its own remediator, with no fallback when
that assumption failed. Net: code-review HIGHs could pass through review unfixed.

On LEA-104 the code-reviewer flagged two HIGHs (`tenants.email` had no unique
constraint; a money-typed column helper was reused for a non-money `area` field)
and applied neither.

### Bug 2 — `pushReviewerPatches` committed scratch artifacts

`pushReviewerPatches` ran `git add -A`, which stages the agent's own summary file
(`review.md` for reviewers, `remediation.md` for the remediator) sitting at the
workspace root. Consequences:

- A code-reviewer that changed no source **still produced a commit** containing
  only `review.md`. From the outside that looked like a real patch.
- The remediation commit carried `remediation.md` into the code repo.

Bug 2 reinforced Bug 1: the empty-but-non-empty `review.md` commit made the
code-reviewer's "push" step report success, so the gate treated the code-reviewer
as handled. Without that masking commit, `pushReviewerPatches` would have
correctly reported `{ pushed: false }` and the missing fix would have been
obvious.

---

## Decision

### 1. The remediator is the unified safety net behind all three reviewers

The code-reviewer **keeps** its fast path — it still gets the first chance to
self-apply mechanical fixes in-flow. We only add a fallback behind it: the
remediator now consumes CRITICAL/HIGH findings from **all three** reviewer kinds
(`code`, `security`, `test`). Three coordinated changes (all three were enforcing
the old sec/test-only contract):

- `shouldRemediate(results)` gates on **any** reviewer carrying
  `findings.critical > 0 || findings.high > 0` (the `code`-kind exclusion is
  removed).
- The dispatcher's `findingsByKind` map carries **all** reviewer comment bodies,
  not just security/test.
- `buildRemediationParams` iterates `['code', 'security', 'test']` and injects a
  `## Code Review` section alongside the others.

**Idempotency.** The remediator reads the current state of the branch and applies
fixes. If the code-reviewer already self-applied a fix, the remediator sees the
satisfied state and reports a no-op; if it re-applies the same change, the diff is
empty. Either is fine — the remediator prompt instructs it to inspect current
state before changing anything and to treat an already-satisfied finding as a
no-op. The single-pusher invariant is preserved (the code-reviewer pushes first
during fan-out; the remediator pushes last, sequentially).

### 2. Scratch artifacts move outside the workspace clone

Reviewers and the remediator now write their summary to a **sibling** directory of
the clone, `{workspacePath}-artifacts/<specialist-id>.md` (e.g.
`…-artifacts/code-reviewer.md`, `…-artifacts/code-remediator.md`) — outside the
git working tree **by construction**. The provisioner pre-creates the directory
and returns its path; the fan-out and dispatcher clean it up alongside the
workspace. `pushReviewerPatches` operates only on the clone, which now has no
artifact to leak.

> Implementation note: the workspace clone lives directly at
> `os.tmpdir()/helm-review-<id>-<uuid>` (its parent is the shared tmpdir, not a
> per-run dir), so artifacts go to the `…-<uuid>-artifacts` sibling rather than a
> `_helm-artifacts/` child of a per-run parent. Same intent — outside the clone —
> realized against the actual layout.

### 3. Defense in depth: `pushReviewerPatches` short-circuits on no source changes

Even with (2), `pushReviewerPatches` inspects `git status --porcelain` and
treats **untracked** scratch artifacts leaked into the workspace as non-source:

- A status entry is a "leaked artifact" only when it is **untracked** (`??`)
  *and* its path is `review.md`, `remediation.md`, or under a `_helm-artifacts/`
  directory. A *tracked* file of the same name being modified is real source and
  is kept — so a product repo that legitimately versions a `review.md` is not
  harmed.
- If every change is a leaked artifact, the function returns `{ pushed: false }`
  with no commit or push.
- Staging excludes only the specific leaked-untracked paths detected
  (`git add -A -- . :(exclude)<leaked-path>`), so a leak never lands in the
  commit even alongside genuine source changes.

The artifact **names** here are a defensive in-workspace pattern, not the real
location: real summaries live in the sibling `{workspacePath}-artifacts/`
directory (2) and never enter the clone. `_helm-artifacts/` in particular is a
hypothetical in-workspace leak path (it echoes the original artifact-dir naming);
the exclusion exists only for the case where a misbehaving agent writes a scratch
file into its workspace despite (2). The absence of *source* changes then
prevents an empty, misleading commit.

---

## Revisit when

- The code-reviewer's self-apply path is removed or it becomes comment-only — the
  "first chance, then remediator safety net" split collapses and the gate logic
  should be reconsidered.
- A reviewer kind is added or renamed: `shouldRemediate`, the dispatcher's
  `findingsByKind` map, and `buildRemediationParams`' `['code','security','test']`
  loop must all learn the new kind (the same three-spot change this ADR made).
- The workspace layout changes so the clone is no longer a direct
  `tmpdir()/helm-review-…` dir (e.g. clone moves under a per-run parent) — the
  `{workspacePath}-artifacts` sibling convention and its cleanup sites need
  revisiting.
- A fan-out reviewer failure should block (rather than be masked by) a successful
  remediation — the dispatch result/transition semantics are out of scope here and
  tracked separately; revisit if that decision lands.

---

## Consequences

- The remediator's prompt now expects code-review findings too, and documents the
  idempotency assumption.
- A code-reviewer that writes a summary but no source no longer produces a commit
  — the gap is visible (`{ pushed: false }`) instead of masked.
- The single-pusher invariant is unchanged: code-reviewer first, remediator last.
- Forward-looking only. Pre-existing branches that already carry committed
  `review.md` / `remediation.md` artifacts (e.g. LEA-104 PR #3) are cleaned up
  manually by the operator; this change does not rewrite history.

---

## Alternatives considered

- **Make the code-reviewer comment-only (like security/test), letting the
  remediator do all the fixing.** Rejected: it removes the fast path where the
  code-reviewer fixes obvious things in a single round, adding a remediation hop
  for every mechanical nit.
- **Detect an "empty source commit" and rewind it.** Rejected: more complex and
  more fragile than simply moving artifacts out of the clone and short-circuiting
  on no source changes.
- **`.git/info/exclude` the artifacts instead of relocating them.** Workable for
  untracked files (the bug doc floated it), but keeping artifacts inside the clone
  leaves the leak one mistake away; a sibling directory removes the failure mode
  structurally. The pathspec exclusion in (3) covers the residual case.

---

## References

- `packages/orchestrator/src/specialists/code-workspace.ts` — `artifactsDirFor` /
  `artifactFileFor`, provisioners pre-create + return the sibling dir,
  `pushReviewerPatches` source-only status/staging
- `packages/orchestrator/src/specialists/reviewer-fanout.ts` — `shouldRemediate`,
  reviewer prompt writes to the artifact path, artifact read + cleanup
- `packages/orchestrator/src/specialists/remediation.ts` — `['code','security','test']`
  kinds, idempotency wording, artifact read
- `packages/orchestrator/src/dispatcher.ts` — `findingsByKind` carries all kinds;
  artifacts cleaned up with the workspace
- `helm/docs/bugs/code-review-findings-no-remediation-fallback.md` — the bug doc
- [ADR-017](017-reviewers-foundation.md) / [ADR-018](018-real-reviewers.md) —
  reviewer fan-out and the single-pusher / code-reviewer-pushes design this builds on
- [ADR-019](019-remediation-gate.md) — the original remediation gate this extends
