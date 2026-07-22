# issue_72 — Implementation Plan

## Overview
Persist human-resolved `product_decision` conflicts as a durable decision ledger keyed by a stable conflict fingerprint, then thread that ledger through review dispatch so later review loops recognize the same conflict as already settled. The review loop should still process unrelated findings and unresolved AUTO items, but it must stop escalating the same human-decided conflict again across retries, re-dispatches, and fresh process sessions.

## Implementation Steps
1. Add a first-class persisted decision record to Helm's item state so a human choice survives beyond one review run. Extend the item persistence model with a `ResolvedProductDecision` shape that captures the stable fingerprint, conflict kind, topic/title, affected scope markers or paths, chosen option, source comment metadata, and the timestamp the decision was recorded. Store the ledger on the item artifact itself so future review cycles can load it without depending on in-memory state or a single job record. Make writes idempotent so the same fingerprint does not create duplicate records.

2. Centralize decision parsing and fingerprint derivation so structured comments and checklist-style inputs resolve to the same conflict identity. Add a shared parser/helper that accepts the existing structured decision comment forms, legacy field labels, and checklist-style inputs, then normalizes them into one decision object. Derive the conflict fingerprint from the product-decision context, not from raw prose alone: conflict kind, topic/title, and the relevant scope markers or affected paths should participate in the key. Keep the parser conservative on malformed input so clearly ambiguous comments remain non-actionable.

3. Persist the resolved decision when Helm receives a valid human decision on the pull request. Update the GitHub webhook path to validate the comment against the latest adjudication context, then write the resolved decision into the item ledger before acknowledging success. Record the decision in an audit-friendly form on the item history or equivalent artifact note so operators can trace when the choice was made, what was chosen, and which conflict it resolved. Preserve the current behavior for unrelated comments and for reviewer disagreements that are not tied to a recorded `product_decision`.

4. Thread the stored decision ledger into the review dispatch path so later loops can suppress repeat escalation. Load the persisted decisions when scheduling `reviewer-fanout` and pass them through the dispatcher into the review loop as part of the review context. Teach the adjudication pass to compare newly surfaced conflicts against the stored fingerprint set before deciding that human input is required. If a conflict matches a stored decision, mark that branch as settled and continue processing the remaining findings instead of reopening the same A/B choice.

5. Keep remediation support intact for already-decided conflicts. When the chosen option still has not been implemented, let the remediator consume the stored choice so it can continue the mechanical work without asking the human to decide again. Preserve the distinction between a conflict that is already settled and a non-conflict finding that still requires review or remediation. Ensure the recorded choice remains visible in the review artifact trail so operators can tell why a conflict was skipped or deferred.

6. Harden the behavior across re-dispatches and process restarts. Re-read the persisted decision ledger every time a review dispatch is scheduled; do not rely on a cached in-memory copy. Keep the storage and read path deterministic so a later dispatch on the same item sees the same settled fingerprint set even after the process restarts. Fail closed on ambiguous fingerprints: if a later adjudication cannot prove a conflict matches a stored decision, it should still escalate normally rather than silently suppressing a new disagreement.

## Files to Touch
- `apps/api/src/services/types.ts` - add the persisted resolved-decision type and item-level ledger fields.
- `apps/api/src/services/item-store.ts` - persist and read the decision ledger with idempotent upsert semantics.
- `apps/api/src/services/item-store.test.ts` - verify durable storage, replay, and audit metadata on the item artifact.
- `apps/api/src/routes/webhooks.ts` - record a human decision when the PR comment matches the latest adjudication context.
- `apps/api/src/routes/webhooks.test.ts` - cover first-seen decisions, duplicate decisions, malformed input, and non-matching adjudications.
- `apps/api/src/services/dispatch-scheduler.ts` - load the stored decision ledger and pass it into the review dispatch context.
- `apps/api/src/services/dispatch-scheduler.test.ts` - verify the review context includes the persisted decision snapshot and survives re-dispatch.
- `packages/orchestrator/src/dispatcher.ts` - thread decision context through the `reviewer-fanout` path into the review loop.
- `packages/orchestrator/src/review-loop/adjudication.ts` - add normalized decision parsing / fingerprint helpers for settled-conflict matching.
- `packages/orchestrator/src/review-loop/adjudication.test.ts` - verify structured and checklist-style inputs normalize to the same conflict fingerprint.
- `packages/orchestrator/src/review-loop/code-review-loop.ts` - suppress HUMAN_REQUIRED escalation for conflicts already present in the stored decision ledger.
- `packages/orchestrator/src/review-loop/code-review-loop.test.ts` - cover mixed outcomes where resolved conflicts are skipped but unrelated findings still progress.
- `packages/orchestrator/src/specialists/review-adjudicator.ts` - include the persisted decision context in the adjudicator prompt/artifact trail so the agent can see settled choices.
- `packages/orchestrator/src/specialists/review-adjudicator.test.ts` - verify the prompt and artifact handling still work with injected settled decisions.

## Test Strategy
- Decision parser and fingerprint tests: structured decision comments, legacy field labels, and checklist-style inputs normalize to the same resolved decision; missing conflict identity, missing choice, or ambiguous scope markers stay non-actionable; fingerprints stay stable across harmless formatting drift while still distinguishing different topics or scopes.

- Item persistence tests: writing the same resolved decision twice does not duplicate the ledger entry; reloading the item from disk restores the recorded choice and audit metadata; the persisted item artifact remains readable after a restart-style re-read.

- Route tests for human decision recording: a valid PR decision comment records the resolved choice and audit trail; a repeated comment for the same fingerprint stays idempotent; a malformed or unrelated comment does not mutate the ledger.

- Review-loop tests: a conflict already present in the decision ledger is not escalated again; unrelated findings and remaining AUTO items still flow through to remediation or review; a later dispatch after a process restart sees the same settled conflict set.

## Risks / Open Questions
- The exact conflict fingerprint shape needs to be strict enough to stay stable across wording changes but flexible enough to survive legitimate comment-format drift.
- The most natural persistence home is the item artifact, but if the current item JSON gets too large or too coupled to review history, a dedicated decision-ledger file may be cleaner.
- The review loop currently reasons about fresh adjudication output; the implementation needs to avoid suppressing genuinely new conflicts that merely resemble a previously settled one.
- If the chosen option is only partially implemented, the system still needs to show the stored decision clearly while letting remediation continue without reopening human review.
