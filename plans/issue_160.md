# issue_160 — Implementation Plan

> **Status: draft, depends on ADR-045.** Implements
> [specs/issue_160.md](../specs/issue_160.md). Do not start until LH accepts
> [ADR-045](../decisions/045-api-operator-auth.md) and answers its open
> questions; update this plan first if the answers differ from the
> recommendation.

## Overview
Add one Hono middleware that requires the operator bearer token on every
non-webhook `/api/*` route and on the `/ws` upgrade, configured by
`HELM_API_TOKEN` (fail closed) with an explicit `HELM_API_AUTH=disabled`
escape hatch, and make the Vite dev proxy add the header for the dashboard.

## Implementation Steps
1. `apps/api/src/lib/api-auth.ts` (no `hono/bun` import, so it runs under
   vitest/Node, like `origin-guard.ts`):
   - `MIN_TOKEN_LENGTH = 32`.
   - `resolveApiAuth(env)` → `{ mode: 'token', token } | { mode: 'disabled' }
     | { mode: 'misconfigured' }`, plus `errors: string[]` and
     `warnings: string[]` for startup logging (never including the token).
   - `isProtectedPath(path)`: `/ws`, and `/api/*` except the exact webhook
     paths. Reuse `WEBHOOK_PATHS` from `origin-guard.ts` so both guards stay
     in sync.
   - `apiAuth(config)`: Hono `MiddlewareHandler`. Disabled → `next()`.
     Misconfigured → `401`. Token → parse `Authorization` (`Bearer`,
     case-insensitive scheme), compare with Hono's `timingSafeEqual`
     (`hono/utils/buffer`) or the built-in `bearer-auth` middleware with a
     custom JSON `401` response; on failure log `console.warn` with method
     and path only and return `401 { error: 'Unauthorized' }` with
     `WWW-Authenticate: Bearer`.
2. `apps/api/src/app.ts`: resolve the config once from `process.env`, print
   errors/warnings, register `app.use('/api/*', apiAuth(...))` right after
   the origin guard and before the routers. Export the resolved middleware
   so `index.ts` can reuse it.
3. `apps/api/src/index.ts`: register the same middleware on `/ws` before
   `upgradeWebSocket`.
4. `apps/web/src/lib/api-proxy-target.ts` and `apps/web/vite.config.ts`: read
   `HELM_API_TOKEN` from the shell env; when set, add
   `headers: { Authorization: 'Bearer …' }` to the `/api` and `/ws` proxy
   entries. Never expose it through `import.meta.env` (no `VITE_` prefix).
   Verify the header reaches the API on the WebSocket upgrade.
5. `turbo.json`: add `HELM_API_TOKEN` and `HELM_API_AUTH` to the `dev` task
   `passThroughEnv` (same reason as `HELM_API_HOST` in #159).
6. Docs in helm: AGENT.md variables table; `docs/local-dev.md` section
   "API authentication" (header, fail closed, escape hatch, dashboard,
   rotation) and `curl` examples with the header; CHANGELOG `[Unreleased]` →
   Security entry with the impact and upgrade steps.
7. Docs in helm-knowledge (separate PR): add the header to the `curl`
   commands in `operations/production-instance.md`,
   `operations/onboarding-product.md` and
   `operations/review-loop-smoke-test.md`; add an "API authentication
   (helm#160)" note to `operations/production-instance.md`; set ADR-045 to
   Accepted only if LH has not already done it.

## Files to Touch
- helm: `apps/api/src/lib/api-auth.ts`, `apps/api/src/lib/api-auth.test.ts`,
  `apps/api/src/app.ts`, `apps/api/src/index.ts`, existing route tests that
  call protected routes through `app` (add the header or set
  `HELM_API_AUTH=disabled` in their setup), `apps/web/src/lib/api-proxy-target.ts`,
  `apps/web/src/lib/api-proxy-target.test.ts`, `apps/web/vite.config.ts`,
  `turbo.json`, `AGENT.md`, `docs/local-dev.md`, `CHANGELOG.md`.
- helm-knowledge: the runbooks listed in step 7.
- Not touched: `.env*`, `apps/api/scripts/sync-env-from-1password.sh`,
  workflows, deploy, tunnel (ADR-045 open question 4).

## Test Strategy
- `api-auth.test.ts`: config resolution (unset, blank, short, valid,
  `HELM_API_AUTH=disabled`, unknown `HELM_API_AUTH`), path matching (webhooks
  exempt, `/api/*` protected, `/ws` protected, `/health` not matched), and the
  middleware through a small Hono app (missing header, wrong token, wrong
  scheme, query-string token, valid token, disabled mode; handler not called
  on `401`; the token never appears in captured logs).
- Through the real `app`: a dispatch without the token returns `401` and
  creates no job; with the token it reaches the handler; a `GET` read without
  the token returns `401`; a signed webhook with no `Authorization` is
  accepted; a foreign `Origin` with a valid token still gets `403` from the
  #162 guard.
- `api-proxy-target.test.ts`: header added only when `HELM_API_TOKEN` is set.
- The `/ws` upgrade lives in `index.ts` (Bun only); cover it by testing the
  shared middleware on a `/ws` route in Node and with a manual check under
  Bun before the PR.
- Gate: `pnpm install --frozen-lockfile && pnpm lint && pnpm test`.

## Rollout
- The implementation PR in helm is **high risk** (security/auth, breaking for
  operators who skip the release note). Per AGENT.md it escalates to LH: no
  auto-merge.
- Ship it together with the runbook PR in helm-knowledge and the upgrade
  steps from ADR-045 in the release notes.
- Rollback precondition: on an instance with a public ingress or a
  non-loopback `HELM_API_HOST`, restrict the ingress to `/api/webhooks/*` and
  `/health` (or put an authenticated proxy in front) and verify it from
  outside **before** setting `HELM_API_AUTH=disabled` or reverting. The
  `docs/local-dev.md` section, the CHANGELOG entry and the
  `operations/production-instance.md` note state this, and the startup
  warning for `disabled` points to it.

## Risks
High: authentication on every operator route, fail closed by default. Main
risks: an update without the token locks operators out of the dashboard and
manual endpoints (webhooks keep working); a proxy header bug breaks the
dashboard; a test fixture that bypasses auth hides a regression. Mitigations:
explicit startup error naming the variable, `HELM_API_AUTH=disabled` escape
hatch, tests through the real `app`, and a manual dashboard check.
Rollback: `HELM_API_AUTH=disabled` and restart, or revert the release, only
after the ingress precondition in Rollout is met; prefer setting the token.
