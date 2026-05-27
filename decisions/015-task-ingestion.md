# ADR-015: Task Ingestion into the Spec-Writer Prompt

**Date:** 2026-05-27
**Status:** Accepted
**Supersedes:** —
**Related:** ADR-010 (Spec Merge Detection), ADR-011 (Plan-Writer)

---

## Context

The first end-to-end run against `helm-playground` validated the full pipeline, but
exposed a concrete gap: the spec-writer only knows the item's `externalId` and whatever
product context (README / AGENT.md) the orchestrator fetches from the knowledge repo.
It has no access to the issue title or description from the tracker. As a result the
agent invents a placeholder spec, which propagates through plan-writing and
implementation without reflecting the actual task.

The fix requires injecting the tracker item's **title** and **description (body)** into
the spec-writer prompt so the agent specifies the real task.

---

## Decision

### Approach B — Fetch at dispatch (chosen)

The orchestrator fetches the tracker item **when the spec-writer is dispatched**
(i.e., at stage `discovery`), injects `{ title, body }` as a `## Task` section into the
prompt, and discards the data afterwards. The tracker remains the single source of truth.

### Alternatives considered

**Approach A — Persist at item creation.**
Store `title` and `body` in `ItemState` when the item is first created (webhook or
manual trigger). Pros: always available; no extra network call at dispatch time.
Cons: stale data (the issue may be edited between creation and dispatch); `ItemState`
grows a field that is only ever used by one specialist; requires a schema migration for
existing items. Discarded in favour of the simpler fetch-at-dispatch approach.

---

## Design decisions

### 1. Injected fetch function — decoupling the orchestrator from any adapter

`DispatchOptions.fetchTask?: (externalId: string) => Promise<{ title: string; body?: string } | null>`

The orchestrator receives a plain function instead of an adapter reference. This mirrors
the existing pattern for `transition` (injected `ItemStore.transition`) and for
`fetchFn` (injectable HTTP fetch). Benefits:

- The orchestrator package has no compile-time dependency on `@helm/adapters`.
- A future Linear adapter (or any other tracker) wires in an equivalent function without
  changing the orchestrator.
- Tests provide a simple `vi.fn()` — no adapter setup or network mocks needed.

The API layer (`apps/api/routes/dispatch.ts`) builds the concrete function by calling
`getGitHubAdapter().getItem(externalId)` and mapping the result to `{ title, body }`.

### 2. `NormalizedItem.body?: string`

Added as an optional field to the tracker-agnostic `NormalizedItem` type. `body` is
optional because:

- Not all trackers expose a description field.
- Items that genuinely have no body (empty GitHub issue description) map to `body: ''`
  (empty string from the GraphQL response), which the prompt builder treats as
  "(no description provided)".
- Adapters that do not yet support body (e.g., a future Linear adapter) can leave the
  field `undefined` without breaking callers.

The `GET_PROJECT_ITEMS` GraphQL query is extended with `body` in the `... on Issue`
fragment. The `GitHubIssueContent` type and the `normalizeItem` mapping are updated
accordingly.

### 3. Graceful degradation

`fetchTask` is called **best-effort** in the spec-writer branch:

- If absent (`DispatchOptions.fetchTask` not provided) → no Task section, same
  behaviour as before this ADR.
- If it returns `null` (item not found in tracker — e.g., a manually created item with
  a synthetic ID that does not exist in GitHub Projects) → spec written without Task
  section, dispatch continues normally.
- If it throws (network error, token expired, adapter init failure) → error logged,
  `null` used as fallback, dispatch continues without Task section.

No dispatch failure is ever introduced by a tracker fetch error.

### 4. Spec-writer only

Task ingestion applies **only to the spec-writer**. The plan-writer and implementer
operate from already-written artifacts (spec / plan from the knowledge repo) and do not
need the raw tracker item. Injecting the task there would add noise without benefit and
would couple those specialists more tightly to the tracker.

### 5. Prompt structure

When `task` is provided, `buildSpecWriterPrompt` injects a `## Task` section **before**
the instruction paragraph:

```markdown
## Task

**Title:** <title>

<body, or "(no description provided)" if empty/absent>

---

Your task: write a specification for item <externalId> based on the task described above.
```

When `task` is absent the section is omitted and the instruction reverts to
`"write a specification for item <externalId>."` — backward-compatible with any caller
that does not provide `fetchTask`.

---

## Consequences

- **Positive:** The spec-writer specifies the real task; the full pipeline produces
  meaningful artifacts instead of placeholders.
- **Positive:** Zero `ItemState` schema changes; no migration needed.
- **Positive:** The orchestrator remains adapter-agnostic; the injected-function pattern
  scales to Linear and other future trackers.
- **Negative:** One extra network call per spec-writer dispatch. At the cache TTL
  (default 5 min) the GitHub Projects adapter may return a warm-cache hit; at worst it
  issues one GraphQL `GET_PROJECT_ITEMS` pagination call.
- **Known limitation:** If the tracker item is edited *after* the spec is written, the
  stored spec may diverge from the tracker. This is acceptable at the current maturity
  level; a re-dispatch overwrites the spec with the current item content.
