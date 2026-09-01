# Arriendo Fácil — Helm on Mac Mini

Operational runbook for running the Helm API against product `arriendo-facil`
on the Mac Mini (`lhpaul_assistant@mac-mini`).

## Goal

Helm (not a bare Claude session) owns LEA items: spec → plan → impl → review
loop with CodeRabbit as `review.external.provider`.

## Current layout (2026-09-01)

| Piece | Location |
|---|---|
| Helm monorepo | `~/Git/Helm/helm` (`develop`) |
| Knowledge (primary product) | `~/Git/Leasity/leasity-tenants-knowledge` |
| App repo | `~/Git/Leasity/leasity-tenants` |
| `HELM_DATA_DIR` | `~/Git/Leasity/helm-data` |
| API | `http://127.0.0.1:3001` via LaunchAgent `com.lh.helm.af-api` |
| Public URL | **Tailscale Funnel** `https://mac-mini-de-luis.tailc0e5af.ts.net/` → `:3001` |
| Env input | `apps/api/.env.leasity-tenants` (op:// refs + Mini paths) |
| Resolved env | `apps/api/.env` (gitignored; currently injected from MacBook) |

Product config (knowledge `.helm/product.yaml`):

- `review.external.provider: coderabbit`
- `review.early_loop.enabled: true`
- Tracker: Linear team `LEA`

## Public ingress (Tailscale Funnel)

Stable HTTPS without a custom Cloudflare domain. Enabled once on the tailnet
(admin link from `tailscale funnel` when first run).

**Important — Linear DNS:** Linear’s delivery log shows failures as
`Could not resolve the webhook URL's host via DNS lookup` (HTTP status `-`).
That means the request **never reached the Mini** — not a Helm secret/handler
issue. Funnel’s public `*.ts.net` DNS can briefly go NXDOMAIN even while
`tailscale funnel status` looks fine inside the tailnet (known Tailscale
behavior; public records can take up to ~10 minutes after enable/reset).

When Linear emails “webhook was disabled”:

1. From a non-tailnet resolver: `dig @8.8.8.8 +short mac-mini-de-luis.tailc0e5af.ts.net A`
   (must return Funnel relay IPs, not empty/NXDOMAIN).
2. `curl -sS -o /dev/null -w '%{http_code}\n' https://mac-mini-de-luis.tailc0e5af.ts.net/health`
3. If DNS is empty: `tailscale funnel reset` then `tailscale funnel --bg 3001`
   (or toggle the `funnel` nodeAttr in the Tailscale ACL to force DNS republish).
4. Re-enable the webhook in Linear → Webhook settings.

If NXDOMAIN keeps recurring for Linear while GitHub webhooks are fine, prefer a
stable public hostname (Cloudflare Tunnel / custom domain) instead of relying on
Funnel DNS alone — GitHub often caches successful resolutions; Linear is less
forgiving on NXDOMAIN bursts.

```bash
ssh mac-mini
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale

# Start / re-assert (persists in Tailscale serve config)
$TS funnel --bg 3001
$TS funnel status

# Disable
$TS funnel --https=443 off
```

Smoke from anywhere:

```bash
curl -s https://mac-mini-de-luis.tailc0e5af.ts.net/api/products | jq '.[].product.slug'
# → arriendo-facil
```

Do **not** use cloudflared quick tunnels for AF webhooks — the URL changes on
restart (replaced 2026-08-20; see helm#103).

## Start / stop (API) — launchd (LEA-259)

The API runs as a user LaunchAgent, `com.lh.helm.af-api`. It starts at login and
`KeepAlive` restarts it if it dies, so a reboot no longer takes the ingress down.

**Why this replaced tmux:** on 2026-09-01 the Mini rebooted at 05:52 and the API
did not come back — the public ingress returned 502 to Linear and GitHub for
~49 minutes, until an agent started it by hand at 06:41. The two watchdog
LaunchAgents on the same box came back at 05:52:51 unattended, which is what
made the fix obvious.

```bash
ssh mac-mini
helm-af-api status     # launchd state + /health, warns about a stale tmux session
helm-af-api restart    # after pulling the Helm monorepo or knowledge
helm-af-api logs 60    # stdout + stderr
```

Under launchd the process runs **without** `--watch`: restarts are decided by
`KeepAlive`, not by the filesystem. With `--watch`, a `git pull` of the monorepo
would restart the API mid-webhook. Restart explicitly after pulling.

Do **not** start a second copy in tmux — it takes `:3001` and leaves the
LaunchAgent in a crash loop. `helm-af-api status` warns when a legacy
`helm-af-api` tmux session exists.

Install / reinstall (from the Cerebro LH checkout on the Mini):

```bash
zsh ~/Git/Cerebro/LH/scripts/mac-mini/install-helm-af-api.sh
```

The installer refuses to run without `apps/api/.env`, kills a legacy tmux
session, bootstraps the agent and blocks until `/health` answers.

| Piece | Path |
|---|---|
| Plist (source of truth) | Cerebro LH `scripts/mac-mini/launchd/com.lh.helm.af-api.plist` |
| Installed plist | `~/Library/LaunchAgents/com.lh.helm.af-api.plist` |
| Logs | `~/.local/state/helm/af-api.log` / `.err` |
| Control CLI | `~/bin/helm-af-api` |

The env still comes from `apps/api/.env` on disk (bun auto-loads it from the
working directory). That file survives reboot, so the API restarts unattended;
regenerating it still needs an `op` session — the open half of TD-003.

## Secrets

1Password item `op://Leasity/leasity-tenants`:

- `linear-api-key`
- `github-webhook-secret` — GitHub → Helm
- `linear-webhook-secret` — Linear → Helm (**created 2026-08-20**)

Helm GitHub PAT: `op://Helm/helm/github-token`.

Mini `op` CLI is often **not signed in** over SSH. Until a Service Account or
desktop unlock is available, resolve on the MacBook and `scp` `.env`:

```bash
# MacBook
cd ~/Git/Helm/helm/apps/api
# ensure .env.leasity-tenants paths point at Mini user, then:
op inject -i .env.leasity-tenants -o /tmp/helm-af-mini.env --force
scp /tmp/helm-af-mini.env mac-mini:~/Git/Helm/helm/apps/api/.env
rm /tmp/helm-af-mini.env
```

## Webhooks

### GitHub (done)

Hooks on `lhpaul/leasity-tenants` and `lhpaul/leasity-tenants-knowledge`:

- URL: `https://mac-mini-de-luis.tailc0e5af.ts.net/api/webhooks/github`
- Events: `pull_request`, `issue_comment`, `check_run`, `status`, `release`
- Secret: `github-webhook-secret`

Helm returns **200** for `ping` on Linear products (helm#102).

### Linear (pending — needs admin UI) — helm#104

API token lacks `admin` scope for `webhookCreate`. Create manually:

1. Linear → Settings → Administration → API → Webhooks → New webhook.
2. URL: `https://mac-mini-de-luis.tailc0e5af.ts.net/api/webhooks/linear`
3. Team: Leasity (`LEA`).
4. Resource types: Issue, Comment.
5. Signing secret: paste value from
   `op read 'op://Leasity/leasity-tenants/linear-webhook-secret'`.

Until this exists, ingest items with `POST /api/items` and advance stages
manually / via GitHub PR webhooks only.

## Smoke checks

```bash
curl -s http://127.0.0.1:3001/api/products | jq '.[].product.slug'
# → arriendo-facil

curl -s http://127.0.0.1:3001/api/products/arriendo-facil | jq '.review.external.provider,.review.early_loop'
# → "coderabbit" / {"enabled":true}

curl -s http://127.0.0.1:3001/api/items | jq '.[].externalId'
```

Create item (primary product only):

```bash
curl -s -X POST http://127.0.0.1:3001/api/items \
  -H 'content-type: application/json' \
  -d '{"externalId":"LEA-246","triggeredBy":"manual:operator"}'
```

Dispatch (when ready to burn Codex cycles):

```bash
curl -s -X POST http://127.0.0.1:3001/api/products/arriendo-facil/items/LEA-246/dispatch
```

## Known Helm fixes (AF early-loop)

- **helm#105** (2026-08-20): CodeRabbit Combined Status often has `creator: null`.
  Older Helm treated that as `unavailable` → `external_repeated_skip` on LEA-246
  before a pending intent could land. Fix: trust allowlisted context with missing
  creator; synthetic `pending` when no status yet; rate-limited success → defer.

## Open debts

1. ~~**Persistent public URL**~~ — done via Tailscale Funnel (helm#103 closed).
2. ~~**Linear webhook**~~ — created (“Helm Mac Mini”); secret in 1Password.
   If Linear emails “webhook was disabled”, re-enable in UI. After helm#106 the
   handler ACKs within Linear’s 5s deadline (side effects run in background).
3. **Mini 1Password session** — Service Account or always-on desktop unlock so
   `pnpm sync-env -- leasity-tenants` works on the Mini without MacBook inject.
   `op` on the Mini reports `no active session found for account my` after every
   reboot, and the desktop app does not auto-unlock. `sync-env-from-1password.sh`
   already works unchanged with `OP_SERVICE_ACCOUNT_TOKEN`, so a service account
   needs no code change — only an account that can issue one.
   → **TD-003** / [LEA-259](https://linear.app/lh-paul/issue/LEA-259)
4. ~~**Optional:** `launchd` for Helm API so reboot survives without tmux attach.~~
   — done 2026-09-01, `com.lh.helm.af-api` (see «Start / stop (API)»).
5. **Residual race:** status webhook can arrive before `onExternalReviewDeferred`
   persists the intent (`no pending intent for revision`); poll path still works.
   → **TD-002** / [LEA-258](https://linear.app/lh-paul/issue/LEA-258)

## Related

- LEA-194 friction learning: `learnings/2026-07-13-lea-194-local-helm-review-loop-friction.md`
- Product onboarding: `operations/onboarding-product.md`
- Cerebro: `LH/20 - Proyectos/Infra-Mac-Mini.md`, `docs/agents/mac-mini/dev-session/`
