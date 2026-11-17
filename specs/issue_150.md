# issue_150 — Specification

## Context

The [2026-11 product evaluation](../operations/product-evaluation-2026-11.md)
found that Helm has no releases: `CHANGELOG.md` has only `[Unreleased]`, there
are no tags or GitHub releases, and `main` of `lhpaul/helm` still points at the
May 2026 scaffold while all work merges to `develop`. The production instance
runs a hand-pulled `develop`, so its revision is not recorded, and the
`released` stage in [Project #3](https://github.com/users/lhpaul/projects/3)
does not correspond to any version (evaluation decision 2).
[lhpaul/helm#150](https://github.com/lhpaul/helm/issues/150) asks for a
documented release policy.

This item writes the policy as a proposal for the owner. It does not cut a
release.

## Acceptance Criteria

- A policy document in this repo covers: the release trigger or cadence,
  versioning (scheme and first version), the `develop` → `main` flow (release
  branch or direct merge), tags, how the `CHANGELOG.md` `[Unreleased]` section
  is cut, and how a release is announced. Hotfixes are covered too.
- It defines what `released` means in Project #3 and when an item moves to it,
  for both the `Status` and `Helm Stage` fields, and how existing items are
  treated.
- It describes, in generic terms, how a deployed instance is updated to a
  version and how it is rolled back. No hostnames, paths, machine or service
  names, or other private operational detail.
- It is based on the current state, read with git and `gh` (read only):
  history, `CHANGELOG.md`, branches, tags, releases, repository merge settings
  and branch protection.
- It separates what is already in force from what is proposed, and lists the
  open decisions for the owner with a recommendation for each.
- It is linked from the documents that describe the affected areas: the
  production-instance runbook, the backlog runbook and the product evaluation.
- No release, tag, `release/*` or `hotfix/*` branch is created; `main` of
  `lhpaul/helm`, workflows, branch protection and Project #3 fields are not
  changed.

## Technical Notes

- `HELM_VERSION` in `packages/shared` is `0.0.0` and `/health` already returns
  it, so a release that bumps it makes the running version observable.
- `helm_version: "0"` in `.helm/product.yaml` is a config schema version, not a
  release version; the policy keeps the two apart.
- Per ADR-032, a GitHub `release.published` event bulk-promotes `merged` items
  to `released` on a Helm instance that receives that repository's webhooks.

## Out of Scope

- Cutting the first release or changing code (`HELM_VERSION`, package versions).
- Adding release workflows, rulesets or branch protection.
- Changing Project #3 fields or items, or creating backlog issues.
- The private operations runbook of the production instance.
