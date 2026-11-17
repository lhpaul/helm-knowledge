# Helm release policy

**Date:** 2026-11-17

**Issue:** [lhpaul/helm#150](https://github.com/lhpaul/helm/issues/150) —
spec [issue_150](../specs/issue_150.md), plan [issue_150](../plans/issue_150.md)

**Status:** proposal. Section 2 lists what is already in force; everything in
sections 3–6 is proposed and takes effect only when the owner approves it. No
release, tag, branch, workflow, branch protection or board field was created
or changed for this document. Open decisions are in section 7.

**Source:** [product evaluation, decision 2](product-evaluation-2026-11.md#7-decisions-for-the-owner)

## 1. Current state

Read-only snapshot taken on 2026-11-17 with git and `gh`: `lhpaul/helm`
`develop` at `5b751fd`, this repo `main` at `b0fdba2`.

| Fact | Evidence |
| --- | --- |
| No tags and no GitHub releases | `git tag`, `gh release list`, tags API: empty |
| `main` holds only the three scaffold commits of 2026-05-11 (`43fe698`). `develop` is 394 commits ahead and 0 behind, so `main` is an ancestor of `develop` | `git rev-list --left-right --count origin/main...origin/develop` |
| Default branch is `develop`. No PR has been merged into `main` | Repository settings; `gh pr list --base main --state merged` is empty |
| PRs are merged with merge commits. The repository allows merge, squash and rebase | `git log --merges`; repository settings |
| `main` and `develop` have no branch protection and no rulesets | Branch protection API returns 404; rulesets API is empty |
| CI (`lint` with type-check, and `test`) runs on every pull request and on pushes to `develop`, not on pushes to `main`. There is no release workflow | `.github/workflows/ci.yml` |
| `CHANGELOG.md` follows Keep a Changelog and SemVer but has only `[Unreleased]`, with about 80 entries in repeated `Added`, `Changed`, `Fixed` and `Removed` groups (3, 4, 4 and 1) | `CHANGELOG.md` |
| `HELM_VERSION` in `packages/shared` is `0.0.0`, and `/health` returns it as `version`. All workspace packages are private and at `0.0.0` | Code at `5b751fd` |
| `helm_version: "0"` in `.helm/product.yaml` is the config schema version (`z.literal('0')`), not a release version | `packages/shared` product schema |
| The production instance runs a dedicated checkout of `develop` that the owner pulls and restarts by hand, so its running revision is not recorded | [Production-instance runbook](production-instance.md); evaluation section 4, item 5 |
| Project #3 has `Status` (Todo, In Progress, Done) and `Helm Stage` (the ten workflow stages, ending `merged`, `released`). `released` is set on #71, #73 and #82 from the July orchestrator runs, before any tag existed | Project field list; evaluation section 6 |

## 2. Already in force

These rules exist today and this proposal keeps them:

- **Branch naming** (`AGENT.md`): `feature/*`, `fix/*`, `refactor/*` from
  `develop`; `hotfix/*` and `release/v*` are reserved for release work.
- **CHANGELOG** (`AGENT.md`): Keep a Changelog plus SemVer. Feature and fix
  PRs add their entry under `[Unreleased]` on `develop`; hotfixes write a
  versioned section directly.
- **Merge authority** (`AGENT.md`): the Helm Dev agent may merge its own low
  or medium risk PRs to `develop`. A PR that targets `main` or `release/*`, or
  is a `hotfix/*`, goes to the owner. Production is updated only by hand by
  the owner.
- **Stage semantics** ([ADR-032](../decisions/032-split-final-stage-merged-vs-released.md)):
  `merged` means the change is merged; `released` means it is shipped. On a
  Helm instance that receives a repository's webhooks, a published GitHub
  release moves every `merged` item of that product to `released`.
- **Knowledge repos are trunk-based** ([branch-rulesets guide](branch-rulesets-setup.md)):
  this repo has no releases; a change is in effect when it merges to `main`.

One inconsistency: `AGENT.md` says `release/v*` branches start from `main`,
while the ADF template and the branch-rulesets guide start them from
`develop`. This proposal starts them from `develop` (decision D5).

## 3. Versioning (proposed)

- **Scheme:** SemVer `MAJOR.MINOR.PATCH`, tags `vX.Y.Z`.
- **First version:** `v0.1.0`, containing everything on `develop` at the cut.
  Helm stays in `0.y.z` while its contract can still change.
- **Public contract** (what a version number speaks for): the `product.yaml`
  schema, the HTTP API and webhook endpoints, the environment variables, the
  layout of `HELM_DATA_DIR`, operator scripts such as `pnpm sync-env`, and the
  supported Node, Bun and pnpm versions.
- **Bump rules while in `0.y.z`:**
  - an incompatible change to the contract bumps `y` and must carry an upgrade
    note;
  - a new capability bumps `y`;
  - fixes and internal changes only bump `z`.
- **`1.0.0`** is cut when the owner declares the contract stable (decision D2).
  From then on, standard SemVer applies.
- **Version source:** the release PR sets `HELM_VERSION` in `packages/shared`,
  which `/health` already reports. Private workspace packages stay at `0.0.0`
  (decision D3). The config schema version `helm_version` changes only when the
  schema itself is versioned, independently of releases.

## 4. Release flow (proposed)

### Trigger

Releases are on demand, with no fixed calendar. A release is due when any of
these holds:

1. a change on `develop` is needed on a deployed instance (instances run tags,
   section 6);
2. an incompatible change to the contract has merged, so it ships on its own
   with its upgrade note;
3. `[Unreleased]` has user-visible entries older than about four weeks.

An agent may propose a release when a trigger holds. The owner decides.

### Steps

Invariant: `main` is always an ancestor of `develop`. It holds today.

1. **Branch.** Create `release/vX.Y.Z` from the current `develop`.
2. **Cut the CHANGELOG.** Rename `[Unreleased]` to
   `## [X.Y.Z] - YYYY-MM-DD`, add a new empty `## [Unreleased]` above it, merge
   repeated category groups into one `Added`, `Changed`, `Deprecated`,
   `Removed`, `Fixed` and `Security` list, and put an **Upgrade notes** list
   first when the release changes the contract (config, env vars, data layout,
   runtime versions). Add Keep a Changelog compare links at the end of the
   file.
3. **Set the version.** Set `HELM_VERSION` to `X.Y.Z`.
4. **Release PR.** Open a PR from `release/vX.Y.Z` to `main`. Its body lists
   the issues included and the upgrade notes. CI runs on it. The local AI
   reviewer may be skipped for the release PR when it only contains the
   CHANGELOG cut and the version bump (ADF does the same for `release/*`);
   anything else in it needs a normal review.
5. **Merge.** The owner merges it with a merge commit (not squash), so the
   history on `main` is the history on `develop` (decision D4).
6. **Tag.** Create an annotated tag `vX.Y.Z` on that merge commit and push
   it.
7. **Publish.** Create the GitHub release from the existing tag
   (`gh release create vX.Y.Z --verify-tag`) with the CHANGELOG section as its
   notes.
8. **Back-merge.** Open a PR that merges `main` into `develop`, so `develop`
   gets the CHANGELOG cut and the version and the invariant still holds.
9. **Board and record.** Update Project #3 (section 5) and record the new
   version in the owner's private operations notes.

Steps 1–4 and 8 can be prepared by an agent. Steps 5–7 are the owner's, or
an agent's under an explicit authorization for that one release.

### Hotfixes

For a defect that must be fixed on a deployed version before the next release:

1. create `hotfix/<slug>` from `main` (that is, from the latest tag);
2. fix it and write a new `## [X.Y.Z+1] - YYYY-MM-DD` section directly below
   `[Unreleased]`, and set `HELM_VERSION`;
3. PR to `main`; the owner merges it; then tag and publish as in steps 6–7;
4. merge `main` back into `develop` through a PR, resolving the CHANGELOG so
   the hotfix entry appears only in its versioned section.

### Announcement

The GitHub release is the announcement: notes, upgrade notes and a link to
the release PR. Each consumer's operator reads it before updating. No other
channel is required (decision D7).

## 5. "Released" in Project #3 (proposed)

| Field | Value | When |
| --- | --- | --- |
| `Status` | `Done` | When the item's work is merged and the issue is closed. Unchanged from today. |
| `Helm Stage` | `merged` | When the item's PR merges into `develop` of `lhpaul/helm`. |
| `Helm Stage` | `released` | When a published GitHub release of `lhpaul/helm` contains that merge (`git tag --contains <merge>` names it). Set as step 9 of the release. |

- **Items only in this repo** (documentation, specs, policies) are trunk-based
  and never released: their terminal `Helm Stage` is `merged`, as a product
  with `final_stage: merged` would be under ADR-032.
- **Items from other repositories** on the board (Helm Core, unrelated
  repositories) follow their own repository's policy; this one does not apply.
- **Automation.** No Helm instance receives `lhpaul/helm` webhooks today, so the
  ADR-032 release webhook does not fire and step 9 is manual. If Helm processes
  its own backlog again (evaluation decision 1), publishing the release moves
  the `merged` items automatically. The production instance receives webhooks
  from its consumer's repositories only (recorded in the
  [runbook](production-instance.md), not checked live), so publishing a Helm
  release does not change the consumer's items.
- **Existing items.** `v0.1.0` will contain everything merged so far, so on
  publication every `Done` item from `lhpaul/helm` can be set to `released`,
  including #71, #73 and #82, whose value then becomes accurate. Before that,
  no field is changed. Whether to set `Helm Stage` on items the orchestrator
  did not process is decision D6.

## 6. Updating and rolling back an instance (proposed)

Generic for any Helm deployment. The private runbook of each instance supplies
the concrete service, paths and ingress.

A deployed instance runs a tag, not a branch. Its checkout is used only to
serve it (development uses separate clones), and its running version is the
`version` that `/health` returns.

### Update to `vX.Y.Z`

1. **Read the release notes** and every version between the running one and
   the target, especially the upgrade notes.
2. **Choose a quiet moment.** A restart can interrupt a running specialist and
   drop webhooks sent while the API is down. Some trackers disable a webhook
   after repeated failed deliveries, so keep the restart short.
3. **Record the starting point:** the current `/health` version and the
   checked-out tag.
4. **Back up `HELM_DATA_DIR`** when the target release declares a data-layout
   change, or whenever in doubt.
5. **Check out the tag** in the serving checkout (fetch tags, then check out
   `vX.Y.Z`), and install dependencies from the lockfile
   (`pnpm install --frozen-lockfile`).
6. **Apply the upgrade notes:** new or renamed env vars (regenerate the env
   with `pnpm sync-env`), `product.yaml` changes, runtime version changes.
7. **Restart through the supervisor.** Do not start a second copy by hand.
8. **Verify:** `/health` returns `X.Y.Z`; run the smoke checks of the
   [runbook](production-instance.md#smoke-checks); confirm that the next
   webhook delivery succeeds.
9. **Record** the version in the instance's private operations notes.

### Roll back

1. Check out the previous tag recorded in step 3 and install from its
   lockfile.
2. Undo the env and `product.yaml` changes from step 6, if the old version
   cannot read them.
3. Restore the `HELM_DATA_DIR` backup only if the release notes say the new
   version writes data the old one cannot read. Restoring discards everything
   recorded since the backup, including items that moved meanwhile, so check
   the tracker afterwards.
4. Restart through the supervisor, verify as in step 8, and record the
   rollback.
5. File a fix on `develop`, or a hotfix if the previous version is not an
   acceptable place to stay.

A release whose data change cannot be rolled back without the backup says so
in its upgrade notes.

## 7. Open decisions for the owner

| # | Decision | Options | Recommendation |
| --- | --- | --- | --- |
| D1 | Adopt this policy | Adopt as written; adopt with changes; keep production on a hand-pulled `develop` and record that instead | Adopt. It answers evaluation decision 2 and makes the running version visible through `/health`. |
| D2 | First version and `1.0.0` | `v0.1.0` now; `v1.0.0` now | `v0.1.0`. Cut `1.0.0` when the contract is declared stable or a second consumer is onboarded. |
| D3 | Version source | `HELM_VERSION` only; also bump every workspace `package.json` | `HELM_VERSION` only. The packages are private and unpublished. |
| D4 | Merge method for release and back-merge PRs | Merge commit; squash | Merge commit. It matches current practice and keeps `main` an ancestor of `develop`. The squash-only setting in the branch-rulesets guide is for consumer product repos and stays as is. |
| D5 | `release/v*` branch base | From `develop`, as ADF does; from `main`, as `AGENT.md` says today | From `develop`, and correct `AGENT.md` in a separate PR. |
| D6 | `Helm Stage` for items the orchestrator did not process | Set it at merge and release for every `lhpaul/helm` item; use it only for items Helm processes | Set it for every `lhpaul/helm` item as part of the release, so `released` means the same thing on the whole board. |
| D7 | Announcement | GitHub release only; also another channel | GitHub release only while the owner is the only operator. |
| D8 | Who runs steps 5–7 | Owner always; an agent under explicit per-release authorization | Owner for `v0.1.0`; revisit after two releases. |
| D9 | Protection and automation | Protect `main` (PR required, no force push, no deletion); add a tag or release workflow | Protect `main` before the first release. Defer any release workflow until the manual flow has run at least twice. Both are separate changes. |

## 8. Proposed follow-ups

None of these was created. Each needs the owner's approval first.

1. Cut `v0.1.0` following section 4.
2. Correct the `release/v*` base in `AGENT.md` (D5).
3. Protect `main` of `lhpaul/helm` (D9).
4. Switch the production instance from `develop` to the `v0.1.0` tag, and
   record the version in the private operations notes.
5. Once adopted, mark this document as in force and consider recording it as
   an ADR.
