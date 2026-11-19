# ADR-046: Where per-item usage records are stored

**Date:** 2026-11-19
**Status:** Proposed
**Related:** lhpaul/helm#151 (this decision), `specs/issue_151.md`,
`plans/issue_151.md`, ADR-021 (Claude Code and Codex runtimes), ADR-042
(cumulative review-loop budget), ADR-045 (API operator auth)

---

## Context

Helm must record, per agent session, tokens, cost (or an explicit
"unknown"), duration and the item/stage it belongs to, and answer aggregate
queries by item and period (see the spec). Helm has no database (decision
closed in AGENT.md); operational data lives as files under `HELM_DATA_DIR`.
Jobs are already one JSON file per dispatch (`data/jobs/<jobId>.json`) with
product, item, specialist, status and timestamps, and `JobStore` already
scans that directory to list jobs per item.

## Decision (proposed)

**Option A: store the session records inside the job record** as a new
optional `usage` array, written together with the job's final update, and
aggregate by reading jobs.

## Options

### A. `usage` array on the job record (recommended)

- Pros: no new store, path or format; atomic with the job write; item and
  specialist already on the record; additive optional field, so no migration
  and old jobs stay valid; smallest change.
- Cons: a job killed with the server (`orphaned`) loses what it had spent
  unless records are flushed during the run; a period query scans every job
  file (same as today's per-item listing; fine at this scale, would need an
  index later); job files grow by a few hundred bytes per session.
- Mitigation: flush records to the job as sessions end (one atomic update per
  session), so an orphaned job keeps the sessions that finished.

### B. Separate append-only ledger (`$HELM_DATA_DIR/usage/<productSlug>/<YYYY-MM>.jsonl`)

- Pros: survives job pruning and orphaned jobs by construction; period
  queries read only the months in range; one concern per file.
- Cons: a second persistence surface to document, back up and keep
  consistent with jobs; new directory on deployed instances; more code
  (writer, reader, month partitioning, concurrency on append); the join to
  job status/`cyclesCompleted` needs a second read.

### C. Events on the item history

- Pros: already per item.
- Cons: bloats item files (ADR-042 deliberately avoids per-cycle history
  events); not queryable by period without scanning every item; mixes audit
  and metering.

### D. External metering (provider dashboards)

- Not viable: no per-item attribution and Codex subscription runs expose no
  per-run USD.

## Consequences (if A)

- Positive: low risk, no deployment change, reversible by ignoring the field.
- Negative: period aggregates are O(jobs); usage is coupled to job
  retention (there is no pruning today).
- Neutral: the `Job` JSON shape gains one optional field; readers that
  ignore unknown fields are unaffected.

## Revisit when

- Jobs are pruned or archived, or the number of job files makes a period
  query slow (move to B or add an index).
- A second consumer needs usage independent of jobs (billing export).
- The owner wants usage to survive a lost `data/jobs/` directory.
