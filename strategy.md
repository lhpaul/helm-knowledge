# Helm strategy

**Status:** agreed direction; implementation and migration decisions remain open

**Updated:** 2026-10-30

**Execution plan:** [ADF, Helm, and Helm Core roadmap](operations/agent-first-roadmap.md)

## Purpose

Helm helps people develop and evolve software with capable AI agents while
retaining product intent, design context, appropriate technical review, and
clear authority. A small team should be able to deliver useful work without
spending most of its time operating the development workflow itself.

The primary users are technical leads and small software teams, product and
design collaborators who need a shared handoff to engineering, and operators
who need visibility and safe intervention while agents work.

Helm is the product direction. The current AI Development Framework (ADF) is
the foundation used by existing projects. Helm Core is the name of a proposed,
agent-first core experiment for Helm. It is not yet an implementation, a new
source of truth, or an approved replacement for either existing system.

## Product principles

1. **Agents own work within an explicit contract.** Give the agent the outcome,
   relevant project context, authority, and completion evidence. Let it choose
   the steps and use available tools. Do not require a human approval merely
   because a document or workflow stage exists.
2. **Involve people where their decisions matter.** Product direction, UI/UX,
   durable architecture and data-model tradeoffs, and actions beyond delegated
   authority may need a human decision. The agent should present the options,
   recommendation, and consequences. Technical review and tests remain part of
   the evidence; autonomy is not a substitute for verification.
3. **Prefer instructions and capabilities over vendor integrations.** Agents
   discover the tracker, reviewers, and tools available to the project. Report
   missing access or an unavailable review honestly; never present an absent
   review as a clean one. Project-specific conventions can be documented locally.
4. **Keep deterministic mechanisms where they earn their cost.** Tests,
   security boundaries, exact identity, concurrency, interruption recovery, and
   potentially destructive operations may require code. Introduce or retain a
   helper for a concrete guarantee, not simply to support another vendor.
5. **Design is product context.** Mockups can be visual references in a spec.
   Changes to a living mockup can also produce proposed implementation work,
   grouped by implementation unit and confirmed by a person before creation.
6. **Existing consumers remain supported.** ADF's current supported workflows
   remain the compatibility baseline. Fix verified blockers and preserve
   appropriate safeguards while measuring a simpler path in parallel.
7. **Migrate from evidence.** A prototype does not replace ADF or Helm until
   representative journeys, recovery, consumer adoption, and tradeoffs are
   demonstrated and a migration decision is made.

## Roles and boundaries

| Project | Role | Current priority |
| --- | --- | --- |
| [ADF](https://github.com/lhpaul/ai-dev-framework-template) | Stable workflow foundation for current consumers | Safety, real blockers, remote execution, and mockup workflows |
| [Helm](https://github.com/lhpaul/helm) and this knowledge repo | Product direction, product context, and existing product implementation | Reconcile current use and roadmap; preserve useful product capabilities |
| Helm Core | Independent experiment for a simpler agent-first foundation for Helm | Establish its contract and prove real end-to-end journeys |

The Core may become a component of Helm or inform a different evolution. The
experiment starts without requiring Helm's current server, dashboard, state
machine, or vendor-specific adapters. This is a scope boundary for the
experiment, not a decision to remove those components from Helm.

## Decision rights and safety

Within the user's authority and repository policy, the agent can investigate,
implement, review, and prepare delivery. Humans decide product and UX direction
and meaningful architectural or data tradeoffs when judgment or authority is
needed. Production changes, destructive actions, external communications, and
scope expansion require the relevant explicit authority; they are not implied by
this strategy. A project's instructions and the user's specific direction take
precedence over general autonomy preferences.

Independence and fresh evidence matter: a current change needs appropriate review
and validation; stale evidence, missing access, or an unavailable reviewer cannot
be reported as success. The right amount of review depends on the change and
its risk, not a fixed number of vendor platforms.

## Near-term priorities

1. Reconcile the ADF and Helm portfolios and verify reported safety gaps.
2. Complete ADF remote hub execution and enable both agreed mockup outcomes.
3. Set up and pilot Helm Core in parallel, without creating a second Helm
   product or disrupting existing consumers.
4. Evaluate review quality, intervention, delivery time, recovery, and consumer
   compatibility before deciding whether and how Helm adopts the new core.

The [roadmap](operations/agent-first-roadmap.md) records the initial work,
dependencies, validation, setup choices, and decision gates. Existing ADRs and
protocols remain effective for current operations until changed through their
normal review process; this strategy does not silently supersede them.
