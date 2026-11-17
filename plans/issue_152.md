# issue_152 — Implementation Plan

## Overview
Stop forked vitest workers from reading a truncated transformed-module cache file (A), and remove the test pattern that triggers the rewrite in the orchestrator suite (B).

## Implementation Steps
1. A: add `patches/vitest@2.1.9.patch` to helm. It changes `dist/chunks/resolveConfig.*.js`: `atomicWriteFile` writes to `.tmp-*` in the same directory and renames it over the target, falling back to `writeFile` if that fails. The cache directory is created synchronously before the pending-write check. Register it under `patchedDependencies` in `pnpm-workspace.yaml` with a "remove on vitest 3" note, and add only the patch hash to `pnpm-lock.yaml` (no re-resolution).
2. B: in `packages/orchestrator/src/review-loop/code-review-loop.test.ts`, replace the five `vi.mock(..., importOriginal)` partial mocks with module-namespace imports and top-level `vi.spyOn(...)` with the same default implementations. Replace the `vi.importActual('./false-positives.js')` call with the original function captured before spying.
3. CHANGELOG `[Unreleased]` → Fixed entry.

## Files to Touch
- helm: `patches/vitest@2.1.9.patch`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`, `packages/orchestrator/src/review-loop/code-review-loop.test.ts`, `CHANGELOG.md`.
- helm-knowledge: `specs/issue_152.md`, `plans/issue_152.md`.

## Test Strategy
- Reproduction: concurrent `vitest run` of `@helm/orchestrator` with CPU burners. Diagnostic preloads, kept outside the repo, trace cache writes in the main process and cache reads in workers, and in-memory loader hooks trace vite-node fetch-cache misses. Failures must match empty reads one to one.
- Same stress with the fix: zero failures, zero empty or partial reads, zero duplicate transforms.
- Gate: `pnpm install --frozen-lockfile` from a clean `node_modules`, then `pnpm lint && pnpm test`.

## Risks
Low to medium. The patch changes third-party dist code, but only the cache write path, mirroring the upstream fix. If a later install changes the vitest chunk name, the patch fails to apply loudly instead of silently. Rollback: revert the commit (removes the patch and the test change).
