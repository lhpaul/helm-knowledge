# issue_70 — Specification

## Context
The review loop currently requires manual intervention in two common cases:

1. When an implementer finishes and the item transitions to `code-review`, the reviewer fan-out does not always start automatically.
2. When a `HUMAN_REQUIRED` adjudication is resolved on a PR, the review loop does not resume from the current HEAD unless an operator manually dispatches it.

This creates avoidable operator work and delays review feedback. The goal of this item is to make review-loop re-dispatch automatic in both situations while preserving idempotence.

## Acceptance Criteria
- When an item transitions from implementer completion into `code-review`, the review loop is dispatched automatically without requiring a manual `POST .../dispatch`.
- When a structured human decision resolves a `HUMAN_REQUIRED` adjudication on a PR, the review loop is dispatched automatically from the current HEAD without requiring a manual `POST .../dispatch`. The resolving event must be a new `issue_comment` webhook on the open implementation PR containing `<!-- helm:product-decision -->` plus the adjudication conflict kind, matching conflict title, and chosen option.
- Re-dispatch is idempotent: repeated state transitions, duplicate marker comments, retries, or webhook repeats must not create duplicate concurrent review jobs for the same item or PR HEAD.
- The automation must not trigger when the item is already in a state where the review loop is active or already scheduled for the same target.
- The automation must preserve the current review target semantics, including dispatching from the latest available HEAD after a human decision is posted.
- The behavior is covered by tests for both trigger paths and for the no-double-run case.

## Technical Notes
- Treat the implementer-to-`code-review` transition as a first-class lifecycle event that can enqueue a review-loop dispatch if one is not already pending.
- Detect human resolution through a new `issue_comment` created webhook on the open implementation PR. The comment must contain the `<!-- helm:product-decision -->` marker and the structured decision payload, for example:

  ```md
  <!-- helm:product-decision -->
  ## Human decision
  - **Conflict:** product_decision · Payment redirect trust boundary
  - **Chosen:** B — ...
  ```

  The payload must include the conflict kind (`product_decision` or `doc_conflict`), the conflict title matching the adjudication `Conflicts` entry text after `·`, and the chosen option letter/label. Ignore edits to free-form comments without the marker; free-form prose without the marker must not enqueue review.
- On a valid human-resolution event, if the item is in `code-review` or has just escalated and is waiting for human resolution, enqueue reviewer fan-out / review-loop dispatch from the current PR HEAD only when no equivalent job is already running or scheduled for that same HEAD.
- Use a stable deduplication key of `(productSlug, externalId, targetRevision/PR HEAD SHA)`. The trigger source is metadata only and must not be part of uniqueness.
- The implementer-transition path and the human-resolution path must not create concurrent duplicate review jobs for the same target revision.
- The dispatch path should be safe to call multiple times and should short-circuit when an equivalent job already exists.
- The human-resolution path should read the current PR HEAD at dispatch time so the resumed review run evaluates the latest code after the decision.
- Persistence of the chosen option across cycles is out of scope for this item and is covered separately by issue #72.
- Prefer a minimal change to the existing review-loop orchestration rather than introducing a new workflow surface.
