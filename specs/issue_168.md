# issue_168 — Specification

> **Status: draft, waiting for the owner.** Phase 1 (spec, plan, ADR) of
> [lhpaul/helm#168](https://github.com/lhpaul/helm/issues/168), the follow-up
> of [#151](https://github.com/lhpaul/helm/issues/151) (decision 5 of
> [specs/issue_151.md](issue_151.md)). [ADR-047](../decisions/047-price-table-source.md)
> is **Proposed**; the questions in "Open questions for the owner" must be
> answered before implementation. Priority: Low.

## Context

#151 records, per agent session, tokens and the USD the runtime reports.
Claude Code reports `total_cost_usd`; Codex reports tokens but no USD
(subscription billing), so Codex sessions have `costUsd: null` and an item run
with Codex cannot be compared in money with one run with Claude Code.

#168 adds a **separate, labelled estimate** computed from the recorded tokens
and a per-model price table. It never replaces or mixes with `costUsd`.
`costUsd` and `costSource` keep exactly the semantics defined in #151.

## What is recorded today (verified in `lhpaul/helm` develop, after PR #167)

Each usage record (`UsageRecord`, one per `spawn()` → `wait()`) holds
`tokens: { input, output, cacheRead, cacheCreation, reasoning }` (each a number
or `null`), `model: string | null`, `costUsd`, `costSource`, `runtime`,
`status`, timestamps. What each runtime fills in:

| | Claude Code | Codex |
| --- | --- | --- |
| `input` | `usage.input_tokens` (**excludes** cache reads and writes) | `turn.completed.usage.input_tokens` (**includes** the cached portion) |
| `output` | `usage.output_tokens` | `output_tokens` |
| `cacheRead` | `usage.cache_read_input_tokens` | `cached_input_tokens` (a subset of `input`) |
| `cacheCreation` | `usage.cache_creation_input_tokens` | always `null` (no such counter) |
| `reasoning` | always `null` | `reasoning_output_tokens` (informational; assumed to be a subset of `output`, see decision 4) |
| `costUsd` / `costSource` | `total_cost_usd` / `reported` | `null` / `unknown` |
| `model` | keys of the result's `modelUsage`, sorted and joined with `,` (so a session that used two models reads `a,b`); falls back to the `--model` hint | only the `--model` hint from `product.yaml`; `null` when none was passed (the CLI's default model is not reported) |
| Failed, cancelled, timed-out or no-result session | all counters `null`, `model` = hint or `null` | same |

Consequences that shape this spec:

1. The record holds **session totals**, not per-model tokens. A Claude session
   whose `modelUsage` has several models cannot be priced from the record
   alone (the tokens are not split per model).
2. Claude's cache-write counter is one number: the 5-minute and 1-hour cache
   write tiers (which have different list prices) are not distinguished.
3. Codex's `model` is only as good as the `product.yaml` hint.

## Proposal

### The field

A new **derived** value `estimatedCostUsd`, per session, computed from
`tokens` and `model` with the price table of
[ADR-047](../decisions/047-price-table-source.md). It is:

- **separate**: never added to, substituted for, or defaulted from `costUsd`;
  no field, total or table in the API sums the two;
- **labelled**: wherever it appears it is accompanied by the fixed note
  `estimate: tokens × public list price, not a billed amount`, and the price
  table version and as-of date used;
- **nullable**: `null` when it cannot be computed. Never `0` for "unknown".

It is computed when the aggregate is read (proposal; decision in open question
1), so it needs no change to the stored record and covers #151 records that
already exist.

### Formula

Prices are USD per 1,000,000 tokens, per model and per token type. A price
table entry (ADR-047) declares the rates it has:

| Rate | Meaning |
| --- | --- |
| `input` | uncached input |
| `cacheRead` | cache read / cached input |
| `cacheCreation` | cache write (only for providers that bill it) |
| `output` | output (includes reasoning tokens) |

Per session, with `r = rate / 1_000_000`:

