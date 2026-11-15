# issue_145 — Specification

## Context

The [November 2026 product evaluation](../operations/product-evaluation-2026-11.md)
found that this public repository carries private operational detail about the
infrastructure its owner runs Helm on.
[lhpaul/helm#145](https://github.com/lhpaul/helm/issues/145) asks to remove it
from every current file of `helm-knowledge` and `lhpaul/helm`, keeping the
documents useful with generic descriptions.

## Acceptance Criteria

- No current file of this repo contains private operational detail: machine
  or host names, personal paths, secrets-manager references, service or tunnel
  configuration, internal URLs, names of private client products, or links to
  private repositories or private trackers.
- Each finding is replaced by a generic description. A runbook that loses its
  meaning without the detail is replaced by a generic summary and a neutral
  note that the detailed runbook is kept privately.
- Cross-references to renamed or rewritten files still resolve.
- The same sweep runs over the documentation of `lhpaul/helm`; findings there
  go in a separate docs-only PR to `develop`, or the knowledge PR states that
  there were none.
- PRs and commits describe only the types of detail removed, never the detail.
- `markdownlint-cli2` and `scripts/check-knowledge.sh origin/main` pass.

## Technical Notes

- Sweep with `git grep` for host and node names, home paths, `op://`, tunnel
  and service-manager terms, IPs and internal hostnames, private product and
  client names, and repository links; check repository visibility with
  `gh repo view`.
- Opaque tracker item keys and short product labels stay as identifiers, so
  existing cross-references keep working; their links and expansions go.

## Out of Scope

- Rewriting git history. Old revisions still contain the detail; purging them
  is a separate decision for the owner.
- Old branches of this repo, code and configuration files of `lhpaul/helm`,
  the production instance and its deployment.
