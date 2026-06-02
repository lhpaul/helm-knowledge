# ADR-026: Product-readiness gate

**Date:** 2026-06-02
**Status:** Accepted
**Context:** Bloque I — readiness/hardening; gap surfaced by the Arriendo Fácil pilot

---

## Context

The spec-writer reads a product's code-repo docs (`README`, agent instructions)
to ground the spec it derives from a tracker task. When those docs are missing or
content-drifted, the spec-writer doesn't fail — it **invents** plausible-looking
context and produces a spec built on fiction. The Arriendo Fácil pilot hit this:
a drifted `CLAUDE.md` led the spec-writer down a wrong path, and the failure was
silent (a confident-but-wrong spec), not loud (an error the operator could act on).

There was no precondition on dispatch. Any item at `discovery` could be dispatched
to the spec-writer regardless of whether the product was actually documented well
enough to spec against.

We want a cheap, opt-in check that converts this silent failure into a loud,
actionable one — *before* an agent dispatch is spent — without disrupting the
running pilot or other products.

---

## Decision

### 1. A per-product `workflow.readiness_gate` with three modes

`workflow.readiness_gate: skip | warn | required`, **default `skip`**.

- `skip` — no check (backward compatible; existing `product.yaml` files are
  unaffected, and the running leasity-tenants pilot is untouched unless opted in).
- `warn` — run the check, log any gaps, but proceed with dispatch.
- `required` — block dispatch when the product is not ready.

Per-product (not global) is deliberate: the gate must not start blocking the live
pilot the moment it merges. A product opts in (`required`) when its docs are
expected to be in place; the playground can run `required` from day one.

### 2. What "ready" means

For each code repo with `role: 'app'` (`docs` / `infra` repos are **exempt** — the
spec-writer reads the app's docs), the repo must have:

- a `README.md`, **and**
- agent instructions: one of `AGENTS.md` / `AGENT.md` / `CLAUDE.md`. `AGENTS.md`
  (plural) is the cross-tool open standard (agentsmd.com); the others are accepted
  for compatibility. This list is the single source of truth (`AGENT_INSTRUCTION_FILES`)
  shared by the gate **and** the `fetchProductContext` reader, whose fallback chain
  is extended here from `AGENT.md → CLAUDE.md` to `AGENTS.md → AGENT.md → CLAUDE.md`
  so the two cannot drift.

### 3. Existence checks via the GitHub Contents fetch, no clone

`checkProductReadiness(product, token, fetchFn?)` reuses the same
`raw.githubusercontent` primitive as `fetchProductContext` (the dispatch path does
not clone the code repo — the implementer clones later). All current and near-term
products are on GitHub; a shallow-clone fallback for a non-GitHub remote can be added
if one ever appears. Per-repo and per-file checks run concurrently.

Error semantics are explicit:

- **404** → file absent → reported in `missingContext`.
- **Unparseable repo URL** or **missing `GITHUB_TOKEN`** → reported as
  **unverifiable** (it does *not* silently pass — an un-checkable repo is treated
  as not-ready so `required` fails loudly).
- **Any other non-2xx / network error** → **propagates**. The route maps it to a
  `502`, never a `422`: a GitHub outage is an infrastructure failure, not a client
  precondition failure.

### 4. The gate guards the spec-writer entry only

In the dispatch route, the gate runs only when the **resolved specialist** would be
the spec-writer (stage `discovery`, or an explicit `specialistId: spec-writer`) and
`readiness_gate !== 'skip'`. It runs **before** job creation, so a non-ready product
returns `422` instead of a `202` that fails downstream.

Later stages (`plan-writer`, `implementer`, `reviewer-fanout`) and the
operator-triggered remediators (`spec-/plan-/code-remediator`) **bypass** the gate:
they operate on structured artifacts (a spec, a plan, an open PR), not raw repo docs,
and the remediators are themselves the fix for missing context — gating them would be
self-defeating. Inductively, if the spec-writer cleared the gate, downstream stages
can trust the docs were present.

`resolveSpecialistId(currentStage, specialistId?)` is extracted from the dispatcher
and exported from `@helm/orchestrator` so the route decides "would this run the
spec-writer?" from the single source of truth, not a duplicated mapping.

### 5. Route responses

- `required` + not ready → `422 { error: 'Product not ready for dispatch', missing_context: [{ repo, role, missing[] }] }`.
- `required` + check throws → `502 { error: 'Readiness check failed' }`.
- `warn` + not ready or throws → `console.warn`, proceed with `202`.
- `skip` → no check, no calls.

---

## Consequences

- **Silent invention becomes a loud, actionable 422.** Operators see exactly which
  repo is missing which file before an agent dispatch is spent.
- **The pilot is safe.** Default `skip` means no behavior change for leasity-tenants
  or any existing product until it explicitly opts in.
- **Honest status codes.** A precondition failure (`422`) and an infrastructure
  failure (`502`) are never conflated, mirroring the dispatch-honesty principle from
  earlier sessions.
- **Cheap.** Existence checks are a handful of `raw.githubusercontent` GETs on the
  request path; no clone.
- **Reader/gate consistency.** Extending the agent-instructions fallback to include
  `AGENTS.md` keeps the spec-writer's context reader aligned with what the gate
  accepts.

---

## Alternatives considered

- **Always-on hard gate (no `skip`/`warn`).** Rejected: it would start `422`-ing the
  live pilot's dispatches the moment it merged and the pilot restarted. Per-product,
  default-`skip` is the safe rollout.
- **Gate every dispatch, not just the spec-writer.** Rejected: product-readiness is
  about the docs the spec-writer reads; blocking a `plan-remediator` or `implementer`
  on a missing `README` is incoherent (they work on artifacts, not repo docs) and
  blocking remediators is self-defeating.
- **Shallow-clone the repo to inspect files.** Rejected for v0: heavier and slower on
  the request path; the Contents fetch is sufficient for existence checks and matches
  the existing `fetchProductContext` mechanism. Revisit only for a non-GitHub remote.
- **Validate that files referenced in the issue body exist.** Deferred (explicit
  follow-up). Issue bodies legitimately reference files that don't exist yet (every
  "create X" issue would false-positive); the motivating pilot failure was
  content-drift in `CLAUDE.md`, which the repo-doc presence check already addresses.
  Revisit once the gate has produced real false-positive data.
- **Treat an unverifiable repo as ready.** Rejected: silently passing an un-checkable
  product defeats the gate's purpose. Unverifiable is reported as not-ready.

---

## References

- `packages/orchestrator/src/readiness.ts` — `checkProductReadiness`
- `packages/orchestrator/src/specialists/fetch-product-context.ts` — `AGENT_INSTRUCTION_FILES`, fallback chain, `fetchRawFile`
- `packages/orchestrator/src/dispatcher.ts` — `resolveSpecialistId`
- `apps/api/src/routes/dispatch.ts` — gate wiring, 422/502/202 responses
- `packages/shared/src/config/product-schema.ts` — `workflow.readiness_gate`
- `operations/onboarding-product.md` — `readiness_gate` field
- [ADR-021](021-codex-runtime.md) — note: the "H3" referenced there (per-specialist hybrid runtimes) is a *different* item; this ADR is the roadmap's H3 (readiness gate)
- [ADR-024](024-spec-plan-remediator.md) — the remediators that the gate deliberately exempts
