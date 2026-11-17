# issue_159 — Specification

## Context
The local review of the v0.1.0 release PR (lhpaul/helm#158) flagged a blocker that already exists on `develop`: `apps/api/src/index.ts` exports a Bun server config without `hostname`. Bun then listens on every interface (`0.0.0.0`), and the API has no authentication, so anyone who can reach the host on port 3001 can read items and trigger dispatches.

Other listeners in the monorepo:
- `apps/web` (Vite dev server, port 5173): Vite already binds to `localhost` unless `--host` is passed. Its proxy targets `http://localhost:3001` / `ws://localhost:3001`; on hosts where `localhost` resolves to `::1` first, that proxy would miss an API bound to `127.0.0.1` only.
- No other HTTP servers in `apps/*`, `packages/*` or `scripts/`.

## Decision
- The API listens on `127.0.0.1` by default.
- `HELM_API_HOST` overrides it explicitly (for example `0.0.0.0` or a LAN address). Empty or whitespace-only values fall back to the default. When the resolved host is not a loopback address, the API logs a warning at startup that the API has no authentication.
- The startup log prints the real bind address instead of a hard-coded `localhost`.
- The Vite dev proxy targets `127.0.0.1:3001` so local dev keeps working.
- Port stays 3001 (out of scope).

## Impact on existing instances
- Single-host setups that reach the API through `localhost`/`127.0.0.1`, a local tunnel or a local reverse proxy keep working, as long as the forwarder targets `127.0.0.1:3001` (or a `localhost` that resolves to IPv4).
- Setups that reach the API from another machine (LAN, container network, remote proxy) stop working after the update until they set `HELM_API_HOST` and restart. Prefer an authenticated proxy over exposing the API directly.

## Acceptance Criteria
- Without `HELM_API_HOST`, the server config uses `hostname: '127.0.0.1'`.
- With `HELM_API_HOST` set, the trimmed value is used; empty/blank values use the default.
- A non-loopback host logs a warning; loopback hosts (`127.0.0.1`, `::1`, `localhost`, `127.x.x.x`) do not.
- Unit tests cover default, override, blank fallback and the warning.
- `HELM_API_HOST` is documented (AGENT.md variables table, local dev docs) and the CHANGELOG `[Unreleased]` notes the change and the impact for existing instances.
- `pnpm install --frozen-lockfile && pnpm lint && pnpm test` is green.

## Out of Scope
- Adding authentication to the API (to be proposed as a separate issue).
- Changing `.env*` files, secrets, workflows, deploy, service definitions or the tunnel.
- Making the port configurable.
