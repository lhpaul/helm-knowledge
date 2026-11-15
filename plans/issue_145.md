# issue_145 — Implementation Plan

## Overview

Sweep both public repos for private operational detail and replace each
finding with a generic description, without copying the detail anywhere.

## Implementation Steps

1. Run the `git grep` sweep from the spec over this repo and `lhpaul/helm`;
   check the visibility of every linked repository.
2. Replace the production-instance runbook with a generic runbook under a
   neutral file name, keeping the lessons that apply to any deployment, and
   update references to it.
3. Generalize the tech-debt entries and the product evaluation (host, service
   manager, ingress and secrets-manager detail).
4. In ADRs, learnings, specs, plans and runbooks, replace the private product
   name, links to the private code repo and tracker, and references to the
   owner's private notes with generic wording.
5. In `lhpaul/helm`, do the same for documentation only (`AGENT.md`,
   `CHANGELOG.md`, `docs/`) in a separate PR to `develop`.
6. Re-run the sweep, markdown lint and knowledge checks; open the PRs and run
   the local AI reviewer until clean.

## Files to Touch

- `specs/issue_145.md`, `plans/issue_145.md`
- `operations/` runbooks, tech-debt register and product evaluation
- `decisions/`, `learnings/`, `discovery/`, `specs/`, `plans/` and
  `false-positives.md` entries that name the pilot product or link private
  resources

## Test Strategy

Documentation only: the sweep returns no findings, markdown lint and knowledge
checks pass, and every relative link to a renamed file resolves.

## Risks

Low. Generic wording can lose context that a future reader needs; the
detailed runbook stays in the owner's private notes. History still holds the
old text; purging it is out of scope and left to the owner. Rollback: revert
the PR.
