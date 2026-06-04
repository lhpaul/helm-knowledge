# Branch rulesets — setup for Helm-driven code repos

Canonical GitHub branch ruleset configuration for any code repo that
Helm dispatches to (the "app" repo in `product.yaml.code_repos`).
Matches the **develop + main** branching pattern documented in the
[`ai-dev-framework-template`](https://github.com/lhpaul/ai-dev-framework-template).

Use this when:

- **Onboarding a new product** to Helm — configure the rulesets before
  the first `spec-writer` dispatch lands a PR.
- **Migrating an existing trunk-based product** to develop+main (e.g.
  Arriendo Fácil migrated 2026-06-03; see the corresponding entry in
  `operations/migrations/`).

The setup creates **two rulesets** per code repo: `helm-develop` (the
integration branch) and `helm-main` (the release branch). Knowledge
repos stay trunk-based (decisions/learnings don't need release
branching) and are out of scope.

---

## Prerequisites

- The `develop` branch exists in the repo. If not, create it first:

  ```bash
  cd <your-clone>
  git checkout main && git pull
  git checkout -b develop
  git push -u origin develop
  ```

- The repo's **default branch is `develop`** (GitHub → Settings → General
  → Default branch → switch to `develop`). Required so Helm
  specialists' PRs target the right branch via the `default_branch`
  field in `product.yaml`.

- You have admin permission on the repo (rulesets are an Admin-tier
  setting).

---

## Ruleset 1 — `helm-develop`

GitHub UI: **Settings → Rules → Rulesets → New branch ruleset**.

