# issue_120 — Specification

## Context
`review.external.provider: local-ai-reviewer` runs the ADF companion on implementation PRs. Spec and plan PRs live in the knowledge repo. The early artifact review loop (#71, `review.early_loop.enabled`) already runs the same review loop, including the external slot, on those PRs, but the local reviewer adapter always executes the companion in the process checkout (the code repo) and has no notion of artifact PRs. The companion checks origin and HEAD and fails closed on a wrong checkout, so the external review lands as `skipped:unavailable` and has to be triggered by hand. The Codex backend also requires a `REVIEW.md` in the reviewed repo, and nothing checks or documents that for the knowledge repo.

## Acceptance Criteria
- A product can opt in to local external review of knowledge-repo spec and plan PRs from `product.yaml` (`review.external.local_ai_reviewer.artifacts`). Default is off.
- When enabled, the early artifact loop runs the local reviewer on the artifact PR with no manual trigger in the happy path. An optional `artifacts.command` selects an operator wrapper that runs in the knowledge checkout; it defaults to `local_ai_reviewer.command`.
- When not enabled, artifact PRs get internal review only (`skipped:not_configured`), and no companion is run against the wrong checkout.
- When the backend is `codex`, Helm checks that the reviewed knowledge repo has a `REVIEW.md` at the PR head. If absent, the result is `skipped:unavailable` with provider reason `review_md_missing`. Helm never creates `REVIEW.md` or any file in the reviewed repo. The requirement is documented.
- Artifact PRs must belong to the product's configured knowledge repo; any other repo is refused as unavailable.
- Implementation PR behavior is unchanged.
- Schema validation, docs and tests cover the new options.

## Out of Scope
- Other providers (bugbot, coderabbit, codex-github) on artifact PRs.
- Changing the early loop, stop rules or deferral.
- Enabling the option in any product config; that is an operator decision.

## Technical Notes
- Provider-specific logic stays in the local-ai-reviewer adapter; the loop only tells the runner which artifact kind the PR is.
- Command stays trusted operator config; PR identity stays positional.
- REVIEW.md check uses `gh api` with fixed arguments at the exact head; only a 404 counts as missing, other errors let the companion decide.
