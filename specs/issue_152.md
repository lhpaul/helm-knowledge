# issue_152 — Specification

## Context
During #149, 1 in ~170 stressed `@helm/orchestrator` runs had about 20 failures in a few test files because the exports of `specialists/git-helpers.ts` were `undefined` (`buildAuthenticatedUrl is not a function`, `sanitizeToken is not a function`).

Root cause (reproduced, see the helm PR for method and numbers): a race in vitest 2.1.9, not in Helm runtime code.

- With `pool: forks`, the main vitest process writes each transformed module to a cache file (`<tmpdir>/<project-id>/ssr/<sha1(id)>`) and workers read it with `readFileSync`. The write uses `writeFile`, which truncates the file before writing.
- `review-loop/code-review-loop.test.ts` partially mocks `git-helpers`, `fetch-product-context`, `pr-helpers`, `false-positives` and `summary` with `vi.mock(path, importOriginal)`. `importOriginal`/`importActual` request the module by its absolute path, while normal imports use the root-relative id (`/src/...`).
- vite-node deduplicates in-flight transforms by id, so two concurrent requests with different ids transform the same file twice. vitest then rewrites the existing `/src/...` cache file (truncate + write) while other workers may be reading it. A worker that reads the empty file evaluates an empty module, so every export is `undefined`.
- vitest fixed this upstream in 3.x (vitest-dev/vitest#7531: write-then-rename, and create the cache directory before checking pending writes).

## Decision
LH approved (2026-11-17) both, in one helm PR:
- **A.** Backport vitest#7531 into vitest 2.1.9 with a pnpm patch (`patchedDependencies`), without changing any dependency version. Remove the patch when upgrading to vitest 3.
- **B.** Remove the `importOriginal`/`importActual` partial mocks from `code-review-loop.test.ts` so the suite no longer requests modules under two ids.

## Acceptance Criteria
- The signature is reproduced repeatably under load before the fix, with evidence linking failures to empty cache-file reads.
- With the fix, the same stress shows no failures and no empty or partial cache reads.
- `code-review-loop.test.ts` keeps the same mocked behavior (including "head lookups never reach the real `gh`", #117) using `vi.spyOn` on the real modules.
- No dependency version changes; the lockfile diff only adds the patch hash.
- No timeout increases, vitest retries, skipped tests, runtime behavior or CI workflow changes. `pnpm install --frozen-lockfile && pnpm lint && pnpm test` is green.

## Out of Scope
- Upgrading vitest/vite-node (separate decision).
- Rewriting `importOriginal` mocks in `apps/*` tests; the patch (A) removes the race for them.
