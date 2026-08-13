# ADR-036 review loop — E2E smoke test (Helm dogfood)

Validates the bounded **internal fanout ↔ remediate ↔ external review** loop on a
real impl PR for the `helm` product.

> **Provider status (2026-08-13):** Haystack was retired end-to-end by
> [lhpaul/helm#85](https://github.com/lhpaul/helm/issues/85) — do **not** install
> or poll it for Helm. The current external provider is **CodeRabbit**
> (`review.external.provider: coderabbit`), with **Bugbot** as the interim /
> rollback provider. The recorded dogfood runs below predate the switch and are
> kept verbatim as history; read them as Haystack-era evidence, not as setup
> instructions.

**Depends on:** [lhpaul/helm#86](https://github.com/lhpaul/helm/pull/86) (CodeRabbit adapter, merged) and [lhpaul/helm#85](https://github.com/lhpaul/helm/issues/85) (Haystack removal). The `review` block in `.helm/product.yaml` arrived in [lhpaul/helm-knowledge#41](https://github.com/lhpaul/helm-knowledge/pull/41) and was switched to CodeRabbit in [lhpaul/helm-knowledge#63](https://github.com/lhpaul/helm-knowledge/pull/63).

**ADR:** [036-pr-review-loop-external-adapter.md](../decisions/036-pr-review-loop-external-adapter.md)
(see the *Haystack retirement* addendum)

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
| Product config sets a supported provider | `review.external.provider` is `coderabbit` (default) or `bugbot` in `.helm/product.yaml` |
| Webhook readiness enabled | `review.external.resume_on_check_run: true` in `.helm/product.yaml` |
| Pilot item in `code-review` with open `helm/impl/<id>` PR | GitHub Projects / Helm dashboard |

Then satisfy the row for the **configured** provider only:

| `review.external.provider` | Provider app installed | Readiness signal Helm trusts | Trust config it must match |
| -------------------------- | ---------------------- | --------------------------- | -------------------------- |
| `coderabbit` (current default) | CodeRabbit posts a review on a recent PR | GitHub **status** whose context is allowlisted, from a trusted sender login | `review.external.coderabbit.status_contexts` / `.trusted_identities` |
| `bugbot` (interim / rollback) | Cursor Bugbot posts a check run on a recent PR | GitHub **check run** whose name is allowlisted, from a trusted GitHub App identity | `review.external.bugbot.check_names` / `.trusted_app_identities` |

> Readiness is name **and** identity: an allowlisted name from an untrusted app or
> sender is ignored (ADR-036 Option B trust boundary). If a run never resumes,
> check both columns before anything else.

> External analysis typically completes a few minutes after a PR push. When it is
> still pending the adapter returns `deferred` / `analysis_pending`; Helm persists
> the intent and resumes on the provider's readiness signal (ADR-036 addendum
> *Deferred External Analysis*).

---

## Test matrix

| Scenario | Setup | Pass criteria |
| -------- | ----- | ------------- |
| **A — Clean exit** | Impl PR with no CRITICAL/HIGH internal findings and the external provider returns zero blocking findings | Dispatch completes `status: done`; item stays in `code-review`; no remediation transition after external review |
| **B — External remediation cycle** | The external provider returns a blocking finding that internal reviewers missed | Loop transitions to `remediation`, pushes fix, returns to `code-review`, re-runs internal fanout |
| **C — Escalation at max_cycles** | Blockers persist across cycles (or inject a non-fixable blocker in a test PR) | Dispatch returns `escalated: true` with stop-rule message; item requires human intervention |
| **D — Deferred analysis and resume** | Dispatch while the provider's analysis is still running, then let it finish and emit its readiness signal | Dispatch returns `status: deferred` with `reason: analysis_pending`; **exactly one** pending intent is persisted, carrying the configured provider, this `externalId`, this PR number, and the **exact** target revision; the readiness event resumes `reviewer-fanout` **once** — no duplicate job, no second intent |

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
4. External adapter for the configured provider (`CodeRabbitExternalReviewAdapter` / `BugbotExternalReviewAdapter`)
5. If external blockers → `code-remediator` with normalized findings → back to step 1
6. If external analysis is still pending → external `status: deferred` / `reason: analysis_pending`. **Not terminal:** Helm persists one pending intent (provider + item + PR number + exact target revision) and returns; the provider's readiness signal resumes step 4 for that same revision. Readiness for any other revision is a no-op.
7. Terminal: dispatch `status: done`, loop `escalated: true`, or external `status: skipped` (provider unavailable)

### 4. Record outcome

| Field | Value |
| ----- | ----- |
| Date | |
| Item | |
| PR | |
| Scenario (A/B/C) | |
| Cycles completed | |
| External adapter result | `clean` / `needs_fixes` / `skipped` / `escalate` / `deferred` (`reason: analysis_pending` — resumable, not terminal) (see ADR-036 `ExternalReviewResult`) |
| Dispatch loop escalated | `escalated: true` on job result (stop-rule or external blockers) |
| Blocking external finding ids (if any) | |
| Deferred (if scenario D) | intents persisted (expect 1) / resumed revision / duplicate jobs (expect 0) |
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
| External `status: deferred` + `analysis_pending` | Provider analysis still running | Expected — Helm stores the intent and resumes on the readiness webhook. If it never resumes, verify `resume_on_check_run: true` and that the readiness event matches the stored PR **and** target revision |
| Dispatch `escalated: true` | Adapter returned `escalate`, or the skip budget ran out | Check job JSON for `escalationReason` (`external_escalate`, `external_repeated_skip`); the loop retries skips up to `review.loop.stop_rule.no_progress_cycles` before escalating with a PR comment |
| Infinite advisory churn | Treating advisories as blockers | Confirm the adapter's `blocking_severities` for the configured provider |
| No Review Loop Summary on PR | Clean exit had zero external advisories, or summary post failed (best-effort) | Check external `clean` result includes advisories; look for `<!-- helm:review-loop-summary -->` comment |
| Style finding on CHANGELOG | Known false positive | Do **not** restructure CHANGELOG; dismiss per ADR-036 and `false-positives.md` |

---

## Related

- Helm adapters: `packages/orchestrator/src/external-review/coderabbit/`, `packages/orchestrator/src/external-review/bugbot/`
- Haystack retirement: [lhpaul/helm#85](https://github.com/lhpaul/helm/issues/85), ADR-036 addendum
- Epic: [lhpaul/helm#52](https://github.com/lhpaul/helm/issues/52)
