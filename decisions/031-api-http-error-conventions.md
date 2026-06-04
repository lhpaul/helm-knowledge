# ADR-031: API HTTP error conventions

**Date:** 2026-06-04
**Status:** Accepted
**Context:** Bloque I — readiness/hardening; API-wide consistency advisory surfaced by the Haystack triage of helm#42 (LEA-109 rollback session)

---

## Context

Helm's API routes (`apps/api/src/routes/`) hand-rolled their own error-response
shapes and path-param validation. Across four routes — `items.ts`,
`dispatch.ts`, `rollback.ts`, `jobs.ts` — the pattern was ~80% consistent but
diverged in details:

- **Error-class → HTTP mapping** was a per-route `if (err instanceof X) return
  c.json({ error: … }, status)` ladder, repeated with small variations
  (`items.ts` mapped `ItemAlreadyExistsError`/`ItemNotFoundError`/
  `WorkflowTransitionError`; `rollback.ts` mapped `ItemNotFoundError`/
  `StageMismatchError`).
- **`externalId` path-param validation** was `EXTERNAL_ID_REGEX.test(externalId)`
  plus an explicit `'.'` / `'..'` defense-in-depth check, copy-pasted verbatim
  across `dispatch.ts`, `rollback.ts`, and `jobs.ts` — and present **without**
  the dot-defense in `items.ts` (a no-op difference, since the regex's leading-dot
  lookahead rejects `.`/`..` anyway).
- **`jobId` validation** used `JOB_ID_REGEX` in `jobs.ts`.

The error-response **shape** (`{ error: string }` plus optional structured
fields like `details`, `missing_context`, `runningJobId`) was already
consistent; the divergence was in the *implementation*, not the wire format.

The Haystack triage of helm#42 (the rollback session, ADR-029) flagged this
divergence as a real-but-deferable tech debt: the rollback route was the
**fourth** to accumulate the duplicated path-param pattern. The driver kept it
consistent with `items.ts`/`dispatch.ts` rather than diverging further, but the
inconsistency itself is the debt. The fourth duplication is the natural trigger
to centralize.

## Decision

Centralize the canonical error-class→HTTP mapping and the path-param validation
in a new HTTP-presentation helper, `apps/api/src/lib/http-errors.ts`. Routes
adopt the helpers; the response **bytes are unchanged** — every existing route
test passes unmodified.

### Helper home — `apps/api/src/lib/`

A new `apps/api/src/lib/` directory is the home for HTTP-presentation helpers
(response mapping, path-param validation). This separates the HTTP layer from
`apps/api/src/services/`, which is the **data layer** (item-store, job-store,
errors, types, sync). The monorepo already uses `web/src/lib/` for the same
role on the web side. Establishing the convention while the surface is one file
is cheaper than refactoring later once 3–4 helpers have accumulated under
`services/`.

The existing `EXTERNAL_ID_REGEX` (`services/types.ts`) and `JOB_ID_REGEX`
(`services/job-store.ts`) constants **stay in their current locations** for this
session — they have their own callers, and the validators import them. The
`lib/` convention applies to *new* HTTP-presentation helpers; a follow-up
session may relocate the constants alongside the validators if the surface
accumulates.

### Validators — discriminated-union return (no throw)

```ts
validateExternalId(value): { ok: true; value } | { ok: false; response: { body; status: 400 } }
validateJobId(value):      { ok: true; value } | { ok: false; response: { body; status: 400 } }
```

The route destructures and either uses `result.value` or returns
`c.json(result.response.body, result.response.status)`. Validators never throw,
so the route stays in straight-line control flow. `validateExternalId` folds in
the `'.'` / `'..'` dot-defense uniformly, so `items.ts` gains it for free (a
no-op for the regex, as noted above).

### Error mapper — shape-preserving, message-faithful

```ts
mapErrorToResponse(error, extras?): { body: ErrorResponseBody; status: 400 | 404 | 409 | 422 | 500 }
```

| Error class                | Status | Body                              |
| -------------------------- | ------ | --------------------------------- |
| `ItemNotFoundError`        | 404    | `{ error: error.message, …extras }` |
| `ItemAlreadyExistsError`   | 409    | `{ error: error.message, …extras }` |
| `StageMismatchError`       | 400    | `{ error: error.message, …extras }` |
| `WorkflowTransitionError`  | 422    | `{ error: error.message, …extras }` |
| _unknown_                  | 500    | `{ error: 'Internal server error', …extras }` |

Each recognized class returns its own `.message`. This is **byte-identical** to
the strings the routes built by hand, because the error classes already set
`.message` to exactly those strings — e.g. `ItemNotFoundError.message` is
`"Item not found: <id>"`, which is what `items.ts` and `rollback.ts` emitted
literally. Unknown errors map to a generic `500` with **no `error.message`
leak** (no internal paths/state in the body).

### Migration shape — preserving Hono's default 500

Today, unrecognized errors `throw err` from the route catch block and reach
Hono's default error handler (generic 500). To keep that behavior byte-for-byte,
the migrated catch blocks re-throw when the mapper returns 500:

