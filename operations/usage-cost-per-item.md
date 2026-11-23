# Cost per item: reading the usage aggregate

Runbook for the usage records introduced by
[lhpaul/helm#151](https://github.com/lhpaul/helm/issues/151)
([ADR-046](../decisions/046-usage-record-storage.md),
[spec](../specs/issue_151.md)). It explains how to read the aggregate and what
"unknown" means. "Cost" here means agent cost only; human wait time is not
measured.

## What is recorded

Each agent session (one `spawn()` to `wait()`) leaves one record on its job
(`data/jobs/<jobId>.json`, field `usage`): item, job, specialist, stage, runtime,
model, start/end, duration, token counters, cost and cost source. Records hold
no prompts, outputs, file paths or credentials. Retention is the same as
`data/`; there is no cap.

The stage comes from the job's specialist, not the session's: `spec`
(spec-writer, spec draft reviewer, spec remediator), `plan` (the plan
equivalents), `code` (implementer) and `review` (reviewer-fanout, including
code remediation inside the review loop). The reviewer, adjudicator and
remediator sessions of an early spec or plan review loop therefore count as
`spec` or `plan`.

## How to read it

Both routes are `GET`, read-only and behind the existing `HELM_API_TOKEN`; no new
configuration is needed.

```bash
# One item, with a per-stage breakdown
curl -H "Authorization: Bearer $HELM_API_TOKEN" \
  http://127.0.0.1:3001/api/products/<slug>/items/<externalId>/usage

# A product over a period (from inclusive, to exclusive; ISO date or date-time)
curl -H "Authorization: Bearer $HELM_API_TOKEN" \
  "http://127.0.0.1:3001/api/products/<slug>/usage?from=2026-11-01&to=2026-12-01&groupBy=item"

# The same numbers as a table, read from the job files (no network)
pnpm --filter @helm/api usage -- <slug> [externalId] [--from <iso>] [--to <iso>] [--group-by item|stage|month]
```

`groupBy` accepts `item`, `stage` or `month`. Invalid dates or parameters return
`400`; a missing or wrong token returns `401`. Replace the host and port with
those of the instance being queried.

`from` and `to` filter sessions (tokens, cost, duration) on the session's start
and job-level figures on the job's start. A job that straddles a boundary
therefore contributes its review rounds wholly to the period where it started,
while its sessions split by their own start.

## What "unknown" means

- A figure the runtime did not report is `null` on the record and is excluded
  from every sum. `0` only ever means a measured zero.
- Every total carries its denominator: `tokens.<counter>.sessionsReported`,
  `costUsd.sessionsWithCost` and `costUsd.sessionsUnknown`. Read a total only
  together with its count.
- Claude Code reports tokens and USD. Codex reports tokens but no USD
  (subscription billing), so its `costUsd` is `null` with `costSource:
  unknown`. An all-Codex item shows `costUsd.total: 0` with `sessionsUnknown`
  equal to its session count: that `0` means "nothing known", not "free".
  Mixed runtimes never produce a misleading total because the unknown sessions
  are counted separately.
- Codex `input` tokens include the cached portion (`cacheRead`) and Codex has no
  cache-creation counter, so that counter is unreported for it.
- A session that ended without the runtime's final message (crash, timeout,
  cancel) has `null` tokens and cost; its duration is measured by Helm.
- The reported `costUsd` is never replaced or corrected by an estimate; the
  estimate is a separate block, described next.

## Estimated USD (`estimatedCostUsd`)

[lhpaul/helm#168](https://github.com/lhpaul/helm/issues/168) (implemented in
[lhpaul/helm#169](https://github.com/lhpaul/helm/pull/169); spec
[issue_168](../specs/issue_168.md), plan [issue_168](../plans/issue_168.md),
[ADR-047](../decisions/047-price-table-source.md), Accepted) adds a **separate,
labelled estimate** next to `costUsd` in every aggregate (overall, each
`byStage` entry, each `groups` entry).

- **What it means.** Tokens and model of each session priced with a per-model
  table of public API list prices. Every block carries the note: *estimate: what
  this usage would cost at public API list price, not a billed amount; all
  cache writes use a single rate*, plus `priceTable.version` and `asOf`. For
  Codex (subscription) it is the API-list-price equivalent, useful to compare
  items run with different runtimes, not for budgeting. Claude sessions are
  estimated too, so the estimate can be eyeballed against the reported
  `costUsd`; it is never blended with it, and no field sums the two.
- **Derived at read time.** It is computed when the aggregate is read, not
  stored on the record, so old records are estimated too and past figures move
  when the table changes (the table version in the response says which one
  applied).
- **Own denominator.** `sessionsEstimated + sessionsNotEstimated` equals
  `sessions`, independent of `costUsd.sessionsWithCost` / `sessionsUnknown`.
  `total` sums only estimated sessions; read it with `sessionsEstimated`. A
  bare `total: 0` with `sessionsEstimated: 0` means nothing could be estimated.
- **Never 0 for unknown.** A session is not estimated when it has no tokens
  (`noTokens`), no model (`noModel`), several models (`multiModel`), a model
  without a price (`noPrice`), a required counter missing
  (`incompleteTokens`) or inconsistent counters (`inconsistentTokens`).
  `notEstimatedReasons` counts each reason.
- **`unpricedModels`** lists the distinct model ids (sorted, at most 20) seen
  in `noPrice` sessions. A model there needs a price entry or an alias.
- **Where the table lives.** A versioned module in `lhpaul/helm`
  ([`usage-price-table.ts`](https://github.com/lhpaul/helm/blob/develop/apps/api/src/services/usage-price-table.ts)),
  each entry with its public source URL and date. Prices are not copied into
  this repository.
- **Maintenance.** The table is reviewed monthly. A price change or a new model
  is a small PR in `lhpaul/helm` that edits that module citing the source and
  date, and the values are reviewed in that PR.
- **Not modelled.** Tiered or long-context pricing, batch or fast-mode rates,
  tool fees, the 5-minute vs 1-hour cache-write split and regional multipliers.

## Gaps the aggregate makes visible

| Field | Meaning |
| --- | --- |
| `jobsInterrupted` | Jobs closed as `orphaned` after a server restart. The session in flight at that moment leaves no record; sessions that had already finished are kept. |
| `jobsNotInstrumented` | Jobs written before this feature (no `usage` field). Their sessions are not known and add nothing to session totals; their `cyclesCompleted` still counts toward `reviewRounds`. |
| `jobsWithCaptureGaps` | Jobs where a record could not be written. The total is known to be incomplete. If both the record write and the failure counter fail (for example an unwritable data directory), only the server log shows it and the aggregate cannot report it. |

The external reviewer runs outside Helm's runtimes, so the response carries the
note `external-review: not measured` instead of a number.

## Review rounds

`reviewRounds` is the sum of `cyclesCompleted` over the item's `reviewer-fanout`
jobs. Cycles of the early spec and plan review loops are not counted as rounds;
their sessions are counted under `spec` and `plan`.

## Revisit

Period queries scan every job file. Revisit the storage choice (ADR-046, "Revisit
when") if jobs are pruned or archived, or if the scan becomes slow.
