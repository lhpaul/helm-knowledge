---
title: "LEA-109 stack validation (final) — §4 additive-table question settled, first reviewer-vs-reviewer conflict"
category: "agent-behavior"
date: "2026-06-03"
source:
  type: "session"
  ref: "piloto AF LEA-109 (Better Auth + email OTP en apps/api — Plan A user→tenants, BETTER_AUTH_DATABASE_URL split)"
tags: ["pilot", "code-review", "schema", "contract-drift", "stack-validation", "haystack", "reviewer-fanout", "remediator", "adr-027", "adr-025"]
---

# LEA-109 — stack validation (final): the §4 additive-table question, settled

LEA-109 was the decisive evidence point for two open questions from the LEA-104
and LEA-105 retros: (1) does the post-#53 / ADR-027 §4 stack hold on a third
schema-touching item, and (2) does the code-reviewer treat **tables present in
the diff but ABSENT from §4** (`session`, `account`, `verification`) as
"Contract drift §4" (a false-positive class) or as legitimate new tables?

Both are now answered. The item also surfaced the pilot's first
**reviewer-vs-reviewer architectural conflict** and a set of new operational
failure modes worth preserving verbatim.

## Context — the §4 empirical question, settled (verbatim)

> Code-reviewer round 2 ran to completion and did NOT flag `session`,
> `account`, or `verification` as Contract drift §4. Treated them as
> legitimate new tables, engaged on real architecture (split-contract HIGH)
> instead. ADR-027 "Revisit when" criterion for additive-tables is settled —
> both Helm code-reviewer and Haystack are robust against false-positives on
> legitimately-new tables. No sharpening needed.

Supporting evidence:

- **Haystack** never flagged the new auth tables as "absent-from-§4" drift; it
  engaged their *internal* correctness instead (a real missing
  `UNIQUE (provider_id, account_id)` on `account` — fixed in remediation).
- **Code-reviewer (round 2)** emitted `HIGH · Separate auth database breaks the
  shared-client contract` (about the DB *connection* architecture, not table
  drift) and `MEDIUM · Turbo strict mode will hide the new auth env var`.
  Nowhere did it call `session`/`account`/`verification` "drift" or
  "absent from §4."
- The one real §4 item on LEA-109 was **additive drift on a column**:
  `email_verified` added to `tenants` (Plan-A-mandated by Better Auth).
  Caught by the **operator §4.2 cross-check**, not by any agent; closed by
  documenting it in the target repo `CLAUDE.md` §4.2 *in the same PR, before
  triage* — which is why neither Haystack nor the reviewers flagged it.

## Final scorecard — LEA-104 vs LEA-105 vs LEA-109

| Dimension | LEA-104 | LEA-105 | LEA-109 |
| --- | --- | --- | --- |
| §4-driven fix batches | 5 | 0 | 1 (`email_verified`, operator-caught) |
| Haystack rounds | 5 | 2 | 4 (across remediation commits) |
| Reviewer-fanout HIGH · Contract drift §4 | 0 (missed pervasively) | 0 (genuine) | **0 (genuine — tables judged legit)** |
| Reviewer flagged new auth tables as drift? | n/a | n/a | **No** |
| Additive drift cases | n/a | 1 (extra unique index) | 1 (`email_verified` column) |
| Reviewer-fanout completion | full | full | **partial (round 1, code reviewer errored) → full on round 2 + adjudication path** |
| Codex cost | ~$5–8 | ~$0 + 16 min | **$0** (impl 18.3 min + 2 remediation passes) |

## New failure modes surfaced (field-tested gotchas — verbatim)

LEA-109 was operationally the hardest pilot item so far. The honest list of
**new** failure modes, in order encountered:

1. **Codex CLI 0.133.0 `image_generation_user_error`** — implementer failed
   turn 1: `The model 'gpt-image-2' does not exist`. A Codex-CLI-version
   default registering an image tool with an invalid model. Deterministic;
   fixed by upgrading Codex to 0.136.0. (Documented separately at the time.)
2. **Watch-mode dev-server orphaning** — `bun run --watch` hot-reloads on any
   orchestrator source save; on boot Helm marks in-flight jobs `orphaned`. A
   parallel Helm session editing `codex.ts` orphaned an implementer dispatch
   9s in. Two sessions can be code-compatible yet **operationally** collide.
3. **Codex model capacity error** — `Selected model is at capacity` after a
   10.8-min run. Transient; cleared on retry.
4. **Partial reviewer-fanout completion** — round 1: the code reviewer errored
   (`Agent finished with status 'error'`), security + test ran, the
   code-remediator still fired. The fanout is **not** all-or-nothing.
