# Discovery Artifacts

Discovery is the lightweight product-shaping step before a spec is drafted. It
prevents a tracker item from becoming implementation work before the problem,
scope, and evidence are clear enough for the Spec Writer.

## When to create one

Create a discovery artifact for any item where one of these is true:

- Product behavior is ambiguous.
- The item affects user experience, onboarding, pricing, permissions, or data
  visibility.
- Multiple solution shapes are plausible.
- The issue brief is short, stale, or written as an implementation request
  instead of a user problem.

Small bugs, mechanical refactors, and clear operational fixes may skip discovery.

## File naming

Use the tracker identifier when available:

```text
discovery/HELM-123-short-slug.md
```

For GitHub issue-backed work, use:

```text
discovery/issue-123-short-slug.md
```

## Template

```markdown
# Discovery: <title>

- **Item**: <tracker id or link>
- **Date**: YYYY-MM-DD
- **Owner**: <human or agent>
- **Status**: draft | ready-for-spec | superseded

## Problem

What problem are we trying to solve, in user/product terms?

## Evidence

What evidence says this matters? Include user reports, observed workarounds,
support threads, metrics, or stakeholder notes.

## Current workaround

What do users or operators do today?

## Smallest valuable version

What is the smallest version that proves the bet without overbuilding?

## Scope boundaries

What is explicitly out of scope for this item?

## Spec handoff notes

What should the Spec Writer carry forward?
```
