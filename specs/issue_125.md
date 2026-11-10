# issue_125 — Specification

## Context
In real Helm deployments, 46 of 80 escalations were `adjudication_conflict`, mostly from the early artifact review (spec-draft-reviewer, plan-draft-reviewer). ADR-037 sends the loop to a human whenever the review-adjudicator returns `HUMAN_REQUIRED`. Many of those conflicts are not real product decisions: the draft is editable and the conflict is resolvable by the ADR > spec > CLAUDE.md hierarchy or by an edit.

## Acceptance Criteria
- In early artifact review, a `doc_conflict` the adjudicator resolves by the ADR-037 hierarchy no longer escalates; the fix goes to the remediator as an AUTO plan item.
- The adjudicator prompt for draft artifacts states that wording/clarity/structure findings are plan items, not conflicts.
- Real `product_decision` conflicts, `doc_conflict`s without a hierarchy resolution, and an explicit `HUMAN_REQUIRED` still escalate.
- Implementation review and high-risk handling are unchanged.
- Tests show both directions (fewer escalations; real ones preserved). Docs and CHANGELOG updated.

## Out of Scope
- Changing ADR-037, stop rules, max cycles, or the `adjudication_conflict` reason.
- Per-product tuning knobs.

## Technical Notes
- Deterministic guard in `resolveHierarchyDocConflicts`, applied only when the adjudication ran on a draft artifact; reviewer opinion is never a valid `Resolved by` source.
