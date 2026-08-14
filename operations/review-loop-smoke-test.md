# ADR-036 review loop — E2E smoke test (Helm dogfood)

Validates the bounded **internal fanout ↔ remediate ↔ external review** loop on a
real impl PR for the `helm` product.

> **Provider status (2026-08-14):** The default external provider is
> **CodeRabbit** (`review.external.provider: coderabbit`), with **Bugbot** kept
> configured as rollback. **Codex GitHub** is implemented and supported, but is
> **not the default**: it has no terminal signal for a *clean* run, so a PR with
> no findings can sit deferred until its intent expires (see
> [Codex trigger and readiness](#codex-trigger-and-readiness)). It was made the
> default earlier on 2026-08-14 and rolled back the same day for that reason.
> Haystack was retired end-to-end by
> [lhpaul/helm#85](https://github.com/lhpaul/helm/issues/85) — do **not** install
> or poll it for Helm; the product schema now rejects `provider: haystack`. The
> recorded dogfood runs below predate every switch and are kept verbatim as
> history; read them as Haystack-era evidence, not as setup instructions.
>
> Select `codex-github` only for a run an operator is watching, and read
> [Codex trigger and readiness](#codex-trigger-and-readiness) first: its
> readiness signal is a **submitted PR review**, not a status or check run, and
> Codex reviews are **not requested by Helm**.

**Depends on:** [lhpaul/helm#95](https://github.com/lhpaul/helm/pull/95) (Codex GitHub adapter), [lhpaul/helm#86](https://github.com/lhpaul/helm/pull/86) (CodeRabbit adapter, merged) and [lhpaul/helm#85](https://github.com/lhpaul/helm/issues/85) (Haystack removal). The `review` block in `.helm/product.yaml` arrived in [lhpaul/helm-knowledge#41](https://github.com/lhpaul/helm-knowledge/pull/41), was switched to CodeRabbit in [lhpaul/helm-knowledge#63](https://github.com/lhpaul/helm-knowledge/pull/63), and briefly to Codex GitHub in [lhpaul/helm-knowledge#67](https://github.com/lhpaul/helm-knowledge/pull/67), which then rolled the default back to CodeRabbit.

**ADR:** [036-pr-review-loop-external-adapter.md](../decisions/036-pr-review-loop-external-adapter.md)
(see the *Haystack retirement* and *Codex GitHub provider* addenda)

---

## Concurrency

Run **one** smoke dispatch at a time per item (`externalId`). Parallel dispatches against
the same item can race on stage transitions and remediation workspace provisioning.
If a job is already running, wait for it to finish (or check `GET …/jobs/<jobId>`) before
starting another dispatch for that item.

## Prerequisites

| Requirement | Check |
| ----------- | ----- |
| Helm API running locally | `pnpm --filter @helm/api dev` |
| `GITHUB_TOKEN` with repo + PR scope | `gh auth status` |
| Product config sets a supported provider | `review.external.provider` is `coderabbit` (default), `bugbot`, or `codex-github` (opt-in) in `.helm/product.yaml` |
| Webhook readiness enabled | `review.external.resume_on_check_run: true` in `.helm/product.yaml` — this one flag gates **all** readiness events, `pull_request_review` included, despite the check-run name |
| Webhook delivers `pull_request_review` (Codex only) | The repo webhook subscribes to **Pull request review** events, not just check runs / statuses |
| Codex reviews are triggered (Codex only) | *Automatic reviews* enabled in Codex's GitHub settings, or an `@codex review` comment on the pilot PR — see [Codex trigger and readiness](#codex-trigger-and-readiness) |
| Pilot item in `code-review` with open `helm/impl/<id>` PR | GitHub Projects / Helm dashboard |

Then satisfy the row for the **configured** provider only:

| `review.external.provider` | Provider app installed | Readiness signal Helm trusts | Trust config it must match |
| -------------------------- | ---------------------- | --------------------------- | -------------------------- |
| `coderabbit` (current default) | CodeRabbit posts a review on a recent PR | GitHub **status** whose context is allowlisted, from a trusted sender login | `review.external.coderabbit.status_contexts` / `.trusted_identities` |
| `codex-github` (opt-in, watched runs only) | Codex posts a PR review on a recent PR (manually or automatically triggered) | Submitted **`pull_request_review`** (`action: submitted`) carrying `review.commit_id`, from a trusted review-**author** login | `review.external.codex_github.trusted_identities` (exact login, `[bot]` suffix required) |
| `bugbot` (rollback) | Cursor Bugbot posts a check run on a recent PR | GitHub **check run** whose name is allowlisted, from a trusted GitHub App identity | `review.external.bugbot.check_names` / `.trusted_app_identities` |

> Readiness is name **and** identity: an allowlisted name from an untrusted app or
> sender is ignored (ADR-036 Option B trust boundary). If a run never resumes,
> check both columns before anything else.
>
> Codex has no name to allowlist — the author login **is** the whole anchor
> (ADR-036 Option C). `review.external.codex_github.check_names` only labels an
> in-flight analysis inside the deferral reason; it never grants readiness.
> Author matching is **exact**, so `chatgpt-codex-connector[bot]` is trusted and
> the un-suffixed `chatgpt-codex-connector` is not — a human could register that
> account. (Check-run *app* identities are matched with the suffix ignored,
> because that value comes from GitHub's app record; do not copy that leniency
> here.)
>
> External analysis typically completes a few minutes after a PR push. When it is
> still pending the adapter returns `deferred` / `analysis_pending`; Helm persists
> the intent and resumes on the provider's readiness signal (ADR-036 addendum
> *Deferred External Analysis*).

---

## Codex trigger and readiness

Only relevant while `review.external.provider` is `codex-github`. Three things
make this provider behave unlike the other two; the first two are operator
responsibilities, and the third is why it is **not the default**:

**1. Nothing triggers the review on Helm's behalf.** `ExternalReviewAdapter` is a
read-only contract — Helm reads the review, it never asks for one (ADR-036
*Codex GitHub provider*). So a pilot PR gets a Codex review only if:

- **Automatic:** *Automatic reviews* is enabled for the repo in
  [Codex's GitHub settings](https://chatgpt.com/codex/cloud/settings/general) —
  Codex then reviews on PR open and on draft→ready.
- **Manual:** someone comments `@codex review` on the PR. This path additionally
  needs a **Codex cloud environment for that repo**
  ([settings](https://chatgpt.com/codex/cloud/settings/environments)); without
  one Codex answers `To use Codex here, create an environment for this repo`
  and submits an empty review — observed on `helm-knowledge` 2026-08-14, where
  automatic reviews worked and the manual trigger did not. That empty
  environment-error review is not a clean result: reject it as
  `skipped` / `unavailable` before evaluating findings.

Verify which one applies **before** dispatching, otherwise a correct deferral
looks like a hang:

```bash
# Automatic path: a review already exists for the current head SHA
gh pr view <pr> --json headRefOid --jq .headRefOid
gh api repos/<owner>/<repo>/pulls/<pr>/reviews \
  --jq '.[] | select(.user.login=="chatgpt-codex-connector[bot]")
        | {state, commit_id, submitted_at, body}'

# Manual path: request one, then re-run the query above until it appears
gh pr comment <pr> --body "@codex review"
```

Only a **submitted** review counts. A draft (`state: PENDING`, `submitted_at:
null`) shows up in the `reviews` query above but carries no findings yet; the
adapter skips it and keeps deferring, so read `submitted_at` before concluding
the review has landed.

**2. Readiness is the submitted review itself.** Check the webhook actually
arrives and is accepted:

| Check | Expected |
| ----- | -------- |
| Webhook event | `pull_request_review` with `action: submitted` (`X-GitHub-Event: pull_request_review` in the delivery log) |
| Review author | `review.user.login` exactly matches an entry in `review.external.codex_github.trusted_identities` |
| Revision pin | `review.commit_id` is present **and** equals the stored intent's target revision — a review without `commit_id` is dropped |
| Intent match | Stored provider, `externalId`, PR number, and revision all match; any mismatch is a deliberate no-op, not a failure |
| Resume | Exactly one `reviewer-fanout` job enqueued for that revision |

Verdict mapping to expect once the review lands (ADR-036):

| Codex review | Adapter result |
| ------------ | -------------- |
| `APPROVED` / `COMMENTED`, no unresolved P0/P1 inline comments | `clean` (surviving P2/P3 comments ride along as advisories) |
| Any unresolved inline comment at `P0`/`P1`, or an unlabeled one | `needs_fixes` — unlabeled safe-fails to `high`, so it blocks |
| `CHANGES_REQUESTED` with no surviving inline finding | `needs_fixes` — the verdict itself is the blocker |
| `DISMISSED` | `skipped` / `unavailable`, never a clean bill |
| No review yet for this revision | `deferred` / `analysis_pending` (never `skipped` — Codex has no pending signal to read) |

Resolving a Codex review thread retracts its finding: a resolved thread's comment
is suppressed and cannot be resurrected by the flat review-comments list. If the
fix did not change the PR head, resolving the blocking P0/P1 threads can flip the
same scenario-B review back to `clean`.

If the remediation pushed a new commit, first trigger Codex again and wait for a
submitted review whose `review.commit_id` equals the new head SHA. The old review
belongs to the previous target revision and cannot satisfy readiness for the
current intent, even if every old thread is resolved or outdated. Only evaluate
resolved threads after the submitted review is pinned to the current head.

**3. A clean run may produce no terminal signal at all — this is why
`codex-github` is not the default.** Codex publishes neither a check run nor a
commit status (verified 2026-08-14: `check-runs` and `status` are empty for
Codex on both dogfood repos), and a run that finds nothing can end as a 👍
reaction rather than a submitted review. Helm reads reactions from no provider,
so there is nothing left to resume on: the PR stays `deferred` until its intent
expires at `review.external.max_defer_sec`, and re-triggering does not help
because the rerun is clean too.

Consequences for anyone selecting this provider:

- **Scenario A cannot be driven to a pass on the reaction path.** Reach `clean`
  the way scenario B does — get Codex to submit a review with findings, then
  resolve every P0/P1 thread so the same submitted review re-reads as `clean`.
  An intent that expires with only a 👍 on the PR is the known gap, not a bug in
  the loop.
- **Watch the run.** Deferral is indistinguishable from "Codex was quiet", so
  treat this provider as an operator-attended selection, not a background
  default.
- **Making it the default needs a signal first.** Either Codex publishes a check
  run / status / review on no-findings runs, or Helm gains a reaction-based
  terminal signal it can trust to be Codex's and to be pinned to the target
  revision — reactions carry no SHA today, so that is not a small change.

---

## Test matrix

| Scenario | Setup | Pass criteria |
| -------- | ----- | ------------- |
| **A — Clean exit** | Impl PR with no CRITICAL/HIGH internal findings and the external provider returns zero blocking findings | Dispatch completes `status: done`; item stays in `code-review`; no remediation transition after external review. **Under `codex-github`,** the provider must have *submitted* a review for the target SHA — reach that by resolving the findings of an existing submitted review, not by hoping a no-findings rerun lands one (see point 3 above) |
| **B — External remediation cycle** | The external provider returns a blocking finding that internal reviewers missed | Loop transitions to `remediation`, pushes fix, returns to `code-review`, re-runs internal fanout |
| **C — Escalation at max_cycles** | Blockers persist across cycles (or inject a non-fixable blocker in a test PR) | Dispatch returns `escalated: true` with stop-rule message; item requires human intervention |
| **D — Deferred analysis and resume** | Dispatch while the provider's analysis is still running, then let it finish and emit its readiness signal | Dispatch returns `status: deferred` with `reason: analysis_pending`; **exactly one** pending intent is persisted, carrying the configured provider, this `externalId`, this PR number, and the **exact** target revision; the readiness event resumes `reviewer-fanout` **once** — no duplicate job, no second intent |
| **E — Codex trigger and review readiness** (`codex-github` only) | Dispatch against a PR with **no** Codex review yet, then trigger one — automatically (open / mark ready with *Automatic reviews* on) for one run, and manually (`@codex review`) for the other | Both runs: dispatch returns `deferred` / `analysis_pending` (never `skipped`) while no review exists; the submitted `pull_request_review` from `chatgpt-codex-connector[bot]` pinned to the same `commit_id` resumes the loop **once**; a review from an untrusted login, one without `commit_id`, or one pinned to a stale SHA leaves the intent untouched. Run **E′** as the negative case: an untriggered PR is never resumed and its intent expires at `review.external.max_defer_sec` (default 30 min) |

**Semantic reminder (ADR-036):** `clean` means **zero blocking findings**, not zero
advisories. A style/nitpick finding on CHANGELOG is advisory — do not chase it.

---

## Procedure

### 1. Pick or create a pilot item

Use an item already in `code-review` with an open impl PR, or advance one through
the pipeline until `helm/impl/<externalId>` is open against `main`.

Record:

- Item `externalId`: `________________`
- Impl PR URL: `________________`

### 2. Dispatch code-review

```bash
curl -s -X POST "http://localhost:3000/api/products/helm/items/<externalId>/dispatch" \
  -H "Content-Type: application/json" \
  -d '{}' | jq .
```

Or trigger via the Helm dashboard equivalent.

Monitor job:

```bash
curl -s "http://localhost:3000/api/products/helm/jobs/<jobId>" | jq .
```

### 3. Verify loop phases (logs / job result)

Expected order per ADR-036:

1. Internal `reviewer-fanout` (code + security + test)
2. Internal remediation if CRITICAL/HIGH from security/test (and code per ADR-025)
3. Repeat 1–2 until internal clean or stop-rule
4. External adapter for the configured provider (`CodexGitHubExternalReviewAdapter` / `CodeRabbitExternalReviewAdapter` / `BugbotExternalReviewAdapter`)
5. If external blockers → `code-remediator` with normalized findings → back to step 1
6. If external analysis is still pending → external `status: deferred` / `reason: analysis_pending`. **Not terminal:** Helm persists one pending intent (provider + item + PR number + exact target revision) and returns; the provider's readiness signal resumes `reviewer-fanout` **once** for that same revision. Readiness for any other revision is a no-op. Under `codex-github` the readiness signal is the submitted `pull_request_review` (§ [Codex trigger and readiness](#codex-trigger-and-readiness)), and "no review yet" reaches this branch too — so an untriggered PR sits here until `review.external.max_defer_sec` expires the intent.
7. If external review is `skipped` (provider unavailable) → **retryable**, not terminal: the loop retries up to `review.loop.stop_rule.no_progress_cycles` before giving up.
8. Terminal: dispatch `status: done`, loop `escalated: true`, or a `skipped` result once the skip budget is exhausted (escalates as `external_repeated_skip`).

### 4. Record outcome

| Field | Value |
| ----- | ----- |
| Date | |
| Item | |
| PR | |
| Scenario (A/B/C/D/E) | |
| Provider under test | `coderabbit` (default) / `bugbot` / `codex-github` (opt-in) |
| Codex trigger (if `codex-github`) | automatic (*Automatic reviews*) / manual (`@codex review`) / none (negative case E′) |
| Cycles completed | |
| External adapter result | `clean` / `needs_fixes` / `skipped` / `escalate` / `deferred` (`reason: analysis_pending` — resumable, not terminal) (see ADR-036 `ExternalReviewResult`) |
| Dispatch loop escalated | `escalated: true` on job result (stop-rule or external blockers) |
| Blocking external finding ids (if any) | |
| Deferred (if scenario D) | intents persisted (expect 1) / resumed revision / duplicate jobs (expect 0) |
| Readiness signal (if scenario E) | submitted `pull_request_review` — author login / `commit_id` / resumes (expect 1) |
| Pass / Fail | |

Paste the job result JSON or link the dispatch log in [lhpaul/helm#52](https://github.com/lhpaul/helm/issues/52) when filing the smoke-test completion note.

---

## Recorded dogfood run

### Run 2 — full dispatch E2E (Scenario A)

| Field | Value |
| ----- | ----- |
| Date | 2026-07-02 |
| Item | `issue_55` |
| PR | https://github.com/lhpaul/helm/pull/61 |
| Scenario | A — clean exit |
| Cycles completed | 1 |
| External adapter result | `clean` (Haystack rating 5, 0 findings) |
| Dispatch loop escalated | `false` |
| Blocking Haystack ids | — |
| Pass / Fail | **Pass** |
| Job | `d9481f8c-0cca-45b2-b804-c43f7e210494` — `status: done`, ~5 min wall-clock |

Notes:

- Pilot PR is docs-only (`docs/adr-036-smoke-issue-55.md`); internal reviewers posted
  code/security/test comments; Haystack returned zero blockers; no Review Loop Summary
  (expected when external advisories are empty).
- Local fixes required before green run: `code_repos[].default_branch: develop` (repo
  default, not `main`), Claude CLI model aliases (`sonnet` / `opus`, not
  `claude-sonnet-4-6`), and temporarily disabling multi-product registry when
  `helm-playground-knowledge` still uses legacy specialist IDs.

### Run 1 — adapter-only smoke

| Field | Value |
| ----- | ----- |
| Date | 2026-07-01 |
| Item | N/A (adapter-only smoke; no open impl PR) |
| PR | https://github.com/lhpaul/helm/pull/51 (merged) |
| Scenario | A — adapter smoke against real Haystack triage |
| Cycles completed | 1 (external only) |
| External result | `clean` (0 blockers, 1 advisory: Weak test coverage) |
| Blocking Haystack ids | — |
| Pass / Fail | **Pass** (adapter + Haystack CLI integration verified) |

---

## Troubleshooting

| Symptom | Likely cause | Action |
| ------- | -------------- | ------ |
| Reviewer fan-out instant `error` (130ms) | Invalid `model` in `product.yaml` (e.g. `claude-sonnet-4-6` not available in Claude CLI) | Use CLI aliases (`sonnet`, `opus`) or a model your CLI accepts; verify with `claude -p ok --print --model <name>` |
| Reviewer fan-out timeout (~600s) | Diff base wrong (`default_branch: main` while impl PR targets `develop`) or huge monorepo scan | Set `code_repos[].default_branch` to the repo's integration branch; add reviewer `extra_hints` to scope smoke PRs |
| `Product not found: helm` with multi-product registry | A sibling product's `product.yaml` fails validation (legacy specialist IDs) | Fix or temporarily exclude the broken entry from `.helm/products.yaml` |
| External `skipped` / `unavailable` | Provider app not installed on the repo, or it published no review/status for the head SHA | Confirm the provider app is installed and has run on the PR; check the configured `check_names` / `status_contexts` match what GitHub actually reports |
| External `status: deferred` + `analysis_pending` | Provider analysis still running | Expected — Helm stores the intent and resumes on the readiness webhook. If it never resumes, check every matching key, because any mismatch is a deliberate no-op rather than a failure: `resume_on_check_run: true`; the readiness signal's name/context is allowlisted **and** its app/sender identity is trusted; and the event matches the stored **provider**, **item** (`externalId`), **PR number**, and **exact target revision** |
| Codex run deferred forever, no review on the PR | Nobody triggered Codex — *Automatic reviews* off and no `@codex review` comment | Expected, not a bug: Helm never requests the review (read-only adapter). Enable automatic reviews or comment `@codex review`, then wait for the submitted review; the untriggered intent expires at `review.external.max_defer_sec` (default 30 min) |
| Codex reviewed the PR but the loop never resumed | Webhook not subscribed to **Pull request review**, review author login not exactly allowlisted, missing `review.commit_id`, or the review is pinned to a stale SHA | Check the four in that order. `chatgpt-codex-connector[bot]` must appear verbatim in `review.external.codex_github.trusted_identities` — the un-suffixed login is deliberately untrusted. A review pinned to an older head SHA is a no-op by design |
| `@codex review` answers `To use Codex here, create an environment for this repo` | No Codex cloud environment exists for the repo — the manual trigger needs one even when automatic reviews already work | Treat the submitted empty environment-error review as `skipped` / `unavailable`, not `clean`. Create the environment in [Codex settings](https://chatgpt.com/codex/cloud/settings/environments), or fall back to the automatic path (push / mark ready). Scenario E's manual leg cannot pass until the environment exists |
| Codex left a 👍 reaction and no review | Codex found nothing to flag — a reaction is not a readiness signal | The adapter keeps deferring until timeout. Do not prescribe retriggers as a fix: another clean run can leave the same reaction-only outcome. For unattended dogfood, use `coderabbit`; for an attended Codex pilot, record the gap and adjudicate manually or add a trusted SHA-pinned signal before making this path pass |
| Codex advisory treated as a blocker | Comment carried no parseable `P0`–`P3` label, so it safe-failed to `high` | Intended (ADR-036): Codex only posts what it judged high-priority. Resolve the thread to retract it, or relabel; do not widen `codex_github.blocking_severities` |
| Codex `DISMISSED` review read as unavailable | A dismissed review is `skipped`, never `clean` | Expected — get a fresh review rather than treating the dismissal as a pass |
| Dispatch `escalated: true` | Adapter returned `escalate`, or the skip budget ran out | Check job JSON for `escalationReason` (`external_escalate`, `external_repeated_skip`); the loop retries skips up to `review.loop.stop_rule.no_progress_cycles` before escalating with a PR comment |
| Infinite advisory churn | Treating advisories as blockers | Confirm the adapter's `blocking_severities` for the configured provider |
| No Review Loop Summary on PR | Clean exit had zero external advisories, or summary post failed (best-effort) | Check external `clean` result includes advisories; look for `<!-- helm:review-loop-summary -->` comment |
| Style finding on CHANGELOG | Known false positive | Do **not** restructure CHANGELOG; dismiss per ADR-036 and `false-positives.md` |

---

## Related

- Helm adapters: `packages/orchestrator/src/external-review/codex-github/`, `packages/orchestrator/src/external-review/coderabbit/`, `packages/orchestrator/src/external-review/bugbot/`
- Codex review loader (GitHub queries behind the adapter): `apps/api/src/services/codex-github-review-loader.ts`
- Readiness webhook parsing: `packages/adapters/src/github-projects/webhook-parser.ts` (`pull_request_review` branch)
- Haystack retirement: [lhpaul/helm#85](https://github.com/lhpaul/helm/issues/85), ADR-036 addendum
- Epic: [lhpaul/helm#52](https://github.com/lhpaul/helm/issues/52)
