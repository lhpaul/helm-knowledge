# ADR-033: Tracker writeback — stage → Linear / GitHub Projects

**Date:** 2026-06-04
**Status:** Accepted
**Context:** Bloque I / writeback — close the store→tracker loop. Follows ADR-029
(item store kept pure-local) and ADR-032 (`merged`/`released` split). Surfaced
by the Arriendo Fácil pilot (Linear showed every LEA item stale).

---

## Context

Helm reads workflow items from the external tracker and advances stage in a
local item store (the store of record). It never wrote stage **back**. So the
tracker (Linear label / GitHub Projects single-select) reflected nothing after
intake: every item read as if no work had happened.

This was visible during the AF pilot — LEA-103…109 all showed stale in Linear
even though the store had advanced them correctly through spec/plan/impl.

**Intake note (verified against the real code):**

- The entire adapter write-surface has **zero non-test call sites**.
  `setSubStage`, `ensureSubStages`, `setStatus`, `comment` exist on both
  adapters (`packages/adapters/src/linear/adapter.ts`,
  `…/github-projects/adapter.ts`) and on the `IssueTrackerAdapter` interface,
  are unit-tested, but nothing in `apps/` calls them. Helm v0 was
  read-from-tracker + local store of record only.
- `apps/api/src/services/item-store.ts` is **pure-local** — no adapter import.
  The single persist choke point is the private `applyTransition()` (shared by
  `transition()` and `forceTransition()`); `create()` is a separate
  stage-mutation entry point (sets `INITIAL_STAGE`).
- `getIssueTrackerAdapter()` already exists in `apps/api/src/services/index.ts`
  — a provider-aware singleton resolving the token from env and returning a
  ready `LinearAdapter` / `GitHubProjectsAdapter`. Reused, not rebuilt.
- **Echo risk is real.** Helm already consumes a tracker→store webhook: a human
  moving the Linear label / GitHub option fires `item_updated`, which
  transitions the store. Naïve writeback on *every* transition would loop:
  tracker → webhook → store transition → writeback → tracker → …
- **Adapter caching nuance (load-bearing for the design):** Linear's
  `setSubStage` self-heals (it creates the `helm:*` label if missing), but
  GitHub's throws (`"call ensureSubStages first"`) when the single-select option
  map is not set up. And **neither** adapter no-ops a repeat `ensureSubStages`
  cheaply — both re-fetch labels/fields over the network every call. So a
  correct design must run `ensureSubStages` at least once, but not per
  transition.

## Decision

Add a thin transition-service wrapper that, after the store applies a stage
change, writes the new stage back to the tracker via `setSubStage`
(best-effort). The `ItemStore` stays pure-local. A one-shot
`writeback-backfill` command reconciles already-advanced items.

### Locked decisions

- **Service wrapper, not in the store.** New
  `apps/api/src/services/item-service.ts` exposes `transitionItem` /
  `forceTransitionItem` / `createItem`, each pairing the store call with a
  single private `writebackStage` helper. The store stays pure-local (its
  valued property — ADR-029). All stage-mutating call sites migrate to the
  wrapper (`routes/items`, `routes/dispatch`, `routes/webhooks` for both the
  GitHub and Linear branches, `routes/release`, `routes/rollback`).
- **Best-effort.** A writeback that throws logs a warning and continues; the
  store is the source of truth. A tracker API hiccup must never fail the
  workflow (consistent with how the webhook handlers already swallow external
  errors).
- **Anti-echo.** Skip writeback when the transition was tracker-originated —
  `triggeredBy` starts with `webhook:github-projects` or `webhook:linear`. All
  other triggers DO write back, including `webhook:code-repo`,
  `webhook:knowledge-repo`, `webhook:release`, `manual:*`, and `agent:*` (those
  originate outside the issue tracker, so the tracker does not know yet).
- **`setSubStage` only.** Stage label only. `setStatus` (auto-close on terminal)
  and `comment` (stage-change / PR-link notes) are **out of scope** — separate
  policy decisions, deferred (see *Revisit when*).
- **One-shot backfill.** A `writeback-backfill <slug>` command runs
  `ensureSubStages` once, then `setSubStage(currentStage)` for every store item
  (best-effort per item). Supports **both** providers (the AF pilot is Linear).
  This is what makes LEA-103…109 current.

