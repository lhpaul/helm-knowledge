# Tech Debt Register

Deferred cleanups and refactors that are intentionally out of scope when first
identified, recorded here so they are not lost. Each item is non-blocking by
definition — if it were blocking, it would be a backlog item in the tracker, not
here.

When an item is picked up, move it to the tracker (or open a PR directly for
trivial ones) and mark it `Resolved` with the PR/issue reference rather than
deleting it.

| Status legend |                                            |
| ------------- | ------------------------------------------ |
| `Open`        | Not yet scheduled                          |
| `Scheduled`   | Has a tracker item / planned session       |
| `Resolved`    | Fixed — keep the row with the PR reference |

---

## TD-001 — Consolidate the `externalId` regex in `@helm/shared`

- **Status:** Open
- **Date identified:** 2026-05-25
- **Origin:** Session 13 (helm PR #20), Cowork review
- **Effort:** Small
- **Risk if ignored:** Low, but real

### Context

The externalId validation regex (`/^(?!\.)[A-Za-z0-9._-]+$/`) is duplicated in
three places:

- `apps/api/src/services/types.ts` → `EXTERNAL_ID_REGEX`
- `packages/orchestrator/src/specialists/spec-publisher.ts` → `EXTERNAL_ID_SAFE`
- `packages/shared/src/spec-branch.ts` → `VALID_EXTERNAL_ID` (added in Session 13)

They were duplicated deliberately to keep `@helm/shared` free of cross-package
app dependencies.

### Proposed fix

`@helm/shared` is the lowest-level package and depends on nothing, so it should be
the single source of truth. Export the regex (or an `isValidExternalId()` helper)
from `@helm/shared` and have `apps/api` and `@helm/orchestrator` import it,
removing the two local copies.

### Why it matters

Three independent copies can drift. If one is loosened or fixed without the others,
a path-traversal validation gap could open on whichever surface lags behind. The
probability is low, but the failure mode is a security hole, so it is worth closing.
