# ADR-047: Source and maintenance of the per-model price table

**Date:** 2026-11-20
**Status:** Proposed (waiting for the owner)
**Related:** lhpaul/helm#168 (this decision), lhpaul/helm#151,
`specs/issue_168.md`, `plans/issue_168.md`, ADR-046 (usage record storage),
ADR-021 (Claude Code and Codex runtimes)

---

## Context

Issue #168 estimates USD from the tokens recorded per session (#151), so Helm needs
a table of prices per model and token type (input, cached input / cache read,
cache write where billed, output). #151 deliberately kept pricing out of the
runtimes, and the estimate must never be confused with the reported `costUsd`.

Facts that constrain the choice:

- Prices are published by the providers on public pages, change over time and
  differ per model; Helm cannot know them from the runtime output (Codex
  reports no USD at all).
- Helm is open source and its repos are public: the table must hold only
  public data, each value with its source and date, and never a number copied
  from a private invoice or account.
- Helm has no database; operational data is files (ADR-046) and configuration
  is `product.yaml` (in the knowledge repo, per Product) plus environment
  variables on the instance.
- A wrong or stale price silently produces a wrong estimate, so gaps must be
  visible (a model with no price is `noPrice`, listed in `unpricedModels`) and
  every number must be reviewable.
- The estimate is derived at read time (spec, open question 1), so the table
  in effect is applied to all history.

No price values are proposed in this ADR. The first table is filled in the
implementation PR, copying from the providers' public pricing pages, citing
the URL and date of each entry.

## Decision (proposed)

**Option A: a versioned module in `lhpaul/helm`**
(`apps/api/src/services/usage-price-table.ts`), a typed constant reviewed
through normal PRs, with this shape per model:

- `id` (the model id as the runtime reports it) and optional `aliases`
- `rates` in USD per 1,000,000 tokens: `input`, `cacheRead`, `output`, and
  `cacheCreation` only where the provider bills cache writes
- `inputIncludesCacheRead: boolean` (Codex-style counters vs Claude-style)
- `source` (public URL) and `asOf` (`YYYY-MM-DD`) per entry

and a table-level `version` and `asOf`, echoed in every response that shows an
estimate. Maintenance: a price change or a new model is a small PR that edits
this file, cites the source and date, and is reviewed like code; the owner
names a review cadence (spec, open question 7). A gap shows up in
`unpricedModels`, not as a wrong number.

## Options

### A. Versioned module in the app repo (recommended)

- Pros: public, reviewable, diffable; atomic with the code that reads it; no
  new configuration, file, dependency or deployment step; the table version in
  responses ties an estimate to an exact table; works offline; trivially
  testable (shape validation, fixtures).
- Cons: a price change needs a PR and a release (acceptable: Low priority,
  prices move slowly relative to Helm's cadence); one table for every
  instance, so an operator with negotiated prices cannot override it.
- Mitigation: the `unpricedModels` list and the `asOf` date make staleness
  visible; D below is the escape hatch if per-instance prices are needed.

### B. Operator file (path in an environment variable) or a section in `product.yaml`

- Pros: prices change without a release; per-instance or per-Product prices
  (negotiated rates).
- Cons: new configuration on every deployed instance and a new failure mode
  (missing, malformed or stale file); with `product.yaml` the table would live
  in the knowledge repo, away from the code that interprets it, and every
  Product would repeat the same public prices; harder to review in one place
  and to test; needs a documented schema and loader errors.

### C. Fetch prices at runtime from a network source (provider API or a community price list)

- Pros: always fresh; no manual upkeep.
- Cons: Helm has no stable provider pricing API to depend on, and a community
  list is a third-party supply-chain input to the numbers; a network call in a
  read path (or a cache with its own storage and invalidation); estimates
  stop being reproducible; offline and test determinism are lost; the data
  cannot be reviewed before it takes effect. Not recommended for an estimate
  whose value is comparability.

### D. Repo module as default plus an optional operator override file

- Pros: A's reviewability by default, B's flexibility when someone needs it.
- Cons: two sources to document and merge (override semantics, precedence,
  version reporting); more code than #168 warrants today. Can be added later
  without breaking A (the override is additive), so it is a follow-up, not v1.

### E. No table: ask the owner for a single flat rate per runtime

- Pros: trivial.
- Cons: ignores that cached input and output are priced very differently and
  that models differ widely; the estimate would be misleading, so it fails the
  issue's requirement of prices per model and token type.

## Consequences (if A)

- Positive: no migration, no dependency, no deployed-instance configuration;
  reversible by removing the block from the aggregate.
- Negative: prices are only as fresh as the last PR; estimates for past
  periods change when the table changes (the table version in the response
  says which one applied).
- Neutral: the table is public data with sources, consistent with the
  repository being public.

## Open questions for the owner

1. Option A, B, C, D or E? (Recommendation: A.)
2. Who supplies and approves the first table (models, sources, date)? It is
   not written in this phase.
3. Review cadence for the table (monthly, per new model adopted, or both).
4. Does any instance need prices different from the public list? If yes, D
   moves from "later" to "now".

## Revisit when

- An instance needs negotiated or per-Product prices (add D).
- The set of models grows enough that manual upkeep is a burden.
- A provider publishes a stable machine-readable pricing source worth
  trusting (reconsider C, with a pinned and reviewed snapshot).
- Estimates need to be stable across table changes (revisit persisting the
  estimate on the record, spec open question 1).