### Implementation notes

- **`ensureSubStages` memoization.** `writebackStage` runs `ensureSubStages`
  exactly once per adapter instance, memoized in a
  `WeakMap<IssueTrackerAdapter, Promise<void>>`. Keying on the adapter object
  (a process singleton from `getIssueTrackerAdapter`) means the memo resets
  automatically when `_resetForTests` swaps the singleton — no separate reset
  hook — and a failed ensure is evicted so a later transition retries. This is
  required because GitHub's `setSubStage` throws without a prior ensure, and
  neither adapter's ensure is a cheap repeat.
- **No `index.js` re-export.** The wrappers are imported directly from
  `item-service.ts` by call sites, **not** re-exported through
  `services/index.ts`. `item-service.ts` imports the factory accessors *from*
  `index.ts`; re-exporting it back would create an index↔item-service cycle.
  The cycle is benign at runtime but breaks `vi.mock('./index.js',
  importOriginal)` in route tests — the spread would bind the real wrappers to
  the real `getItemStore` instead of the test's mock store. Keeping the
  dependency one-directional (item-service → index) avoids it.

## Alternatives considered

- **Writeback inside `ItemStore.applyTransition`.** Rejected: couples pure-local
  persistence to adapters + network IO; every transition becomes a network
  call; harder to test; violates the ADR-029 boundary.
- **Writeback at each call site.** Rejected: duplicated across ~8 sites and easy
  to forget — the next new route silently drifts. One choke point cannot be
  forgotten.
- **Always writeback + rely on idempotency to break the echo.** Rejected: noisy
  (invalid-transition logs on every echo) and wasteful (a network round-trip per
  echo). Explicit anti-echo by `triggeredBy` is cleaner and cheaper.
- **`ensureSubStages` on every transition.** Rejected: both adapters re-fetch
  over the network on each call — a per-transition network storm. Memoize once.

## Consequences

- The tracker now reflects stage; the pilot is legible in Linear from here on.
- Best-effort means store and tracker can drift transiently (a failed writeback
  is logged, not retried). The `writeback-backfill` command is the recovery
  tool; periodic reconcile is deferred.
- Auto-close (`setStatus`) and stage-change comments remain manual until a
  follow-up adopts them.
- New process surface: `pnpm --filter @helm/api writeback-backfill <slug>` —
  documented in `operations/onboarding-product.md`.

## Tests

- `apps/api/src/services/item-service.test.ts` — writeback fires on a normal
  transition; anti-echo skips `webhook:github-projects` / `webhook:linear`;
  writes back for `webhook:release` / `webhook:code-repo` / `manual:*` /
  `agent:*`; best-effort (adapter throw → wrapper still resolves, store result
  returned, warning logged); ensure failure skips `setSubStage` but still
  returns; ensure memoized once across transitions and evicted on failure;
  `create` writes the initial label; `forceTransition` writes back.
- `apps/api/src/services/writeback-backfill.test.ts` — ensure once + setSubStage
  per item; per-item failure does not abort (reconciled/failed counts);
  provider-agnostic; empty store; ensure-failure propagates; unsupported
  provider rejected.
- Migrated route tests assert writeback happens / is skipped: `webhooks` (GitHub
  `item_updated` anti-echo; `pull_request_merged` writes back), `webhooks-linear`
  (`item_updated` anti-echo), `items` / `release` / `rollback` (writeback on the
  respective transition). Existing transition assertions stay green.

## Revisit when

- We want auto-close on terminal stages or PR-link comments — adopt `setStatus`
  / `comment` (the deferred surface).
- Drift becomes frequent enough to justify a scheduled reconcile loop instead of
  the manual `writeback-backfill` command.
- Failed writebacks need durability — add a retry queue (best-effort + backfill
  cover drift recovery for now).

## References

- ADR-029 — item store kept pure-local (the boundary this preserves).
- ADR-032 — `merged`/`released` split (the stages now mirrored to the tracker).
- `apps/api/src/services/item-service.ts` — the wrapper + `writebackStage`.
- `apps/api/src/services/writeback-backfill.ts`,
  `apps/api/src/scripts/writeback-backfill.ts` — the reconcile command.
- AF pilot — gap surfaced (Linear showed items stale despite store advancing).
