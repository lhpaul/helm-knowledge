# ADR-032: Split the final stage — `merged` vs `released`

**Date:** 2026-06-04
**Status:** Accepted
**Context:** Bloque I / H5 — workflow semantic clarity. Follows #27 (cycle closed through to `released`) and ADR-029 (operator escape-valve pattern).

---

## Context

The final workflow stage was a single `released`, entered the moment the
`helm/impl/<id>` PR merged. So `released` actually meant **merged**, not
**shipped to users**. This conflated two genuinely distinct states and made
`released` unreliable for any product where "PR merged" ≠ "live for users".

**Intake note (brief premise was imprecise):** the roadmap phrases H5 as
"split `code-review → merged → released`", which reads as if a `merged` stage
already existed. It did not. Verified against the real code at intake:

- `packages/workflow/src/types.ts` — `WORKFLOW_STAGES` ended
  `… 'code-review', 'remediation', 'released'`. No `merged`.
- `packages/workflow/src/state-machine.ts` —
  `'code-review': ['in-development', 'remediation', 'released']`. The
  `code-review → released` edge was **direct**.
- `apps/api/src/routes/webhooks.ts` — `ARTIFACT_STAGE_MAP.impl = 'released'`,
  so an impl-branch merge drove the item straight to `released`.

So the current chain was `code-review → released` (direct), and H5 is
**additive**: insert `merged` before `released`, repoint the impl merge to
land in `merged`, and add a *new* trigger for `merged → released`.

Two further facts confirmed at intake and relied upon below:

- **Single product per Helm instance.** `getProductConfig()` returns one
  `config.product`; the release webhook needs no repo→product resolution.
- **Adapters auto-enumerate stages.** Both adapters' `ensureSubStages` build
  their option/label set from `WORKFLOW_STAGES`, so adding `merged` yields a
  new GitHub Projects single-select option and a Linear `helm:merged` label
  with no hand-maintained mapping.

## Decision

Insert a `merged` stage before `released`. End-state chain:
`… → code-review → merged → released`.

- A merged `helm/impl/<id>` PR now lands the item in **`merged`** (PR merged).
- **`released`** (shipped to users) is entered only by an explicit release
  trigger, shipped in two forms this session:
  - **Manual operator promote** — `POST /api/items/:externalId/release`
    advances one item `merged → released`. A normal **forward** edge, so it
    uses `ItemStore.transition()` (not `forceTransition`, which stays the
    rollback-only escape valve, ADR-029).
  - **Bulk release webhook** — a GitHub `release` event with
    `action: published` promotes **every** `merged` item of the instance
    product to `released`. Idempotent and delivery-safe (per-item errors
    logged, still `200`); routed through the tracker-agnostic pure parser so
    Linear products ship via GitHub releases too.
- **Per-product opt-out** via a new `workflow.final_stage` field
  (`z.enum(['merged', 'released']).default('released')`). A product with
  `final_stage: merged` (e.g. the playground, or any product with no
  user-facing release step) terminates at `merged`: the release endpoint
  returns `409` and the release webhook is a no-op.
- The **state machine stays product-agnostic**: the `merged → released` edge
  exists for every product. `final_stage` gates the *trigger*, not the *edge*
  — opt-out products simply never fire the release trigger.

### Locked decisions

1. **Additive split, not rename** (roadmap). `merged` is new; `released` stays
   in the enum but its trigger changes.
2. **Trigger = manual API + release webhook** (both shipped this session).
3. **`final_stage` product field** for opt-out (default `released`).
4. **Grandfather** existing `released` items — no migration script,
   forward-only.
5. **Product-agnostic state machine** — `final_stage` gates the trigger, not
   the edge.

### Reconciliations vs the H5 brief

Two brief details were reconciled against the real code at intake; both are
deliberate departures, recorded here:

- **`final_stage` placement → `workflow.final_stage`, not top-level.** The
  brief specified a *top-level* field. Intake found that `stages_enabled`,
  `designer_gate`, `qa_gate`, and `readiness_gate` already live under
  `workflow`, and that `stages_enabled` is **prompt-descriptive only** (it is
  interpolated into specialist prompts via `stages_enabled.join(' → ')` and
  governs nothing about terminal-stage reachability). So `final_stage` is not
  redundant with any existing control, and it belongs in the `workflow`
  governance group rather than at the root. The "top-level" framing predated
  knowledge of the `workflow` grouping.
