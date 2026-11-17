# issue_149 — Specification

## Context
During verification of #143, one full `pnpm test` run had 19 transient failures in `@helm/orchestrator` under machine load; the package passed in isolation and the next two full runs were green. A flaky gate erodes trust in `pnpm test` before every PR and in CI, and can make a development session retry or block for no real reason.

Investigation (CPU burners plus several concurrent `vitest run` / `pnpm test` processes) found two signatures:

1. **Reproduced (15 of 20 stressed runs failed before the fix):** four reviewer-fanout tests in `packages/orchestrator/src/dispatcher.test.ts` verified workspace cleanup by listing the shared `os.tmpdir()` for any `helm-review-issue_1-*` entry. Other test files and other test processes create workspaces with that prefix at the same time, so the before/after listings differed.
2. **Seen once in ~170 stressed runs, not reproducible:** exports of `specialists/git-helpers.ts` were `undefined` inside three test files of one run (20 failures). Tracked separately in #152.

## Acceptance Criteria
- The four reviewer-fanout cleanup tests assert only on the workspace paths they provisioned themselves (and their `-artifacts` siblings), never on a shared-directory listing.
- The tests still fail if the dispatcher/review loop stops removing the provisioned workspace (checked by mutation).
- No timeout increases, vitest retries, or skipped tests.
- At least 5 consecutive full `pnpm test` runs are green, including at least one under load; method and result are in the PR.
- No runtime behavior or CI workflow changes. `pnpm lint` and `pnpm test` are green.

## Technical Notes
- The test `runGit` mock already receives the clone destination; recording it gives each test its own workspace paths.
- Signature 2 is not fixed here: per the issue, no fix is invented for a failure that could not be reproduced. #152 holds the evidence and next steps.

## Out of Scope
- Signature 2 (#152), including any vitest/vite-node upgrade.
- Changes to `provisionReviewerWorkspace` naming or location.
