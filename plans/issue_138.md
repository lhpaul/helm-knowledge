# issue_138 — Implementation Plan

## Overview

Documentation only. Record the service-account decision in TD-003 and add an
owner-facing runbook for the setup. No code changes.

## Implementation Steps

1. Read the current `sync-env` script on `develop` of `lhpaul/helm` without
   running it, and note which CLI commands it calls.
2. Check those commands against the official 1Password documentation on
   service accounts and `OP_SERVICE_ACCOUNT_TOKEN`.
3. Write `operations/secrets-service-account.md`: prerequisites, the decision,
   numbered steps for the owner, verification checks, risks (rotation, vault
   scope, revocation), the open question about the script's sign-in check and
   rollback.
4. Update TD-003 in `operations/tech-debt.md`: add an `In progress` status to
   the legend, set TD-003 to `In progress`, pending the owner, record the
   2026-11-16 decision and link the runbook.
5. Link the runbook from the Secrets section and the Open debts list of
   `operations/production-instance.md`.
6. Run markdownlint and `scripts/check-knowledge.sh origin/main`, and sweep the
   diff for private detail.

## Files to Touch

- `operations/secrets-service-account.md` (new)
- `operations/tech-debt.md`
- `operations/production-instance.md`
- `specs/issue_138.md`, `plans/issue_138.md` (new)

## Test Strategy

No code. Local markdownlint and `scripts/check-knowledge.sh origin/main` pass,
and a manual sweep of the diff finds no hostnames, personal paths, vault or item
names, URLs other than public documentation, or tokens. The owner's first run of
the runbook is the end-to-end check.

## Risks

Low: documentation only. The procedure carries operational risk when the owner
runs it (token exposure, vault scope), so the runbook states each risk and its
mitigation. If the script's sign-in check rejects a service account, the runbook
says so and the fix goes to a separate code item. Rollback: revert the PR.
