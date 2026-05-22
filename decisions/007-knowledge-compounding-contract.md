# ADR-007: Knowledge repo compounding contract

**Status**: Accepted
**Date**: 2026-05-22
**Deciders**: LH

## Context

Helm's v0 already separates Product knowledge from code repositories. The
knowledge repo stores specs, plans, ADRs, wiki, and retrospectives. That
structure is enough for artifact review, but it does not yet make three
important feedback loops explicit:

1. Product strategy should ground discovery, specs, and plans.
2. Solved problems should become reusable learnings for future agents.
3. Workflow operations should produce lightweight pulse reports before the full
   QA/Sentry/product-analytics loop exists.

The comparison with compound-engineering patterns reinforced that these loops
should be first-class artifacts, not ad hoc notes inside retrospectives.

## Decision

Extend the Product knowledge repo contract with four first-class surfaces:

- `strategy.md`: durable product anchor read by discovery, spec, and plan
  specialists.
- `discovery/`: lightweight pre-spec artifacts for ambiguous or product-shaped
  work.
- `learnings/`: reusable knowledge captured from bugs, reviews, workflow
  failures, and implementation discoveries.
- `pulse-reports/`: periodic operational reports on workflow health, cost,
  stuck work, and review quality.

These join the existing durable surfaces: `.helm/`, `specs/`, `plans/`,
`decisions/`, `wiki/`, `retrospectives/`, and reserved `ux-options/`.

Specialists should read from these surfaces as follows:

- Spec Writer reads `strategy.md`, relevant `discovery/`, `wiki/`,
  `decisions/`, and `learnings/`.
- Plan Writer reads the approved spec plus `strategy.md`, `decisions/`, `wiki/`,
  and `learnings/`.
- Implementer reads the approved plan plus relevant `learnings/` and `wiki/`.
- Reviewers may request new `learnings/` entries when findings reveal reusable
  patterns.
- Workflow Pulse generates reports from operational data and publishes them to
  `pulse-reports/` through the orchestrator git PR publish step. Agents do not
  write directly to the Product knowledge repo.

The v0 persistence rule remains unchanged: no local database is required for
these artifacts. Markdown in git is the source of truth. Helm may later build a
rebuildable SQLite or embedding index over the knowledge repo, but that index is
not canonical.

## Consequences

**Positive:**

- Agents have a clear place to find product strategy before drafting artifacts.
- Discovery becomes durable without forcing every item through a heavyweight PRD
  process.
- Repeated bugs and reviewer findings can compound into future context.
- Pulse reporting can ship before QA regression and Sentry integrations.
- The MOME pilot gets useful operational visibility without expanding v0 storage
  scope.

**Negative / trade-offs:**

- More folders can look like process overhead if they are treated as mandatory
  for every small fix.
- Specialists need retrieval discipline; dumping every file into context will
  waste tokens.
- Pulse reports can drift into retrospectives unless their scope stays limited
  to current workflow health.
- `strategy.md` needs occasional human review or it becomes stale grounding.

## Rules

1. `strategy.md` is required for Product knowledge repos after this ADR.
2. `discovery/` artifacts are required only for ambiguous or product-shaped work;
   small bugs and mechanical refactors may skip them.
3. `learnings/` entries must be reusable. Do not capture one-off typo fixes.
4. `pulse-reports/` are operational snapshots, not long-form retrospectives.
5. Any future index over these folders must be rebuildable from git.

## Alternatives considered

### Put strategy and learnings inside `wiki/`

Rejected. `wiki/` is broad and will likely contain domain docs, runbooks, and
glossary content. Strategy and learnings are core workflow inputs and deserve
stable, predictable paths.

### Put pulse reports inside `retrospectives/`

Rejected. Retrospectives analyze completed work and produce improvement actions.
Pulse reports are time-windowed operational readouts. Mixing them makes both
less crisp.

### Wait until v1 with SQLite indexing

Rejected. The artifact contract should be settled before runtime indexing. The
folders are useful immediately and do not require a database.

## Revisit when

Revisit this ADR if:

1. Product teams consistently skip discovery because it feels too heavy.
2. `learnings/` becomes noisy enough that retrieval quality drops.
3. Pulse reports need structured querying that cannot be handled by markdown and
   filesystem aggregation.
4. UX Lab moves from reserved `ux-options/` to a shipped v1 feature and needs a
   deeper artifact contract.

## References

- `README.md` - current knowledge repo contract.
- `discovery/README.md` - discovery artifact guidance.
- `learnings/README.md` - learning capture guidance.
- `pulse-reports/README.md` - pulse report shape.
- `operations/workflow-pulse.md` - v0 pulse runbook.
