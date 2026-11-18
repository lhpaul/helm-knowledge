# issue_160 — Implementation Plan

> **Status: ready.** Implements [specs/issue_160.md](../specs/issue_160.md)
> under [ADR-045](../decisions/045-api-operator-auth.md) (Accepted
> 2026-11-18). Risk: **high** (security/auth, breaking for operators who skip
> the release note); the implementation PR escalates to LH and is not
> auto-merged.

## Overview
Add one Hono middleware that requires the operator bearer token on every
`/api/*` route (reads and writes) except the signed webhooks, and on the
`/ws` upgrade. It is configured by `HELM_API_TOKEN` and fails closed when
the token is missing or too short; the only bypass is the explicit
`HELM_API_AUTH=disabled`. The Vite dev proxy adds the header for the
dashboard, and `.env.example` documents the variables for `sync-env`.

## Implementation Steps
1. `apps/api/src/lib/api-auth.ts` (no `hono/bun` import, so it runs under
   vitest/Node, like `origin-guard.ts`):
   - `MIN_TOKEN_LENGTH = 32`.
   - `resolveApiAuth(env)` → `{ mode: 'token', token } | { mode: 'disabled' }
     | { mode: 'misconfigured' }`, plus `errors: string[]` and
     `warnings: string[]` for startup logging (they name variables, never
     include the token). Order: `HELM_API_AUTH` trimmed and equal to
     `disabled` (case-insensitive) → `disabled` with a warning; any other
     non-empty `HELM_API_AUTH` → warning, continue; trimmed
     `HELM_API_TOKEN` empty → `misconfigured` with an error; shorter than 32
     → `misconfigured` with an error; otherwise `token`.
   - `isProtectedPath(path)`: `/ws`, and every `/api/*` path except the
     exact entries of `WEBHOOK_PATHS` (reuse it from `origin-guard.ts` so
     both guards stay in sync; unregistered paths under `/api/webhooks/`
     stay protected).
   - `apiAuth(config)`: Hono `MiddlewareHandler`. Unprotected path or
     `disabled` → `next()`. `misconfigured` → `401`. `token` → parse
     `Authorization` (`Bearer`, case-insensitive scheme, single token, no
     fallback to query or cookies), compare with Hono's `timingSafeEqual`
     (`hono/utils/buffer`), or use the built-in `bearer-auth` middleware
     with a custom JSON `401` response. On failure log `console.warn` with
     method and path only and return `401 { error: 'Unauthorized' }` with
     `WWW-Authenticate: Bearer`.
2. `apps/api/src/app.ts`: resolve the config once from `process.env`, print
   errors (`console.error`) and warnings (`console.warn`), register
   `app.use('/api/*', apiAuth(...))` right after the origin guard and before
   the routers. Export the middleware instance so `index.ts` reuses it.
3. `apps/api/src/index.ts`: register the same middleware on `/ws` before
   `upgradeWebSocket`.
4. `apps/web/src/lib/api-proxy-target.ts` and `apps/web/vite.config.ts`: read
   `HELM_API_TOKEN` from the shell env (`process.env`, not `loadEnv` with a
   `VITE_` prefix); when non-blank, add
   `headers: { Authorization: 'Bearer …' }` to the `/api` and `/ws` proxy
   entries; otherwise add no header. Never expose it through
   `import.meta.env` or `define`. Check that the header reaches the API on
   the WebSocket upgrade.
