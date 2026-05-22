# Helm Strategy

- **Status**: Active
- **Last updated**: 2026-05-22

## Target problem

Small software teams are increasingly relying on AI agents to ship product work,
but the workflow around those agents is still fragile. Work often jumps from a
tracker item directly to implementation, losing product intent, design context,
technical planning, and quality gates along the way.

Helm exists to make AI-assisted software development operationally reliable for
small teams that need enterprise-quality output without enterprise-sized teams.

## Our approach

Helm orchestrates a formal workflow across Product, Design, Technical Planning,
Implementation, Review, and Release. It keeps source-of-truth artifacts in git,
uses issue trackers for workflow state, and gives agents isolated runtime
environments with observable logs, costs, and review gates.

The product is protocol-first: workflow contracts remain human-readable and
reviewable, while Helm automates the execution and coordination around them.

## Primary users

- CTOs and technical leads in small startups who own software quality with a
  very small team.
- Product and design collaborators who need a shared, reviewable handoff into
  engineering.
- Agent-assisted development operators who need visibility, cost tracking, and
  safe intervention while agents work.

## Active tracks

- Stabilize v0 workflow orchestration: product registry, item stages, specialist
  dispatch, and workdir handling.
- Make the knowledge repo the product's durable memory: strategy, discovery,
  specs, plans, ADRs, learnings, wiki, pulse reports, and retrospectives.
- Reach MOME pilot readiness by preserving agent-hq parity while adding formal
  Spec -> Plan -> Dev quality gates.

## Key metrics

- Time from item selection to human-review-ready PR.
- Review cycles per item.
- Agent run failure/interruption rate.
- Cost per item and per specialist.
- Percentage of implementation work backed by discovery, spec, and plan
  artifacts.

## Not working on yet

- Multi-tenant SaaS.
- Full UX Lab implementation.
- Full QA regression gate.
- Sentry-driven incident repair loop.
- Non-Claude-Code runtimes beyond interface readiness.
