# issue_146 — Implementation Plan

## Overview

Generalize the private detail left in code and configuration files of
`lhpaul/helm` and let `sync-env` accept a validated generic product slug.

## Implementation Steps

1. Run the sweep from the spec over `lhpaul/helm`.
2. Rewrite `apps/api/.env.example` with a generic product block and a Helm
   block, using placeholder secret references and generic example paths.
3. In `sync-env`, replace the fixed slug list with strict slug validation
   (pattern plus length cap; `example` is reserved for the template) and make
   the usage text generic.
4. Make the `.gitignore` comment generic without changing its patterns.
5. Replace the private repository link in the PR-URL parser test with
   `example-org/example-repo`.
6. Trim the captured Claude Code `init` events in the runtime fixtures to a
   minimal generic tool and server list; the runtime ignores `init` events.
7. Add `sync-env` tests and a CHANGELOG entry; run lint and tests; re-run the
   sweep.

## Files to Touch

- `apps/api/.env.example`, `apps/api/scripts/sync-env-from-1password.sh`
- `apps/api/src/scripts/sync-env.test.ts` (new)
- `.gitignore`, `CHANGELOG.md`
- `packages/orchestrator/src/review-loop/contract-validation-scope.test.ts`
- `packages/orchestrator/src/runtimes/__fixtures__/claude-code/*.jsonl`

## Test Strategy

New tests run the script copy with a stub CLI: valid slugs (including a
generic one) write the output, invalid or reserved slugs fail before the CLI
is called, and a missing input file fails with a clear message. Existing
runtime fixture tests still pass after trimming `init`.

## Risks

Medium: it touches a secrets sync script. Accepting any valid slug widens the
input, so the slug is validated before it builds a path. Existing input files
keep working because their slugs match the pattern. Rollback: revert the PR.
