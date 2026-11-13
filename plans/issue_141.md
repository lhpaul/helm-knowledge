# issue_141 — Implementation Plan

## Overview
Fix the readonly fixture in `code-review-loop.test.ts` and add a `typecheck` task that CI already runs through `pnpm lint`.

## Implementation Steps
1. In `packages/orchestrator/src/review-loop/code-review-loop.test.ts`, replace `as const` on the `clean` fixture with `satisfies ExternalReviewResult` (type-only import from `../external-review/types.js`).
2. Add `"typecheck": "tsc --noEmit"` to every workspace package (`apps/api`, `apps/web`, `packages/*`).
3. Add a `typecheck` task to `turbo.json` and a root `typecheck` script; change root `lint` to `turbo run lint typecheck`.
4. Add a CHANGELOG `[Unreleased]` → Fixed entry.

## Files to Touch
- helm: `packages/orchestrator/src/review-loop/code-review-loop.test.ts`, `package.json`, `turbo.json`, `apps/*/package.json`, `packages/*/package.json`, `CHANGELOG.md`.
- helm-knowledge: `specs/issue_141.md`, `plans/issue_141.md`.

## Test Strategy
`pnpm --filter @helm/orchestrator exec tsc --noEmit`, `pnpm build`, `pnpm install --frozen-lockfile && pnpm lint && pnpm test`. Confirm the guard works by checking that `pnpm lint` fails on `develop`'s fixture and passes after the fix.

## Risks
Low. Test-only type change plus a script. `pnpm lint` gets slower by one `tsc --noEmit` per package. Rollback: revert the commit.
