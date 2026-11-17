# issue_162 — Implementation Plan

## Overview
Reject cross-origin browser requests to the API's state-changing, non-webhook routes with one Hono middleware, configured by an origin allowlist (local UI by default, `HELM_ALLOWED_ORIGINS` to add more).

## Implementation Steps
1. `apps/api/src/lib/origin-guard.ts` (no `hono/bun` import, so it runs under vitest/Node):
   - `DEFAULT_ALLOWED_ORIGINS`: `http://localhost:5173`, `http://127.0.0.1:5173`, `http://[::1]:5173`.
   - `normalizeOrigin(value)`: URL-parse; return `url.origin` only for `http:`/`https:` with no credentials, path other than `/`, query or hash; otherwise `null`.
   - `resolveAllowedOrigins(env)` → `{ origins: Set<string>, warnings: string[] }`: defaults plus each non-blank comma-separated entry of `HELM_ALLOWED_ORIGINS`; invalid entries produce a warning and are skipped.
   - `WEBHOOK_PATHS`: exact `/api/webhooks/github`, `/api/webhooks/linear`.
   - `checkOrigin({ method, path, origin, secFetchSite }, allowed)` → `'allow' | 'reject'` (pure function with the policy from the spec).
   - `originGuard(allowed)`: Hono `MiddlewareHandler`; on reject logs `console.warn` (method, path, `JSON.stringify(origin)`) and returns `403 { error: 'Cross-origin request rejected' }`.
2. `apps/api/src/app.ts`: resolve the allowlist from `process.env` once, print its warnings, and register `app.use('/api/*', originGuard(...))` before the routers.
3. `turbo.json`: add `HELM_ALLOWED_ORIGINS` to the `dev` task `passThroughEnv` (same reason as `HELM_API_HOST` in #159).
4. Docs: `HELM_ALLOWED_ORIGINS` row in `AGENT.md`; "Cross-origin protection" section in `docs/local-dev.md`.
5. CHANGELOG `[Unreleased]` → Security entry with the policy and impact for existing instances.

## Files to Touch
- helm: `apps/api/src/lib/origin-guard.ts`, `apps/api/src/lib/origin-guard.test.ts`, `apps/api/src/app.ts`, `apps/api/src/routes/dispatch.test.ts` (end-to-end cases through `app`), `turbo.json`, `AGENT.md`, `docs/local-dev.md`, `CHANGELOG.md`.
- helm-knowledge: `specs/issue_162.md`, `plans/issue_162.md`, `operations/production-instance.md` (impact note).

## Test Strategy
- `origin-guard.test.ts`: normalization (default ports, case, trailing slash, rejected forms), env parsing with warnings, and the policy matrix (safe methods, webhook paths, allowed/foreign/`null` Origin, `Sec-Fetch-Site` values, no headers), plus the middleware through a small Hono app (403 body, handler not called).
- `dispatch.test.ts`: through the real `app`, a foreign `Origin` gets 403 and creates no job; an allowed `Origin` and a header-less request reach the handler; a webhook route with a foreign `Origin` is not rejected by the guard.
- Gate: `pnpm install --frozen-lockfile && pnpm lint && pnpm test`.

## Risks
Medium: security hardening on every state-changing route. It is additive (no auth, no data model, no deploy/secrets/workflow changes) and keeps non-browser clients and webhooks working; only browser tools on unlisted origins are rejected, which is the goal. Rollback: revert the commit, or add the needed origin to `HELM_ALLOWED_ORIGINS`.
