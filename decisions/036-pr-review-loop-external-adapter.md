# ADR-036: PR review loop and external review adapter

**Date:** 2026-07-01
**Status:** Accepted
**Supersedes:** —
**Related:** ADR-017 (Reviewer Fan-Out Foundation), ADR-019 (Remediation Gate), ADR-025 (Remediation Covers All Reviewers), [ai-dev-framework-template #1112](https://github.com/lhpaul/ai-dev-framework-template/issues/1112) (epic: External review loop — Haystack advisory hardening)

---

## Context

Helm closes the implementation pipeline with `reviewer-fanout` and a single-pass
remediation gate (ADR-019). After remediation, reviewers are **not** re-run; the
item waits in `code-review` for human merge. That leaves two gaps:

1. **No bounded re-review loop** — fixes from `code-remediator` are not verified
   by a second fan-out pass; ADR-019 explicitly deferred this ("Revisit When").
2. **No external review integration** — Haystack (and future tools like
   CodeRabbit, Greptile, Bugbot) run outside the orchestrator today. Session work
   on Helm itself uses ad-hoc polling in `AGENT.md`; product repos dispatched by
   the API have no equivalent.

Cross-repo analysis with `ai-dev-framework-template` showed a mature pattern:
deterministic **blocking vs advisory** classification, `clean` meaning **no
blockers** (not zero findings), post-clean **advisory dispositions**, and a
Haystack stop-rule so agents do not chase non-deterministic advisories forever.

Operational constraints from the Helm pilot (Arriendo Fácil) and product direction:

- **One external review tool per product** — not a sequential multi-bot stack like
  the template's `review.on_draft.github` + `review.on_ready.github` lists.
- **Haystack first** — already used in pilots; modeled agnostically so swapping
  providers is a config + adapter change, not a loop rewrite.
- **Internal reviewers stay** — `reviewer-fanout` plus runtime skills/commands
  (Claude Code, Codex, Cursor) are complementary, not replaced by the external slot.

The template's Haystack wrapper (`haystack-reviewer.sh`) already implements the
correct semantic (`RESULT=clean` when `BLOCKING_COUNT=0`). Known gaps there
(structured advisory output, disposition triggers, false-positive catalog) are
tracked in [ai-dev-framework-template #1112](https://github.com/lhpaul/ai-dev-framework-template/issues/1112)
(sub-items ai-dev-framework-template#1113–#1118); Helm should implement the **target contract** and stay
aligned as the template catches up.

---

## Decision

### 1. `clean` means no blockers — not zero findings

A PR (or review-loop cycle) is **clean** when there are **zero blocking
findings** from configured reviewers. Advisory findings, suggestions, and known
false positives may remain; they must not block merge or re-trigger the fix loop
indefinitely.

This matches Haystack reality: triage often reports recommendations and false
positives even when the code is shippable. Chasing `SUGGESTION_COUNT=0` is an
anti-pattern (validated in AF LEA-104 Haystack stop-rule learnings).

### 2. One external reviewer slot per product (`ExternalReviewAdapter`)

Introduce an adapter interface (same philosophy as `IssueTrackerAdapter`) with
one implementation per provider:

```typescript
interface ExternalReviewAdapter {
  readonly provider: string;
  reviewPullRequest(ctx: ExternalReviewContext): Promise<ExternalReviewResult>;
}
```

Config in `.helm/product.yaml` (scalar, not a list):

```yaml
review:
  external:
    provider: haystack   # haystack | coderabbit | … — one value only
    haystack:
      major_is_blocking: false
      poll_interval_sec: 15
      timeout_sec: 120
  loop:
    max_cycles: 5
    stop_rule:
      no_progress_cycles: 2
```

When `review.external` is absent, external review is **skipped**; the internal
loop still runs.

**v1 implementation:** `HaystackExternalReviewAdapter` — wraps `haystack triage
--json` + optional `haystack pr-status --json`, porting category →
blocking/advisory rules from `haystack-reviewer.sh`. Provider-specific false-positive
playbooks (e.g. CHANGELOG `Rules violation`) live in the adapter, not in generic
loop code.

### 3. Normalized finding model

All providers map to a shared shape before the loop or remediator sees them:

```typescript
type NormalizedFinding = {
  id: string;           // stable ledger key: provider-native id when available,
                        // else canonical signature (provider, path, category, line)
  severity: 'critical' | 'high' | 'medium' | 'low' | 'info';
  blocking: boolean;    // adapter decision — not raw bot category alone
  path?: string;
  summary: string;
  detail?: string;
  fixHint?: string;
};
```

The `id` must stay stable across review cycles so `no_progress_cycles` and advisory
disposition tracking do not churn when a provider rewrites `summary` text. Do **not**
hash free-form summary prose into the ledger key.

Only `blocking: true` findings trigger `code-remediator` or count as loop blockers.
Advisories are recorded for summary/disposition, not re-triage loops.

### 4. Loop order and phases (v1 scope)

Per `code-review` dispatch (or dedicated `review-loop` job):

```
1. Internal: reviewer-fanout
2. If CRITICAL/HIGH from security/test → code-remediator (existing ADR-019 gate)
3. Repeat 1–2 until internal clean or max_cycles / stop_rule escalates
4. External: ExternalReviewAdapter (Haystack v1)
5. If external blockers → code-remediator with normalized findings → back to 1
6. Stop: clean (no blockers), escalate (human), or skipped (external unavailable)
```

Returning to step 1 after external remediation re-runs internal fanout so fixes
for external blockers cannot bypass internal reviewers. The same `max_cycles` /
`stop_rule` budget applies across internal and external-driven iterations.

**In scope v1:** bounded internal re-review (closes ADR-019 "Revisit When" for
the fanout↔remediate cycle) + external review with blocker-driven remediation
that loops back through internal fanout.

**Out of scope v1:** multi-platform external sequence, draft/ready GitHub phases,
CI loop orchestration, merge automation, reviewer-loop CI guard workflow.

### 5. Advisory dispositions and false positives

After a **clean** exit with remaining advisories:

1. Post or update a **Review Loop Summary** on the PR (markers TBD in
   implementation plan).
2. Document each advisory disposition: **Addressed | Accepted | Deferred |
   Rejected** (one-line rationale). Rejected covers catalogued false positives
   (`helm-knowledge/false-positives.md` per product).
3. Do **not** re-run Haystack solely to eliminate advisories.

Optional v2: machine-readable false-positive patterns in product config for
auto-`Rejected` before agent disposition.

### 6. Stop rule

Escalate to human when:

- `cycle >= max_cycles` (default 5), or
- open blocker count unchanged or increased for `no_progress_cycles` consecutive
  cycles (default 2), or
- external review returns `escalate` / repeated `skipped` with evidence findings
  may exist (e.g. Haystack `pending_timeout` + analysis-ready comment on PR).

Do not implement unbounded review↔remediate loops.

**Escalation comment — upsert, not append** (added 2026-08-14, lhpaul/helm#93).
Every escalation renders the `<!-- helm:review-loop-escalation -->` comment and
**upserts it by marker** on the PR, the same contract the Review Loop Summary
already uses (§5). A still-blocked item re-escalates on every re-dispatch, and
appending buried the PR under identical comments; from this decision on, an
escalation rewrites the newest marked comment instead of adding one. The upsert
applies to every reason code, internal and external. There is no dedup
migration — comments left by earlier runs stay where they are, and the newest
of them is the one subsequent escalations update.

Because the comment is rewritten in place, it must be self-contained — it
carries the current reason, the cycles completed in this dispatch, the lifetime
lane counters when the caller knows them (ADR-042), and the external signal.
The escalation *history* is not kept on the PR: it lives in the item's history
events, which are idempotent per `(lane, reason, cyclesTotal)` (ADR-042 §5), so
the PR shows the latest state and the item shows how it got there.

Posting stays best-effort: a failed upsert is swallowed rather than converting
an escalation into a loop crash — the operator still gets `escalated` and
`escalationReason` on the job result.

**Known limitation:** the loop never retracts the comment. An item that
escalates and then converges on a later dispatch leaves the last escalation
comment on the PR; the clean-exit signals are the Review Loop Summary and the
item's stage, not the absence of this comment.

### 7. Relationship to ADR-019

ADR-019's single-pass remediation and no re-fanout is **superseded in intent** for
the review-loop path only: the loop may re-run fanout after remediation up to
`max_cycles`. Severity gates (`shouldRemediate`: CRITICAL/HIGH from
security/test only) and single-pusher invariants are unchanged.

---

## Alternatives considered

### A — Port `pr-review-loop.sh` wholesale into Helm repos

**Rejected:** ~6k lines bash, multi-platform, agent-in-repo execution model.
Helm needs a TypeScript job-friendly runner in `packages/orchestrator` (or
`packages/adapters`), not a fork of the template script.

### B — Multiple external reviewers per product (template default)

**Rejected:** Higher cost, latency, and conflicting signals. One slot matches
Helm product usage and simplifies adapter swap.

### C — Treat all Haystack findings as blockers

**Rejected:** Would cause infinite loops and duplicate the AF pilot failure mode.
Advisory classification is required.

### D — External review before internal fanout

**Rejected for v1:** Internal LLM reviewers are cheaper relative to Haystack
triage and already push mechanical fixes; running Haystack on a rough PR wastes
triage budget. Order may be revisited per product if data shows otherwise.

---

## Consequences

### Positive

- **Closed loop** for `code-review` without manual session polling.
- **Provider swap** is one config key + new adapter; loop, remediator, and ledger
  stay stable.
- **Aligned semantics** with ai-dev-framework-template (`clean` = no blockers).
- **Pilot learnings codified** — stop-rule, false-positive catalog, Haystack
  non-determinism.

### Trade-offs / known limitations

- **Haystack non-determinism** remains; stop-rule escalates rather than forcing
  convergence.
- **Disposition step** is agent-orchestrated in v1 (like template Protocol 93);
  structured enforcement is a follow-up aligned with template epic T2.
- **No CI loop** in v1 — repo CI still runs independently; orchestrator does not
  poll required checks yet.
- **Single code repo** assumption inherited from ADR-017/019 until multi-repo
  remediation lands.

---

## Addendum — Deferred External Analysis

External reviewer latency is not a human-escalation condition by itself. When an
adapter can distinguish "analysis is still pending" from provider failure,
authentication failure, skipped analysis with ready evidence, or actual blocking
findings, it returns a provider-agnostic result:

```ts
{ status: 'deferred', reason: 'analysis_pending' }
```

Helm persists a pending external-review intent keyed by product slug, external
item id, provider, PR number, and target revision. The intent records
`createdAt`, `expiresAt`, and the provider identity. Repeated pending results for
the same revision update the same durable intent instead of creating parallel
review jobs.

Resume is event-driven when possible. A provider readiness signal, such as a
GitHub check-run or status update, may enqueue the reviewer-fanout resume path
only when it matches the stored provider, item, PR number, and exact target
revision. Readiness for an older or newer revision is a no-op; Helm never resumes
optimistically when the revision cannot be proven.

Provider-specific recognition remains inside the adapter layer and webhook
normalization. For v1, Haystack maps pending triage budget exhaustion to the
generic deferred result when `review.external.defer_when_pending` is not disabled.
Haystack CLI flags, check names, and triage parsing are not part of the canonical
review-loop contract.

---

## Addendum — Haystack retirement (2026-08-13, lhpaul/helm#85)

**Haystack is retired as a Helm external review provider.** The body of this ADR
above is kept as the historical record of the v1 design; this addendum records
what changed and what replaces it.

**Why:** Haystack stopped working as an external review provider. Its support was
still wired through the schema, adapter, webhook parser, product config, and
docs, which cost maintenance and confused operators about which provider is
current.

**Migration target:** `review.external.provider: coderabbit` (ADR-036 adapter
contract unchanged, landed in lhpaul/helm#86). `bugbot` remains supported as an
interim/rollback provider. Helm's own product config moved to CodeRabbit before
this removal (lhpaul/helm-knowledge#63).

**What was removed:**

- `review.external.provider` accepts only `bugbot` | `coderabbit`. The strict
  schema now **rejects** both `provider: haystack` and any
  `review.external.haystack` block — a product config carrying either fails to
  parse.
- `packages/orchestrator/src/external-review/haystack/**` — adapter, `haystack`
  CLI wrapper, triage polling, category and finding-id normalization,
  skip-evidence probe, and fixtures — plus the Haystack branch in
  `runExternalReviewIfConfigured`.
- The `haystack / review` check-name allowlist and the Haystack GitHub App
  trusted identities in the GitHub Projects webhook parser. A `Haystack / Review`
  check run no longer emits `external_review_ready`, so it can never resume a
  deferred review.
- The `external_skip_evidence` stop-rule escalation reason (§6). Only the
  Haystack `pr-status` probe ever produced that evidence, so the escalation
  behavior of the remaining providers is unchanged: `external_escalate` on
  adapter `escalate`, `external_repeated_skip` once the skip budget
  (`review.loop.stop_rule.no_progress_cycles`) is exhausted.

**Behavior notes:** the post-skip retry backoff was read from
`review.external.haystack.poll_interval_sec`; it is now a fixed 15s. The
deferred-analysis contract in the addendum above is **unchanged and still
current** — `deferred` / `analysis_pending` remains a resumable outcome, not a
terminal one, and is now implemented by the Bugbot and CodeRabbit adapters. What
differs per provider is only the readiness signal Helm will trust: a check run
with an allowlisted name from a trusted GitHub App identity (Bugbot), or a status
with an allowlisted context from a trusted sender login (CodeRabbit). Both are
name **and** identity checks, and both must still match the stored provider,
item, PR number, and exact target revision before a resume is enqueued.

**Not changed — historical provenance:** ADRs, learnings, specs, plans, and the
`**Example:**` / `**Origin:**` fields of `false-positives.md` keep their Haystack
attributions; they are an accurate record of where a finding came from. What did
change in `false-positives.md` is the *active* `**Pattern:**` / `**Action:**`
text, which is now provider-neutral — that text is matched against live findings
by the review loop, so naming a retired provider there would only narrow matching
against CodeRabbit and Bugbot output. Provenance moved into `**Origin:**` rather
than being dropped.

---

## Addendum — Codex GitHub provider (2026-08-14)

**`codex-github` is added as a third external review provider.** The adapter
contract in the body of this ADR is unchanged; what this addendum records is a
provider whose *readiness signal* is a shape the earlier two did not have.

> **Status correction (same day):** `codex-github` was briefly made the dogfood
> default and was **rolled back to `coderabbit`** before this addendum shipped —
> see *Not the default: no terminal signal on a clean run* below. It stays fully
> implemented and supported as an opt-in selection.

**Why it was tried:** CodeRabbit rate-limited every review invocation on the open
dogfood PRs (lhpaul/helm#95, lhpaul/helm-knowledge#67), so it stopped producing
signal. Its rate-limited `success` status is already normalized to `skipped`
rather than `clean` — correct, but it means the loop learns nothing and burns its
skip budget. Codex is already the runtime behind every Helm specialist, so its
GitHub reviewer bills against the same ChatGPT subscription.

**The readiness signal is a submitted PR review.** Codex publishes no commit
status and no reliable check run. It signals completion by submitting a GitHub
review, so:

- **Trust anchor:** the review **author login**, allowlisted exactly
  (`chatgpt-codex-connector[bot]`). This is Option C, the same shape as the
  CodeRabbit status-sender check. The `[bot]` suffix is required in the
  allowlist: a human can register the un-suffixed login, so matching there is
  never relaxed. Check-run **app** identities are matched with the suffix
  ignored, because that value comes from GitHub's app record rather than a
  user-settable account name.
- **Readiness webhook:** `pull_request_review` with `action: submitted`, carrying
  `review.commit_id`. It must still match the stored provider, item, PR number,
  and exact target revision before a resume is enqueued — same rule as the
  check-run and status paths, no new exception.
- **"Not reviewed yet" is `deferred`, not `skipped`.** Bugbot and CodeRabbit both
  have a pending signal to read; Codex has none, so a missing review is
  indistinguishable from an unfinished one. Returning `skipped` would spend the
  repeated-skip budget waiting for something that only arrives by webhook, so the
  adapter defers and lets `max_defer_sec` bound the wait.
- **A draft review is not readiness.** GitHub's reviews endpoint exposes a
  `PENDING` review (with `submitted_at: null`) before its author submits it, and
  a draft carries no inline comments. Selecting it would fall through to `clean`
  on an empty finding set, so the loader requires a submitted review — the same
  contract the webhook path already enforces via `action: submitted`.

**Not the default: no terminal signal on a clean run.** Codex publishes no check
run and no commit status, and a run that finds nothing can end as a 👍 reaction
rather than a submitted review. Helm reads reactions from no provider, and a
reaction carries no `commit_id` to pin to the target revision even if it did — so
a genuinely clean PR has nothing to resume on and sits `deferred` until
`max_defer_sec` expires the intent. Re-triggering does not help: the rerun is
clean too. This is the decisive difference from the other two providers, whose
worst case (`skipped`) is still terminal and lets the loop make progress.

Consequently the dogfood default returns to `coderabbit`, and `codex-github` is
selected per-run where an operator is watching the loop. Promoting it to a
default requires one of: Codex publishing a check run, status, or review on
no-findings runs; or Helm gaining a reaction-based terminal signal that can be
attributed to Codex **and** pinned to a revision. Neither exists today.

**Severity mapping:** Codex reports on its own P-scale — `P0 → critical`,
`P1 → high`, `P2 → medium`, `P3 → low`. An unlabeled comment normalizes to
`high`, not the `medium` the other two adapters use as their unknown-severity
default: Codex only posts what it already judged high-priority, so an unparsed
label must safe-fail toward blocking. A `CHANGES_REQUESTED` review blocks even
when no inline finding survives; a `DISMISSED` review is `skipped`, never read
as a clean bill.

**Operator prerequisite (not a code contract).** Codex reviews are not automatic
by default — the repo needs *Automatic reviews* enabled in Codex's GitHub
settings, or an `@codex review` comment on the PR. Helm does **not** request the
review itself: `ExternalReviewAdapter` is a read-only contract, and having a
poller post comments would both widen it and risk comment spam on every deferred
cycle. Until automatic reviews are on, a deferred intent for an untriggered PR
simply expires.

**Rollback (exercised 2026-08-14):** `coderabbit` and `bugbot` remain fully
supported. Reverting is a one-line `review.external.provider` change in the
product config plus flipping `auto_review.enabled` back on in `.coderabbit.yaml`
(both repos); every provider block is kept in the dogfood config for exactly that
reason. Selecting `codex-github` again is the same one-line change in reverse.

---

## Addendum — Codex trusted clean terminal signal (2026-08-18, lhpaul/helm#96)

The Codex GitHub addendum above closed with a blocking gap: Codex had **no
terminal signal for a clean run** Helm could trust, so a genuinely clean PR sat
`deferred` until `max_defer_sec` expired the intent. This addendum defines the
contract that closes it, ported from the framework's
[ai-dev-framework-template#1490](https://github.com/lhpaul/ai-dev-framework-template/pull/1490)
(`fix(review-loop): require Codex current-head evidence`) and adapted to Helm's
adapter/loader split.

### 1. The clean-terminal contract Helm expects of a reviewer provider

A provider may return `clean` only on evidence that is **all four** of:

1. **Attributable** — authored by a trusted identity. Review and root-comment
   **authors** match exactly; only check-run **app** identities relax the `[bot]`
   suffix, because the app slug comes from GitHub's app record and is not
   user-settable.
2. **Head-pinned** — tied to the exact revision under review. For Codex that is
   a submitted review whose `commit_id` matches the target revision, or a root PR
   comment whose `Reviewed commit:` marker names it (abbreviated SHAs match by
   prefix).
3. **Terminal** — a verdict, not an acknowledgement. A 👍 reaction, a "starting a
   review" comment, or a draft (`PENDING`) review is not a verdict.
4. **Parseable as a pass** — the body reads as an explicit approval. Anything
   SHA-pinned that Helm cannot classify is ambiguous, and ambiguous is not clean.

Evidence failing (1) or (2) is ignored outright. Evidence satisfying (1) and (2)
but failing (3) or (4) is **unavailable**, never clean.

### 2. Root PR comments are the second evidence channel

Codex publishes no check run and no commit status, and it does not always submit
a review — but it does reliably post a root comment naming the commit it
reviewed. Helm now reads those comments (trusted authors only) and classifies
each one as: SHA-pinned **terminal** evidence, a **usage-limit** notice, a
**missing-environment** notice, or **ancillary**.

Unavailability wording is only read outside quoted spans, and a body carrying a
multi-backtick or 3+-tilde run is not classified at all. A Codex review *of the
classifier itself* quotes the phrases it matches on; without the guard, a clean
review of this code reads back as `unavailable`.

### 3. Precedence when evidence disagrees

1. **Blocking evidence always wins**, whatever its age and whatever else is
   present. An actionable finding must never hide behind an "unavailable".
2. A **usage-limit** notice stops the invocation: once quota is exhausted, a
   useful review is not going to arrive moments later in the same window.
3. A **failed root-comment read** is missing evidence, not absent evidence — a
   clean submitted review cannot silently override it.
4. Otherwise the **newest** terminal evidence wins; on an exact timestamp tie the
   less-clean side does.

Rule 4 is what lets an operator who creates the Codex environment mid-loop have
the resulting fresh review supersede the recorded environment error, while a
later bare acknowledgement — which carries no information — never does.

### 4. What is now unavailable rather than clean or indefinitely deferred

`reaction-only` · `stale review or stale summary` · `draft review` · `dismissed
review` · `missing Codex cloud environment` · `exhausted usage limit` ·
`unparseable SHA-pinned response` · `failed root-comment read`.

Each carries a `providerReason` on the `skipped` result, which the
`external_repeated_skip` escalation now names — a quota stop and a
misconfiguration both read as `unavailable` otherwise, and the human receiving
the escalation has to tell them apart.

### 5. Resume path

A trusted Codex root comment whose marker names a **full** 40-hex SHA emits
`external_review_ready` from the `issue_comment` webhook, alongside the existing
`pull_request_review`/`submitted` path. An abbreviated marker cannot address a
pending intent (matched by exact revision), so those runs are picked up by the
adapter on the next poll instead. Widening intent matching to prefix comparison
is deliberately **not** done here: it loosens a trust-boundary comparison and is
a product decision, not an implementation detail.

### 6. The default reviewer is unchanged

`coderabbit` remains the dogfood default. lhpaul/helm#96 requires the trusted
signal to be **dogfooded on a real PR with validation evidence captured** before
the switch, and that has not happened yet. Promotion is a separate, explicitly
approved change — the 2026-08-14 rollback is the precedent for why it is not
bundled with the implementation.

---

## Revisit when

- A second external provider is needed in production → add adapter only; revisit
  config schema enum.
- Template epic lands structured `ADVISORY_FINDINGS` → Helm adapter output should
  converge on the same KV/JSON contract.
- Operators report `max_cycles` too low/high from cost or quality data.
- Multi-repo products become common → loop must iterate `code_repos[]`, not
  `[0]` only.

---

## References

- `ai-dev-framework-template`: `haystack-reviewer.sh`, `haystack-triage.md`,
  Protocol 93 (advisory dispositions), epic [#1112](https://github.com/lhpaul/ai-dev-framework-template/issues/1112)
  (T1–T6: ai-dev-framework-template#1113–#1118).
- Helm: ADR-017, ADR-019, ADR-025; `helm-knowledge/false-positives.md`;
  `helm-knowledge/learnings/2026-06-02-af-pilot-lea-104-arc.md` (Haystack
  stop-rule).
