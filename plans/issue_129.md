# issue_129 — Implementation Plan

## Overview
Add `packages/shared/src/external-id.ts` as the single owner of the `externalId` rule and replace every other copy with imports from `@helm/shared`.

## Implementation Steps
1. Add `external-id.ts` in `@helm/shared` exporting `EXTERNAL_ID_REGEX` and `isValidExternalId()`; export both from the package index; use it in `spec-branch.ts`.
2. Orchestrator: replace `EXTERNAL_ID_SAFE` in `spec-publisher`, `code-workspace`, `early-remediator`, `fetch-product-context`, `code-review-loop` and the inline regex in `dispatcher` with `isValidExternalId()`; drop the now-unneeded test mock entry.
3. API: make `services/types.ts` re-export `EXTERNAL_ID_REGEX` from `@helm/shared`.
4. Add unit tests in `@helm/shared` covering accepted and rejected values.
5. Update AGENT.md guidance and the CHANGELOG `[Unreleased]`.

## Files to Touch
- helm: `packages/shared/src/{external-id.ts,external-id.test.ts,index.ts,spec-branch.ts}`, `packages/orchestrator/src/**` (call sites above), `apps/api/src/services/types.ts`, `AGENT.md`, `CHANGELOG.md`.
- helm-knowledge: `specs/issue_129.md`, `plans/issue_129.md`.

## Test Strategy
New shared unit tests for accepted/rejected values; existing api and orchestrator suites must stay green unchanged. Then `pnpm install --frozen-lockfile && pnpm lint && pnpm test`.

## Risks
Low. Pure refactor with identical regex. Rollback: revert the PR.
