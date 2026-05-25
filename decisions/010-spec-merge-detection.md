# ADR-010: Spec merge detection via webhook

**Date:** 2026-05-25
**Status:** Accepted
**Context:** Session 13 — spec merge loop (spec-draft → spec-ready)

---

## Context

ADR-009 left a known limitation: when the spec PR in the knowledge repo is merged,
Helm has no mechanism to advance the item from `spec-draft` to `spec-ready`.  The
transition remained a manual step, defeating the automation goal.

The item is ready for planning only after the spec has been reviewed and accepted by
the team.  The merge of `helm/spec/{externalId}` into the knowledge repo's default
branch is the natural signal for that acceptance.  We need to close this loop
automatically.

---

## Decision

**Detect spec PR merges via a GitHub webhook from the knowledge repo, reusing the
existing `/api/webhooks/github` endpoint and `GITHUB_WEBHOOK_SECRET`.**

When a `pull_request` event with `action: closed` and `pull_request.merged: true`
arrives, the webhook route extracts the head branch ref.  If it matches the
`helm/spec/{externalId}` naming convention, the route calls
`itemStore.transition({ externalId, toStage: 'spec-ready', triggeredBy:
'webhook:knowledge-repo' })`.

The knowledge repo webhook must be configured by the operator to send `Pull requests`
events to the same Helm API endpoint that already receives GitHub Projects events.
No new endpoint, no new secret, no new environment variables.

---

## Design

### Separation of concerns

The adapter layer (`parseGitHubWebhook`) is kept generic: it emits a
`pull_request_merged` event carrying only the raw `headRef` string.  It does **not**
interpret the `helm/spec/` prefix — that naming convention is Helm-specific and
belongs in the application layer.

The route (`webhooks.ts`) calls `parseSpecBranch(event.headRef)` from `@helm/shared`
to convert the raw ref into an `externalId` (or `null` for non-spec branches).  This
keeps the adapter reusable for future event types and avoids leaking Helm conventions
into the protocol layer.

### Single source of truth for the branch convention

`@helm/shared` exports:
- `SPEC_BRANCH_PREFIX = 'helm/spec/'`
- `specBranchName(externalId)` — used by `spec-publisher.ts` when creating the branch.
- `parseSpecBranch(ref)` — used by `webhooks.ts` when the PR is merged.

Both sides of the loop reference the same constant, so a future change to the prefix
stays in one file.

### Idempotency

The same idempotent error-handling pattern already used for `item_updated` is applied:

- `WorkflowTransitionError` (item not in `spec-draft`, e.g. already `spec-ready`) →
  `console.error` + 200.  Not a delivery problem.
- `ItemNotFoundError` (knowledge repo serves multiple Helm products, or item was
  deleted) → `console.error` + 200.
- Unexpected error → 500, letting GitHub retry.

Non-spec branches (any `headRef` that does not match `helm/spec/{externalId}`) are
silently accepted with 200, no logging, no side effects.

---

## Alternatives considered

### Polling the knowledge repo for merged PRs

A background loop could call `gh pr list --state merged --head "helm/spec/"` every
N minutes and transition any items whose PRs have been merged since the last poll.

**Rejected** because:
- Requires a persistent background task and clock-based state management.
- Polls when nothing has happened (wasted API quota) and is delayed by up to N
  minutes when something does happen.
- The webhook model is already in place and tested; adding polling would duplicate
  the merge-detection responsibility.

### New endpoint / new secret

A separate `/api/webhooks/knowledge-repo` endpoint with its own secret would give
cleaner separation if the knowledge repo diverges from the tracker repo.

**Deferred** in favour of reuse.  The current setup is single-product and both repos
are in the same GitHub org, so a shared secret and endpoint reduces operator
configuration burden.  When multi-product or cross-org support is added, the endpoint
can be split without breaking the event model.

### Checking `repository.full_name` in the payload

GitHub includes the repo identity in the webhook payload.  Verifying it against
`product.knowledge_repo.url` would reject stray events from repos that happen to
share the same webhook endpoint.

**Deferred.**  The `helm/spec/{externalId}` branch prefix is already a strong filter;
a stray merge event for a matching branch in a different repo is an unlikely threat
model for v0.  Adding the check is straightforward and is noted as a future hardening
step.

---

## Consequences

### Positive

- The spec loop is closed: merge in the knowledge repo → `spec-ready` automatically.
- Zero new infrastructure: same endpoint, same secret, same idempotency model.
- Separation of adapter (generic event) from route (Helm-specific interpretation)
  keeps both layers testable in isolation.
- `parseSpecBranch` validates the externalId with the same regex used elsewhere,
  blocking path-traversal attempts at the parsing step.

### Negative / Trade-offs

- The knowledge repo must have a webhook configured to send `Pull requests` events
  to the Helm API.  This is a one-time operator step with no code equivalent.
- If the Helm API is unreachable when the PR is merged, GitHub will retry delivery,
  but only for a limited window.  A missed delivery leaves the item stuck in
  `spec-draft`; a human can manually trigger the transition.

---

## Revisit when

- Multi-product support is added (each product may have a different knowledge repo
  → the endpoint would need to route by `repository.full_name`).
- The knowledge repo and tracker repo are in different GitHub orgs (single secret may
  not cover both).
- Webhook delivery reliability becomes a concern (consider a reconciliation job that
  polls for merged spec PRs as a fallback).
