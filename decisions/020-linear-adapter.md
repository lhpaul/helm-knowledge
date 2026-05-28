# ADR-020: Linear Adapter

**Date:** 2026-05-28
**Status:** Accepted
**Supersedes:** —
**Related:** ADR-005 (GitHub Projects Adapter), ADR-015 (Task Ingestion)

---

## Context

Helm's issue-tracker integration has so far been GitHub Projects only (ADR-005, Session 5).
The MOME product uses Linear, which means without a Linear adapter there can be no pilot on
that product.

Session 20 adds `LinearAdapter` as a first-class alternative, mirroring the GitHub adapter
architecture but targeting Linear's GraphQL API.

---

## Decision

### 1. `IssueTrackerSchema` becomes a discriminated union on `provider`

`product.yaml` now accepts two shapes under `issue_tracker`:

```yaml
# GitHub Projects (unchanged)
issue_tracker:
  provider: github_projects
  org: acme-corp
  project_number: 3
  custom_field_name: Helm Stage   # default: "Helm Stage"

# Linear (new)
issue_tracker:
  provider: linear
  api_key_env: LINEAR_API_KEY          # name of env var holding the PAT
  team_key: MOM                        # Linear team identifier
  webhook_secret_env: LINEAR_WEBHOOK_SECRET
```

TypeScript discriminated union via `z.discriminatedUnion('provider', [...])` gives
compile-time narrowing. All existing `product.yaml` files (github_projects) are
backward-compatible; no migration required.

### 2. Authentication: raw `Authorization` header — no `Bearer` prefix

**This is the critical gotcha for Linear PATs.**

Linear personal access tokens must be passed as:

```
Authorization: <token>
```

Not `Bearer <token>`. The `@linear/sdk` npm package and `linear-mcp@1.2.0` both
add the `Bearer` prefix in their HTTP clients, causing 401 responses for PATs.
This was discovered during MOME's agent-hq integration: the SDK reported
authentication errors that only disappeared when the header was sent raw.

The adapter uses `fetch` directly and constructs the header without any prefix.
A loud comment in `adapter.ts` documents this constraint so future maintainers
don't accidentally "fix" it back to `Bearer`.

### 3. Sub-stage tracking via `helm:*` labels

Linear does not have single-select custom fields equivalent to GitHub Projects'
`SINGLE_SELECT` field type. Instead, the adapter uses team labels following the
naming convention `helm:{stage}` (e.g. `helm:discovery`, `helm:spec-draft`).

**`ensureSubStages`** creates any missing `helm:*` labels in the configured team.
Idempotent; safe to call on every server startup.

**`setSubStage`** removes all existing `helm:*` labels from the issue and adds
the new one. Exactly one `helm:*` label is active at a time. If the label doesn't
exist in the cache (missed by `ensureSubStages` or label was deleted), the adapter
calls `ensureSubStages` and retries once before throwing.

Labels use `ISSUE_REMOVE_LABEL` / `ISSUE_ADD_LABEL` mutations rather than the
full `issueUpdate` with a replacement set, to minimise race conditions on
concurrent edits.

### 4. `externalId` = Linear `identifier`

Linear issues have two IDs:
- **`id`**: UUID node-ID used in all GraphQL mutations (e.g. `abc123-def456-...`)
- **`identifier`**: Human-readable, e.g. `MOM-123`

Helm's `externalId` is the `identifier` (human-readable). The adapter maintains
an `identifier → { id: UUID }` cache to avoid re-fetching the UUID on every write.

### 5. `NormalizedItem.body` = `issue.description`

Linear's `description` field is the long-form body of the issue (supports Markdown).
It maps directly to `NormalizedItem.body`.

### 6. Status mapping from `state.type`

Linear workflow states have a `type` field:
- `"triage"`, `"backlog"`, `"unstarted"`, `"started"` → `status: 'open'`
- `"completed"`, `"cancelled"` → `status: 'closed'`

`setStatus('closed')` uses the first `completed`-type state found in the team.
`setStatus('open')` uses the first `backlog`-type state (falling back to `unstarted`,
`triage`, then `started`).

### 7. Separate webhook endpoint `/api/webhooks/linear`

Linear webhooks are routed to `/api/webhooks/linear`, separate from
`/api/webhooks/github`. This avoids payload ambiguity and keeps each route
focused on a single provider's signature scheme and event envelope.

Linear signs the raw body with HMAC-SHA256 and sends the hex digest in the
`Linear-Signature` header (no `sha256=` prefix, unlike GitHub's
`X-Hub-Signature-256`). `verifyLinearSignature` in `webhook-signature.ts`
handles this, mirroring `verifyGitHubSignature` with that one difference.

### 8. `registerWebhook` is a no-op

Linear's API supports programmatic webhook registration, but v0 does not
implement it. Operators configure the webhook manually in the Linear UI
(Settings → API → Webhooks) pointing to `/api/webhooks/linear`. A console
warning is emitted if `registerWebhook` is called, so future callers notice
immediately rather than silently getting no events.

### 9. `getIssueTrackerAdapter()` provider-aware factory

`apps/api/src/services/index.ts` now exports `getIssueTrackerAdapter()`, which
reads `product.issue_tracker.provider` and returns the appropriate adapter
instance. `getGitHubAdapter()` is kept as a soft-deprecated alias (marked
`@deprecated` in JSDoc) used by the existing dispatch route.

---

## Consequences

**Positive:**
- MOME pilot is unblocked: Linear team `MOM` can now be tracked by Helm.
- The `IssueTrackerAdapter` interface proved stable — LinearAdapter implements
  it without any interface changes.
- The discriminated union is backward-compatible; existing GitHub products need
  no changes.

**Negative / trade-offs:**
- Label-based sub-stages are less atomic than a single-select field: two
  concurrent `setSubStage` calls on the same issue could produce inconsistent
  label state. Acceptable for v0 (Helm's single-agent execution model makes
  this unlikely).
- `registerWebhook` is a no-op, requiring manual operator setup per product.
  Acceptable for v0; Linear's webhook API is straightforward to automate in v1.
- State resolution for `setStatus` is heuristic (first matching state type).
  Teams with unusual state configurations may see unexpected behaviour; the
  operator should ensure standard Linear state types are present.

---

## Alternatives considered

**Use `@linear/sdk`**: Rejected. The official SDK sends `Bearer <token>` for
PATs, causing 401s on Linear's API. Discovered in MOME agent-hq. A raw `fetch`
client with the correct header is simpler and avoids a dependency that has a
known auth bug for this use case.

**Single-select custom field via Linear's custom fields API**: Linear does support
custom fields but they are a paid feature not universally available. Labels are
available on all plans and fit the requirement.

**Unified `/api/webhooks/tracker` endpoint**: A single endpoint auto-detecting
the provider at runtime was rejected as brittle (payload shapes overlap; signature
headers differ). Separate routes are explicit and independently testable.
