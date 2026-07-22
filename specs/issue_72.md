# issue_72 — Specification

## Context
When a review-adjudicator escalates a disagreement as `HUMAN_REQUIRED` with a `product_decision`, a human may resolve the conflict by posting a decision on the pull request. Today, later review cycles can treat the same disagreement as unresolved and surface the same A/B choice again.

This item ensures that once a human decision is recorded for a specific conflict, Helm treats that decision as settled across later re-dispatches and subsequent review loops. The system must continue processing any remaining actionable findings, but it must not reopen the same resolved product decision.

This applies to adjudication outcomes that are already captured as human product decisions and is separate from automatic re-dispatch behavior.

## Acceptance Criteria
- A `product_decision` recorded for a specific conflict is not escalated again in later review loops when the same conflict reappears.
- The resolved choice is associated with the conflict in a durable way so future adjudication can recognize it as already settled.
- Review cycles continue processing unrelated findings and remaining AUTO items after a resolved decision is recorded.
- The recorded decision is visible in item or job artifacts for audit and traceability.
- If the chosen option has not yet been implemented, the system may surface it as an actionable remediator step, but it must not ask the human to re-decide the same conflict.
- The same resolved decision behavior works across re-dispatches, not just within a single in-memory review session.

## Technical Notes
- The persisted record should bind the human choice to a stable conflict fingerprint derived from the relevant product decision context, including the topic and affected paths or equivalent scope markers.
- The spec should preserve the distinction between:
  - unresolved disagreement that still needs human input
  - resolved disagreement with a stored human choice
  - remaining non-conflict findings that still require review or remediation
- The audit trail should make it clear when the decision was recorded, what choice was made, and which conflict it resolved.
- The implementation should avoid coupling this behavior to a single comment format; structured decision comments and checklist-style inputs should both be acceptable sources of the resolved choice.
- The remediator may consume the stored choice to continue work, but this spec does not require automatic re-dispatch behavior itself.
- This item should not change the policy for unrelated reviewer disagreements that are not tied to a recorded `product_decision`.
