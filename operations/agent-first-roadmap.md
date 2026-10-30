# ADF, Helm, and Helm Core: agent-first roadmap

**Date:** 2026-10-30

**Status:** proposed execution plan for the agreed strategy

**Strategy:** [Helm strategy](../strategy.md)

## Goal and scope

Preserve ADF's existing supported capabilities, deliver the agreed remote-hub
and design outcomes, and test a simpler agent-first foundation for Helm. ADF
stabilization and Helm Core discovery can run in parallel; avoid duplicate
implementation and do not cut consumers over on the basis of a prototype.

This document is a prioritized plan, not evidence that a repository, board,
issues, or product changes have been created. Every issue below is a proposed
backlog entry until placed in its owning tracker. Verify current state, scope,
and dependencies before starting work.

## Portfolio and sequencing

| Priority | Owner | Outcome | Dependency / completion evidence |
| --- | --- | --- | --- |
| P0 | ADF + Helm | Reconcile both backlogs, supported consumers, and live state | Named tracker sources, owners, representative workflows, and outstanding risks |
| P0 | ADF | Investigate [hotfix review #2077](https://github.com/lhpaul/ai-dev-framework-template/issues/2077) and [CI credentials #1835](https://github.com/lhpaul/ai-dev-framework-template/issues/1835) | Verify current behavior and exposure; fix confirmed gaps or document disposition |
| P1 | ADF | Complete [remote hub epic #1719](https://github.com/lhpaul/ai-dev-framework-template/issues/1719) | Verify closed children; deliver [worker preflight #1721](https://github.com/lhpaul/ai-dev-framework-template/issues/1721); prove run-item, run-items and run-epic remote journeys |
| P1 | ADF + design owner | Use mockups as spec references and carry them through planning and implementation | Support snapshots and living sources; verify [spec asset readiness #1994](https://github.com/lhpaul/ai-dev-framework-template/issues/1994) |
| P1 | ADF + design owner | Propose implementation work from living mockup changes | Pilot [design-led epic #1667](https://github.com/lhpaul/ai-dev-framework-template/issues/1667), including human confirmation before item creation |
| P1 | Helm Core | Establish a minimal standalone experiment and run a real work-to-PR journey | Core setup, per-node workspace plan, and shared Helm board below; no dependency on the existing Helm service |
| P1 | Helm | Reconcile product vision, implementation, current deployments and pilots | Document actual usage and integration constraints; assess Fleet and Grok Bot without changing running services |
| P2 | ADF | Resolve other current-consumer blockers and release fixes | Verify reports on current versions; include Linear, batch, release or sync issues when the supported path is affected |
| P2 | Helm Core + Helm | Measure and decide whether to extend, integrate, or stop the experiment | Compare real journeys; record choice and evidence; no automatic migration |

Priorities indicate ordering and decision importance, not permission to bypass
repository policy, prescribed PRs, risk limits, or explicit human authority.
Select a small number of independent items at a time and re-evaluate after each
release. Do not freeze the existing backlog as a requirement to implement
every open issue; preserve supported workflows and triage each issue on merit.

## ADF delivery details

### 1. Establish the operating baseline

Inventory supported workflows and representative consumers, including releases,
sync, tracker use, delegated and batch merges, and multi-repo hubs. Record for
each journey its active version, owner, known blocker, and evidence. Preserve
existing consumer-specific configuration and verify deployment or adoption
separately from a template PR merge.

The 2026-10-30 snapshot found 154 open ADF issues, 70 not on Project 1, and
reopened [#1647](https://github.com/lhpaul/ai-dev-framework-template/issues/1647)
marked Released. Refresh these numbers. Reconcile issue status and duplicate
reports before changing the board; keep unselected work visible rather than
closing it merely to reduce counts.

### 2. Complete remote execution

For #1719, closed children #1462, #1378 and #1720 are starting evidence, not
proof of the complete current journey. Verify their behavior and deliver #1721:
hub/worker root and product paths resolve, required GitHub access works, and
failures are actionable before mutation. Exercise each of `/run-item`,
`/run-items`, and `/run-epic`, including parent-orchestrated fallback and model
pin behavior, in a representative hub. Record what was actually exercised.

### 3. Deliver both mockup outcomes

**Spec reference:** document and support static snapshots and living in-repo
sources without silently copying a living source into a stale snapshot. Specs
identify the intended reference and revision/context; planning and execution
can find it. Check #1994 against the current spec asset gate and fix it if
reproduced. An inaccessible required reference is reported as blocked.

**Living mockup to work:** pilot #1667 in a product repository. Review the
design diff and implementation tree, propose work grouped by implementation
unit, and obtain human confirmation before creating issues. Review the design
and breakdown together. Keep the epic's integration-branch approach: design
can run ahead there, and mockup plus implementation graduate together. Prove
the proposed invariant with an actual pilot; do not claim that a branch alone
guarantees visual or functional equivalence.

Relevant children: [#1668](https://github.com/lhpaul/ai-dev-framework-template/issues/1668),
[#1669](https://github.com/lhpaul/ai-dev-framework-template/issues/1669),
[#1670](https://github.com/lhpaul/ai-dev-framework-template/issues/1670), and
[#1671](https://github.com/lhpaul/ai-dev-framework-template/issues/1671).
Resolve #1670's open question about branch-creation ownership before
implementation. [#1672](https://github.com/lhpaul/ai-dev-framework-template/issues/1672)
is a wide command rename and can follow functional delivery.
[#1470](https://github.com/lhpaul/ai-dev-framework-template/issues/1470) is not
a prerequisite to #1667; assess its portable viewer and manifest against the
pilot and template-fit decision.

### 4. Resolve additional blockers based on affected journeys

Candidates include [#2076](https://github.com/lhpaul/ai-dev-framework-template/issues/2076)
for Codex delegated review, [#1883](https://github.com/lhpaul/ai-dev-framework-template/issues/1883)
for reviewer stalls, [#1991](https://github.com/lhpaul/ai-dev-framework-template/issues/1991)
for sync bootstrap, and [#2048](https://github.com/lhpaul/ai-dev-framework-template/issues/2048),
[#2049](https://github.com/lhpaul/ai-dev-framework-template/issues/2049),
[#2050](https://github.com/lhpaul/ai-dev-framework-template/issues/2050) for
specific merge/release routes. Select by actual affected consumer, reproduce on
current code, and identify a workaround or release outcome. Verify the current
state of [#2068](https://github.com/lhpaul/ai-dev-framework-template/issues/2068)
before continuing its in-progress work. Pause unrelated adapter expansion.

## Helm product assessment

1. Inventory current Helm code and knowledge-repo revisions, actual deployments,
   active consumers, product configurations, and pilot outcomes. Distinguish
   historical roadmap statements from currently verified behavior.
2. Reconcile [Helm Project 3](https://github.com/users/lhpaul/projects/3) with
   open issues and relevant roadmap commitments. The 2026-10-30 snapshot had
   one open Helm issue, [#62](https://github.com/lhpaul/helm/issues/62), and
   unrelated completed entries on the board; neither the count nor a Done
   field alone proves product readiness. Do not move or close items without
   verifying ownership.
3. Map what Helm currently provides—product context, dashboard, stages,
   runtimes, reviews, tracker sync, and design vision—to user outcomes. Record
   operational cost, current users, and compatibility obligations.
4. Review current ADF-local-reviewer dependency and other provider integrations.
   Compare their guarantees and failure modes with the Core experiment; do not
   remove a safeguard before a tested replacement and migration decision.
5. Maintain current operational ADRs until specifically superseded by reviewed
   decisions. Plan adoption only after the experiment proves the relevant paths.

## Helm Core setup

The intended name is **Helm Core**; `helm-core` is the proposed repository
name. The repository and backlog have not been created as part of this plan.
The name was clear in the owner's repositories on 2026-10-30; it is also used
elsewhere, so publication/branding requires a separate name check.

Before setup, decide the owning account, repository visibility, licensing,
default branch and protected-branch rules. Do not put
secrets or machine-specific credentials in the repository. A separate repo is
the proposed isolation boundary for the experiment, not a separate product.

The setup deliverable should contain:

- A short README and charter linking Helm's strategy, the experimental status,
  non-goals, and the decision gate; identify maintainers and contribution flow.
- Minimal agent instructions: outcome, repository context, authority, review,
  escalation, completion evidence, and project tool discovery. The user's and
  consumer repository's instructions retain precedence.
- A minimal project-owned configuration/example with no credentials. Document
  how to detect absent tools, permissions, and review capabilities.
- A PR-based contribution and Conventional Commit policy, a reproducible quick
  start, and only the smallest validation checks that prove the experiment.
- Create Helm Core issues in its own repository and add them to the shared
  [Helm Project 3](https://github.com/users/lhpaul/projects/3). Use the board's
  repository field or views to distinguish Helm and Core, populate applicable
  project fields, and link ADF and Helm dependencies. Verify actual auto-add
  rules and tracker synchronization before relying on them. Helm's existing
  issue-creation helper and stage writeback must not be assumed to work for Core.
- Add `helm-core` to the Helm workspace after the repository exists, using a
  path appropriate to each machine. Inventory the intended nodes, local
  workspace ownership, checkout paths, and how workspace files are distributed;
  update each selected node's own copy through its proper source of truth.
  Verify the workspace opens and resolves Helm, Helm Knowledge, Core and required
  project folders on each configured node. Report absent or inaccessible nodes
  separately; do not claim multi-node completion based on one computer.
- A disposable or explicitly selected pilot repository, with a safe scope and
  clear distinction between mock fixtures and live integrations.

Do not add a dashboard, server, mandatory state machine, provider adapter
catalog, or broad automation infrastructure as setup prerequisites. A concrete
pilot finding may justify a narrow addition later.

### Dev Fleet and Grok Bot integration assessment

Fleet controls where agents run and how operators reach them. Its current
published node schema requires per-project local paths, permitted directories,
an agent choice, and a `motor` of `adf` or `helm`; it does not currently name
Helm Core as a motor. Before enabling a Core run through Fleet, inspect the
current version and decide whether an existing mode actually fits or a small
Fleet change is needed. Record per-node readiness and only configure the nodes
and permissions the user authorizes. Do not invent a new motor value in a live
config or restart services as part of planning.

The existing Grok Bot Helm Dev brief targets isolated Helm and Helm Knowledge
checkouts and Project 3. It explicitly avoids using the shared Helm workspace
for its sessions because that workspace can include the checkout serving Helm
AF. During setup, verify the brief and current live policy, then decide whether
Helm Dev should cover Core or a separately scoped agent is needed. If coverage
is selected, update the relevant agent brief and launch configuration through
their owning repositories, with an isolated Core checkout, repo-qualified issue
identity, applicable permissions, and an explicit scope. Preserve the existing
per-item authorization and service boundaries unless the user changes them.
The existing brief contains historical reviewer and PR references; verify them
against current Helm policy rather than copying them as current facts.

For each selected integration, record whether work is required, the owning repo
and issue, target node, version and validation evidence. Fleet and Grok Bot
integration is not assumed to be a prerequisite for the standalone Core pilot;
when the user selects either for actual operation, its node-specific setup and
validation become prerequisites for that operation.

## Proposed initial Helm Core backlog

These are issue-ready proposals. IDs, sizing, and estimates are intentionally
not invented; create tracker items after selecting the tracker and confirming
dependencies.

| Order | Proposed issue | Acceptance / evidence | Depends on |
| --- | --- | --- | --- |
| C0 | Bootstrap Helm Core repository, shared backlog and node workspaces | Agreed ownership and visibility; charter, contribution rules and minimal checks; Core issues on Helm Project 3; Helm workspace updated on each selected node or an explicit pending-node record | Setup choices, node access |
| C1 | Define the agent work contract | Outcomes, scope/authority, human decision boundaries, review independence, completion evidence and unavailable states; a reviewer can apply it to a real task | C0 |
| C2 | Discover project context and available capabilities | Find repository conventions and tracker/reviewer capabilities; demonstrate actionable missing-tool and missing-access outcomes without calling missing review clean | C1 |
| C3 | Deliver a real bounded work item to a reviewable PR | Work item → change → appropriate independent review → tests → current-revision evidence; record interventions and elapsed time | C1–C2, pilot repository |
| C4 | Carry a mockup into product definition | Spec links a selected visual reference with enough revision/context to review; distinguish snapshot and living source; report inaccessible input | C1–C2, design reference |
| C5 | Propose work from a living mockup diff | Compare design change and implementation structure, group proposed items by implementation unit, preserve human confirmation before tracker creation; pilot and document limitations | C4, pilot mockup and implementation tree; coordinate ADF #1667 |
| C6 | Prove interruption and tool-unavailability behavior | Interrupt a representative run; demonstrate honest state and safe continuation without asserting uncertain remote actions succeeded or replaying them blindly | C3 |
| C7 | Compare Core with ADF and Helm and record recommendation | Document comparable journeys, time, interventions, review findings, failures, recovery, and portability; recommend integrate, iterate, or stop | C3–C6, baseline observations |
| C8 | Assess Fleet and Grok Bot integration | Verify current Fleet motor and per-node config, assess Helm Dev agent scope and isolated checkouts, record required changes or no-change decision and owning backlog; validate selected integrations before use | C0; access to the selected nodes and runtime |

C3 and C4 may proceed independently after their prerequisites. C5 is a pilot
of the agreed behavior, not permission to create live issues without the
required human confirmation. C6 must exercise actual relevant boundaries;
mocked tests alone do not establish live-provider behavior.

## Milestones and decision gates

**M0 — Portfolio baseline:** safety reports have a verified disposition;
existing consumers and their supported workflows are mapped; tracker drift is
reconciled or explicitly listed. Establish baseline measurements before
claiming improvement.

**M1 — Deliver current needs:** #1719 has end-to-end evidence; spec references
and the design-led mockup pilot have demonstrated both outcomes. Required ADF
fixes are released and consumer adoption is tracked separately.

**M2 — Core proof:** C3–C6 produce reviewable artifacts and demonstrate their
stated behaviors on a representative pilot, including unavailable and
interrupted cases. Any live and simulated evidence is labeled accurately.

**M3 — Architecture and migration decision:** compare delivery time, human
interventions, material defects and review signal, interruption recovery,
maintenance surface, and compatibility. Choose to integrate, iterate, or stop;
identify concrete migration work per consumer and an owner before any cutover.
No claim that every vendor or ADF capability is already supported.

## Governance and documentation ownership

This repo owns the cross-project strategy and roadmap; ADF Project 1 owns ADF
work; Helm Project 3 is the shared product board for Helm and Helm Core. Issues
belong in their respective code repositories; use repository-qualified IDs,
board views and links to distinguish them. Fleet changes belong in the Fleet
backlog, and Grok Bot agent-brief changes in their owning repository. Link
dependencies across trackers and designate one implementation owner per
outcome. Reconcile state from live repos and boards before execution. Use PRs
for repository changes and keep existing user authority and risk limits.
