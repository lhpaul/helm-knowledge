# issue_168 — Implementation Plan

> **Status: ready.** Implements [specs/issue_168.md](../specs/issue_168.md)
> under [ADR-047](../decisions/047-price-table-source.md) (Accepted, option A;
> the owner's decisions of 2026-11-20 are in the spec). Nothing is implemented
> yet and no code PR exists in `lhpaul/helm`.

## Risk and deployment impact

- **Estimated risk: low.** The change is
  additive and read-side: a pure function over the usage records and a static
  table, plus one new block in the aggregate response and one column in the
  script. It does not touch the runtimes, the dispatcher, the stored job
  records, auth, the state machine or the review-loop budgets, and it cannot
  affect a dispatch. The residual risk is a misleading number (a wrong price
  or formula), mitigated by the label, the table `asOf`, the denominators, the
  `unpricedModels` list and human review of every table edit.
- **Not persisted (owner decision 1):** the estimate is derived at read time,
  so the stored record schema and the privacy allow-list do not change. Had it
  been persisted the risk would be medium; if that is ever reopened, treat it
  as a new decision (see the stop conditions).
- **Data migration: none.** Nothing new is written; existing #151 records are
  estimated at read time.
- **New dependencies: none.** No vitest, vite-node or other update. The table
  is a TypeScript module (no JSON import, so no `tsconfig` change).
- **Configuration on a deployed instance: none.** No new environment
  variable, file or `product.yaml` field. Rollout is a normal release;
  rollback is reverting it (the response gains a block that older clients
  ignore). ADR-047 is option A, so there is no operator file or override.
- **Workflows and deploy:** no change to `.github/workflows`, no deploy step.
- **Response compatibility:** the aggregate JSON gains `estimatedCostUsd` (in
  the overall block, each `byStage` entry and each `groups` entry); no
  existing field changes. The script gains one column.

## Preconditions (before the code PR)

1. Done (2026-11-20): the owner answered the open questions and ADR-047 is
   Accepted, option A.
2. **First price table:** the implementation session builds it in the
   `lhpaul/helm` PR, copying each rate from the provider's public pricing
   page and citing the URL and the date read per entry; the owner approves the
   values in that PR. It does not invent or estimate values; a model whose
   price cannot be traced to a public source is left out (it will show as
   `noPrice`).
3. Verify against the providers' documentation (spec decision 10) that Codex
   `reasoning_output_tokens` is a subset of `output_tokens`, and which Claude
   model ids `modelUsage` reports (dated snapshots, suffixes), to define the
   aliases.

## Implementation steps (phase 2, repo `lhpaul/helm`, base `develop`)

1. **Price table** (`apps/api/src/services/usage-price-table.ts`): typed
   `PRICE_TABLE = { version, asOf, models: [{ id, aliases?, rates,
   inputIncludesCacheRead, source, asOf }] }` as in ADR-047, plus a
   `lookupPrice(modelId)` (exact id or declared alias, nothing else).
2. **Estimator** (`apps/api/src/services/usage-estimate.ts`): a pure
   `estimateSessionCost(record, table) → { usd: number } | { usd: null,
   reason }` implementing the counter normalization (invalid → `null`), the formulas and
   the reason codes of the spec, in the documented check order. It reads only `record.tokens` and `record.model`
   (never `costUsd`, `costSource`, `DispatchResult` or `totalCostUsd`).
3. **Aggregation** (`apps/api/src/services/usage.ts`): extend the
   accumulator (`UsageCore`) with `estimatedCostUsd` (`total`,
   `sessionsEstimated`, `sessionsNotEstimated`, `notEstimatedReasons`,
   `unpricedModels`, plus `priceTable` and `note`), filled per session next to
   the existing `costUsd` code so it follows the same period filter,
   `byStage` and `groups`. Every `estimatedCostUsd` block (overall, each
   `byStage` entry, each `groups` entry) carries `priceTable` and `note`
   (spec: single response contract); the report-level `notes[]` repeats the
   note once. `costUsd` accumulation is not edited.
4. **Script** (`apps/api/src/scripts/usage.ts`): one extra column and the
   footer (note, table version/date); no combined total.
5. **Routes** (`apps/api/src/routes/usage.ts`): no change expected (the
   report object carries the block); only the response type is extended.
6. **Docs** (helm): `docs/local-dev.md` (the new block, how to read it),
   `CHANGELOG.md` `[Unreleased]` → Added. In helm-knowledge (separate small
   PR, `Refs lhpaul/helm#168`): update `operations/usage-cost-per-item.md`
   (replace "No USD is estimated" with how to read `estimatedCostUsd`, its
   denominator and that it is an estimate) and a short note on how to update
   the table and the monthly review (owner decision 8); no host names or private details. ADR-047 moves to Accepted in
   its own commit or PR once the owner decides.

## Tests

- `usage-estimate.test.ts`: both formulas with fixture token counts (the
  `write-success.jsonl` and `exec-success*.jsonl` numbers) against a
  **test-only table** with round, obviously fake rates so expected values are
  hand-checkable (AC 1, 2); every reason code and the precedence order of the spec (AC 3); failure-path records
  (AC 4); measured zeros → `0`; invalid counters (negative, `NaN`, infinite, above
  `Number.MAX_SAFE_INTEGER`, non-number) normalized to `null`; overflow of the
  per-session estimate and of the running total (huge counters and rates)
  → `inconsistentTokens` with a finite total; alias and no-prefix-match; no read of
  `costUsd`.
- `usage.test.ts` (extended): every block in the overall, `byStage` and
  `groups` output carries `note` and `priceTable` (AC 8); separation (AC 5: `costUsd`/`costSource` of
  every record unchanged, no summed field, Claude has both, Codex only the
  estimate); own denominator and reason counts on a mixed Claude/Codex/failed
  fixture (AC 6); overall, `byStage`, `groups`, `from`/`to`, empty scope
  (AC 7); legacy records and odd values (AC 10); `unpricedModels` capped and
  sorted.
- `usage-price-table.test.ts`: shape validation of the shipped table (AC 9), including duplicate ids, alias-to-id and alias-to-alias collisions across entries.
- `usage-script.test.ts` (or the existing script test): the extra column,
  footer and absence of a combined total (AC 8).
- `usage-route.test.ts` (extended): block present with the operator token,
  `401`/`400` unchanged (AC 11).
- Calibration fixture (documented, not a gate): the `write-success.jsonl`
  Claude session has a reported `costUsd`; a test asserts only that
  the estimate and `costUsd` are reported as two separate numbers, and a
  comment records how far the first real table lands from it.
- Regression: existing usage, dispatcher and scheduler tests unchanged and
  green. Run `pnpm install --frozen-lockfile && pnpm lint && pnpm test`
  before the PR.

## Files to touch

- helm: `apps/api/src/services/usage-price-table.ts` (+ test),
  `apps/api/src/services/usage-estimate.ts` (+ test),
  `apps/api/src/services/usage.ts` (+ test),
  `apps/api/src/scripts/usage.ts` (+ test), response typing in
  `apps/api/src/routes/usage.ts` if it declares one, `docs/local-dev.md`,
  `CHANGELOG.md`.
- helm-knowledge: `operations/usage-cost-per-item.md`, ADR-047 status.
- Not touched: runtimes, `UsageRecord`, dispatcher, scheduler, `JobStore`,
  workflows, deploy, `.env*`, lockfile, dependencies, auth middleware, state
  machine, review-loop budgets.

## Sequencing and size

One PR in `lhpaul/helm` (steps 1–6; roughly one table, one pure function, one
accumulator extension, one script column, tests), plus one small docs PR in
helm-knowledge. The code PR carries the first sourced price table and the owner
approves its values there (owner decisions 3 and 8); the unit tests use a
separate test-only table with obviously fake rates.

## Stop conditions for phase 2

Stop and ask the owner if: a vitest or any other dependency update seems
necessary; the owner reopens the decision to persist the estimate or to capture
per-model or cache-tier tokens (that edits `UsageRecord`, the runtimes and the privacy
test, and risk becomes medium); the implementation needs edits beyond the
files above; Codex `reasoning_output_tokens` turns out not to be a subset of
`output_tokens`; a price cannot be traced to a public source and date; or risk
turns out high.
