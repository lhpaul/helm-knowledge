# Arriendo Fácil — Helm on Mac Mini

Operational runbook for running the Helm API against product `arriendo-facil`
on the Mac Mini (`lhpaul_assistant@mac-mini`).

## Goal

Helm (not a bare Claude session) owns LEA items: spec → plan → impl → review
loop with CodeRabbit as `review.external.provider`.

## Current layout (2026-08-20)

| Piece | Location |
|---|---|
| Helm monorepo | `~/Git/Helm/helm` (`develop` or fix branch) |
| Knowledge (primary product) | `~/Git/Leasity/leasity-tenants-knowledge` |
| App repo | `~/Git/Leasity/leasity-tenants` |
| `HELM_DATA_DIR` | `~/Git/Leasity/helm-data` |
| API | `http://127.0.0.1:3001` in tmux `helm-af-api` |
| Public tunnel | tmux `helm-af-tunnel` — **quick** `*.trycloudflare.com` (ephemeral) |
| Env input | `apps/api/.env.leasity-tenants` (op:// refs + Mini paths) |
| Resolved env | `apps/api/.env` (gitignored; currently injected from MacBook) |

Product config (knowledge `.helm/product.yaml`):

- `review.external.provider: coderabbit`
- `review.early_loop.enabled: true`
- Tracker: Linear team `LEA`

## Start / stop

```bash
ssh mac-mini
# API
tmux attach -t helm-af-api
# Tunnel
tmux attach -t helm-af-tunnel
```

Restart API after pulling Helm or knowledge:

```bash
tmux send-keys -t helm-af-api C-c
# wait a second
tmux send-keys -t helm-af-api 'bun run --watch src/index.ts' Enter
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

- URL: `https://<tunnel>/api/webhooks/github`
- Events: `pull_request`, `issue_comment`, `check_run`, `status`, `release`
- Secret: `github-webhook-secret`

**If the quick tunnel restarts, the URL changes** — update both hooks or GitHub
deliveries fail. Prefer a named Cloudflare tunnel (see Open debts).

Helm must return **200** for `ping` on Linear products (fix: `lhpaul/helm#102`).

### Linear (pending — needs admin UI)

API token lacks `admin` scope for `webhookCreate`. Create manually:

1. Linear → Settings → Administration → API → Webhooks → New webhook.
2. URL: `https://<current-tunnel>/api/webhooks/linear`
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

## Open debts (pause AF product work until resolved)

1. **Persistent public URL** — replace trycloudflare quick tunnel with a named
   Cloudflare tunnel (or equivalent) and point GitHub/Linear hooks at it.
2. **Linear webhook** — create in UI with admin (token scope gap).
3. **Mini 1Password session** — Service Account or always-on desktop unlock so
   `pnpm sync-env -- leasity-tenants` works on the Mini without MacBook inject.
4. **Merge `lhpaul/helm#102`** — ping fix into `develop`; Mini currently runs the
   fix branch.
5. **Optional:** `launchd`/`brew services` for API + tunnel so reboot survives.

## Related

- LEA-194 friction learning: `learnings/2026-07-13-lea-194-local-helm-review-loop-friction.md`
- Product onboarding: `operations/onboarding-product.md`
- Cerebro: `LH/20 - Proyectos/Infra-Mac-Mini.md`, `docs/agents/mac-mini/dev-session/`
