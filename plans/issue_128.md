# issue_128 — Implementation Plan

## Overview
Add an idempotent `scripts/ensure-review-labels.sh` to the Helm repo, document the required labels, and test it with a fake `gh`.

## Implementation Steps
1. Add `scripts/ensure-review-labels.sh`: required-label table, `gh label list` check, `gh label create` only for missing ones, `--repo` and `--dry-run` flags, non-zero exit on any `gh` failure.
2. Add `apps/api/src/scripts/ensure-review-labels.test.ts` running the script with a fake `gh` on PATH.
3. Add `docs/review-labels.md` listing the required labels and how to run the script; link it from `docs/local-ai-reviewer.md`.
4. Add a CHANGELOG `[Unreleased]` entry.

## Files to Touch
- helm: `scripts/ensure-review-labels.sh`, `apps/api/src/scripts/ensure-review-labels.test.ts`, `docs/review-labels.md`, `docs/local-ai-reviewer.md`, `CHANGELOG.md`.
- helm-knowledge: `specs/issue_128.md`, `plans/issue_128.md`.

## Test Strategy
Vitest with a fake `gh` that records calls: missing label → one create; present label → zero creates; `gh` failure → non-zero exit; `--dry-run` → no create. Then `pnpm lint && pnpm test`.

## Risks
Low. Only creates labels; never modifies existing ones. Rollback: delete the script and doc.
