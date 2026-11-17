# issue_150 — Implementation Plan

## Overview

Documentation only. Write a release policy proposal for Helm under
`operations/`, grounded in a read-only snapshot of `lhpaul/helm`, and link it
from the affected runbooks. No code, release, tag, branch, workflow, protection
or board change.

## Implementation Steps

1. Read the current state with git and `gh`: `develop` and `main` history,
   tags and releases, `CHANGELOG.md`, `HELM_VERSION`, package versions, CI
   workflow, repository merge settings, branch protection and rulesets, and
   Project #3 fields.
2. Read the existing conventions: `AGENT.md` (branch naming, CHANGELOG,
   merge authority), ADR-032 (`merged` vs `released`), the backlog runbook and
   the branch-rulesets guide.
3. Write `operations/release-policy.md`: current state (verified), what is
   already in force, the proposal (versioning, trigger, flow, tags, CHANGELOG
   cut, announcement, hotfixes, Project #3 semantics, instance update and
   rollback), open decisions with recommendations, and proposed follow-ups.
4. Link it from `operations/production-instance.md`,
   `operations/helm-backlog.md` and decision 2 of
   `operations/product-evaluation-2026-11.md`.
5. Run markdownlint and `scripts/check-knowledge.sh origin/main`, and sweep the
   diff for private detail.

## Files to Touch

- `operations/release-policy.md` (new)
- `operations/production-instance.md`
- `operations/helm-backlog.md`
- `operations/product-evaluation-2026-11.md`
- `specs/issue_150.md`, `plans/issue_150.md` (new)

## Test Strategy

No code. Local markdownlint and `scripts/check-knowledge.sh origin/main` pass.
A manual sweep of the diff finds no hostnames, personal paths, service or
machine names, private repository or product names, internal URLs or tokens.
Every "verified" statement matches the read-only snapshot.

## Risks

Low: documentation only, and every change in practice is a proposal that the
owner must approve. The main risk is stating a proposal as current practice;
the document labels each part. Rollback: revert the PR.
