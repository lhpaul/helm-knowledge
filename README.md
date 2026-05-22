# helm-knowledge

Knowledge repo for the Helm project: strategy, discovery artifacts, specs, plans,
ADRs, learnings, wiki, pulse reports, and retrospectives.

## Knowledge repo contract

Every Helm Product gets its own knowledge repo. The repo is the durable,
reviewable source of truth for product intent and agent-readable context. Helm's
runtime may cache or index this content, but reviewed markdown in git is the
canonical record.

```text
helm-knowledge/
|-- README.md
|-- strategy.md                  # durable product anchor
|-- .helm/
|   |-- product.yaml             # product config
|   `-- products.yaml            # optional multi-product registry
|-- discovery/                   # one lightweight artifact per item before spec
|-- specs/                       # approved product specs
|-- plans/                       # approved implementation plans
|-- decisions/                   # architecture decision records
|-- learnings/                   # reusable bug/process/implementation learnings
|-- wiki/                        # product wiki: architecture, runbooks, glossary
|-- pulse-reports/               # workflow health and cost pulse reports
|-- retrospectives/              # batch/session retrospectives
`-- ux-options/                  # reserved for UX Lab artifacts
```

## How agents use this repo

- Spec Writer reads `strategy.md`, relevant `discovery/` artifacts, `wiki/`,
  `decisions/`, and `learnings/` before drafting a spec.
- Plan Writer reads the approved spec plus `strategy.md`, `decisions/`,
  `wiki/`, and `learnings/` before drafting a plan.
- Implementer reads the approved plan plus relevant `learnings/` and `wiki/`
  entries before touching code.
- Reviewers can add or request new entries under `learnings/` when a finding
  reveals a reusable pattern.
- Workflow Pulse writes periodic reports under `pulse-reports/` using operational
  data from Helm's `data/` directory.

See [ADR-007](decisions/007-knowledge-compounding-contract.md) for the decision
behind this structure.
