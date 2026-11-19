# issue_151 — Specification

> **Status: draft, phase 1 (spec and plan only).** Implementation in
> `lhpaul/helm` waits for the owner's answers to "Open questions" and for
> ADR-046 to be accepted. Priority: Low (agreed in #136).

## Context

The product evaluation ([lhpaul/helm#136](https://github.com/lhpaul/helm/issues/136),
`operations/product-evaluation-2026-11.md`) found that nobody can say what it
costs to take one item from Spec to merged PR: spend per item is unknown, and
without it Helm cannot be compared with other ways of working.
[lhpaul/helm#151](https://github.com/lhpaul/helm/issues/151) asks for a
queryable cost record per item and per stage (tokens or estimated cost,
duration, review rounds) with a simple aggregate view.

## What exists today (verified in `lhpaul/helm` develop)

| Data | Where it appears | Persisted? |
| --- | --- | --- |
| Claude Code `result` message: `total_cost_usd`, `duration_ms`, `usage` (input, output, cache read/creation tokens), `modelUsage`, `num_turns` | `ClaudeCodeRuntime` reads only `total_cost_usd` and `duration_ms` | Only the two values, inside `DispatchResult` |
| Codex `turn.completed.usage` (`input_tokens`, `cached_input_tokens`, `output_tokens`, `reasoning_output_tokens`); no USD (subscription billing) | `CodexRuntime` ignores the tokens and **returns `totalCostUsd: 0`** | No |
| `AgentResult.totalCostUsd`, `durationMs` (`runtime.ts`) | Every specialist | Not individually |
| `DispatchResult.costUsd`, `durationMs`, `cyclesCompleted`, `escalated` | Dispatcher return value | Yes, as `Job.result` in `data/jobs/<jobId>.json` (`JobStore`) |
| Reviewer fan-out: `costUsd` = sum of the three reviewers, `durationMs` = max (parallel) | `reviewer-fanout.ts` | Only as the aggregate above |
| Review loop: cost and duration accumulated across cycles (`totalCost`, `maxDuration`), `cyclesCompleted` | `code-review-loop.ts` | Only as the aggregate above |
| Item history (stage transitions, escalations) | `ItemStore` | Yes, but carries no cost |
| External reviewer (`local-ai-reviewer`) cost and runtime | Outside Helm's runtimes | Not seen by Helm |

Gaps that matter:

1. **Codex cost is reported as `0`, indistinguishable from "free".** Today a
   Codex run and a Claude run that cost nothing look the same. This is the
   concrete violation of the "never invent a value" rule.
2. **Token counts are discarded** for both runtimes.
3. **Failed, cancelled or timed-out sessions** (no `result` message) fall back
   to `0` cost and a measured duration; the cost is unknown, not zero.
4. **No per-session breakdown.** Fan-out, adjudicator, remediator and writer
   sessions inside one dispatch collapse into one number, so cost by stage is
   only approximate (one job = one specialist, but the review loop mixes
   reviewers, adjudication and remediation).
5. A job that dies with the server (`orphaned: server restarted during
   execution`) loses everything it had spent (today only the final
   `DispatchResult` is written, at the end of the job).
6. Human wait time (PR sits unreviewed) is not Helm's to measure and is out
   of scope; "cost" here means agent cost.

## Proposal

### Unit of measurement: the usage record

One **usage record** per agent session (one `spawn()` → `wait()`), plus the
existing per-job `DispatchResult` as a cross-check. A record has:

| Field | Meaning | Source |
| --- | --- | --- |
| `productSlug`, `externalId` | Item | `SpawnParams` |
| `jobId` | Dispatch that ran the session | scheduler context |
| `specialistId` | `spec-writer`, `reviewer-fanout` members, `implementer`, … | `SpawnParams` |
| `stage` | `spec`, `plan`, `code`, `review` (mapping below) | derived from the job's specialist |
| `runtime` | `claude-code`, `codex`, `mock` | runtime instance |
| `model` | model hint or the model the runtime reports | `SpawnParams.model`, Claude `modelUsage` keys |
| `startedAt`, `endedAt`, `durationMs` | Session wall clock (measured by Helm) | runtime |
| `status` | `done`, `error`, `cancelled` | `AgentResult` |
| `tokens` | `{ input, output, cacheRead, cacheCreation, reasoning }`, each a number or `null` | Claude `usage`; Codex `turn.completed.usage` |
| `costUsd` | number or `null` | Claude `total_cost_usd` only |
| `costSource` | `reported` or `unknown` | runtime |

Stage mapping (by the **job's** specialist, i.e. the dispatch that ran the
session, not the session's own specialist): `spec` = jobs of `spec-writer`
and `spec-draft-reviewer`; `plan` = jobs of `plan-writer` and
`plan-draft-reviewer`; `code` = jobs of `implementer`; `review` = jobs of
`reviewer-fanout`. Every session in a job inherits the job's stage, so the
reviewer, adjudicator and remediator sessions of an early spec or plan
review loop count as `spec`/`plan` (they reuse the same reviewer specialists
as the code review) and code remediation inside the code review loop counts
as `review`. The session's raw `specialistId` is kept in every record so the
mapping can change later without losing data (see open question 2).

### Review rounds

Rounds are counted per item as the sum of `DispatchResult.cyclesCompleted`
over its review jobs, and recorded on each job's rollup. The ADR-042
cumulative ledger already counts cycles for budget purposes; this feature
reads the job-level value and does not change the loop. A per-session `cycle`
number is optional and not required for v1.

### Unknown is explicit, never zero

- A field is `null` when the source did not provide it. `0` only ever means a
  measured zero.
- Codex: tokens are `reported` from `turn.completed.usage`; `costUsd` is
  `null` and `costSource` is `unknown` (subscription billing exposes no USD).
  The runtime result gains `usage` with `costUsd: null` for this case.
  `AgentResult.totalCostUsd` (and `DispatchResult.costUsd`) stay numeric for
  existing callers and are documented as "sum of known costs; `0` when none is
  known, not authoritative"; **no usage aggregate, endpoint or script reads
  them**, only `usage.costUsd`/`costSource`.
- Any session that ended without the runtime's final usage message (crash,
  timeout, cancel before result, orphaned job): tokens and cost `null`,
  duration measured.
- A session interrupted by a server restart never reaches `wait()`, so it
  leaves **no record** (nothing can write after the process dies). Records of
  sessions that finished before the restart are kept (they are flushed as each
  session ends). The gap is made visible, not hidden: the aggregate reports
  `jobsInterrupted`, the count of jobs closed as `orphaned`, whose in-flight
  session spend is unknown.
- No USD is estimated from tokens in v1 (the runtime deliberately has no
  per-model pricing table). An estimate is an open question (5) and, if
  adopted, would be a separate field `estimatedCostUsd` that is never mixed
  into `costUsd`.
- The external reviewer is outside Helm's runtimes: reported as a fixed
  `external-review: not measured` note in the aggregate, not as a zero.

### Aggregation

Aggregates sum only known values and always return the denominator, so a
reader can see how complete a number is:

```json
{
  "scope": { "productSlug": "…", "externalId": "…", "from": "…", "to": "…" },
  "sessions": 14,
  "durationMs": 1234567,
  "tokens": { "input": 0, "output": 0, "cacheRead": 0, "cacheCreation": 0, "reasoning": 0, "sessionsWithTokens": 11 },
  "costUsd": { "total": 0.0, "sessionsWithCost": 6, "sessionsUnknown": 8 },
  "reviewRounds": 3,
  "jobsInterrupted": 0,
  "jobsNotInstrumented": 0,
  "jobsWithCaptureGaps": 0,
  "byStage": { "spec": {…}, "plan": {…}, "code": {…}, "review": {…} }
}
```

`costUsd.total` is the sum of the known costs only; `sessionsUnknown` says
how many sessions are missing. Mixed runtimes therefore never produce a
misleading total.

### Where it is stored

Decision pending: [ADR-046](../decisions/046-usage-record-storage.md)
(Proposed). Recommended: add the per-session records to the job record
(`data/jobs/<jobId>.json`, new optional `usage` array) and aggregate by
reading jobs. No new store, no migration, no dependency. The alternative is a
separate append-only ledger under `$HELM_DATA_DIR/usage/`.

### How it is queried

- `GET /api/products/:slug/items/:externalId/usage` → aggregate for one item
  with `byStage`.
- `GET /api/products/:slug/usage?from=&to=&groupBy=item|stage|month` →
  aggregate for a period (ISO dates, `from` inclusive, `to` exclusive;
  default: all time; invalid dates → `400` per ADR-031).
- Both are `GET` under `/api/*`, so they sit behind the operator token from
  ADR-045 with no extra work; read-only, no new write surface.
- A thin script `pnpm --filter @helm/api usage -- <slug> [externalId]
  [--from … --to …]` prints the same aggregate as a table for operators
  without `curl`. It only calls the same service function (no network).
- Dashboard UI: out of scope.

## Acceptance Criteria

Each criterion is covered by an automated test.

1. **Capture, Claude.** A Claude Code session whose stream ends with a
   `result` message yields a record with tokens (all four counters),
   `costUsd` from `total_cost_usd`, `costSource: reported`, and the measured
   duration (fixture `write-success.jsonl`).
2. **Capture, Codex.** A Codex session yields tokens from
   `turn.completed.usage` and `costUsd: null`, `costSource: unknown`
   (fixtures `exec-success*.jsonl`). `AgentResult.usage` reports unknown
   cost as `null`/`unknown`; the legacy `totalCostUsd` stays `0` for
   compatibility and is never used by the aggregate.
3. **Failure paths.** Error, cancel, timeout and no-result sessions that
   reach `wait()` produce a record with `null` tokens and cost and a measured
   duration; the dispatch outcome and status are unchanged. A job closed as
   orphaned keeps the records of its finished sessions and is counted in
   `jobsInterrupted`; the interrupted session itself has no record.
4. **Association.** Every record carries product, item, job, specialist and
   derived stage; one fan-out dispatch yields one record per reviewer plus
   adjudicator and remediator sessions as they run.
5. **Aggregate by item and stage.** Sums are over known values; the response
   includes `sessionsWithCost`, `sessionsUnknown` and `sessionsWithTokens`;
   an all-Codex item reports `costUsd.total: 0` with `sessionsUnknown` equal
   to its session count and `total` clearly accompanied by that count (never
   presented as measured zero cost).
6. **Aggregate by period.** `from`/`to` filter session-level data (sessions, tokens, cost, duration) on the session's `startedAt`, and job-level data (`reviewRounds`, `jobsInterrupted`, `jobsNotInstrumented`) on the job's `startedAt`; a job that straddles a boundary therefore contributes its rounds wholly to the period in which it started, while its sessions split by their own start;
   `groupBy=month|stage|item` works; invalid input returns `400`.
7. **Review rounds.** The item aggregate reports rounds from job
   `cyclesCompleted`; an item with no review jobs reports `0` rounds and no
   `review` stage entry.
8. **Legacy jobs.** Jobs written before this change (no `usage`) are counted
   as `jobsNotInstrumented` (a job count: the number of sessions in them is
   not known), contribute nothing to session totals, and the read path never
   fails on them. Their `cyclesCompleted` still counts toward `reviewRounds`.
9. **No behaviour change.** Dispatch status, transitions, review-loop budget
   and stop rules behave identically with usage capture on; a failure while
   recording usage is logged (metadata only), never fails the dispatch, and is
   made visible: the job's `usageCaptureFailures` counter is incremented
   (best effort) and the aggregate reports `jobsWithCaptureGaps`, so a
   known-incomplete total is flagged. The guarantee is qualified: if the usage
   write and the counter update both fail (for example the data directory is
   unwritable), nothing durable records the loss; only the log does, and the
   aggregate can only report what the job files hold (the docs say so). A
   test covers this double-failure case and asserts the dispatch still
   succeeds.
10. **Auth.** The usage endpoints return `401` without the operator token
    (ADR-045 middleware) and respond normally with it.
11. **No sensitive data.** Records hold no prompts, outputs, file paths,
    credentials, access tokens or secrets. Usage token *counts* (the numbers
    in `tokens`) are expected and allowed.
12. **Repo checks.** `pnpm lint` and `pnpm test` pass; no workflow, deploy or
    dependency changes.

## Out of Scope

- Estimating USD from tokens or maintaining a pricing table (open question 5).
- Cost of the external reviewer and any human time.
- Dashboard UI, alerts, budgets or enforcement; ADR-042 limits are unchanged.
- Backfilling cost for jobs that ran before this change.
- Changing model or runtime selection.

## Open questions for the owner

1. **Storage (ADR-046).** Job record (recommended) or separate usage ledger?
   The ledger survives orphaned jobs and job pruning; the job record is
   simpler.
2. **Stage of code remediation inside the review loop.** Counted as `review`
   (recommended: it is part of the loop's cost) or as `code`?
3. **Is "unknown" good enough for Codex USD**, or do you want the
   subscription's flat price allocated per item some other way (out of v1)?
4. **Granularity.** Is per-session enough, or do you also want per-message
   (turn) cost? Per-session is what both CLIs expose reliably.
5. **Estimated USD from tokens** as a separate, clearly labelled field in a
   follow-up, or never?
6. **Retention.** Keep usage for the life of `data/` (recommended) or add a
   cap?
7. **Review-round source.** Is job-level `cyclesCompleted` acceptable, or do
   you need the cumulative ledger's count (ADR-042) as the headline number?