- **Anthropic-style entry** (has `cacheCreation`; used for Claude Code):
  `input·r.input + cacheRead·r.cacheRead + cacheCreation·r.cacheCreation + output·r.output`
- **OpenAI-style entry** (no `cacheCreation`; used for Codex, where `input`
  already includes the cached portion):
  `(input − cacheRead)·r.input + cacheRead·r.cacheRead + output·r.output`

Which formula applies is declared by the entry (`inputIncludesCacheRead:
true|false`), not inferred from the runtime name, so a Claude model served by
another runtime, or a future runtime, is priced correctly.
`reasoning` is **not** added: it is a subset of `output` (decision 4).

Arithmetic is plain floating point; stored/returned values are not rounded
(the table output rounds for display only). Tests compare with a tolerance.

### When it is `null` (and why)

Every `null` has a reason, counted separately in the aggregate. Before any
check, each counter is normalized: a value that is not a finite, non-negative
number no larger than `Number.MAX_SAFE_INTEGER` (negative, `NaN`, infinite, too
large, string, missing) is treated as `null`
(unreported), so a malformed or legacy record can never produce a negative or
non-finite estimate; it falls under `noTokens` or `incompleteTokens` like any
unreported counter. The checks then run in this fixed order and the first one that fails decides the reason, so the
order never needs a price entry before one has been identified:

| # | Reason code | Condition |
| --- | --- | --- |
| 1 | `noTokens` | all five counters are `null` (the session produced no usage report: error, cancel, timeout, orphan gap) |
| 2 | `noModel` | `model` is `null` |
| 3 | `multiModel` | `model` contains `,` (several models in one session; tokens not split) |
| 4 | `noPrice` | the model has no entry in the table (exact id, or a table-declared alias; no prefix or fuzzy matching) |
| 5 | `incompleteTokens` | the entry is known and some counter it requires is `null` (required counters below) |
| 6 | `inconsistentTokens` | the entry has `inputIncludesCacheRead` and `cacheRead > input`; or the computed estimate is not finite; or adding it to the running aggregate total would make that total non-finite (overflow: the session is counted here instead and the total stays finite) |

A session with some counters reported but no usable model is therefore
`noModel`/`multiModel`/`noPrice`, and `incompleteTokens` only exists once the
entry is known. Required counters follow the entry: `input`, `output` and
`cacheRead` always; `cacheCreation` only when the entry has a `cacheCreation`
rate. So a Codex session (`cacheCreation: null` by design) is estimable, while
a Claude session missing `cacheCreation` is `incompleteTokens`. A measured `0`
is a number: a session with all counters measured as `0` estimates `0`; a
session with all counters `null` is `noTokens`.

### Aggregation

The item and period aggregates of #151 (`GET …/items/:externalId/usage`,
`GET …/usage?…&groupBy=…`, the `usage` script) gain one more block, next to
`costUsd`, never inside it:

```json
"estimatedCostUsd": {
  "total": 0.0,
  "sessionsEstimated": 8,
  "sessionsNotEstimated": 6,
  "notEstimatedReasons": { "noTokens": 2, "noPrice": 4 },
  "unpricedModels": ["<model id>"],
  "priceTable": { "version": "…", "asOf": "YYYY-MM-DD" },
  "note": "estimate: tokens × public list price, not a billed amount"
}
```

`priceTable` and `note` are part of **every** `estimatedCostUsd` block (overall,
each `byStage` entry, each `groups` entry), so a block read on its own is
always labelled and tied to a table version. This is the single response
contract; the report-level `notes[]` additionally repeats the note once.

- It has **its own denominator**: `sessionsEstimated + sessionsNotEstimated`
  equals `sessions`, independent of `costUsd.sessionsWithCost` /
  `sessionsUnknown`. A Claude session usually appears in both (reported and
  estimated); a Codex session only in the estimate; a failed session in
  neither.
