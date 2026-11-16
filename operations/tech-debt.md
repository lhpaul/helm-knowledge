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
| `In progress` | Decided and being carried out              |
| `Resolved`    | Fixed — keep the row with the PR reference |

---

## TD-001 — Consolidate the `externalId` regex in `@helm/shared`

- **Status:** Resolved (2026-11-10) — issue
  [lhpaul/helm#129](https://github.com/lhpaul/helm/issues/129), fixed in
  [helm#133](https://github.com/lhpaul/helm/pull/133) (code, `develop`) and
  [helm-knowledge#96](https://github.com/lhpaul/helm-knowledge/pull/96) (spec and plan)
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

- **Status:** Resolved (2026-11-12) — issue
  [lhpaul/helm#135](https://github.com/lhpaul/helm/issues/135) (previously tracked as
  LEA-258), fixed in [helm#140](https://github.com/lhpaul/helm/pull/140) (code,
  `develop`) and [helm-knowledge#99](https://github.com/lhpaul/helm-knowledge/pull/99)
  (spec and plan)
- **Date identified:** 2026-08-20
- **Origin:** production instance early loop (pilot item LEA-246); post-helm#105 retest
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

The production instance depends on **public webhooks** (through a public tunnel)
for a snappy review loop. Relying only on poll lengthens cycles and hides
race bugs until a rate-limit or slow CR run masks them.

---

## TD-003 — Production instance: durable secrets-manager session

- **Status:** In progress, pending the owner — a 1Password service account was
  adopted on 2026-11-16 and the owner configures it on the host by hand
  ([runbook](secrets-service-account.md)). It becomes `Resolved` when the owner
  confirms the setup. Tracked as
  [lhpaul/helm#138](https://github.com/lhpaul/helm/issues/138). Only the durable
  secrets-manager session remains: the supervised-service half shipped 2026-09-01
  and its tracker item was **closed** with it (operator decision, 2026-09-01: close
  the ticket, keep the session as tracked debt).
- **Date identified:** 2026-08-20
- **Origin:** production instance bootstrap ([runbook](production-instance.md))
- **Effort:** Small–Medium
- **Risk if ignored:** Low (was Medium; the reboot half is fixed)

### Context

1. `pnpm sync-env` on the production host needs a signed-in secrets-manager
   session; today `.env` is often generated on another machine and copied over.
2. ~~The API ran in a terminal multiplexer; a reboot lost the process until
   someone re-attached.~~ Confirmed in production on 2026-09-01: the host rebooted
   and the API stayed down for ~49 minutes, returning 502 on the public ingress
   while the tracker and GitHub webhooks pointed at it.

### Resolved — API as a supervised service (2026-09-01)

The API now runs as a user-level system service with run-at-login and
restart-on-exit, replacing the multiplexer session. Verified: killing the process
gets a new pid with `/health` 200 in under 8 s. The boot path is the same one the
host's watchdog services already survived reboots with. The service definition and
its installer live in the owner's private operations repo.

### In progress — durable secrets-manager session

After each reboot the secrets-manager CLI has no active session, and the desktop
app does not auto-unlock. `apps/api/scripts/sync-env-from-1password.sh` calls the
CLI's inject command, which already honours a service-account token — a service
account would need **no code change**, only an account plan allowed to issue one.

This no longer blocks unattended operation: `apps/api/.env` persists on disk across
reboot, so the API comes back on its own. What is still manual is *regenerating* that
file (secret rotation, a new key), which falls back to generating it on another
machine as described in the private runbook.

**Why it was deferred rather than fixed (2026-09-01).** The reboot failure mode — the
one that actually cost ~49 minutes of ingress downtime — is closed by the supervised
service. A session only buys the ability to regenerate `.env` on the host alone, which
happens rarely and involves the operator anyway. A service account is the clean fix and
needs no code change, but it is unconfirmed whether the current plan can issue one;
that check is the first step whenever this is picked up. Storing the secrets in the
host's OS keychain was considered and rejected: it would duplicate secrets outside the
secrets manager, against the vault's stated policy.

**What would reopen this:** secrets rotating often enough that generating `.env`
elsewhere becomes a bottleneck, or a second machine needing the same env.

**Decision (2026-11-16): adopt a 1Password service account.** The owner confirmed
that the plan can issue service accounts, which was the open first step. The owner
creates the account (read-only, limited to the one vault the env needs) and
configures it on the host by hand. The token lives in the host user's login
keychain and is loaded into `OP_SERVICE_ACCOUNT_TOKEN` only for the `sync-env` run.
The env secrets stay only in 1Password, so the keychain rejection above still
holds: the keychain keeps only the revocable token that reads them. Procedure,
checks and risks: [secrets-service-account.md](secrets-service-account.md).

`op inject` supports service accounts. The script's `op account list` sign-in
check is not covered by the service-account documentation, so the runbook checks
it before the first run. If it fails, the script needs a small code change, made as
a separate item. The status moves to `Resolved` when the owner confirms on
[lhpaul/helm#138](https://github.com/lhpaul/helm/issues/138) that `.env` was
regenerated on the host.

### Why it matters

Without this, every env refresh on the production host is a manual copy from another
machine, and after a failed restart the public ingress points at a dead `:3001` until
someone notices (tunnel up + API down → 502).
