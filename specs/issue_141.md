# issue_141 — Specification

## Context
On `develop`, `pnpm build` fails because `@helm/orchestrator`'s build is `tsc --noEmit` and `packages/orchestrator/src/review-loop/code-review-loop.test.ts` does not type-check. A fixture declared `{ status: 'clean', blockers: [], advisories: [] } as const` is inferred with `blockers: readonly []`, which is not assignable to `ExternalReviewResult` (`blockers: []`, mutable). `pnpm test` stays green because Vitest does not type-check, and CI only runs `pnpm lint` and `pnpm test`, so the regression went unnoticed.

## Acceptance Criteria
- `pnpm --filter @helm/orchestrator exec tsc --noEmit` passes with no errors.
- `pnpm build` passes for the whole monorepo.
- The fix is limited to the test fixtures (no change to `ExternalReviewResult` or any runtime code); behavior is unchanged.
- Type errors cannot silently return: every workspace package exposes a `typecheck` script (`tsc --noEmit`) and the root `pnpm lint`, which CI already runs, also runs `typecheck` through Turbo. No `.github/workflows` changes.
- Existing tests stay green (same baseline as current `develop`).

## Technical Notes
- Type the fixture with `satisfies ExternalReviewResult` instead of `as const`: it keeps the literal `status` narrowing and gives `blockers` the contextual type `[]`.
- Keep the public type mutable; accepting `readonly` arrays would widen a production contract to fix a test.
- Chaining into `pnpm lint` (not `pnpm test`) keeps tests fast and reuses the existing CI step.

## Out of Scope
- Editing CI workflows (a dedicated `pnpm typecheck` step can be proposed separately).
- Changing `ExternalReviewResult` or review-loop behavior.
