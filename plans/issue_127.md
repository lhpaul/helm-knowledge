# issue_127 — Implementation Plan

## Overview
Add a single lightweight GitHub Actions job plus a local check script to helm-knowledge.

## Implementation Steps
1. Add `.markdownlint-cli2.jsonc` with default rules minus the style rules existing artifacts violate.
2. Add `scripts/check-knowledge.sh`: required files, `REVIEW.md` contract, and checks on specs/plans changed against the merge base.
3. Add `.github/workflows/knowledge-ci.yml` (`pull_request` to `main`, `contents: read`, SHA-pinned actions, `markdownlint-cli2` pinned) running lint then the script.
4. Document the checks in `README.md`.

## Files to Touch
- `.github/workflows/knowledge-ci.yml`, `.markdownlint-cli2.jsonc`, `scripts/check-knowledge.sh`, `README.md`, `specs/issue_127.md`, `plans/issue_127.md`.

## Test Strategy
Run lint and the script locally on the clean tree (must pass), then with `REVIEW.md` stripped and a badly named empty spec (must fail). The PR's own Knowledge CI run is the integration test.

## Risks
Low. Workflow only reads the repo. Possible false reds on future artifacts are fixed by adjusting the script or lint config. Rollback: delete the workflow file.
