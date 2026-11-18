# ADR-045: Authentication for non-webhook API routes

**Date:** 2026-11-18 (proposed; set to the acceptance date when accepted)
**Status:** Proposed
**Related:** lhpaul/helm#160 (this decision), lhpaul/helm#159 (loopback bind,
`HELM_API_HOST`), lhpaul/helm#162 (cross-origin guard, `HELM_ALLOWED_ORIGINS`),
ADR-031 (API HTTP error conventions)

---

## Context

The Helm API (`apps/api`, Bun + Hono, port 3001) has no authentication on any
route except the two webhooks. After #159 it listens on `127.0.0.1` by
default, and after #162 it rejects cross-origin browser requests to
state-changing routes. Neither change authenticates the caller.

### What the API serves today (develop)

| Surface | Routes | Protection today |
| --- | --- | --- |
| Health | `GET /health` | none (used by uptime watchdogs) |
| Reads | `GET /api/product`, `GET /api/products`, `GET /api/products/:slug`, `GET /api/products/:slug/items`, `GET /api/products/:slug/items/:externalId`, `GET /api/items`, `GET /api/jobs/:jobId`, `GET /api/products/:slug/items/:externalId/jobs` | none |
| Operator writes | `POST /api/items`, `POST /api/items/:externalId/transitions`, `POST /api/items/:externalId/merge-reconciliation`, `POST /api/items/:externalId/release`, `POST /api/items/:externalId/rollback`, `POST /api/products/:slug/items/:externalId/dispatch` | #162 origin guard only (blocks browsers on foreign origins; any non-browser client passes) |
| Webhooks | `POST /api/webhooks/github`, `POST /api/webhooks/linear` | HMAC signature (`GITHUB_WEBHOOK_SECRET`, Linear signing secret) |
| WebSocket | `GET /ws` (registered in `apps/api/src/index.ts`, outside `/api/*`) | none; sends one `{"type":"connected"}` message today |

Reads expose item history, job records and product configuration (the
`slack_webhook` notification URL is already stripped by
`publicProductResponse`). Writes create items, move them through the state
machine and start agent runs that spend money and push branches.

### Who calls it

- **Dashboard (`apps/web`)**: a React SPA served by the Vite dev server on
  `localhost:5173`. It only issues `GET` requests through a relative `/api`
  path that the Vite proxy forwards to the API (`apps/web/vite.config.ts`,
  target follows `HELM_API_HOST`). `VITE_API_URL` can point it at another
  base URL. The SPA does not open `/ws` today.
- **Operators and scripts**: `curl` in the runbooks (`docs/local-dev.md`,
  `operations/production-instance.md`, `operations/onboarding-product.md`,
  `operations/review-loop-smoke-test.md`) for item creation, dispatch,
  rollback, release, merge reconciliation and read-only smoke checks. Operator
  automation outside the repos may do the same.
- **The orchestrator and agents**: no HTTP client. The orchestrator runs in
  the API process; spawned agent runtimes do not receive an API URL.
- **GitHub and Linear**: only the webhook routes.
- **Uptime watchdogs**: only `/health`.

### Why loopback and the origin guard are not enough

- A loopback bind does not mean only trusted callers. Any process of any user
  on the host can reach `127.0.0.1:3001`, and so can anything a local tunnel
  or reverse proxy forwards. The reference production layout forwards a public
  HTTPS hostname to `127.0.0.1:3001` so webhooks can reach Helm; with no path
  filter at the ingress, every read and every operator write is reachable
  from the internet by any non-browser client.
- The API cannot tell a tunnel request from a local one: both come from
  loopback. Authentication has to be on the request, not on the network path.
- The #162 guard only stops browsers on foreign origins. `curl` passes by
  design.

## Options

All options keep the webhooks on their signature checks and keep
`GET /health` public.

### A. Operator bearer token in the API (`HELM_API_TOKEN`)

The API reads one shared secret from its environment. A middleware in front
of `/api/*` (except the webhook paths) and on the `/ws` upgrade requires
`Authorization: Bearer <token>`, compared in constant time (Hono's built-in
`bearer-auth` middleware already does this; no new dependency). Missing or
wrong token → `401 {"error":"Unauthorized"}` with
`WWW-Authenticate: Bearer`, following ADR-031's error shape.