- `total` sums only the sessions that were estimated; read it with
  `sessionsEstimated`. An all-Codex item with no priced model shows
  `total: 0, sessionsEstimated: 0, sessionsNotEstimated: N`, and the
  `unpricedModels` list says why (the same "a bare `0` means nothing known"
  rule as `costUsd`).
- It appears in the overall aggregate, in every `byStage` entry and in every
  `groups` entry, with the same period filters as the sessions (session
  `startedAt`). The same `from`/`to`/`groupBy`/`400`/`401` behaviour applies;
  no new route.
- `unpricedModels` lists the distinct model ids (≤ 20, sorted) seen in
  `noPrice` sessions so the gap is actionable: add a price or an alias.
- The `usage` script prints one extra column, headed `est. USD (tokens×list)`,
  and a footer with the note and the table version; it never prints a combined
  "total cost".
- **Calibration, not blending.** Claude sessions have both numbers. The
  estimate is not corrected toward `costUsd`; the owner may compare them by
  eye (and a test fixture does, see the plan) to judge how far the table is
  from reality.

### What does not change

`costUsd`, `costSource`, `costUsd.total/sessionsWithCost/sessionsUnknown`, the
legacy `totalCostUsd`/`DispatchResult.costUsd`, the stored record schema (if
open question 1 is answered "derive"), review-loop budgets, auth (the routes
are the same `GET`s behind the operator token), workflows and deploy.

## Acceptance Criteria

Each criterion is covered by an automated test.

1. **Formula, Anthropic-style.** A session with all four counters measured and
   a priced model yields the sum in the formula (fixture `write-success.jsonl`
   tokens with a test-only table; values chosen by the test, not claimed as
   real prices).
2. **Formula, OpenAI-style.** A Codex session (fixtures `exec-success*.jsonl`
   tokens) yields `(input − cacheRead)·in + cacheRead·cached + output·out`;
   `reasoning` is not added; `cacheCreation: null` does not block it.
3. **Null, never zero.** Each reason code in the table above produces `null`
   with that reason, and the precedence is tested: all-null tokens with a
   null or unknown model → `noTokens`; partial tokens with `model: null` →
   `noModel`; partial tokens with an unknown model → `noPrice`; partial
   tokens with a priced model → `incompleteTokens`; `a,b` model →
   `multiModel`; `cacheRead > input` for an `inputIncludesCacheRead` entry →
   `inconsistentTokens`. A measured all-zero session yields `0`. Counters of
   `Number.MAX_SAFE_INTEGER` with a priced model never yield a non-finite
   estimate or total (the overflow case is `inconsistentTokens`). A record with
   a negative, `NaN`, infinite, too large or non-numeric counter treats that counter as
   `null` (all invalid → `noTokens`; some invalid with a priced model →
   `incompleteTokens`) and never yields a negative or non-finite estimate.
4. **Failure paths.** Error, cancel, timeout and no-result sessions are
   `noTokens`; the dispatch outcome and `costUsd` are untouched.
5. **Separation.** `costUsd` and `costSource` of every record are byte-identical
   with the feature on; no response field equals or sums `costUsd` with the
   estimate; a Claude session keeps its reported `costUsd` and also gets an
   estimate; a Codex session keeps `costUsd: null`.
6. **Own denominator.** `sessionsEstimated + sessionsNotEstimated = sessions`;
   `notEstimatedReasons` adds up to `sessionsNotEstimated`; the block is
   independent of the `costUsd` counts (mixed Claude/Codex fixture).
7. **Item, stage, period, group.** The block appears in the overall aggregate,
   `byStage` and each `groups` entry, honours `from`/`to` on the session's
   `startedAt`, and an empty scope reports `total: 0`, `sessionsEstimated: 0`,
   `sessionsNotEstimated: 0`.
8. **Labelled.** Every `estimatedCostUsd` block (overall, `byStage`, `groups`)
   carries `note` and `priceTable`; the script output carries the note and
   the table version and as-of date and prints no combined cost.
