# issue_151 — Implementation Plan

> **Status: draft, phase 1.** Implements [specs/issue_151.md](../specs/issue_151.md)
> under [ADR-046](../decisions/046-usage-record-storage.md) (Proposed). Nothing
> is implemented yet; start phase 2 only after the owner accepts ADR-046 and
> answers the spec's open questions.

## Risk and deployment impact

- **Estimated risk: medium.** The change is additive and non-security, but it
  touches the runtime result contract (`AgentResult`) and wraps every
  specialist spawn, so a mistake could affect all dispatches. It is not high:
  no auth, data migration, destructive operation or behaviour change to the
  state machine.
- **Data migration: none.** Option A adds an optional field to new job files;
  old jobs stay valid and are reported as not instrumented. If ADR-046 picks
  option B, a new `usage/` directory is created lazily on first write (no
  migration, but a new path to include in backups).
- **New dependencies: none.** Uses `@helm/storage`, Hono and Zod already in
  the repo. No vitest or other dependency update.
- **Configuration on a deployed instance: none.** No new environment
  variable. The usage endpoints are covered by the existing
  `HELM_API_TOKEN` (ADR-045). Rollout is a normal release; rollback is
  reverting it (the extra field is ignored by older code).
- **Workflows and deploy:** no change to `.github/workflows`, no deploy step.

## Implementation steps (phase 2, repo `lhpaul/helm`, base `develop`)

1. **Runtime contract** (`packages/orchestrator/src/runtime.ts`): extend
   `AgentResult` with an optional `usage` object
   (`{ tokens: {input, output, cacheRead, cacheCreation, reasoning} with
   nullable members, costUsd: number | null, costSource: 'reported' |
   'unknown', model?: string }`). Keep `totalCostUsd: number` for existing
   callers so no specialist signature changes; document it as "sum of known
   costs, `0` when none is known, not authoritative". Only `usage` carries the
   unknown marker. Consumers of `totalCostUsd` (`DispatchResult.costUsd`,
   review-loop totals) are not changed and the usage aggregate never reads
   them.
2. **Claude Code runtime** (`runtimes/claude-code.ts`): read `usage` and
   `modelUsage` from the `result` message; `costUsd` from `total_cost_usd`
   (`reported`). When no `result` message arrives, `costUsd: null`,
   `costSource: 'unknown'` instead of `0`.
3. **Codex runtime** (`runtimes/codex.ts`): parse `turn.completed.usage` into
   tokens (sum across turns if several); `usage.costUsd: null`, `unknown`.
   `totalCostUsd` stays `0` for compatibility; a test asserts the aggregate
   ignores it. Verify against both fixtures (`exec-success`,
   `exec-success-0.136`).
4. **Mock runtime** (`runtimes/mock.ts`): report `reported` cost when the
   script gives `costUsd`, otherwise `unknown`, so tests can exercise both.
5. **Capture without touching every specialist.** Add a decorator runtime
   (`UsageRecordingRuntime`, in `packages/orchestrator/src/runtimes/`) that
   wraps `spawn()`, awaits `wait()` and hands a usage record to an injected
   `onUsage(record)` sink. `SpawnParams` already carries `specialistId`,
   `productSlug`, `externalId`, `model`. The **stage is not derived from the
   session's `specialistId`** (early spec/plan review loops reuse the same
   reviewer and adjudicator specialists as the code review): the decorator is
   created per job with a recording context `{ jobId, stage }` where `stage`
   comes from the job's specialist (`stageForJobSpecialist(id)`, a pure
   function next to `STAGE_TO_SPECIALIST` in `dispatcher.ts`:
   spec-writer/spec-draft-reviewer → spec, plan-writer/plan-draft-reviewer →
   plan, implementer → code, reviewer-fanout → review), and stamps it on every
   record along with the raw session `specialistId`. A failing sink is caught and logged (metadata only) and never fails the session; the decorator then also tries to increment `usageCaptureFailures` on the job (best effort, same serialized queue), so the loss is visible.
6. **Persistence** (`apps/api/src/services/job-store.ts`, `dispatch-scheduler.ts`,
   `runtime-factory.ts`): wrap the runtime in the scheduler where the job is
   created, with a sink that appends the record to the job (one atomic
   `JobStore.appendUsage(jobId, record)` per session, so an orphaned job
   keeps finished sessions). `updateJob` is an unlocked read-modify-write, and
   the three reviewers of a fan-out finish concurrently, so `appendUsage` and
   `updateJob` must be serialized per job: a per-`jobId` in-memory promise
   queue (the process is single-writer, as `_inflightKeys` already assumes)
   that every write to a job file goes through, with `appendUsage` reading the
   current file inside the queue and appending, so the final status update
   cannot overwrite `usage` and two simultaneous appends cannot drop a record. A
   session in flight when the server dies leaves no record (it never reaches
   `wait()`); `reconcileOrphanedJobs` is unchanged and the aggregate counts
   those jobs as `jobsInterrupted` from their existing `orphaned` error.
   Add the `usage` field (and `usageCaptureFailures`) to `Job` as optional in the
   type, but `createJob`/`createJobIfNoRunning` always initialize `usage: []`
   and `usageCaptureFailures: 0` on new jobs. That is the durable
   instrumentation marker: absence of `usage` means a pre-change (legacy) job
   and only then counts as `jobsNotInstrumented`; an instrumented job with no
   completed session, or whose first capture failed, has `usage: []` and is
   not legacy. If ADR-046 chooses B, replace the
   sink with an `appendJsonl` writer and add a `UsageStore` reader instead.