- **Release endpoint error codes → `400` (wrong stage) + `409` (opt-out),
  not `409` for both.** The brief's contract wanted `409` for both "item not
  in `merged`" and "product opts out". The codebase convention (ADR-031's
  central `mapErrorToResponse`, and the analogous rollback endpoint, ADR-029)
  maps an unexpected current stage to a `StageMismatchError → 400`. To stay
  consistent with the most analogous operator endpoint, "item not in
  `merged`" returns **400** (`StageMismatchError`). The opt-out case has no
  existing error class — it is a product-config conflict, genuinely distinct
  from a malformed request — so it returns **409** with a dedicated message.

### HTTP contract — `POST /api/items/:externalId/release`

- **Body** (Zod, `.strict()`): `{ reason?: string(1–500) }`.
- **200** `{ externalId, currentStage: 'released', historyEntry }`. History
  entry: `{ fromStage: 'merged', toStage: 'released', triggeredBy:
  'manual:release', at, note?: reason }`.
- **400** invalid body / invalid externalId / item not in `merged`
  (`StageMismatchError`).
- **404** item not found for the instance product.
- **409** product has `final_stage: merged` (no released stage).
- **500** unexpected (logged, generic message).

### Webhook contract — `release.published`

GitHub `release` event, `action: published` → normalized
`{ type: 'release_published', tag, timestamp }`. Handler bulk-promotes every
`merged` item of the instance product to `released`
(`triggeredBy: 'webhook:release'`). No-op for `final_stage: merged` products.
Per-item errors logged; response still `200` (idempotent delivery success).

## Alternatives considered

- **Rename current `released` → `merged` + migrate all items.** Rejected:
  touches existing data for no behavioral gain; grandfathering is lower-risk
  and the historical ambiguity is bounded.
- **Release detection via CI/deploy webhooks.** Rejected for now: no reliable
  deploy signal exists; the manual endpoint plus the GitHub `release` event
  are sufficient.
- **Fully config-driven per-product stage list.** Rejected: a large refactor,
  outside H5's semantic-clarity intent.
- **Parse item IDs from release notes for precise per-release mapping.**
  Rejected: bulk "everything merged ships" plus the surgical manual endpoint
  cover the real cases; revisit on need.
- **`final_stage` at the product root.** Rejected in favor of
  `workflow.final_stage` (see Reconciliations).
- **`409` for the wrong-stage release case.** Rejected in favor of `400`
  (StageMismatch), matching the rollback endpoint (see Reconciliations).

## Consequences

- **Breaking:** an impl PR merge now lands items in `merged` (was `released`),
  and the direct `code-review → released` edge is removed. Any consumer that
  read `released` as "impl PR merged" must switch to `merged`.
- **Grandfather tradeoff:** pre-H5 `released` items are not migrated and are
  therefore indistinguishable from truly-shipped items. Accepted; new items
  get clean semantics. A regression test confirms `ItemStore` leaves existing
  `released` items as-is.
- **Opt-out products** (`final_stage: merged`) terminate at `merged`: the
  release endpoint returns `409`, the release webhook is a no-op.
- Adapters create the `merged` option/label uniformly for **all** products,
  including opt-out ones — `final_stage` only gates whether items *reach*
  `released`, not which stage options/labels exist.

## Tests

- State machine: `code-review → merged` valid, `merged → released` valid,
  `code-review → released` now **invalid**, `merged` not terminal, `released`
  still terminal, `getValidNextStages` counts.
- Webhooks: impl merge now lands in `merged`; `release_published` promotes all
  `merged` items; no-op on a `final_stage: merged` product; non-`published`
  release actions ignored; per-item error keeps the response `200`.
- Release endpoint: happy path (`merged → released`, `triggeredBy:
  manual:release`), wrong stage (`400`), opt-out product (`409`),
  missing/invalid externalId, item-not-found, body validation, grandfather
  (re-release rejected, stage preserved).
- Adapters: Linear `ensureSubStages` label count `9 → 10` (+ `helm:merged`).
- Schema: `workflow.final_stage` defaults to `released`, rejects values
  outside the enum.

## Revisit when

- A product needs per-release item precision (parse the release body for
  specific item IDs instead of bulk-promoting all `merged` items).
- A reliable deploy/CI signal exists (auto-`released` on deploy rather than on
  the GitHub release event).
- More than one product per Helm instance becomes real (the release webhook
  would then need repo→product resolution).

## References

- helm#45 — implementation (state machine, webhook repoint + release handling,
  `release` route, `final_stage` schema field, tests, CHANGELOG).
- ADR-029 — implementer rollback (`forceTransition` escape valve; the
  `StageMismatchError → 400` precedent reused by the release endpoint).
- ADR-031 — API HTTP error conventions (`validateExternalId`,
  `mapErrorToResponse`).
- #27 — cycle closed through to `released`.
- `operations/onboarding-product.md` — `workflow.final_stage`, the release
  endpoint, and the release webhook.
