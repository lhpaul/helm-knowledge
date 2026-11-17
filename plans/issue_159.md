# issue_159 — Implementation Plan

## Overview
Bind the Bun API server to loopback by default, with an explicit `HELM_API_HOST` override, and keep local dev working.

## Implementation Steps
1. Add `apps/api/src/server-config.ts` (no `hono/bun` import, so it runs under vitest/Node):
   - `DEFAULT_API_HOST = '127.0.0.1'`, `API_PORT = 3001`.
   - `resolveApiHost(env)`: trimmed `HELM_API_HOST`, or the default when missing/blank.
   - `isLoopbackHost(host)`: `localhost`, `::1`, `[::1]`, `127.0.0.0/8`.
   - `buildListenConfig(env)` → `{ hostname, port, warning? }`, with a warning when the host is not loopback.
2. `apps/api/src/index.ts`: use `buildListenConfig(process.env)` for `hostname`/`port` in the exported server config, log the real address and the warning if any.
3. `apps/web/vite.config.ts`: proxy targets `http://127.0.0.1:3001` and `ws://127.0.0.1:3001`.
4. Docs: `HELM_API_HOST` row in `AGENT.md`; "API bind address" section in `docs/local-dev.md`.
5. CHANGELOG `[Unreleased]` → Security entry with impact and how to restore the previous behavior.

## Files to Touch
- helm: `apps/api/src/server-config.ts`, `apps/api/src/server-config.test.ts`, `apps/api/src/index.ts`, `apps/web/vite.config.ts`, `AGENT.md`, `docs/local-dev.md`, `CHANGELOG.md`.
- helm-knowledge: `specs/issue_159.md`, `plans/issue_159.md`, `operations/production-instance.md` (impact note).

## Test Strategy
- Unit tests in `server-config.test.ts` for default, override, trimming, blank fallback, IPv6 loopback, and the warning.
- Manual smoke with Bun: start the API with no override and check it answers on `127.0.0.1:3001/health` and does not listen on a non-loopback address; start with `HELM_API_HOST=0.0.0.0` and check the warning.
- Gate: `pnpm install --frozen-lockfile && pnpm lint && pnpm test`.

## Risks
Medium: changes the default network exposure. Instances reached from another host stop answering until they set `HELM_API_HOST`; the CHANGELOG and the production runbook call this out. No auth, deploy, secrets or workflow changes. Rollback: revert the commit, or set `HELM_API_HOST=0.0.0.0`.
