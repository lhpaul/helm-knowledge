# issue_162 — Specification

## Context
The local review of the v0.1.0 release PR (lhpaul/helm#158) flagged a blocker that already exists on `develop`: the API's state-changing routes do not check where a request comes from. The API has no authentication (lhpaul/helm#160) and, since lhpaul/helm#159, listens on `127.0.0.1`. A web page open in the operator's browser can still send a "simple" cross-origin request (HTML form or `fetch` with `mode: 'no-cors'`) to `http://127.0.0.1:3001` or to the public ingress and trigger, for example, `POST /api/products/:slug/items/:externalId/dispatch`. The browser blocks the attacker from reading the response, but the side effect already happened. The API has no CORS middleware, so only non-preflighted requests get through, which is enough.

State-changing routes on `develop` today:

| Route | Kind |
| --- | --- |
| `POST /api/products/:slug/items/:externalId/dispatch` | operator |
| `POST /api/items` | operator |
| `POST /api/items/:externalId/transitions` | operator |
| `POST /api/items/:externalId/merge-reconciliation` | operator |
| `POST /api/items/:externalId/release` | operator |
| `POST /api/items/:externalId/rollback` | operator |
| `POST /api/webhooks/github` | webhook (HMAC signature) |
| `POST /api/webhooks/linear` | webhook (HMAC signature) |

The web UI (`apps/web`) only issues `GET` requests today. The documented legitimate clients of the operator routes are non-browser tools (`curl` in the runbooks, scripts), which send no `Origin` and no `Sec-Fetch-Site` header.

## Decision
Add one origin guard in front of every `/api/*` route:

1. Safe methods (`GET`, `HEAD`, `OPTIONS`) pass unchanged.
2. The webhook routes (`/api/webhooks/github`, `/api/webhooks/linear`, exact paths) pass unchanged; they are authenticated by signature and are called by GitHub/Linear servers.
3. Any other method (POST, PUT, PATCH, DELETE, ...) is checked:
   - If the request has an `Origin` header, it must be in the allowed origins. Otherwise → `403`. `Origin: null` (sandboxed iframes, `data:` URLs, some redirects) is always rejected.
   - If there is no `Origin` but there is `Sec-Fetch-Site`, only `same-origin` and `none` (user-initiated navigation) pass; `same-site` and `cross-site` → `403`.
   - If there is neither header, the request passes. **Explicit decision:** browsers always send `Origin` on cross-origin `POST`/`PUT`/`PATCH`/`DELETE` (Fetch standard), so a request without both headers is not a browser cross-origin request. This keeps `curl`, scripts and the runbook smoke checks working with no change. It is the same policy as Go's `net/http.CrossOriginProtection`.
4. Matching is against an explicit allowlist, not against the `Host` header, so a DNS-rebinding page (attacker hostname resolved to `127.0.0.1`) is still rejected.

Allowed origins:

- Default: the local Helm UI dev server, `http://localhost:5173`, `http://127.0.0.1:5173` and `http://[::1]:5173` (Vite binds to `localhost`; the dev proxy keeps the browser's `Origin`).
- `HELM_ALLOWED_ORIGINS` (optional, comma-separated) **adds** origins, for example when the UI is served from another host or port, or when `HELM_API_HOST` (#159) exposes the stack on a LAN address. Each entry is normalized with the URL parser (`scheme://host[:port]`, default ports dropped, lowercase host). Blank entries are ignored; invalid entries, and entries that are not bare `http`/`https` origins (with a path, query, credentials or `*`), are ignored with a startup warning. A wildcard is not supported.

Rejection: `403` with `{ "error": "Cross-origin request rejected" }`; the server logs one warning line with method, path and the (JSON-escaped) offending origin. No internal details are returned.

## Impact on existing instances
- `curl`/scripts/automation without `Origin` keep working unchanged (runbook smoke checks included).
- Webhooks from GitHub and Linear keep working (exempt by path, still verified by signature).
- The bundled UI on `localhost:5173` keeps working (it only reads today; future UI writes from these origins are allowed).
- Any browser-based tool on another origin that posts to the API (a custom dashboard, a bookmarklet, a UI served on a LAN host) gets `403` until its origin is added to `HELM_ALLOWED_ORIGINS` and the API is restarted.

## Acceptance Criteria
- A state-changing request to a non-webhook route with a non-allowed `Origin` (including `null`) returns `403` and does not run the handler (no dispatch job, no item write).
- A request with an allowed `Origin` (default or from `HELM_ALLOWED_ORIGINS`) reaches the handler.
- A request without `Origin` and with `Sec-Fetch-Site: cross-site` or `same-site` returns `403`; with `same-origin`/`none` or with no `Sec-Fetch-Site` it reaches the handler.
- Webhook routes accept requests with any `Origin` (signature checks unchanged).
- `GET` routes are unaffected by `Origin`.
- Unit tests cover the allowlist parsing and the allowed, rejected, no-header and webhook cases; existing route tests keep passing.
- `HELM_ALLOWED_ORIGINS` is documented (AGENT.md variables table and `docs/local-dev.md`; `.env*` files are not touched) and the CHANGELOG `[Unreleased]` → Security notes the change and the impact for existing instances.
- `pnpm install --frozen-lockfile && pnpm lint && pnpm test` is green.

## Out of Scope
- Authentication or tokens for the API (lhpaul/helm#160).
- CORS headers (the API keeps not sending them; cross-origin reads stay blocked by the browser).
- Cross-site WebSocket hijacking on `/ws` (`GET`, read-only `connected` message today).
- Changing `.env*` files, secrets, workflows, deploy, service definitions or the tunnel.
