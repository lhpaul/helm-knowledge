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