| Field | Value |
|-------|-------|
| **Ruleset Name** | `helm-develop` |
| **Enforcement status** | **Active** (NOT Disabled — Disabled means the rules don't apply, only document intent) |
| **Bypass list** | Empty (add yourself only if you anticipate emergencies; as a solo dev you can edit the ruleset anyway) |
| **Target branches** | `develop` (single target, exact match) |

### Branch rules — toggle by toggle

▶ = activate, ✗ = leave off.

| Rule | Setting | Rationale |
|------|---------|-----------|
| Restrict creations | ✗ Off | `develop` already exists; no need to block future branch creation patterns |
| Restrict updates | ✗ Off | Updates go through PRs (covered by "Require pull request") |
| **Restrict deletions** | ▶ **On** | Protects `develop` from accidental delete |
| Require linear history | ✗ Off | "Allowed merge methods" already controls this — redundant |
| Require deployments to succeed | ✗ Off | No deploy environment wired by default (enable if/when CI deploys are configured) |
| Require signed commits | ✗ Off | Helm specialists commit via PAT, which doesn't sign by default; adds friction without security benefit at this stage |
| **Require a pull request before merging** | ▶ **On** | Essential — all changes flow through PRs |
| ↳ Required approvals | **1** | Operator approves each PR (this IS the Helm workflow) |
| ↳ Dismiss stale PR approvals on new commits | ✗ Off | Helm's pre-merge loop pushes fixes during review; this on would force re-approval after every push — unnecessary friction |
| ↳ Require review from specific teams | ✗ Off | No teams defined |
| ↳ Require review from Code Owners | ✗ Off | No `CODEOWNERS` file (add later if multi-contributor) |
| ↳ Require approval of the most recent reviewable push | ✗ Off | Same friction as dismiss-stale |
| ↳ Require conversation resolution before merging | ✗ Off | Helm reviewers + CodeRabbit post comments programmatically; resolving each manually = friction without value |
| ↳ **Allowed merge methods** | **Squash only** | Match the canonical convention (see ai-dev-framework-template + product `CLAUDE.md` §11). Uncheck Merge + Rebase; leave only Squash |
| **Require status checks to pass** | ▶ **On** | Documents intent; binds when CI is wired |
| ↳ Require branches up to date before merging | ▶ **On** | Prevents merging a PR that's behind `develop` |
| ↳ Do not require status checks on creation | ✗ Off | Default |
| ↳ Add checks | **Empty initially** | Add specific check names (e.g. `lint`, `typecheck`, `test`) when GitHub Actions CI is wired into the repo |
| **Block force pushes** | ▶ **On** | Protects `develop` history |
| Require code scanning results | ✗ Off | No code-scanning tool integrated (configure when one is) |
| Require code quality results | ✗ Off | Same |
| Automatically request Copilot code review | ✗ Off | Helm reviewers + CodeRabbit cover this surface; Copilot would be redundant |

Click **Create**.

---

## Ruleset 2 — `helm-main`

Back to Rulesets → **New branch ruleset**. Same general pattern as
`helm-develop` but stricter (`main` is the release branch).

| Field | Value |
|-------|-------|
| **Ruleset Name** | `helm-main` |
| **Enforcement status** | **Active** |
| **Bypass list** | Empty |
| **Target branches** | `main` |

### Differences vs `helm-develop`

Everything from the `helm-develop` table applies — these are the **only
deltas** for `helm-main`:

| Rule | Setting in `helm-main` | Rationale |
|------|------------------------|-----------|
| **Restrict updates** | ▶ **On** | Only via PR — block direct pushes to `main` (release branch must stay deployable) |
| **Require linear history** | ▶ **On** | `main` should stay squash-only; this enforces no merge commits |
| Required approvals | **1** | Same as `develop` |
| **Allowed merge methods** | **Squash only** | Same as `develop` — release PRs squash to `main` |

Everything else identical to `helm-develop`. Click **Create**.

---

## Verification

After creating both rulesets:

```bash
gh api repos/<owner>/<repo>/rulesets 2>&1 \
  | jq '.[] | {id, name, enforcement, target}'
```

Expected output — two entries, both with `enforcement: "active"`:

```json
{ "id": <num>, "name": "helm-develop", "enforcement": "active", "target": "branch" }
{ "id": <num>, "name": "helm-main",    "enforcement": "active", "target": "branch" }
```

If either appears with `"enforcement": "disabled"`, open it in the UI
and switch Enforcement status → Active → Update ruleset.

---

## Interaction with Helm

After the rulesets are active, **update `product.yaml` in the
corresponding knowledge repo**:

```yaml
code_repos:
  - url: https://github.com/<owner>/<repo>
    default_branch: develop                # NOT main
    role: app
```

This tells Helm specialists (spec-writer, plan-writer, implementer,
reviewer-fanout) to clone `develop` and target it with their PRs.
Helm reads this on dispatch; restart the Helm API after the
`product.yaml` change so the registry picks it up:

```bash
lsof -i :3001 | awk 'NR>1 {print $2}' | xargs kill -9
cd ~/Git/Helm/helm
op run --env-file=apps/api/.env -- pnpm dev 2>&1 \
  | tee logs/helm-api-$(date +%Y%m%d-%H%M).log &
sleep 15
curl -s http://localhost:3001/api/products/<product-slug> \
  | jq '.product.code_repos[0]'
```

Expected: `"default_branch": "develop"`. If still `"main"`, restart was
incomplete or the registry cached — kill any zombie `pnpm dev`
processes and retry.

---

## Updating the product's `CLAUDE.md`

The product repo's `CLAUDE.md` typically has a §11 (or equivalent)
"Branching" section that documents the trunk-based pattern. Replace
that with the develop+main pattern; match the canonical wording from
the `ai-dev-framework-template`:

```markdown
### Branching

- **Develop + main.** `develop` is the integration branch (all
  feature/fix/refactor PRs target it). `main` is the release branch
  (only release and hotfix PRs target it).
- Features/improvements: `feature/<slug>` (from `develop`, back to `develop`).
- Refactors: `refactor/<slug>` (from `develop`, back to `develop`).
- Bug fixes (fast track): `fix/<slug>` (from `develop`, back to `develop`).
- Hotfixes (production-blocking only): `hotfix/<slug>` (from `main`,
  back to `main` + mandatory backport PR to `develop`).
- Releases: `release/v[X.Y.Z]` (from `develop`, to `main`, with a
  mandatory backport PR to `develop` to merge the version bump).
- Helm PRs: auto-generated branch names `helm/spec/<ID>`,
  `helm/plan/<ID>`, `helm/impl/<ID>`. Target `develop` by default
  (per `product.yaml.default_branch`). Do not touch manually.
```

Commit this to `develop` via a docs-only PR. It's the **first PR
through the new flow** — a good sanity check that branch rulesets
work as expected.

---

## When to deviate from this setup

The recommendations above are calibrated for **solo-dev pilot
products** (one operator, Helm-driven, no separate teams). Adjust if:

- **Multi-contributor team:** turn on `Require review from Code Owners`
  + add a `CODEOWNERS` file. Consider raising `Required approvals` to
  2 for `main`.
- **CI deploys:** wire `Require deployments to succeed` once you have
  a deploy environment (Railway, Vercel, etc.) with deployment status
  reports.
- **Signed commits required by org policy:** turn on `Require signed
  commits` + wire GPG/SSH signing on the operator + Helm PAT.
- **Knowledge repo:** the knowledge repo (where ADRs, learnings, and
  product specs live) typically stays **trunk-based on `main`** —
  decisions and learnings aren't released in cycles, they're appended
  monotonically. Skip this setup for knowledge repos.

---

## References

- [`ai-dev-framework-template`](https://github.com/lhpaul/ai-dev-framework-template) — canonical branching strategy this setup implements.
- `operations/onboarding-product.md` — registers a new product in Helm;
  branch rulesets are configured BEFORE the first specialist dispatch.
- `operations/migrations/` — migration entries for products that moved
  from trunk-based to develop+main mid-pilot.
