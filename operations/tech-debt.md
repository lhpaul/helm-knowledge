# Tech Debt Register

Deferred cleanups and refactors that are intentionally out of scope when first
identified, recorded here so they are not lost. Each item is non-blocking by
definition — if it were blocking, it would be a backlog item in the tracker, not
here.

When an item is picked up, move it to the tracker (or open a PR directly for
trivial ones) and mark it `Resolved` with the PR/issue reference rather than
deleting it.

| Status legend |                                            |
| ------------- | ------------------------------------------ |
| `Open`        | Not yet scheduled                          |
| `Scheduled`   | Has a tracker item / planned session       |
| `Resolved`    | Fixed — keep the row with the PR reference |

---

## TD-001 — Consolidate the `externalId` regex in `@helm/shared`

- **Status:** Open
- **Date identified:** 2026-05-25
- **Origin:** Session 13 (helm PR #20), Cowork review
- **Effort:** Small
- **Risk if ignored:** Low, but real

### Context

The externalId validation regex (`/^(?!\.)[A-Za-z0-9._-]+$/`) is duplicated in
three places:

- `apps/api/src/services/types.ts` → `EXTERNAL_ID_REGEX`
- `packages/orchestrator/src/specialists/spec-publisher.ts` → `EXTERNAL_ID_SAFE`
- `packages/shared/src/spec-branch.ts` → `VALID_EXTERNAL_ID` (added in Session 13)

They were duplicated deliberately to keep `@helm/shared` free of cross-package
app dependencies.

### Proposed fix

`@helm/shared` is the lowest-level package and depends on nothing, so it should be
the single source of truth. Export the regex (or an `isValidExternalId()` helper)
from `@helm/shared` and have `apps/api` and `@helm/orchestrator` import it,
removing the two local copies.

### Why it matters

Three independent copies can drift. If one is loosened or fixed without the others,
a path-traversal validation gap could open on whichever surface lags behind. The
probability is low, but the failure mode is a security hole, so it is worth closing.

---

## TD-002 — External-review readiness race before pending intent persists

- **Status:** Scheduled — [LEA-258](https://linear.app/lh-paul/issue/LEA-258/helm-race-webhook-readiness-vs-pending-external-review-intent)
- **Date identified:** 2026-08-20
- **Origin:** AF early-loop on Mac Mini (LEA-246 / knowledge#35); post-helm#105 retest
- **Effort:** Medium
- **Risk if ignored:** Medium (slow resume; poll still recovers)

### Context

When CodeRabbit (or another external provider) finishes analysis, GitHub may deliver
the status/`external_review_ready` webhook **before** the review loop has written the
pending external-review intent via `onExternalReviewDeferred`. The webhook path then
logs `external review readiness ignored — no pending intent for revision` and no-ops.
The in-loop poll still eventually sees the completed status and continues, so this is
not a hard stopper after helm#105, but resume-on-webhook is flaky under fast providers.

### Proposed fix

Persist a provisional pending intent as soon as the loop enters the external-review
wait (or before the first poll), keyed by product + externalId + targetRevision; the
defer callback becomes an upsert. Alternatively, on readiness-without-intent, enqueue
a short re-check / replay once the job records the defer. Add a regression test that
fires readiness between "about to defer" and "intent written".

### Why it matters

AF on Mac Mini depends on Tailscale Funnel webhooks for a snappy review loop. Relying
only on poll lengthens cycles and hides race bugs until a rate-limit or slow CR run
masks them.

---

## TD-003 — Mac Mini Helm AF: durable `op` session + API launchd

- **Status:** Partially resolved — launchd done 2026-09-01; `op` session still open.
  [LEA-259](https://linear.app/lh-paul/issue/LEA-259/helm-af-mini-durable-op-session-api-launchd)
- **Date identified:** 2026-08-20
- **Origin:** AF Helm bootstrap on Mini (`operations/arriendo-facil-mac-mini.md`)
- **Effort:** Small–Medium
- **Risk if ignored:** Low (was Medium; the reboot half is fixed)

### Context

1. `pnpm sync-env -- leasity-tenants` on the Mini needs an unlocked 1Password session;
   today `.env` is often injected from the MacBook.
2. ~~Helm API for AF runs in tmux (`helm-af-api`); a reboot loses the process until
   someone re-attaches.~~ Confirmed in production on 2026-09-01: the Mini rebooted at
   05:52 and the API stayed down until 06:41 — ~49 minutes of 502 on the public
   ingress, with Linear and GitHub webhooks pointed at it.

### Resolved — API under launchd (2026-09-01)

`com.lh.helm.af-api`, a user LaunchAgent with `RunAtLoad` + `KeepAlive`, replaces the
tmux session. Verified: `SIGKILL` on the process gets a new pid with `/health` 200 in
under 8 s. The boot path is the same one the two watchdog LaunchAgents on this box
already survive reboots with (both logged at 05:52:51, unattended).

Source of truth is the Cerebro LH repo:
`scripts/mac-mini/launchd/com.lh.helm.af-api.plist`, `scripts/mac-mini/helm-af-api`
(control CLI), `scripts/mac-mini/install-helm-af-api.sh`.

### Still open — durable `op` session

After each reboot `op` reports `no active session found for account my`, and the
1Password desktop app does not auto-unlock. Note that
`apps/api/scripts/sync-env-from-1password.sh` calls `op inject`, which already honours
`OP_SERVICE_ACCOUNT_TOKEN` — a service account would need **no code change**, only an
account allowed to issue one.

This no longer blocks unattended operation: `apps/api/.env` persists on disk across
reboot, so the API comes back on its own. What is still manual is *regenerating* that
file (secret rotation, a new key), which falls back to the MacBook inject documented in
the runbook.

### Why it matters

Without this, every Mini reboot or env refresh is a manual MacBook→scp dance and
Funnel points at a dead port until someone notices.