7. **Aggregation service** (`apps/api/src/services/usage.ts`): pure function
   over jobs (and usage records) returning the aggregate shape in the spec:
   sums over known values, `sessionsWithCost`, `sessionsUnknown`,
   per-counter token `sessionsReported`, `jobsNotInstrumented`, `byStage`,
   `reviewRounds` from `Job.result.cyclesCompleted`, `jobsInterrupted`, `jobsWithCaptureGaps` (jobs whose `usageCaptureFailures` > 0), filters by period (session `startedAt` for session data, job
   `startedAt` for job-level data such as rounds), and `groupBy`.
8. **API** (`apps/api/src/routes/usage.ts`, registered in `app.ts`): the two
   `GET` routes in the spec, Zod validation (`from`/`to` ISO, `groupBy`
   enum), errors per ADR-031. They fall under `/api/*`, so the ADR-045
   middleware applies automatically.
9. **Script** (`apps/api/src/scripts/usage.ts` + package script): table
   output from the same service function; reads `HELM_DATA_DIR` like the
   other scripts.
10. **Docs** (helm): `docs/local-dev.md` (the two endpoints and the script),
    AGENT.md only if it lists endpoints, `CHANGELOG.md` `[Unreleased]` →
    Added. In helm-knowledge (separate PR, `Refs lhpaul/helm#151`): a short
    section in `operations/` explaining how to read the aggregate and what
    "unknown" means; no host names or private details.

## Tests

- `claude-code.test.ts` / `codex.test.ts`: fixtures → tokens, cost and
  `costSource`; stream without result → unknown (AC 1–3).
- `usage-recording.test.ts`: decorator emits one record per session, sink
  failure does not fail the session and bumps `usageCaptureFailures`, job-specialist→stage table, and early spec/plan review sessions attributed
  to `spec`/`plan` rather than `review` (AC 3, 4, 9).
- `job-store.test.ts`: N simultaneous `appendUsage` calls (and one
  concurrent final `updateJob`) keep all N records and the final status;
  `usage` persisted per session, legacy job (no `usage`)
  still reads, orphaned job keeps finished sessions (AC 8).
- `usage.test.ts` (service): all-Codex item, mixed runtimes, partially reported token counters (each counter keeps its own `sessionsReported`), period and
  `groupBy` (including a review job whose sessions straddle `from`/`to`: rounds
  follow the job's `startedAt`, sessions their own), review rounds, legacy
  jobs (no `usage` field) counted in `jobsNotInstrumented` while a new job with
  `usage: []` is not, a job with one recorded and one failed
  session counted in `jobsWithCaptureGaps`, and a double failure (record and counter both fail) leaving the dispatch successful with only a log line, empty scope (AC 5–7).
- `usage-route.test.ts`: `400` on bad input, `401` without token, `200` with
  it (AC 6, 10).
- Dispatch regression: existing dispatcher and scheduler tests unchanged and
  green (AC 9). Run `pnpm install --frozen-lockfile && pnpm lint && pnpm
  test` before the PR.

## Files to touch

- helm: `packages/orchestrator/src/runtime.ts`,
  `runtimes/{claude-code,codex,mock}.ts` and their tests,
  `runtimes/usage-recording.ts` (+ test), `dispatcher.ts` (stage mapping
  export only), `apps/api/src/services/{job-store,dispatch-scheduler,runtime-factory}.ts`,
  `apps/api/src/services/usage.ts` (+ test), `apps/api/src/routes/usage.ts`
  (+ test), `apps/api/src/app.ts`, `apps/api/src/scripts/usage.ts`,
  `apps/api/package.json` (script entry only), `docs/local-dev.md`,
  `CHANGELOG.md`.
- helm-knowledge: one runbook section under `operations/`.
- Not touched: workflows, deploy, `.env*`, lockfile, dependencies, auth
  middleware, state machine, review-loop budgets.

## Sequencing and size

Two PRs in `lhpaul/helm` keep each reviewable: (1) runtime contract,
runtimes, decorator and persistence (steps 1–6); (2) aggregation, API,
script and docs (steps 7–10). The second depends on the first. Plus one
small docs PR in helm-knowledge.

## Stop conditions for phase 2

Stop and ask the owner if: ADR-046 is not accepted; a vitest or other
dependency update seems necessary; the runtime contract change forces edits
in more than the runtimes and the scheduler wiring; or risk turns out high.
