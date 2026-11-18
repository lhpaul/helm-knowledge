# issue_160 — Specification

> **Status: draft, depends on ADR-045.** This spec targets the option
> recommended in [ADR-045](../decisions/045-api-operator-auth.md) (operator
> bearer token). It must not move to implementation until LH accepts ADR-045
> and answers its open questions. If LH picks another option or other
> answers, this spec and its plan are rewritten first.

## Context
The Helm API has no authentication on its non-webhook routes
(lhpaul/helm#160). #159 made it listen on `127.0.0.1` and #162 blocks
cross-origin browser writes, but any process on the host and any client that
reaches it through a tunnel or proxy can still read items, jobs and product
config and trigger dispatches. Route inventory, callers and the options are
in ADR-045.

## Decision (from ADR-045, pending acceptance)
- New variable `HELM_API_TOKEN`: the shared operator token.
- Protected: every `/api/*` route except the exact webhook paths
  `/api/webhooks/github` and `/api/webhooks/linear`, plus the `GET /ws`
  upgrade.
- Not protected: `GET /health`, the two webhook routes (they keep their
  signature checks).
- A protected request must carry `Authorization: Bearer <token>`. The scheme
  is matched case-insensitively; the token is compared in constant time.
  Tokens in the query string or other headers are not accepted.
- Failure: `401` with `{ "error": "Unauthorized" }` and
  `WWW-Authenticate: Bearer`. No detail about which part failed. The server
  logs one warning line with method and path (never the received token).
- Missing configuration (fail closed): when `HELM_API_TOKEN` is unset or
  blank, protected routes answer `401` and the API logs a startup error that
  names the variable. Webhooks and `/health` keep working.
- `HELM_API_AUTH=disabled` (exact value, case-insensitive) turns the check
  off; the API logs a warning at every startup. Any other value of
  `HELM_API_AUTH` is ignored with a startup warning.
- A configured token shorter than 32 characters is treated as missing (fail
  closed) with a startup error.
- Middleware order: the #162 origin guard first, then authentication, then
  the routers.
- Dashboard: the Vite dev proxy adds `Authorization: Bearer <token>` to
  forwarded `/api` and `/ws` requests when `HELM_API_TOKEN` is set in the
  shell that runs `pnpm dev`. The SPA code does not change and the token is
  never sent to the browser.

## Impact on existing instances
- After updating, the operator must set `HELM_API_TOKEN` in the API
  environment (secrets manager → `sync-env` input → `apps/api/.env`) and
  restart, and export it in the shell that runs the dashboard. Until then,
  protected routes answer `401`; webhooks keep advancing items.
- Every `curl`/script call to `/api/*` (except webhooks) adds
  `-H "Authorization: Bearer $HELM_API_TOKEN"`. Runbooks in both repos are
  updated in the implementation PRs.
- Webhooks and `/health` watchdogs: no change.
- Escape hatch for single-user dev machines and for rollback:
  `HELM_API_AUTH=disabled`. It reopens the API to every client that reaches
  it, so on an instance with a public ingress or a non-loopback
  `HELM_API_HOST` it may only be used after the ingress is restricted to
  `/api/webhooks/*` and `/health` (or an authenticated proxy is in front),
  as described in ADR-045. The startup warning for `disabled` says so, and
  the docs and CHANGELOG entry repeat it.

## Acceptance Criteria
- With a valid token configured, a protected route without `Authorization`,
  with a wrong token, with a non-Bearer scheme or with the token only in the
  query string returns `401` with the body and header above and does not run
  the handler (no item write, no dispatch job).
- The same routes with `Authorization: Bearer <token>` reach the handler;
  `GET` reads are protected the same way as writes.
- `GET /ws` without a valid token is rejected with `401` before the upgrade;
  with the token it upgrades and receives `{"type":"connected"}`.
- Webhook routes accept signed requests with no `Authorization` header;
  their signature checks are unchanged. `GET /health` answers `200` with no
  header.
- With `HELM_API_TOKEN` unset, blank or shorter than 32 characters,
  protected routes return `401` and a startup error is logged; with
  `HELM_API_AUTH=disabled` they behave as today and a startup warning is
  logged.
- The #162 origin guard still rejects a foreign `Origin` with `403` on a
  state-changing route, even when the request carries a valid token.
- The received token never appears in logs or error bodies.
- The dashboard on `localhost:5173` keeps loading products and items when
  `HELM_API_TOKEN` is exported in the `pnpm dev` shell.
- Docs: `HELM_API_TOKEN` and `HELM_API_AUTH` in the AGENT.md variables table
  and `docs/local-dev.md`; runbook `curl` commands updated; CHANGELOG
  `[Unreleased]` → Security entry with the impact and the upgrade steps.
- `pnpm install --frozen-lockfile && pnpm lint && pnpm test` is green.

## Out of Scope
- Session cookies or a login screen (ADR-045 option C).
- Per-user tokens, roles, audit log, multiple accepted tokens.
- Proxy or tunnel configuration (ADR-045 option B is an operator task).
- Changing `.env*` values, secrets, `sync-env` inputs, workflows, deploy,
  service definitions or the tunnel (see ADR-045 open question 4).
- CORS headers.
