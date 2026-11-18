# issue_160 — Specification

> **Status: ready.** Implements [ADR-045](../decisions/045-api-operator-auth.md)
> (Accepted 2026-11-18, decided by the owner: option A, fail closed, reads
> protected, one token, `.env.example`/`sync-env` docs updated, interim
> ingress restriction done by the operator). Risk: **high** (security/auth).

## Context
The Helm API has no authentication on its non-webhook routes
(lhpaul/helm#160). #159 made it listen on `127.0.0.1` and #162 blocks
cross-origin browser writes, but any process on the host and any client that
reaches it through a tunnel or proxy can still read items, jobs and product
config and trigger dispatches. Route inventory, callers, options and the
owner decisions are in ADR-045.

## Decision (ADR-045)
- New variable `HELM_API_TOKEN`: the shared operator token. Only one token is
  accepted at a time.
- Protected: every `/api/*` route, reads (`GET`) and writes alike, plus the
  `GET /ws` upgrade.
- Not protected: `GET /health` and the signed webhook routes under
  `/api/webhooks/*` (today exactly `/api/webhooks/github` and
  `/api/webhooks/linear`, which keep their signature checks). The exemption
  is the set of registered webhook routes, shared with the #162 guard, so a
  path under `/api/webhooks/` that is not a registered webhook still requires
  the token.
- A protected request must carry `Authorization: Bearer <token>`. The scheme
  is matched case-insensitively; the token is compared in constant time.
  Tokens in the query string, cookies or other headers are not accepted.
- Failure: `401` with `{ "error": "Unauthorized" }` and
  `WWW-Authenticate: Bearer`. No detail about which part failed. The server
  logs one warning line with method and path (never the received token or
  the configured one).
- Fail closed: when `HELM_API_TOKEN` is unset, blank or shorter than 32
  characters, protected routes answer `401` and the API logs a startup error
  that names the variable (not its value). The API still starts; webhooks and
  `/health` keep working.
- Explicit opt-out: `HELM_API_AUTH=disabled` (exact value, case-insensitive)
  turns the check off; the API logs a warning at every startup that says
  the API is unauthenticated and points to the rollback precondition. Any
  other value of `HELM_API_AUTH` is ignored with a startup warning (auth
  stays on).
- Middleware order: the #162 origin guard first, then authentication, then
  the routers.
- Dashboard: the Vite dev proxy adds `Authorization: Bearer <token>` to
  forwarded `/api` and `/ws` requests when `HELM_API_TOKEN` is set in the
  shell that runs `pnpm dev`. The SPA code does not change and the token is
  never sent to the browser (no `VITE_` variable, not in the bundle).
- Secrets wiring: `apps/api/.env.example` documents `HELM_API_TOKEN` and
  `HELM_API_AUTH` and adds `HELM_API_TOKEN=op://<vault>/<item>/<field>` to
  every product input block it declares for `sync-env`. Names, placeholders
  and docs only.

## Impact on existing instances
- Interim (already decided, operator-side, outside the repos): the public
  ingress only serves `/api/webhooks/*` and `/health`.
- After updating, the operator must set `HELM_API_TOKEN` in the API
  environment (secrets manager → private `sync-env` input → `apps/api/.env`)
  and restart, and export it in the shell that runs the dashboard. Until
  then, protected routes answer `401`; webhooks keep advancing items.
- Every `curl`/script call to `/api/*` except webhooks, reads included, adds
  `-H "Authorization: Bearer $HELM_API_TOKEN"`. Runbooks in both repos are
  updated in the implementation PRs.
- Webhooks and `/health` watchdogs: no change.
- Rotation: new value, restart the API and `pnpm dev`; there is a short
  window in which callers with the old token get `401`.
- Opt-out for single-user dev machines and for rollback:
  `HELM_API_AUTH=disabled`. It reopens the API to every client that reaches
  it. On an instance with a public ingress it may only be used after
  confirming from outside that the ingress only serves `/api/webhooks/*` and
  `/health` (or that an authenticated proxy is in front). With a
  non-loopback `HELM_API_HOST` it may only be used after moving the API back
  to loopback or blocking the API port to everything but loopback at the host
  firewall, and confirming from another host that the port is unreachable;
  the ingress rule alone does not stop direct LAN clients. See ADR-045
  "Rollback". The docs, `.env.example` and the CHANGELOG entry repeat both
  conditions.

## Acceptance Criteria
Each criterion is covered by an automated test unless marked *manual*.

1. **Token required on writes.** With a valid token configured, a
   state-changing route (for example
   `POST /api/products/:slug/items/:externalId/dispatch` and `POST /api/items`)
   without `Authorization`, with a wrong token, with a token of a different
   length, with a non-Bearer scheme (`Basic …`) or with the token only in the
   query string returns `401` with `{ "error": "Unauthorized" }` and
   `WWW-Authenticate: Bearer`, and the handler does not run (no item write,
   no dispatch job).
2. **Token required on reads.** The same holds for `GET` reads (for example
   `GET /api/products` and `GET /api/jobs/:jobId`): `401` without a valid
   token, `200`/normal response with it.
3. **Valid token accepted.** `Authorization: Bearer <token>` and
   `authorization: bearer <token>` reach the handler on reads and writes.
4. **WebSocket.** `GET /ws` without a valid token is rejected with `401`
   before the upgrade (the shared middleware is tested on a `/ws` route under
   vitest). With the token, the real Bun server upgrades and sends
   `{"type":"connected"}` (*manual*, under Bun, recorded in the PR).
5. **Exemptions.** `POST /api/webhooks/github` with a valid signature and no
   `Authorization` is accepted and its signature check is unchanged (a bad
   signature still fails as today); the same for the Linear route.
   `GET /health` answers `200` with no header. A request to an unregistered
   path under `/api/webhooks/` without a token gets `401`.
6. **Fail closed.** With `HELM_API_TOKEN` unset, blank (`""` or spaces) or
   shorter than 32 characters, protected reads and writes return `401`, a
   startup error naming `HELM_API_TOKEN` is logged, and webhooks and
   `/health` still work.
7. **Explicit opt-out.** With `HELM_API_AUTH=disabled` (also `DISABLED`),
   protected routes behave as today without a token and a startup warning is
   logged. With `HELM_API_AUTH` set to any other value (for example `off`,
   `false`), auth stays on and a startup warning is logged.
8. **Origin guard order.** The #162 guard still rejects a foreign `Origin`
   with `403` on a state-changing route, even when the request carries a
   valid token; a request with a valid token and an allowed or absent
   `Origin` passes both.
9. **No token leakage.** Neither the received nor the configured token
   appears in logs (startup and per-request) or in error bodies.
10. **Vite proxy.** The proxy config adds `Authorization: Bearer <token>` to
    the `/api` and `/ws` entries only when `HELM_API_TOKEN` is set, and adds
    no header when it is unset or blank. The token is not exposed through
    `import.meta.env` or `define`. *Manual*: the dashboard on
    `localhost:5173` loads products and items with the token exported in the
    `pnpm dev` shell, and shows errors (not a crash) without it.
11. **Turbo.** `HELM_API_TOKEN` and `HELM_API_AUTH` are in the `dev` task
    `passThroughEnv`.
12. **`.env.example` / `sync-env`.** `apps/api/.env.example` documents
    `HELM_API_TOKEN` (required unless opted out, minimum 32 characters, how to
    generate one) and `HELM_API_AUTH` (only value `disabled`, with the
    rollback warning), and each product input block it shows has a
    `HELM_API_TOKEN=op://<vault>/<item>/<field>` line. No real values. No real
    `.env*` file is read or written and neither `op` nor `pnpm sync-env` is
    run during the implementation. `sync-env-from-1password.sh` does not make
    the token mandatory (that would break the opt-out); the API enforces it.
13. **Operation docs.** `HELM_API_TOKEN` and `HELM_API_AUTH` in the AGENT.md
    variables table; a `docs/local-dev.md` "API authentication" section
    (header, fail closed, opt-out and its precondition, dashboard, rotation);
    every runbook `curl` to `/api/*` except webhooks carries the header
    (helm and helm-knowledge); `operations/production-instance.md` records the
    upgrade steps and the ingress restriction as defense in depth; CHANGELOG
    `[Unreleased]` → Security entry with the breaking impact and upgrade
    steps.
14. **Gate.** `pnpm install --frozen-lockfile && pnpm lint && pnpm test` is
    green, with no dependency added or upgraded.

## Out of Scope
- Session cookies or a login screen (ADR-045 option C).
- Per-user tokens, roles, audit log, a second accepted token.
- Proxy, tunnel or ingress configuration (the interim restriction is an
  operator task outside the repos).
- Real secret values, private `sync-env` inputs, `.env` files, running
  `op`/`sync-env`, workflows, deploy, service definitions or the tunnel.
- CORS headers.