5. **Reviewer-vs-reviewer conflict + remediator oscillation** — see EP#8/EP#9.
6. **Disk-full (100%, 235Mi free)** — blocked the fanout dispatch (Codex agents
   can't write transcripts) and wedged Docker. Also left a stale
   `.git/HEAD.lock` from a crashed git process.
7. **Docker daemon wedge** — `docker info` *hangs* (doesn't error) under disk
   pressure; naive wait-loops block forever. Always hard-timeout daemon probes.

Operational lesson: every long-running dispatch needs a **bounded** poll, every
daemon probe needs a **hard per-attempt timeout**, and GitHub **GraphQL** limits
(hit late in the session) can be sidestepped via the **REST** endpoints
(`gh api` instead of `gh pr edit`/`gh pr merge`).

## Retro evidence points

### EP#6 — reviewer-fanout partial completion is a real state
The fanout can finish with one reviewer errored and the other two plus the
remediator having run. There is no equivalent of the Haystack stop-rule for
partial coverage. **Gotcha:** if a single reviewer errors, close the coverage
gap by **re-dispatch**, do not paper over it with the other reviewers' clean
signal. (On LEA-109 the missing reviewer was the *code* reviewer — i.e. the one
carrying the ADR-027 §4 logic — so the empirical question was unanswered until a
clean re-dispatch.)

### EP#7 — code-remediator promoted a "deploy-time advisory" to a HIGH-driven fix
The operator's advisory D (production `DATABASE_URL` must be a service-role that
bypasses FORCE-RLS) was escalated by the **security reviewer** to a `HIGH` and
turned into a real architectural fix (`BETTER_AUTH_DATABASE_URL` least-privilege
split). Second time ADR-025 + reviewer-fanout caught something that would have
been a production gotcha (first: LEA-104 §4-drift). **The system finds real
bugs, not just nits.**

### EP#8 — first reviewer-vs-reviewer conflict (candidate Helm session)
Security and code reviewers held genuinely **opposing** HIGHs:
- Security: shared client ⇒ whole API on RLS-bypassing role ⇒ split it.
- Code: a separate auth DB URL ⇒ violates the "use the shared client" spec.

The code-remediator has no tie-breaker, so it **oscillated** (pass 1 introduced
the split; pass 2 reverted it). Resolution required **director adjudication** +
an explicit catalogue entry. **Candidate Helm session:** extend the
code-remediator to defer to a "catalogued/accepted" surface (e.g.
`helm-knowledge/false-positives.md` or `product.yaml`) for known
LH-adjudicated findings, instead of oscillating between opposing reviewers.

### EP#9 — `shouldRemediate()` auto-dispatch is a foot-gun when reviewers disagree (candidate Helm session)
ADR-025 assumed reviewer HIGHs all point the same direction. When they oppose,
the remediator picks one and ping-pongs across fanout passes — each pass can
re-open what the previous one closed. **Candidate Helm session:** rate-limit
remediator dispatches per PR, or require all reviewers to ack a single
tie-breaker direction before the remediator acts.

### EP#4 / EP#5 — director-slip-caught-by-driver (linked, not duplicated)
LEA-109 added a second EP#5 instance: LH's sequencing note ("implementer merges
→ code-review → dispatch fanout") was stale — the item was already in
`code-review` and the fanout must inspect the **open** diff. The driver paused
and reconciled before acting. See
[2026-06-02-director-stale-mental-model-codex-runtime.md](./2026-06-02-director-stale-mental-model-codex-runtime.md)
for the EP#4 (Codex coder) instance; the pattern "director slip caught by driver
intake / pre-action pause" is now confirmed across two driver instances.

## How the conflict was resolved (adjudication of record)

`BETTER_AUTH_DATABASE_URL` is a **connection-scope** split (least privilege),
NOT a separate auth **database** — same PostgreSQL DB, same table set, Plan A
`user`→`tenants` mapping intact. The plan's "no separate auth database"
prohibition is about **data isolation** (a second source of truth), which the
split honors. Canonical wording lives in the target repo `CLAUDE.md` §5 "Auth
connection scope (LEA-109 adjudication)" and as a catalogued false-positive in
`helm-knowledge/false-positives.md`. The split was restored in `4cfaa28`;
reviewer-fanout round 3 was intentionally **skipped** to prevent further
remediator oscillation (review skill + Haystack were the closing surfaces).

## Closing observation — the stack worked

At the LEA-104 retro the prediction was **"1–2 batches §4-driven post-#53"**;
the actual at LEA-109 was **1**, and it was operator-caught (additive column
drift), not a substitutive miss. **The §4 stack delivered on its design
promise.** Everything else LEA-109 surfaced — the architectural conflict, the
security HIGH, the missing `account` unique constraint — is **signal that the
system is finding real bugs, not noise.** The hard parts of LEA-109 were
operational (Codex/Docker/disk/fanout-orchestration), not contract-fidelity.

## Follow-ups created
- LEA-131 (Low) — remove redundant `name → firstName` mapping.
- LEA-137 (Medium) — prod OTP provider + structured-logging bundle (now also
  covers plaintext-OTP-at-rest, the security LOW).
- LEA-138 (Low) — residual direct test coverage for auth schema constraints +
  `readRequiredAuthEnv`.