- **Dashboard:** the Vite dev proxy adds the header server-side when it
  forwards `/api` and `/ws` (it reads `HELM_API_TOKEN` from the shell, like
  `HELM_API_HOST` in #159). The SPA code and the browser never hold the token.
  A UI built and served elsewhere with `VITE_API_URL` is not covered; it
  needs a proxy that adds the header, or option C later.
- **WebSocket:** the upgrade `GET /ws` goes through the same check before
  `upgradeWebSocket`. The Vite proxy adds the header on the upgrade request;
  non-browser clients send it directly. Tokens in query strings are not
  accepted (they end up in logs and history).
- **Local clients:** `curl -H "Authorization: Bearer $HELM_API_TOKEN"`. Every
  runbook command that hits `/api/*` (reads included) changes.
- **Cost:** small. One middleware, one env var, one proxy header, docs.
- **Weaknesses:** one shared secret with no per-user identity or audit; the
  token sits in the shell of whoever runs `pnpm dev`; the Vite dev server
  becomes an authenticated gateway, so it must stay on `localhost` (with
  `vite --host` it would hand the token's authority to the LAN, though #162
  still blocks foreign-origin browser writes).

### B. Delegate authentication to the proxy or tunnel

Helm stays unauthenticated. The operator puts an identity-aware proxy in front
of the public hostname (an access policy at the tunnel provider, an OAuth
proxy, a private network) and bypasses it only for `/api/webhooks/*` and
`/health`.

- **Dashboard and WebSocket:** covered by the proxy's browser login when the
  UI is reached through it; the local dev UI is not affected.
- **Local clients:** unchanged; loopback callers stay unauthenticated.
- **Cost:** no Helm code. Configuration lives with the operator.
- **Weaknesses:** Helm cannot enforce or check it; a missing path rule
  silently reopens the API. Local processes stay unauthenticated. Every new
  operator has to rebuild the same setup. Good as defense in depth, not as
  the only control.

### C. Login and session cookie for the dashboard (on top of A)

Add `POST /api/session`, which takes the operator token once and sets an
`HttpOnly`, `SameSite=Strict` session cookie (signed with a server key,
`Secure` over HTTPS). The middleware accepts either the bearer header or a
valid session cookie. The cookie rides on `fetch` and on the WebSocket
upgrade automatically, so the dashboard can be served from any origin that the #162
allowlist accepts, without a header-injecting proxy.

- **Dashboard and WebSocket:** covered from any allowed origin, including a
  built UI on a remote host.
- **Local clients:** same as A (bearer header).
- **Cost:** medium. Login screen, cookie signing key and rotation, session
  expiry, logout, and keeping the #162 guard as the CSRF defense for
  cookie-authenticated writes.
- **Weaknesses:** more surface than Helm v0 needs while the only UI is a
  local dev server.

### D. Split listeners: public webhooks, loopback operator API

Serve the webhooks on a second port and point the tunnel only at it; the
operator API stays on `127.0.0.1:3001`.

- **Dashboard, WebSocket and local clients:** unchanged.
- **Cost:** small to medium (two Bun servers, tunnel and watchdog
  reconfiguration on every instance).
- **Weaknesses:** removes the internet exposure but no local caller is
  authenticated, and exposing the operator API on a LAN with
  `HELM_API_HOST` stays open. It is network segmentation, not authentication.

## Proposed decision

**Option A**, with option B documented as defense in depth and option C left
as a follow-up when a dashboard served outside the local dev server exists.

- `HELM_API_TOKEN` (shared operator token) protects every `/api/*` route
  except `/api/webhooks/github` and `/api/webhooks/linear`, plus the `/ws`
  upgrade. Reads are protected too: they expose item, job and product data.
- `GET /health` stays public and unchanged.
- The middleware runs after the #162 origin guard and before the routers; it
  does not replace the guard (the guard still blocks a browser on a foreign
  origin that somehow holds a valid token or cookie in the future).
- **Fail closed** (see open question 1): when `HELM_API_TOKEN` is not set,
  protected routes answer `401` and the API logs a startup error that names
  the variable. An explicit `HELM_API_AUTH=disabled` keeps today's behavior
  for a single-user dev machine and logs a startup warning on every boot.
- Tokens shorter than 32 characters are rejected at startup with an error
  (the API still starts so webhooks keep flowing; protected routes answer
  `401`).
- Rotation: change the value and restart the API (and `pnpm dev` for the
  proxy). No multi-token support in the first version (open question 3).

### Why A

- It closes the internet exposure through the existing tunnel and the
  local-process exposure with one control that Helm itself enforces.
- It covers the dashboard and the WebSocket without code in the SPA, because
  the only supported dashboard today is the Vite dev server.
- It needs no new dependency and keeps the API's error conventions.
- B and D depend on per-instance configuration Helm cannot verify; C costs
  more than the current UI justifies and can be added later on top of A.

## Impact on an already deployed instance

| Who | Change needed |
| --- | --- |
| Operator of a running instance | Generate a token (for example `openssl rand -hex 32`), store it in the secrets manager, add it to the product's `sync-env` input, regenerate `apps/api/.env`, restart the API. |
| Dashboard users | Export `HELM_API_TOKEN` in the shell that runs `pnpm dev` (Turbo passes it through), as with `HELM_API_HOST`. |
| `curl`, scripts, smoke checks | Add `-H "Authorization: Bearer $HELM_API_TOKEN"` to every `/api/*` call except webhooks. |
| GitHub and Linear webhooks | None. |
| Uptime watchdogs on `/health` | None. |
| Tunnel or proxy | None required. Recommended: also restrict the public hostname to `/api/webhooks/*` and `/health` (option B as defense in depth). |

Backward compatibility: with fail closed, updating without setting the token
makes every protected route answer `401` (the dashboard shows errors, operator
`curl` fails), while webhooks keep advancing items. The CHANGELOG
`[Unreleased]` → Security entry must say this, and the release notes must
list the steps above.

Rollback: setting `HELM_API_AUTH=disabled` or reverting the release reopens
every operator read and write to any client that reaches the API. On an
instance with a public ingress (the reference production layout), **first**
restrict the ingress to `/api/webhooks/*` and `/health` (or put an
authenticated proxy in front of it), confirm from outside that other `/api/*`
paths are blocked, and only then disable auth or revert. On a machine with no
ingress and no `HELM_API_HOST` override, the rollback only reopens the API to
local processes, as before this change. Prefer fixing the token (set it,
restart) over rolling back.

**Interim mitigation until the implementation ships** (operator-side, no
Helm change): limit the public ingress to `/api/webhooks/*` and `/health`.

## Open questions for LH

1. **Fail closed or opt-in?** Proposed: fail closed with the explicit
   `HELM_API_AUTH=disabled` escape hatch. The alternative (auth only when
   `HELM_API_TOKEN` is set, warning otherwise) avoids breaking any update but
   leaves every instance that misses the release note open, including the
   production layout with a public tunnel.
2. **Should reads be protected too?** Proposed: yes. The alternative is to
   protect only writes and `/ws`, which keeps read-only smoke checks
   unchanged but leaves item history, jobs and product config readable by
   any caller that reaches the API.
3. **One token or several?** Proposed: one token in the first version. Two
   accepted tokens (`HELM_API_TOKEN` plus a `HELM_API_TOKEN_PREVIOUS`) would
   allow rotation without a gap; it can be added later without breaking
   changes.
4. **Secrets wiring.** Adding the token to `.env.example` and the `sync-env`
   inputs touches secrets files and scripts. Proposed: the implementation PR
   only documents the variable (AGENT.md, `docs/local-dev.md`, CHANGELOG) and
   LH adds it to the secrets manager and the private `sync-env` inputs. Should
   the implementation also update `.env.example` (comment only, no value)?
5. **Interim mitigation.** Should the operator restrict the public ingress to
   `/api/webhooks/*` and `/health` now, before the implementation ships?
   That is an operator change outside the Helm repos and is not part of this
   decision.

## Consequences

- Positive: every non-webhook caller has to prove it holds the operator
  token, whether it reaches the API from loopback, a LAN bind or the public
  tunnel. The dashboard keeps working through the dev proxy without code
  changes in the SPA.
- Negative: one shared secret, no per-user identity or audit trail; every
  runbook command and operator script changes; one more secret to rotate; an
  update that skips the release note breaks the dashboard and operator
  `curl` until the token is set.
- Neutral: webhooks, `/health`, the #159 bind and the #162 origin guard do
  not change.

## Alternatives considered

Options B, C and D above. B is kept as recommended defense in depth; C is a
possible follow-up on top of A; D is not pursued because it does not
authenticate anyone.

## Revisit when

- Helm ships a dashboard served outside the local Vite dev server, or more
  than one human operator needs separate identities or an audit trail
  (consider option C or per-user tokens).
- Helm gets a client that cannot send headers (for example a browser
  `EventSource`).
- The deployment model moves to a managed host where an identity-aware proxy
  is always present (option B could become the primary control).