```ts
} catch (err) {
  const mapped = mapErrorToResponse(err);
  if (mapped.status === 500) throw err; // keep Hono's default 500 path for unknowns
  return c.json(mapped.body, mapped.status);
}
```

So `mapErrorToResponse`'s 500 branch is never emitted by a route — it is
exercised directly by `http-errors.test.ts`. (In this session no recognized
class maps to 500, so `status === 500` unambiguously means "unknown".)

### Locked decisions

- **Approach:** helpers + explicit route-level `try/catch` — **not** Hono
  `.onError()` middleware.
- **Validator shape:** discriminated union (no throw).
- **Response shape:** preserved exactly. **Not breaking.**
- **Error classes:** the five canonical ones — `ItemNotFoundError`,
  `ItemAlreadyExistsError`, `StageMismatchError` (`apps/api/src/services/errors.ts`),
  `WorkflowTransitionError` (`@helm/workflow`) — plus the unknown→500 catch-all.
  No new classes.
- **Excluded — `webhooks.ts`:** returns `c.body(null, 401)` for signature
  failures by design (no JSON leak of internal state). Out of scope.
- **Excluded — `products.ts`:** uses Zod schemas with `.refine()` for slug +
  externalId — a different validation surface (Zod's error messages vs the
  regex-based 400 body). Refactoring it would change the wire format; open as a
  follow-up if it surfaces.
- **Excluded — route-specific status codes that don't map to a known class stay
  inline:** `dispatch.ts`'s readiness-gate `422` (`{ error, missing_context }`)
  and readiness-check-failure `502`; the concurrency `409`
  (`{ error, runningJobId }`) in `dispatch.ts`/`rollback.ts`; and the Zod
  parse-failure `400` (`{ error: 'Invalid request body', details }`). These are
  not error-class mappings and remain explicit `c.json(...)` returns.

## Alternatives considered

- **Hono `.onError()` middleware** — routes `throw`, middleware catches and
  maps. Rejected: changes the mental model (error flow becomes implicit, split
  from the handler), and the routes' inline `try/catch` makes the error paths
  readable at the call site. Open as a separate ADR if the boilerplate
  accumulates (e.g. 5+ more routes).
- **Restructuring the response shape** to `{ error: { code, message, details } }`
  or similar. Rejected: breaking change for any future client, no urgent driver.
  Keep the current `{ error: string } & extras` shape.
- **Single throwing validator** (`validateExternalId(value): string`, throws on
  invalid). Rejected: forces every route to wrap the path-param check in
  `try/catch`; the discriminated union keeps the route in straight-line flow.

## Consequences

- New routes call `validateExternalId`/`validateJobId` + a single `try/catch`
  with `mapErrorToResponse` to get the full canonical error-class coverage. The
  per-route `instanceof` ladders and the duplicated regex+dot-defense are gone.
- Future error classes go in `apps/api/src/services/errors.ts` and get a mapping
  in `http-errors.ts` — single source of truth.
- The `extras` parameter on `mapErrorToResponse` exists for **forward
  compatibility** — no current caller threads it through the mapper. Today's
  `details` / `missing_context` / `runningJobId` bodies are emitted by **inline**
  returns (Zod parse failures, the readiness gate, the concurrency guard) that
  stay inline per the locked scope. `extras` is covered by `http-errors.test.ts`
  directly so the behavior is pinned for the first real caller.
- The migration is purely internal: `apps/api/src/lib/` is established as the
  HTTP-presentation home, but no behavior or wire format changed.

## Tests

- New `apps/api/src/lib/http-errors.test.ts` covers each canonical error-class
  mapping, the unknown→500 catch-all (asserting no `error.message` leak), the
  `extras` merge (including on the 500 body), and the validator happy/error
  paths (valid IDs; `'.'`/`'..'`; regex failures; invalid UUIDs) — each
  asserting the 400 body matches the routes' existing shape.
- Existing route tests (`items.test.ts`, `dispatch.test.ts`, `rollback.test.ts`,
  `jobs.test.ts`) are **unchanged** — they verify the helpers end-to-end as a
  side effect, confirming byte-identical responses.

## Revisit when

- Hono `.onError()` middleware becomes attractive (e.g. 5+ more routes accumulate
  the `try/catch` boilerplate).
- A breaking response-shape change is genuinely required.
- `products.ts`-style Zod validation surfaces a real bug a unified validator
  would have caught — at which point reconcile the two validation surfaces.
- The HTTP-helper surface in `lib/` grows enough to justify relocating
  `EXTERNAL_ID_REGEX` / `JOB_ID_REGEX` out of `services/` alongside the
  validators.

## References

- ADR-008 — async dispatch (the `/dispatch` route family)
- ADR-026 — product-readiness gate (`dispatch.ts`'s inline `422`/`502`)
- ADR-029 — implementer rollback on failure (`rollback.ts`; the session whose
  Haystack triage flagged this consistency advisory)
- AF pilot LEA-109 retro — the rollback session that surfaced the recurring
  inconsistency
