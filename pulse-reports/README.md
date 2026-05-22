# Pulse Reports

Pulse reports are short, periodic snapshots of Helm workflow health. They are
not retrospectives and not product analytics dashboards. They answer: how is the
agent-assisted development system operating right now?

## v0 scope

In v0, a pulse report should be generated from filesystem and repository state:

- `data/agent-runs/*/meta.json` for run status, specialist, stage, item, and
  duration.
- `data/agent-runs/*/costs.jsonl` for cost by run, specialist, model, and time
  window.
- `data/reviewers/pr-*.json` for reviewer fan-out completion and remediation
  state.
- Issue tracker stage data for stuck or aging items.
- GitHub PR metadata for review cycles and human-review readiness.

## Report shape

```markdown
# Workflow Pulse: YYYY-MM-DD

## Window

<start> to <end>

## Headlines

- <2-4 notable workflow signals>

## Throughput

- Items advanced:
- PRs opened:
- PRs human-review-ready:
- PRs merged:

## Agent health

- Runs started:
- Runs completed:
- Runs interrupted:
- Longest-running active run:

## Cost

- Total equivalent API cost:
- Highest-cost specialist:
- Highest-cost item:

## Review quality

- Review fan-outs completed:
- Remediation runs:
- Repeated reviewer finding themes:

## Followups

- <1-5 concrete next actions>
```

## Storage

Store reports as:

```text
pulse-reports/YYYY-MM-DD-workflow-pulse.md
```
