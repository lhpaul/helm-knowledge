# ADR-036 review loop — E2E smoke test (Helm dogfood)

Validates the bounded **internal fanout ↔ remediate ↔ external Haystack** loop on a
real impl PR for the `helm` product.

**Depends on:** [lhpaul/helm#58](https://github.com/lhpaul/helm/pull/58) (Haystack adapter), [lhpaul/helm-knowledge#41](https://github.com/lhpaul/helm-knowledge/pull/41) (`review` in `.helm/product.yaml`).

**ADR:** [036-pr-review-loop-external-adapter.md](../decisions/036-pr-review-loop-external-adapter.md)

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
| Haystack CLI installed | `command -v haystack` |
| Haystack auth configured | `haystack triage lhpaul/helm#<N> --json --no-wait` returns JSON (not HTTP 401) |
| Product config includes `review.external.provider: haystack` | `.helm/product.yaml` in this repo |
| Pilot item in `code-review` with open `helm/impl/<id>` PR | GitHub Projects / Helm dashboard |

> Haystack analysis typically completes 2–4 minutes after a PR push. The adapter
> polls with `poll_interval_sec: 15` and `timeout_sec: 120` (ADR-036 defaults).

---

## Test matrix

| Scenario | Setup | Pass criteria |
| -------- | ----- | ------------- |
| **A — Clean exit** | Impl PR with no CRITICAL/HIGH internal findings and Haystack returns zero blocking categories | Dispatch completes `status: done`; item stays in `code-review`; no remediation transition after external review |
| **B — External remediation cycle** | Haystack returns a blocking finding (e.g. `Logic error`) that internal reviewers missed | Loop transitions to `remediation`, pushes fix, returns to `code-review`, re-runs internal fanout |
| **C — Escalation at max_cycles** | Blockers persist across cycles (or inject a non-fixable blocker in a test PR) | Dispatch returns `escalated: true` with stop-rule message; item requires human intervention |

**Semantic reminder (ADR-036):** `clean` means **zero blocking findings**, not zero
Haystack advisories. `Rules violation` on CHANGELOG is advisory — do not chase it.

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
4. `HaystackExternalReviewAdapter` — `haystack triage o/r#N --json`
5. If external blockers → `code-remediator` with normalized findings → back to step 1
6. Terminal: dispatch `status: done`, loop `escalated: true`, or external `status: skipped` (Haystack unavailable)

### 4. Record outcome

| Field | Value |
| ----- | ----- |
| Date | |
| Item | |
| PR | |
| Scenario (A/B/C) | |
| Cycles completed | |
| External adapter result | `clean` / `needs_fixes` / `skipped` / `escalate` (see ADR-036 `ExternalReviewResult`) |
| Dispatch loop escalated | `escalated: true` on job result (stop-rule or external blockers) |
| Blocking Haystack ids (if any) | |
| Pass / Fail | |

Paste the job result JSON or link the dispatch log in [lhpaul/helm#52](https://github.com/lhpaul/helm/issues/52) when filing the smoke-test completion note.

---

## Recorded dogfood run

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

> Full dispatch E2E (internal fanout → external → remediation) still requires an
> open `helm/impl/<id>` PR and a `code-review` dispatch — repeat this procedure
> when the next pilot PR is available.

---

## Troubleshooting

| Symptom | Likely cause | Action |
| ------- | -------------- | ------ |
| External `skipped` / `unavailable` | Haystack CLI missing or `status=none` | Install/auth Haystack; ensure analysis was submitted for the PR |
| External `status: escalate` (adapter) / dispatch `escalated: true` + `pending_timeout` | Analysis still synthesizing after 120s, or stop-rule fired | Re-dispatch after Haystack UI shows complete, or raise `timeout_sec` temporarily; check job JSON for `escalated: true` and `escalationReason` (`external_escalate`, `external_skip_evidence`, `external_repeated_skip`) |
| External `skipped` with configured Haystack | Triage CLI/auth failure while analysis may still be ready | Loop retries up to `no_progress_cycles`; escalates with PR comment if `pr-status` shows `analysisStatus=ready` or after repeated skips |
| Infinite advisory churn | Treating advisories as blockers | Confirm adapter maps `Rules violation`, `Major` (default), etc. as advisory |
| `Rules violation` on CHANGELOG | Known Haystack false positive | Do **not** restructure CHANGELOG; dismiss per ADR-036 / template haystack-triage.md |

---

## Related

- Template reference: `ai-dev-framework-template/scripts/development-workflow/haystack-reviewer.sh`
- Helm adapter: `packages/orchestrator/src/external-review/haystack/`
- Epic: [lhpaul/helm#52](https://github.com/lhpaul/helm/issues/52)
