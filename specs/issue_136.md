# issue_136 — Specification

## Context

The Helm P1 item in the [agent-first roadmap](../operations/agent-first-roadmap.md)
asks to reconcile Helm's product vision, implementation, current deployments
and pilots; document actual usage and integration constraints; and assess
Fleet and Grok Bot without changing running services.
[lhpaul/helm#136](https://github.com/lhpaul/helm/issues/136) turns that into a
documentation deliverable. No inventory exists today, and
[Project #3](https://github.com/users/lhpaul/projects/3) has not been reconciled
with the roadmap.

## Acceptance Criteria

- An evaluation document in `operations/` inventories Helm deployments,
  consumers and observed usage, with the date and revisions it was taken at.
- It documents integration constraints and assesses Fleet and Grok Bot from
  read-only evidence, without changing any running service or configuration.
- It reconciles Project #3 with the roadmap as a proposal: a table with item,
  situation and proposed action, plus roadmap coverage and gaps. No board
  field, status or priority is changed, and no issue is created or closed.
- It separates verified facts from assumptions and lists the product
  decisions left to the owner.
- The roadmap links to the evaluation.
- The repository is public: no client or third-party product names, personal
  paths, hostnames, internal URLs, IPs, tokens or private-repository data.
  Consumers are described generically.
- `markdownlint-cli2` and `scripts/check-knowledge.sh origin/main` pass.

## Technical Notes

- Allowed sources (read-only): this repo, `lhpaul/helm` code and history,
  `lhpaul/helm-core`, `gh` reads of issues, PRs and Project #3, and the
  owner's private notes. Facts from private sources appear only in aggregate
  or generic form.
- No running service is called. Usage evidence comes from GitHub history
  (PR branches and Helm's own published PR body text), not from the API.

## Out of Scope

- Changes to Helm code, services, LaunchAgents, tunnels, secrets or nodes.
- Changes to Project #3 fields or issues, and changes to Fleet or agent briefs.
- A migration or architecture decision; this item only prepares the evidence.