5. `turbo.json`: add `HELM_API_TOKEN` and `HELM_API_AUTH` to the `dev` task
   `passThroughEnv` (same reason as `HELM_API_HOST` in #159).
6. `apps/api/.env.example` (names, placeholders and docs only):
   - variables section: `HELM_API_TOKEN` (operator token, required unless
     opted out, at least 32 characters, generate with
     `openssl rand -hex 32`, export it too in the `pnpm dev` shell for the
     dashboard) and `HELM_API_AUTH` (only `disabled`; reopens the API; only
     after the rollback preconditions below: ingress restricted to
     `/api/webhooks/*` and `/health`, and no non-loopback bind reachable from
     the network);
   - add `HELM_API_TOKEN=op://<vault>/<item>/<field>` to every product input
     block (`.env.<product>` and `.env.helm`).
   Do not touch `apps/api/scripts/sync-env-from-1password.sh` (making the
   token mandatory there would break the opt-out; the API enforces it). Do
   not read or write real `.env*` files and do not run `op` or
   `pnpm sync-env`.
7. Docs in helm: AGENT.md variables table (`HELM_API_TOKEN`,
   `HELM_API_AUTH`); `docs/local-dev.md` section "API authentication"
   (header, fail closed, opt-out and its precondition, dashboard, rotation
   with its short `401` window) and the header on every `curl` to `/api/*`
   except webhooks; CHANGELOG `[Unreleased]` → Security entry with the
   breaking impact and the upgrade steps from ADR-045.
8. Docs in helm-knowledge (separate PR, `Refs lhpaul/helm#160`): add the
   header to the `/api/*` `curl` commands in
   `operations/production-instance.md`, `operations/onboarding-product.md`,
   `operations/review-loop-smoke-test.md` and
   `operations/branch-rulesets-setup.md`; add an "API authentication
   (helm#160)" note to `operations/production-instance.md` with the upgrade
   steps, the rollback precondition, and the ingress restriction to
   `/api/webhooks/*` and `/health` kept as defense in depth (no host names
   or provider details); mention `HELM_API_TOKEN` among the references in
   `operations/secrets-service-account.md` if that runbook lists variables.

## Files to Touch
- helm: `apps/api/src/lib/api-auth.ts`, `apps/api/src/lib/api-auth.test.ts`,
  `apps/api/src/app.ts`, `apps/api/src/index.ts`, existing route tests that
  call protected routes through `app` (send the header, or set
  `HELM_API_AUTH=disabled` only in tests that are not about auth),
  `apps/web/src/lib/api-proxy-target.ts`,
  `apps/web/src/lib/api-proxy-target.test.ts`, `apps/web/vite.config.ts`,
  `turbo.json`, `apps/api/.env.example`, `AGENT.md`, `docs/local-dev.md`,
  `CHANGELOG.md`.
- helm-knowledge: the runbooks in step 8.
- Not touched: real `.env*` files and private `sync-env` inputs,
  `apps/api/scripts/sync-env-from-1password.sh`, dependencies and lockfile,
  workflows, deploy, tunnel or ingress.

## Test Strategy
Mapped to the spec's acceptance criteria (AC).
- `api-auth.test.ts`:
  - config resolution: unset, blank, whitespace, 31 and 32 characters,
    valid; `HELM_API_AUTH=disabled` and `DISABLED`; unknown values (`off`,
    `false`) keep auth on with a warning; errors and warnings never contain
    the token (AC 6, 7, 9);
  - path matching: both webhooks exempt, unregistered `/api/webhooks/x`
    protected, `/api/*` protected, `/ws` protected, `/health` not matched
    (AC 4, 5);
  - middleware through a small Hono app: missing header, wrong token, token
    of another length, `Basic` scheme, query-string token, lowercase
    `bearer` scheme, valid token, `misconfigured`, `disabled`; handler not
    called on `401`; body, `WWW-Authenticate` header; captured logs contain
    method and path but not the token (AC 1, 3, 6, 7, 9).
- Through the real `app`: dispatch and `POST /api/items` without the token
  return `401` and create no job or item; with the token they reach the
  handler; `GET /api/products` and `GET /api/jobs/:jobId` without the token
  return `401` and with it respond normally; a signed GitHub webhook and a
  signed Linear webhook with no `Authorization` are accepted and a bad
  signature still fails; `GET /health` returns `200`; a foreign `Origin` with
  a valid token gets `403` from the #162 guard (AC 1, 2, 3, 5, 8).
- `api-proxy-target.test.ts`: header added to `/api` and `/ws` only when
  `HELM_API_TOKEN` is non-blank; no `VITE_`-exposed value (AC 10).
- Manual, recorded in the PR: under Bun, `/ws` with the token upgrades and
  receives `{"type":"connected"}` and without it gets `401`; the dashboard
  loads with the token exported and shows errors without it (AC 4, 10).
- Review of the diff: `.env.example` has only names, placeholders and docs;
  `turbo.json` pass-through; docs updated (AC 11, 12, 13).
- Gate: `pnpm install --frozen-lockfile && pnpm lint && pnpm test`, with no
  dependency change (AC 14).

## Rollout
- The implementation PR in helm is **high risk**. Per AGENT.md it escalates
  to LH: no auto-merge. It touches `.env.example` (docs only), which is also
  an escalation trigger.
- The interim ingress restriction is already in place (operator-side); keep
  it after the release as defense in depth.
- Ship it together with the runbook PR in helm-knowledge and the upgrade
  steps from ADR-045 in the release notes. The operator sets the token in
  the secrets manager and the private `sync-env` input before restarting on
  the new release.
- Rollback precondition (ADR-045 "Rollback"), **before** setting
  `HELM_API_AUTH=disabled` or reverting: with a public ingress, confirm from
  outside that it only serves `/api/webhooks/*` and `/health` (or that an
  authenticated proxy is in front); with a non-loopback `HELM_API_HOST`,
  move the API back to loopback or block the API port to everything but
  loopback at the host firewall, and confirm from another host that the port
  is unreachable (the ingress rule does not cover direct LAN clients). The
  `docs/local-dev.md` section, `.env.example`, the CHANGELOG entry and the
  `operations/production-instance.md` note state this, and the startup
  warning for `disabled` points to it.

## Risks
High: authentication on every operator route, reads included, fail closed by
default. Main risks: an update without the token locks operators out of the
dashboard and manual endpoints (webhooks keep working); a proxy header bug
breaks the dashboard; a test fixture that bypasses auth hides a regression;
the opt-out used on an exposed instance reopens it. Mitigations: explicit
startup error naming the variable, `HELM_API_AUTH=disabled` only by exact
value, tests through the real `app` with auth on, a manual dashboard and
`/ws` check, the ingress restriction kept as defense in depth, and the
rollback precondition in every doc. Rollback: `HELM_API_AUTH=disabled` and
restart, or revert the release, only after the ingress and bind
preconditions in Rollout are met; prefer setting the token.