9. **Table integrity.** A test validates the shipped table: every rate is a
   finite non-negative number, every entry cites a source URL and a date,
   every id and alias is unique across all entries (no alias equals another
   entry's id or alias, and no id repeats), and `version`/`asOf` are
   present. (Values themselves are reviewed by a human, not tested.)
10. **Legacy and unknown data.** #151 records written before this change (no
    new fields needed) are estimated like new ones; legacy jobs without
    `usage` add nothing; the read path never throws on odd records (unknown
    model strings, negative or missing counters).
11. **Auth, errors, privacy.** Same `401`/`400` behaviour as #151; the new
    output holds no prompts, paths or credentials, only numbers, model ids and
    the table metadata.
12. **Repo checks.** `pnpm lint` and `pnpm test` pass; no workflow, deploy or
    dependency changes; no new environment variable (option A of ADR-047).

## Out of Scope

- Estimating the cost of the external reviewer, or any human time.
- Any change to `costUsd`/`costSource`, or replacing/“correcting” a reported
  cost with an estimate.
- Billing-grade accuracy: tiered or long-context pricing, batch discounts,
  fast-mode multipliers, web-search or tool fees, the 5-minute vs 1-hour cache
  write tiers and regional multipliers are not modelled; the estimate is a
  list-price approximation and says so.
- Persisting prices per record (see open question 1), a UI, alerts, budgets.
- Fetching prices from a network source at runtime (ADR-047 alternative C).
- Backfilling `model` for old records.

## Decisions proposed in this spec (confirm with the answers below)

1. **Derived at read time**, not stored on the record (open question 1).
2. **Price table in the repo** as a versioned module (ADR-047, Proposed).
3. **`null` with a counted reason**, never `0`, for anything not computable.
4. **Reasoning tokens are not added** to `output`. Codex's counters are
   `input_tokens`, `cached_input_tokens`, `output_tokens` and
   `reasoning_output_tokens`; the fixtures are consistent with reasoning being
   a subset of output (for example 652 reasoning of 939 output). The
   implementation verifies this against the Codex documentation before
   shipping; if it is wrong the formula, and this spec, change.
5. **Exact model-id match plus declared aliases**, no prefix matching, so a
   new model is `noPrice` instead of silently priced as an older one.
6. **No per-model split of multi-model Claude sessions** in v1 (`multiModel`
   → `null`). Splitting would need `modelUsage` tokens in the record.

## Open questions for the owner

Answers change what gets built. Recommendation first.

1. **Derive or persist?** (a) *Derive at read* (recommended): no migration,
   no schema or privacy-test change, covers existing records, a corrected
   price table corrects history; cost: past estimates move when the table
   changes. (b) *Persist on the record* at session end: stable history; cost:
   a new field on every record, a stale price baked in, no coverage of
   existing records, the privacy allow-list and `UsageRecord` change, and
   risk rises from low to medium.
2. **Which models get a price, and from which public source and date?** The
   models in play are those in `product.yaml` for Codex (and any Claude model
   Helm runs). Prices are not written in this phase: they must be copied from
   the provider's public pricing page, with URL and date, in the
   implementation PR. Who supplies/approves the first table?
3. **Should Codex estimates use API list prices?** On a subscription the
   owner does not pay per token, so the figure is "what this usage would cost
   at API list price", useful for comparison, not for budgeting. Confirm that
   is the intended meaning and wording of the label.
4. **Estimate for Claude sessions too?** Recommended yes (enables calibration
   against `costUsd` and keeps one rule for all runtimes). Alternative: only
   where `costUsd` is `null`.
5. **Cache write tier.** Treat all `cacheCreation` as one rate (recommended;
   say so in the note) or ask #151 to also capture the 5-minute/1-hour split
   (a record change; not recommended for a Low item).
6. **Multi-model Claude sessions.** Leave `null` (recommended) or capture
   per-model tokens in the record (a #151 schema change).
7. **Where should price updates be reviewed?** In the `lhpaul/helm` PR that
   edits the table (recommended), with a periodic check cadence the owner
   names (for example monthly, or when a new model is adopted).
