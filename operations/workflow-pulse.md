# Workflow Pulse Runbook

This runbook defines the first implementation path for Helm workflow pulse
reports.

## Purpose

Workflow Pulse is an operational readout for the CTO/operator. It summarizes
agent progress, cost, reviewer health, and stuck work over a short window.

It should be cheap enough to run daily and useful enough to skim in under two
minutes.

## v0 data sources

Use only data Helm already owns in v0:

| Signal | Source |
| --- | --- |
| Agent run status | `data/agent-runs/*/meta.json` |
| Agent logs presence | `data/agent-runs/*/log.txt` |
| Equivalent API cost | `data/agent-runs/*/costs.jsonl` |
| Reviewer fan-out state | `data/reviewers/pr-*.json` |
| Item stage / age | Issue tracker adapter |
| PR state | VCS adapter or `gh` |

Do not introduce a database for the first pulse implementation. If indexing
becomes slow, add a rebuildable SQLite view later; the source of truth remains
filesystem, git, and the issue tracker.

## v0 command shape

Target CLI:

```bash
helm pulse --window 24h
helm pulse --window 7d --write
```

Expected behavior:

- Without `--write`, print a concise terminal summary.
- With `--write`, create `pulse-reports/YYYY-MM-DD-workflow-pulse.md` in the
  Product knowledge repo via a normal git branch and PR.

## v1 extensions

After the MOME pilot proves the workflow loop:

- Add product analytics pulse if the Product config declares analytics sources.
- Add QA regression summaries once `qa_gate` is enabled.
- Add Sentry incident summaries once the `incident` stage exists.
- Add scheduled pulse generation.

## Non-goals

- Alerting.
- Product analytics dashboards.
- Persisting granular cost data in the knowledge repo.
- Replacing retrospectives.
