# issue_127 — Specification

## Context
helm-knowledge has no `.github/` and no CI. Spec and plan PRs #88-#91 merged to `main` with no check, so knowledge artifacts enter `main` without automatic validation: no markdown lint, no required-file check and no `REVIEW.md` check.

## Acceptance Criteria
- Pull requests against `main` run a `Knowledge CI` workflow.
- The workflow runs markdown lint, verifies the required files exist and are non-empty, and validates `REVIEW.md`.
- Specs and plans changed by the PR are checked for name (`issue_<number>.md`), non-empty content, a level-1 heading and at least one level-2 section.
- The workflow is lightweight: no application build or tests, one job, short timeout.
- A PR that violates any check fails the job (red) and is not ready to merge.
- Existing content passes without edits (lint rules that existing artifacts violate are disabled; structural rules stay on).

## Technical Notes
- Workflow permissions are `contents: read`; no secrets and no `pull_request_target`; third-party actions pinned to a commit SHA, the lint tool to an exact npm version.
- Checks live in `scripts/check-knowledge.sh` so they can be run locally and tested without GitHub.
- Branch protection is out of scope: making the check required is a maintainer decision after the first green run.
