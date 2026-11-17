# Production instance — generic runbook

How the single production instance of Helm is run for its one private
consumer product. This page keeps only the shape of the setup and the lessons
that apply to any Helm deployment. The detailed operational runbook (hosts,
paths, service names, ingress and secret locations) is kept in private
operations notes.

## Goal

Helm (not a bare agent session) owns the consumer's tracker items: spec → plan
→ implementation → review loop, with an external review provider configured in
the product's `.helm/product.yaml`.

## Layout

| Piece | Description |
|---|---|
| Host | A dedicated always-on machine run by the owner |
| Helm monorepo | A dedicated checkout on `develop`, used only to serve the instance and updated by hand by the owner. Development agents use separate clones. The [release policy](release-policy.md) proposes running a release tag instead, with a generic update and rollback procedure. |
| Knowledge and app repos | The consumer's private knowledge and code repos, checked out next to Helm |
| `HELM_DATA_DIR` | A directory outside the code checkout |
| API | `apps/api` bound to `127.0.0.1:3001` (the default since helm#159; `HELM_API_HOST` overrides it), run as a user-level system service that starts at login and restarts on failure |
| Public ingress | A named tunnel from a managed provider that forwards a stable public HTTPS hostname to the local API |
| Secrets | Resolved from the secrets manager into `apps/api/.env` (gitignored) with `pnpm sync-env` |

Product config: the tracker is Linear, early artifact review is enabled, and
the external review provider is set in `review.external`.

## Lessons that apply to any deployment

### Public ingress

- Webhooks need a stable public HTTPS endpoint. Ephemeral "quick" tunnel URLs
  change on restart and are not suitable.
- A previous ingress was retired after public DNS resolution for its hostname
  flaked for one webhook sender while the authoritative record stayed healthy.
  GitHub tolerated it; Linear auto-disabled the webhook after failed bursts.
- A watchdog monitors the public health endpoint, not a specific ingress
  product, so swapping the ingress does not break monitoring.

### Bind address (helm#159)

- Since helm#159 the API listens on `127.0.0.1` by default instead of every
  interface. The public ingress must forward to `127.0.0.1:3001` (or to a
  `localhost` that resolves to IPv4). After updating, restart the service and
  check `curl -sf http://127.0.0.1:3001/health` and the public health endpoint.
- Only set `HELM_API_HOST` (for example `0.0.0.0`) when the API must be reached
  from another machine. The API has no authentication; prefer an
  authenticated proxy.

### Cross-origin protection (helm#162)

- State-changing API routes (everything except `GET`/`HEAD`/`OPTIONS` and the
  signed webhooks) reject browser requests whose `Origin` is not an allowed
  Helm UI origin, with `403`. Requests without `Origin` (curl, scripts, the
  smoke checks below) and the GitHub/Linear webhooks are not affected.
- Allowed by default: the local UI dev server on port 5173 (`localhost`,
  `127.0.0.1`, `[::1]`). A browser tool on any other origin needs that origin
  in `HELM_ALLOWED_ORIGINS` (comma-separated) and an API restart.

### Running the API as a service

- Run the API as a supervised service with restart-on-exit, not in a terminal
  multiplexer. On 2026-09-01 a host reboot left a multiplexer-run API down for
  about 49 minutes, and webhooks got 502 the whole time; the supervised
  watchdogs on the same host came back on their own.
- Run it **without** `--watch`: restarts are decided by the supervisor, not by
  the filesystem. With `--watch`, pulling the monorepo would restart the API in
  the middle of a webhook. Restart explicitly after pulling.
- Do not start a second copy by hand: it takes the port and leaves the
  supervised service in a crash loop.

### Secrets

- `apps/api/.env` persists on disk, so the API restarts unattended after a
  reboot. Regenerating it (rotation, a new key) needs a signed-in secrets
  manager session, which the host does not keep across reboots, so today it is
  done from another machine. Tracked as **TD-003** in the
  [tech-debt register](tech-debt.md).
- A read-only 1Password service account removes that dependency: `sync-env`
  runs on the host with `OP_SERVICE_ACCOUNT_TOKEN` loaded only for that run.
  Procedure: [secrets-service-account.md](secrets-service-account.md).

## Webhooks

### GitHub

Hooks on the consumer's code and knowledge repos point at
`<public-base-url>/api/webhooks/github`:

- Events: `pull_request`, `issue_comment`, `check_run`, `status`, `release`
- Secret: the GitHub webhook secret from the secrets manager

Helm returns **200** for `ping` on Linear products (helm#102).

### Linear (helm#104)

The webhook is created in the Linear UI because the API token lacks the admin
scope `webhookCreate` needs:

1. Settings → Administration → API → Webhooks
2. URL: `<public-base-url>/api/webhooks/linear`
3. Team: the consumer's team
4. Resource types: Issue, Comment
5. Signing secret: the Linear webhook secret from the secrets manager

Linear's UI may not offer "Send test"; smoke with a signed POST (HMAC-SHA256 in
`Linear-Signature`) expecting 401 without or with a wrong signature and 200 with
the secret. After helm#106 the handler acknowledges within Linear's 5-second
deadline and runs side effects in the background.

When Linear reports that a webhook was disabled:

1. Check `<public-base-url>/health` and the service and tunnel status on the host
2. Confirm the tunnel is healthy at the provider
3. Re-enable the webhook in Linear (the URL must stay `…/api/webhooks/linear`)

## Smoke checks

```bash
BASE=http://127.0.0.1:3001   # or the public base URL
curl -sf "$BASE/health"
curl -s "$BASE/api/products" | jq '.[].product.slug'
curl -s "$BASE/api/products/<product-slug>" | jq '.review.external.provider,.review.early_loop'
curl -s "$BASE/api/items" | jq '.[].externalId'
```

Create and dispatch an item:

```bash
curl -s -X POST "$BASE/api/items" \
  -H 'content-type: application/json' \
  -d '{"externalId":"<ITEM-ID>","triggeredBy":"manual:operator"}'

curl -s -X POST "$BASE/api/products/<product-slug>/items/<ITEM-ID>/dispatch"
```

## Known Helm fixes (early loop)

- **helm#105** (2026-08-20): CodeRabbit Combined Status often has
  `creator: null`. Older Helm treated that as `unavailable` →
  `external_repeated_skip` before a pending intent could land. Fix: trust an
  allowlisted context with a missing creator; synthetic `pending` when no
  status exists yet; rate-limited success → defer.

## Open debts

1. **Durable secrets-manager session on the host** → **TD-003** in the
   [tech-debt register](tech-debt.md), tracked as
   [helm#138](https://github.com/lhpaul/helm/issues/138). In progress: a
   service account was adopted on 2026-11-16 and the owner sets it up
   ([runbook](secrets-service-account.md)).
2. ~~**Residual race:** a status webhook could arrive before the pending intent
   was persisted.~~ → **TD-002**, resolved in
   [helm#140](https://github.com/lhpaul/helm/pull/140).

## Related

- Release, update and rollback policy (proposal): [release-policy.md](release-policy.md)
- Review-loop friction learning:
  `learnings/2026-07-13-lea-194-local-helm-review-loop-friction.md`
- Product onboarding: `operations/onboarding-product.md`
