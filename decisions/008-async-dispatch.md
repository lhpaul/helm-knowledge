# ADR-008: Async dispatch with filesystem job store

**Date:** 2026-05-23
**Status:** Accepted
**Context:** Session 11 — async dispatch

---

## Context

The synchronous dispatch endpoint (`POST /api/products/:slug/items/:externalId/dispatch`)
awaited the full agent run before returning an HTTP response. The real
`ClaudeCodeRuntime` can take 3–5 minutes to complete, but Bun's maximum
`idleTimeout` is 255 seconds (values above throw `ERR_INVALID_ARG_TYPE` at boot).
A run lasting more than 255 seconds silently drops the HTTP connection while the
agent kept running, leaving the client with no response and no way to recover.

A polling-based async dispatch pattern was chosen to decouple HTTP response time
from agent execution time.

---

## Decisions

### Decision 1: Filesystem job store (`data/jobs/{jobId}.json`)

Job state is persisted as JSON files in `data/jobs/`, using the same
write-tmp-then-rename atomic pattern from `@helm/storage` that the item store
already uses (see ADR-001). Each job file contains a `Job` record:

```
{
  "jobId":        "<UUID v4>",
  "productSlug":  "my-product",
  "externalId":   "issue_42",
  "specialistId": "spec-writer",
  "status":       "running" | "done" | "error" | "cancelled",
  "startedAt":    "<ISO 8601>",
  "finishedAt":   "<ISO 8601>",   // present when status != running
  "result":       { ... },        // DispatchResult, present on done/error
  "error":        "...",          // error message, present on error
}
```

Job files are flat — not nested by item — so direct lookup by `jobId` costs a
single file read. Item-level listing (`listJobsForItem`) does a directory scan
filtered in memory, which is acceptable at v0 scale.

**Rationale:** Consistent with ADR-001's filesystem-first approach. No new
dependencies required. Survives process restarts (persistence survives restart;
see orphan reconciliation below). Atomic writes prevent partial reads.

### Decision 2: Polling over WebSocket for v0

The HTTP API exposes two polling endpoints:

- `GET /api/jobs/:jobId` — fetch a single job by id
- `GET /api/products/:slug/items/:externalId/jobs` — list jobs for an item

WebSocket support is scaffolded (`/ws` in `index.ts`) but not wired to job events
in Session 11. The dashboard uses 5-second polling today; that interval works
well for agent jobs that take minutes. WebSocket push can be added later without
changing the job store contract.

**Rationale:** Polling is simpler, debuggable with `curl`, and sufficient for the
current dashboard refresh rate. Premature push infrastructure would add complexity
with no user-visible benefit at this scale.

### Decision 3: Orphan reconciliation on startup (running → error)

When the API server starts, it calls `reconcileOrphanedJobs()` (fire-and-forget).
Any job still in `status: 'running'` is immediately set to `status: 'error'` with
`error: 'orphaned: server restarted during execution'` and `finishedAt: now`.

**Rationale:** A crash, SIGTERM, or OOM kill during an agent run leaves the job
permanently stuck in `'running'`. Without reconciliation, the concurrency guard
(see Decision 4) would block all future dispatches for that item. Reconciling on
startup restores the item to a dispatchable state within seconds of reboot. The
agent run itself may have continued to completion on the filesystem (e.g.
worktree was written); a human can inspect the worktree and re-dispatch manually.

### Decision 4: Concurrency guard — one active job per item (409 Conflict)

Before creating a new job, the dispatch handler calls `listJobsForItem` and
checks for any job with `status: 'running'`. If one exists, it returns:

```
HTTP 409 Conflict
{ "error": "A dispatch job is already running for this item", "runningJobId": "..." }
```

**Rationale:** The spec-writer specialist writes files into
`data/worktrees/:slug/:externalId/specs/`. Two concurrent runs for the same item
would write to the same directory, producing non-deterministic output and
corrupting the item's workflow state (two concurrent `store.transition()` calls).
A single-concurrency guard at the job level is the simplest safe policy for v0.

---

## Job shape

```typescript
type Job = {
  jobId:        string;           // UUID v4 — safe for filenames
  productSlug:  string;
  externalId:   string;
  specialistId: string;           // 'spec-writer' | 'auto' (from request body)
  status:       'running' | 'done' | 'error' | 'cancelled';
  startedAt:    string;           // ISO 8601
  finishedAt?:  string;           // ISO 8601
  result?:      DispatchResult;   // from @helm/orchestrator
  error?:       string;
};
```

---

## Endpoint summary

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/products/:slug/items/:externalId/dispatch` | Create async job, return `202 { jobId, status: 'running' }` |
| `GET`  | `/api/jobs/:jobId` | Poll job status |
| `GET`  | `/api/products/:slug/items/:externalId/jobs` | List jobs for item (newest first) |

---

## Consequences

**Positive:**
- HTTP response times drop from minutes to milliseconds for dispatch.
- Bun's 255s idleTimeout is no longer a bottleneck for any endpoint.
- Job history is queryable — clients can see past dispatch attempts and their outcomes.
- Orphan reconciliation keeps the system self-healing across restarts.

**Negative / Trade-offs:**
- Clients must poll to detect job completion (acceptable; dashboard already polls at 5s).
- A crash during `reconcileOrphanedJobs` itself (extremely unlikely) could leave
  orphans; the next restart will catch them.
- `listJobsForItem` does a full directory scan — add an index if the jobs directory
  grows beyond ~10 000 files.
- The `runDispatchJob` fire-and-forget pattern means the background task shares the
  process heap; a large agent response cannot be streamed incrementally to the client.
  This is acceptable until a streaming specialist is introduced.
- **Known limitation — single-process concurrency guard.** `createJobIfNoRunning`
  uses an in-memory `_inflightKeys` Set with a synchronous check-and-set. This is
  correct within a single process: Bun's single-threaded event loop guarantees that
  the `has`/`add` pair cannot be interleaved by another coroutine. However, the lock
  does not coordinate across OS processes. In a horizontally-scaled deployment (multiple
  API instances behind a load balancer), two processes could independently pass the
  check and create concurrent jobs for the same item, writing into the same workdir
  simultaneously. This is acceptable for v0 (single-process deployment). If Helm is
  ever scaled horizontally, the guard must be replaced with a cross-process mechanism:
  an advisory lock file on the shared filesystem, an atomic compare-and-swap in the
  job store, or delegation to an external coordination layer.
