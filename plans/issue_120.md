# issue_120 — Implementation Plan

## Approach
1. `packages/shared` product schema: add optional strict `review.external.local_ai_reviewer.artifacts` `{ enabled: boolean (default false), command?: string }`; tests.
2. `ExternalReviewContext` gains optional `artifactKind: 'spec' | 'plan'`. `runExternalReviewIfConfigured` takes an options argument; for artifact PRs it uses the knowledge repo (default branch and ownership check) instead of `code_repos[0]`. The review loop passes the kind when running in `early-artifact` mode.
3. local-ai-reviewer adapter: for artifact contexts, return `not_configured` unless `artifacts.enabled`; use `artifacts.command ?? command`; for backend `codex` run an injectable REVIEW.md preflight (`gh api` contents at head, 404 only) and return `unavailable/review_md_missing` when absent.
4. Docs (`docs/local-ai-reviewer.md`, `docs/product-config.md`), CHANGELOG `[Unreleased]`.
5. Add `REVIEW.md` to this knowledge repo (the reviewed repo owned by the product) so the Codex backend works here.

## Validation
Unit tests: schema, run.ts routing (impl unchanged, artifact enabled/disabled, wrong repo), adapter command selection and preflight outcomes, loop passes kind. `pnpm lint && pnpm test`.

## Risks
Low. Opt-in; implementation path untouched. Behavior change: artifact PRs with local-ai-reviewer but no opt-in now skip external review instead of running in the wrong checkout.
