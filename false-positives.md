# Code-review false positives

Recurring findings from automated code review (Haystack, reviewer agents) that
are **not real issues**. When a triage surfaces one of these, mark it
dismissed/known rather than acting on it.

Each entry: the pattern, why it's a false positive, and a concrete example.

---

## Hardcoded test-fixture credentials (ephemeral testcontainers)

**Pattern:** A reviewer flags "hardcoded credentials / secret-like values
committed in code" pointing at database username/password literals in test
fixtures, citing the secrets policy.

**Why it's a false positive:** These are credentials for a **disposable,
local-only PostgreSQL container** spun up per test run and torn down after. They
are never real secrets, never reach any environment, and sourcing them from env
vars would add ceremony with zero security benefit. This is standard
testcontainers practice.

**Example:** `packages/db/test/fixture.ts` defines
`const postgresUser = 'postgres'`, `const postgresPassword = 'postgres'`, and an
unprivileged `app_user`/`app_user` role for the throwaway `postgres:16-alpine`
container. Flagged by Haystack on PR lhpaul/leasity-tenants#3 (LEA-104) as a
"Rules violation / secrets policy" — dismissed.

---

## Health endpoint returns `degraded` status / extra fields (HTTP 200)

**Pattern:** A reviewer flags the `/health` endpoint for "returning extra data
beyond the documented contract" or "logging/returning a degraded status instead
of only `{ status: 'ok' }`".

**Why it's a false positive:** This behavior is **spec-intended**. The `/health`
endpoint is required to stay HTTP 200 while reporting a degraded application
status (and a `checks`/`db` payload) when the database is unreachable. This was
a deliberate design derived from LEA-103's Haystack feedback and is an explicit
acceptance criterion of the LEA-104 spec — fail-open with visibility, not
fail-closed.

**Example:** `apps/api/src/app.ts` returns `200` with `status: 'degraded'` +
`db: 'unreachable'` when the DB probe fails. Flagged by Haystack on PR
lhpaul/leasity-tenants#3 (LEA-104) as a "Rules violation" — dismissed as
spec-intended.

> Note (separate, NOT a false positive): routing the DB-probe failure log
> through the structured logger instead of `console.warn` is a real follow-up —
> tracked in LEA-118. Only the *degraded 200 behavior itself* is the false
> positive.

---

### CLAUDE.md §10.2 endpoint signature vs §10.3 matching policy

**Pattern:** Haystack flags inconsistency between §10.2 (endpoint
signature `GET /contacts?email=&rut=` — accepts both) and §10.3
(matching policy: email-only for the MVP).

**Why it's a false positive:** §10.3 explicitly addresses the
discrepancy with "RUT is not used for matching even though endpoint #1
accepts it." The endpoint shape (what the API accepts) and the policy
(how we use it) are consistent, not contradictory.

**Action:** Mark as false positive, do not ticket. If Haystack surfaces
this again in future triages (e.g., LEA-105+), skip it.

**Origin:** LEA-104 re-triage 1, 2026-06-02.

---

### `tenantTable(...)` helper name read as RLS / tenant-scoping

**Pattern:** Haystack flags `core_*` (or other non-tenant) tables as using
"tenant-scoped RLS" because they are declared with a helper named
`tenantTable(...)`, and concludes RLS is applied / required.

**Why it's a false positive:** The helper is just
`pgTableCreator((name) => name)` — an identity table factory with misleading
naming. It applies **no** RLS and no tenant scoping. The actual RLS state is
whatever the migration declares, which for `core_*` is none (service-role-only,
per §4.5).

**Action:** Verify by reading the migration's RLS statements
(`grep -c 'ROW LEVEL\|CREATE POLICY'`) before treating as a finding. If the
migration has zero RLS on the flagged tables, dismiss. (Cosmetic rename of the
helper is tracked separately in LEA-124 to reduce this FP surface.)

**Origin:** LEA-105 impl re-triage, 2026-06-02.

---

### Code-reviewer flags `BETTER_AUTH_DATABASE_URL` split as "separate auth database" violation

**Pattern:** Code-reviewer reads "do not introduce a separate auth database" in
the spec/plan literally and flags `BETTER_AUTH_DATABASE_URL` (a connection URL
distinct from `DATABASE_URL`) as a spec violation when it points at the SAME
database as `DATABASE_URL`.

**Why it's a false positive:** The split is a connection-scope separation
(least privilege), not a data separation. Same database, same table set, Plan A
`user`→`tenants` mapping intact. See `CLAUDE.md` §5 "Auth connection scope
(LEA-109 adjudication)" in the target repo for canonical wording.

**Action:** Mark as catalogued false-positive. Do not let the code-remediator
revert the split — that re-opens a real security HIGH (RLS-bypass on whole API).

**Origin:** LEA-109 reviewer-fanout round 2, 2026-06-02.
