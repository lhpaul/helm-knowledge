# Arriendo Fácil — Helm on Mac Mini

Operational runbook for running the Helm API against product `arriendo-facil`
on the Mac Mini (`lhpaul_assistant@mac-mini`).

## Goal

Helm (not a bare Claude session) owns LEA items: spec → plan → impl → review
loop with CodeRabbit as `review.external.provider`.

## Current layout (2026-08-20)

| Piece | Location |
|---|---|
| Helm monorepo | `~/Git/Helm/helm` (`develop`) |
| Knowledge (primary product) | `~/Git/Leasity/leasity-tenants-knowledge` |
| App repo | `~/Git/Leasity/leasity-tenants` |
| `HELM_DATA_DIR` | `~/Git/Leasity/helm-data` |
| API | `http://127.0.0.1:3001` in tmux `helm-af-api` |
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

**Pre-flight (do this before re-enabling Linear):**

```bash
# from MacBook or Mini — uses 8.8.8.8 / 1.1.1.1 (not Tailscale MagiDNS)
cd ~/Git/Helm/helm-knowledge   # or clone path
chmod +x operations/scripts/check-funnel-public.sh

./operations/scripts/check-funnel-public.sh           # one-shot
./operations/scripts/check-funnel-public.sh --watch 5 # dig+curl every 30s × 5m
```

Exit 0 only when public DNS returns Funnel relay IPs (not `100.x`), `/health`
is 200, and unsigned `POST /api/webhooks/linear` returns **401** (handler
reachable). Do **not** re-enable Linear until `--watch` completes with
`fails=0`.

When Linear emails “webhook was disabled”:

1. Run `check-funnel-public.sh` (or manually:
   `dig @8.8.8.8 +short mac-mini-de-luis.tailc0e5af.ts.net A` — must return
   Funnel relay IPs, not empty/NXDOMAIN).
2. `curl -sS -o /dev/null -w '%{http_code}\n' https://mac-mini-de-luis.tailc0e5af.ts.net/health`
3. If DNS is empty: `tailscale funnel reset` then `tailscale funnel --bg 3001`
   (or toggle the `funnel` nodeAttr in the Tailscale ACL to force DNS republish).
4. Re-run `--watch 5`. Only then re-enable the webhook in Linear → Webhook settings.

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

## Start / stop (API)

```bash
ssh mac-mini
tmux attach -t helm-af-api
```

Restart API after pulling Helm or knowledge:

```bash
tmux send-keys -t helm-af-api C-c
# wait a second
tmux send-keys -t helm-af-api 'cd ~/Git/Helm/helm/apps/api && bun run --watch src/index.ts' Enter
```

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
   → **TD-003** / [LEA-259](https://linear.app/lh-paul/issue/LEA-259)
4. **Optional:** `launchd` for Helm API so reboot survives without tmux attach.
   → **TD-003** / [LEA-259](https://linear.app/lh-paul/issue/LEA-259)
5. **Residual race:** status webhook can arrive before `onExternalReviewDeferred`
   persists the intent (`no pending intent for revision`); poll path still works.
   → **TD-002** / [LEA-258](https://linear.app/lh-paul/issue/LEA-258)

## Related

- LEA-194 friction learning: `learnings/2026-07-13-lea-194-local-helm-review-loop-friction.md`
- Product onboarding: `operations/onboarding-product.md`
- Cerebro: `LH/20 - Proyectos/Infra-Mac-Mini.md`, `docs/agents/mac-mini/dev-session/`
