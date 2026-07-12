# ADR-039: Graphify experiment for review blast-radius

**Date:** 2026-07-12
**Status:** Accepted
**Supersedes:** —
**Related:** ADR-017 (Reviewers Foundation), ADR-018 (Real Reviewers), ADR-027 (Contract Drift Validation), ADR-036 (PR Review Loop External Adapter), ADR-037 (Review Adjudicator), ADR-038 (Sticky Finding Progress)

---

## Context

Helm's code-review loop already has strong orchestration (fan-out → optional
adjudication → remediation → external adapter, with stop rules). Reviewer
context today is:

- shallow clone of `helm/impl/<id>`
- tip `git diff` vs the product default branch
- optional capped spec
- undirected on-disk exploration under a time budget

There is **no** structured call/import/dependency graph. Cross-file blast radius
(callers of a changed symbol, shared types across modules, merge-order risk
across open PRs) depends on the agent finding the right files in time.

[Graphify](https://github.com/Graphify-Labs/graphify) builds a local AST
knowledge graph (tree-sitter; no LLM for code) and exposes `query` / `path` /
`explain` plus PR-oriented helpers (`graphify prs`, PR impact). Its published
code-intelligence benchmark on ERPNext claims a lift from ~71% → ~82% key-fact
coverage when a fixed agent gets one graph tool vs grep/read alone.

That capability maps to a real gap in Helm. It does **not** map to the failure
modes that already burned us:

| Past failure | Fix already in place | Graphify role |
| --- | --- | --- |
| CLAUDE.md §4 contract drift (LEA-104) | ADR-027 directed §4 comparison | None — docs, not call graph |
| Conflicting reviewer / Haystack signals | ADR-037 adjudicator + stop rules | None — product/doc conflict |
| Spec / plan ambiguity | Human + remediator paths | None — upstream of code review |

Baking Graphify into Helm as a platform dependency (Python toolchain in every
review workspace, graph freshness on shallow clones, MCP/CLI wiring, another
failure surface when reviews flake) is unjustified until we prove a repeatable
quality win on a real product.

This ADR does **not** accept Graphify as a Helm dependency. **Accepted** here
means we authorize a **bounded experiment** with kill criteria — not product
integration.

---

## Decision

### 1. Run a manual experiment on one product before any Helm integration

**Pilot product:** Arriendo Fácil (`leasity-tenants`), because it already
exercises the review loop and has multi-package blast-radius risk
(`packages/db` ↔ `apps/api` ↔ web/mobile).

**Scope of the experiment (thin wedge only):**

1. Build a code-only graph once on a recent `develop` (or impl) checkout
   (AST only; no docs/media semantic pass required):

   ```bash
   graphify extract .
   ```

2. For **2–3 real impl PRs** (open or recently reviewed), manually produce a
   **PR impact note**: changed symbols → `graphify path` / neighbors / PR
   impact subgraph.
3. Compare that note to what the Helm reviewers (and Haystack, if present)
   actually flagged on the same PR.
4. Record outcomes in this ADR's Consequences / experiment log (or a linked
   operations note) before any productization proposal.

**Explicit non-goals for the experiment:**

- No change to `reviewer-fanout`, remediator, or adjudicator prompts.
- No Helm platform dependency, Docker image change, or CI step.
- No committing `graphify-out/` into product repos as a required artifact.
- No always-on assistant hooks (`graphify cursor install`, PreToolUse, etc.).
- No use for spec/plan review, contract-drift (§4), or adjudication.

### 2. Success criteria (must meet to open a follow-up ADR)

The experiment **passes** only if **all** of the following are true:

1. **Signal:** On at least **two** of the sampled PRs, the impact note surfaces
   a concrete cross-file risk (caller, shared type, or import path) that the
   Helm review cycle did **not** flag, and that a human judges as legitimate
   (not noise).
2. **Actionability:** A reviewer or remediator could have used that finding
   without reading the whole graph — i.e. a short subgraph / path is enough.
3. **Cost:** Building/refreshing the graph for the pilot repo stays cheap
   enough that a future automated step would not dominate review latency
   (ballpark: minutes, not tens of minutes, on a laptop or CI runner).
4. **No substitute:** Findings are not already covered by ADR-027 §4 checks or
   by Haystack on those same PRs.

If any criterion fails, **stop**. Do not productize. Mark this ADR
`Deprecated` with a one-paragraph post-mortem.

### 3. If the experiment passes — only then propose a thin productization

A follow-up ADR (not this one) may propose **optional** reviewer context:

- Inject a **PR impact subgraph** (changed symbols → neighbors/paths) into the
  code (and possibly security) reviewer prompt.
- Keep Graphify **out of** adjudication, remediation policy, and external
  adapters unless a later ADR says otherwise.
- Prefer offline/CLI generation in the review workspace over always-on IDE
  hooks.
- Product opt-in via `product.yaml` (default off).

Until that follow-up is Accepted, Graphify remains **outside** Helm.

---

## Consequences

### Positive (if we stop at the experiment)

- Cheap answer to "does a code graph help our reviewers?" with evidence on a
  product we already operate.
- Avoids platform complexity until value is proven.
- Aligns with the Atipicus / "Hablemos de IA" interest in graph-aided review
  without committing Helm's core.

### Negative / risks

- Manual experiment still costs operator time (setup + 2–3 PR comparisons).
- Graphify's marketing surface is large; easy to overscope beyond blast-radius.
- A shallow Helm clone may not match a full local graph unless the experiment
  uses a full checkout — document that difference so results aren't overclaimed.

### Neutral

- Contract drift, adjudication, and external review remain the primary review
  quality levers regardless of experiment outcome.

---

## Alternatives considered

### A. Integrate Graphify into Helm now (MCP + auto-extract in review workspaces)

Rejected. Operational cost is high; the loop's documented misses were not
primarily "missing call graph." Violates the bar of clear value before
complexity.

### B. Do nothing / never evaluate

Rejected as the standing position only if evaluation cost is high. A manual
pilot on one product is low enough cost to answer the question once.

### C. Adopt a different code-intel layer (SCIP/LSIF, repo maps, custom tree-sitter)

Deferred. Graphify is the concrete candidate already discussed externally and
has PR-impact tooling. If the experiment fails for Graphify-specific reasons
(quality of edges, TS monorepo support) but the *need* for blast-radius context
is confirmed, revisit with another indexer — that would be a new ADR.

### D. Commit `graphify-out/` in every product repo and teach all specialists to query it

Rejected for now. Couples every product to graph freshness and merge drivers;
far beyond the thin wedge.

---

## Revisit when

- The experiment completes (pass → productization ADR; fail → deprecate this).
- Review miss post-mortems repeatedly cite "changed X, broke unseen caller Y"
  after ADR-027 / ADR-037 are in place.
- A product repo grows large enough that undirected exploration routinely hits
  the reviewer time budget without finding dependents.
- Graphify (or an alternative) becomes installable as a single hermetic binary
  with no Python toolchain tax in review workspaces.

---

## Experiment log (fill in during the pilot)

| PR | Graphify finding | Caught by Helm loop? | Caught by Haystack? | Human verdict | Notes |
| --- | --- | --- | --- | --- | --- |
| | | | | | |

**Outcome:** _pending — Pass / Fail / Inconclusive_

**Operator:** _TBD_
)
