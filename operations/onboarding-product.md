# Onboarding a new Product into Helm

This runbook covers how to register a second (or third, etc.) Product in Helm v0.
Follow these steps in order. Estimated time: 30–60 minutes.

---

## Account types — read this first

The onboarding procedure is the same for both account types, but **real-time sync
behaviour differs**:

| Account type | Example | Webhook support | Real-time sync |
|---|---|---|---|
| **Organization-owned Project** | `acme-corp/mome-platform` | ✅ Configure org webhook → Helm receives item events automatically | Yes — items update in Helm as soon as they change in GitHub |
| **Personal-account Project** | `lhpaul/helm-playground` | ❌ GitHub does not expose `projects_v2_item` webhooks for personal accounts | No — run `pnpm --filter @helm/api sync <slug>` manually after changes |

> **For personal accounts:** skip the webhook configuration steps. Use the sync
> command (Step 4.5) whenever you want to pull the latest item state from GitHub.
> This is the expected workflow for local development; production deploys should
> use org-owned Projects.

---

## Prerequisites

- A GitHub org or personal account to host the new product's repos.
- A GitHub Project (v2) created for the product — note the project number.
- Helm server running locally (`pnpm run dev` in `apps/api/`).
- Both knowledge repos cloned side-by-side on your machine:
  ```text
  ~/projects/
  ├── helm-knowledge/               ← HELM_KNOWLEDGE_REPO_PATH
  └── <new-product>-knowledge/      ← sibling directory
  ```

---

## Env vars

Helm runs under Turborepo, which uses **strict env mode**: only variables declared
in `turbo.json:globalPassThroughEnv` are forwarded to task processes. Anything not
listed is stripped before the API process starts.

The canonical list (`turbo.json`):

| Variable | Used by |
|---|---|
| `GITHUB_TOKEN` / `GH_TOKEN` | GitHub Projects adapter, sync command |
| `LINEAR_API_KEY` | Linear adapter |
| `GITHUB_WEBHOOK_SECRET` | GitHub webhook signature verification |
| `LINEAR_WEBHOOK_SECRET` | Linear webhook signature verification |
| `HELM_KNOWLEDGE_REPO_PATH` | Product registry + knowledge repo resolution |
| `HELM_DATA_DIR` | Item/job persistence (defaults to `./data`) |
| `ANTHROPIC_API_KEY` | `claude_code` specialist runtime |
| `OPENAI_API_KEY` | `codex` specialist runtime |
| `CODEX_API_KEY` | `codex` specialist runtime (alternate) |
| `CODEX_ACCESS_TOKEN` | `codex` specialist runtime (alternate) |

> ⚠️ **Footgun:** Si agregás una env var nueva para algún adapter o specialist,
> también declarala en `turbo.json:globalPassThroughEnv` o no va a llegar al proceso
> de la API. Bajo el modo estricto de Turbo el proceso arranca igual pero con la
> variable en `undefined`, así que el síntoma es un adapter/runtime que "no ve" su
> token sin ningún error de arranque.

---

## Step 1 — Create the knowledge repo

Create a new GitHub repository for the product's knowledge base. Convention:
`{org}/{product-slug}-knowledge`.

```bash
gh repo create lhpaul/<product-slug>-knowledge \
  --private \
  --description "Knowledge repo for <Product Name>"
```

Clone it as a sibling of `helm-knowledge`:

```bash
cd ~/projects
gh repo clone lhpaul/<product-slug>-knowledge
```

---

## Step 2 — Create `.helm/product.yaml`

Create the directory and config file inside the new repo:

```bash
mkdir -p ~/projects/<product-slug>-knowledge/.helm
```

Create `.helm/product.yaml` using the template below. Replace all `<...>` placeholders:

```yaml
helm_version: '0'
product:
  slug: <product-slug>         # e.g. "mome-platform" — lowercase alphanumeric + hyphens
  name: <Product Display Name>

issue_tracker:
  provider: github_projects
  org: <github-org-or-username>
  project_number: <n>          # the number from the GitHub Project URL
  custom_field_name: Helm Stage

code_repos:
  - url: https://github.com/<org>/<repo>
    default_branch: main
    role: app                  # app | docs | infra

knowledge_repo:
  url: https://github.com/<org>/<product-slug>-knowledge
  default_branch: main

workflow:
  stages_enabled:
    - discovery
    - spec-draft
    - spec-ready
    - plan-draft
    - plan-ready
    - in-development
    - code-review
    - remediation
    - merged
    - released
  designer_gate: skip          # skip | optional | required
  qa_gate: skip                # skip | smoke | regression
  readiness_gate: skip         # skip | warn | required (ADR-026). Pre-dispatch
                               # check that every role:app code_repo has a
                               # README + agent instructions (AGENTS.md /
                               # AGENT.md / CLAUDE.md) before the spec-writer
                               # runs. `required` blocks with 422 missing_context;
                               # `warn` logs and proceeds. Default skip.
  final_stage: released        # merged | released (ADR-032). Terminal stage for
                               # this product. Default `released`: an impl PR
                               # merge lands the item in `merged`, and it reaches
                               # `released` (shipped to users) only via the
                               # release trigger — the operator endpoint or the
                               # GitHub release.published webhook. Set `merged`
                               # for a product with NO user-facing release step
                               # (e.g. the playground): items terminate at
                               # `merged`, the release endpoint returns 409, and
                               # the release webhook is a no-op. The state
                               # machine is unchanged either way — this only
                               # gates whether items ever reach `released`.

specialists:
  # Specialist IDs are kebab-case (ADR-022). Older configs used snake_case
  # (spec_writer, …); those are now rejected — see the migration note in
  # operations/migrations/2026-05-31-specialist-id-kebab.md.
  # The map has nine specialists: the six builders/reviewers below plus three
  # remediators (spec-remediator, plan-remediator, code-remediator — ADR-024).
  # `remediation` was renamed to `code-remediator`; see the migration note in
  # operations/migrations/2026-06-01-remediator-naming.md.
  spec-writer:
    runtime: claude_code
    model: claude-sonnet-4-6
  plan-writer:
    runtime: claude_code
    model: claude-sonnet-4-6
  implementer:
    runtime: claude_code
    model: claude-opus-4-7
  code-reviewer:
    runtime: claude_code
    model: claude-sonnet-4-6
  security-reviewer:
    runtime: claude_code
    model: claude-sonnet-4-6
  test-reviewer:
    runtime: claude_code
    model: claude-sonnet-4-6
  # Early-stage remediators (ADR-024): iterate an already-published spec/plan PR
  # in-place from operator feedback. Operator-triggered, never auto-dispatched.
  # Cheaper models are fine — they apply targeted edits, not whole artifacts.
  spec-remediator:
    runtime: claude_code
    model: claude-haiku-4-5
  plan-remediator:
    runtime: claude_code
    model: claude-haiku-4-5
  # Code-review remediator (formerly `remediation`).
  code-remediator:
    runtime: claude_code
    model: claude-sonnet-4-6
```

> **All specialists must share one runtime.** The schema enforces that every
> entry in `specialists` uses the same `runtime` (all `claude_code` or all
> `codex`). Mixing runtimes is rejected at load time.

> **Codex host requirement: Codex CLI ≥ 0.136.0.** Products on `runtime: codex`
> require Codex CLI **0.136.0 or newer** on the host running the orchestrator.
> Helm invokes `codex exec --json -C <workdir>` and feeds the prompt over stdin;
> older CLIs (the removed `--print` shape, `< 0.133`) are not supported. See
> ADR-028.

### Extra hints (optional, per specialist)

Each specialist accepts an optional `extra_hints` list — terse, imperative
reminders injected as a `## Hints` section into *that specialist's* prompt for
*this product only* (ADR-023). Use it for patterns the specialist tends to miss
for the product, e.g. version pinning or formatter conventions:

```yaml
  specialists:
    plan-writer:
      runtime: codex
      model: gpt-5.4-mini
      extra_hints:
        - "Pin exact versions for runtime deps (Node, pnpm, TS, frameworks)."
        - "Reference CLAUDE.md sections only after verifying they exist in main."
    implementer:
      runtime: codex
      model: gpt-5.5
      extra_hints:
        - "Use Prettier with singleQuote: true and trailingComma: 'all'."
```

Constraints: each hint is 1–500 chars; max 20 hints per specialist. Order is
preserved as written, so list higher-priority reminders first.

**When to use `extra_hints` vs CLAUDE.md:**

- **CLAUDE.md** — canonical, prose, narrative context: *"what the product is"*.
- **`extra_hints`** — imperative, terse, reminders to the specialist: *"don't
  forget to do X"*. Reach for hints when a specialist keeps missing one specific
  pattern; reach for CLAUDE.md for the broader story.

Commit and push:

```bash
cd ~/projects/<product-slug>-knowledge
git add .helm/product.yaml
git commit -m "feat: add .helm/product.yaml for <Product Name>"
git push -u origin main
```

---

## Step 2.5 — Create the knowledge repo folders

Create the standard folders and seed docs expected by Helm specialists:

```bash
cd ~/projects/<product-slug>-knowledge
mkdir -p \
  discovery specs plans decisions learnings \
  wiki/architecture wiki/runbooks wiki/glossary wiki/onboarding \
  pulse-reports retrospectives ux-options
touch specs/.gitkeep plans/.gitkeep ux-options/.gitkeep
```

Add a `strategy.md` at the repo root. Start from this minimal template:

```markdown
# <Product Name> Strategy

- **Status**: Active
- **Last updated**: YYYY-MM-DD

## Target problem

<Who has what problem?>

## Our approach

<What is the product's guiding approach?>

## Primary users

<Who is this for?>

## Active tracks

- <current track 1>
- <current track 2>

## Key metrics

- <metric 1>
- <metric 2>

## Not working on yet

- <explicit non-goal>
```

For the rest of the folders, copy or adapt the README guidance from the Helm
knowledge repo:

- `discovery/README.md`
- `specs/README.md`
- `plans/README.md`
- `learnings/README.md`
- `pulse-reports/README.md`

Commit and push the knowledge skeleton:

```bash
git add strategy.md discovery specs plans decisions learnings wiki \
  pulse-reports retrospectives ux-options
git commit -m "docs: add Helm knowledge repo skeleton"
git push
```

---

## Step 3 — Create the "Helm Stage" custom field in the GitHub Project

Helm tracks workflow stages via a **single-select custom field** called "Helm Stage"
on the GitHub Project. This field must be created with the 9 canonical stage names
(exact spelling matters — the adapter maps option names to workflow stages).

> ⚠️ **If you copied an existing Project with `gh project copy`:** custom single-select
> fields are **not** cloned by GitHub. You must create "Helm Stage" manually even if
> the source project had it.

Create the field via CLI:

```bash
gh project field-create <project-number> \
  --owner <github-org-or-username> \
  --name "Helm Stage" \
  --data-type SINGLE_SELECT \
  --single-select-options "discovery,spec-draft,spec-ready,plan-draft,plan-ready,in-development,code-review,remediation,merged,released"
```

Verify the field was created:

```bash
gh project field-list <project-number> \
  --owner <github-org-or-username> \
  --format json \
  | jq '.fields[] | select(.name=="Helm Stage")'
```

Expected output: a JSON object with `id`, `name`, and `options`. If the result is
empty, the field was not created — retry the `field-create` command.

> **Alternative — GitHub UI:** Settings → Fields → New field → Single select. Add
> each stage name as an option in the exact order listed above.

---

## Step 3.5 — Add items as real Issues (not Draft Issues)

Helm's adapter only processes **real Issues** (`__typename: 'Issue'` in the GraphQL
response). **Draft Issues** (created via the Project UI "Add item" without a
repository) are silently skipped during sync and will not appear in Helm.

### Option A — Recommended: create Issue first, then add to Project

```bash
# 1. Create a real GitHub Issue in the code repo
gh issue create \
  --repo <org>/<repo> \
  --title "Hello world endpoint" \
  --body "Initial implementation of the health check endpoint."

# 2. Copy the issue URL from the output, then add it to the Project
gh project item-add <project-number> \
  --owner <github-org-or-username> \
  --url https://github.com/<org>/<repo>/issues/<issue-number>
```

### Option B — Convert existing Draft Issues to real Issues

If you already have Draft Issues in the Project, convert them before syncing.

**GitHub UI:** open each item → "Convert to issue" → select repository.

**CLI (GraphQL mutation):**

```bash
# 1. Find draft item node IDs
gh project item-list <project-number> --owner <owner> --format json \
  | jq '.items[] | select(.type=="DRAFT_ISSUE") | {id, title}'

# 2. Get the repository node ID
gh api graphql -f query='{ repository(owner:"<org>", name:"<repo>") { id } }' \
  --jq '.data.repository.id'

# 3. Convert each draft
gh api graphql -f query='
  mutation {
    convertProjectV2DraftIssueItemToIssue(input: {
      itemId: "<draft-item-node-id>",
      repositoryId: "<repository-node-id>"
    }) {
      item { id }
    }
  }'
```

---

## Step 4 — Register the product in `helm-knowledge`

Add an entry to `.helm/products.yaml` in this repo:

```yaml
# .helm/products.yaml
products:
  - path: .
  - path: ../<product-slug>-knowledge   # ← add this line
```

Commit and push via PR:

```bash
cd ~/projects/helm-knowledge
git checkout -b feature/register-<product-slug>
# edit .helm/products.yaml
git add .helm/products.yaml
git commit -m "feat: register <product-slug> in multi-product registry"
git push -u origin feature/register-<product-slug>
gh pr create --title "feat: register <product-slug>" --base main
```

Merge after review.

---

## Step 4.5 — Hydrate existing items

Use the sync command to import items from the GitHub Project into Helm. This step is
**required for personal-account Projects** (no webhook support) and optional for org
Projects with pre-existing items.

```bash
# Run from the helm repo root
pnpm --filter @helm/api sync <product-slug>
```

**Requirements:**
- `GITHUB_TOKEN` must be set with read access to the GitHub Project.
- `HELM_KNOWLEDGE_REPO_PATH` must point to the primary knowledge repo.
- `HELM_DATA_DIR` is optional; defaults to `./data` relative to `apps/api/`.

**Example output:**
```text
[sync] Starting sync for product "helm-playground"…
[sync] product=helm-playground item=issue_1 title="Hello world endpoint" stage=discovery
[sync] product=helm-playground item=issue_2 title="CI pipeline" stage=spec-ready
Synced 2 items in 820ms
```

**Notes:**
- Idempotent: running multiple times is safe. Items with unchanged stage are skipped;
  items with a changed stage get a new transition event appended.
- Only real Issues are synced — Draft Issues are silently skipped (see Step 3.5).
- Items without a "Helm Stage" value are created at the initial stage (`discovery`).
- For org Projects, this is for initial hydration only — webhooks handle ongoing updates.
- For personal-account Projects, re-run this command whenever items change in GitHub.

---

## Step 5 — Restart the Helm server

The product registry is cached in memory. Restart the server to pick up the new entry:

```bash
# Ctrl+C the running server, then:
pnpm run dev
```

---

## Step 6 — Verify

```bash
# Should include the new product
curl http://localhost:4000/api/products | jq '.[].product.slug'

# Should return the product config
curl http://localhost:4000/api/products/<product-slug> | jq '.product'

# Should return the synced items (or empty array if no items yet)
curl http://localhost:4000/api/products/<product-slug>/items
```

---

## Step 7 — Create seed items (optional, primary product only)

> **Warning:** `POST /api/items` currently writes items for the **primary product**
> (`getProductConfig()` slug), not the newly-onboarded product. Multi-product item
> creation will be added in Session 8.
>
> To add items to a newly-registered product: create Issues in GitHub (Step 3.5),
> then run `pnpm --filter @helm/api sync <slug>`.

---

## Operational endpoints

### Rollback a failed implementer dispatch (ADR-029)

Use this endpoint to move an item from `in-development` back to `plan-ready` after
an implementer dispatch fails and leaves the item stuck in `in-development`
(for example: a Codex CLI crash, an image-tool defect, or an environmental wedge
during the dispatch). It re-opens the item for re-planning and re-dispatch.

**Do not change an item's stage by hand-editing `<helm-data>/items/<id>.json`.**
Manual edits skip the concurrency guard and the history entry; always use this
endpoint.

**Preconditions (all must hold, else the call is rejected):**

- The item's current stage **must** be `in-development` (else `400`).
- No dispatch job may be running for the item (else `409` with `runningJobId` —
  wait for the running job to finish or fail first).
- The item must exist for the product (else `404`).

```bash
curl -X POST http://localhost:4000/api/items/<externalId>/rollback \
  -H 'Content-Type: application/json' \
  -d '{"fromStage":"in-development","toStage":"plan-ready","reason":"codex image-tool crash, $0 cost"}'
```

The **only** permitted pair is `in-development → plan-ready` (pinned by strict
schema literals); `reason` is required (1–500 chars) and is recorded in the item
history as `triggeredBy: 'manual:rollback'`.

**Verify the rollback completed:**

```bash
# The current stage should now be 'plan-ready'
curl -s http://localhost:4000/api/items | \
  jq '.[] | select(.externalId == "<externalId>") | .currentStage'
# Expected output:
# "plan-ready"

# The latest history entry should record the manual rollback + your reason
curl -s http://localhost:4000/api/items | \
  jq '.[] | select(.externalId == "<externalId>") | .history[-1]'
# Expected (timestamps will differ):
# {
#   "fromStage": "in-development",
#   "toStage": "plan-ready",
#   "triggeredBy": "manual:rollback",
#   "at": "2026-06-03T22:30:00.000Z",
#   "note": "codex image-tool crash, $0 cost"
# }
```

### Promote a `merged` item to `released` (ADR-032)

Once an item's impl PR has merged, it sits in **`merged`** (PR merged, not yet
shipped to users). Moving it to **`released`** (shipped) is an explicit action —
it does **not** happen automatically on merge. There are two ways to do it.

> **Opt-out products** (`workflow.final_stage: merged`) have no `released`
> stage: the endpoint below returns `409` and the release webhook is a no-op.
> Items terminate at `merged`.

**A. Manual — promote one item.** A normal forward edge (`merged → released`);
no force/escape valve involved.

**Preconditions (all must hold, else the call is rejected):**

- The item's current stage **must** be `merged` (else `400`).
- The product must have `final_stage: released` (else `409` — the product has
  no `released` stage).
- The item must exist for the product (else `404`).

```bash
curl -X POST http://localhost:4000/api/items/<externalId>/release \
  -H 'Content-Type: application/json' \
  -d '{"reason":"shipped in v1.2.0"}'
```

`reason` is **optional** (1–500 chars) and is recorded in the item history as
`triggeredBy: 'manual:release'`. Verify exactly as for rollback above — the
current stage should now be `"released"` and the latest history entry should
show `"fromStage": "merged", "toStage": "released", "triggeredBy":
"manual:release"`.

**B. Bulk — GitHub `release.published` webhook.** When you publish a GitHub
release (`action: published`) for the product's code repo, Helm promotes
**every** item currently in `merged` to `released` in one shot
(`triggeredBy: 'webhook:release'`). This rides the existing
`POST /api/webhooks/github` endpoint and signature scheme — no extra endpoint
to configure. It works for Linear products too (they still ship via GitHub
releases). The promotion is idempotent: items not in `merged` are skipped, and
a per-item failure is logged without failing the delivery. Use the manual
endpoint (A) when you need to ship a single item without cutting a release.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `GET /api/products` only returns one product | `products.yaml` not found or empty | Check the file exists at `$HELM_KNOWLEDGE_REPO_PATH/.helm/products.yaml` |
| New product returns 404 | Slug in products.yaml path doesn't match `product.slug` in its `product.yaml` | Verify the slug in both files matches |
| "Cannot read file" error on startup | Sibling layout broken — repos not in same parent dir | Check `$HELM_KNOWLEDGE_REPO_PATH/../<product>-knowledge/.helm/product.yaml` exists |
| "Invalid product.yaml" error | Schema validation failure | Check all required fields are present and correctly typed |
| `Could not resolve to an Organization with the login of 'X'` | Running a Helm version prior to Session 7.5 against a personal-account project | Update Helm to Session 7.5+, which uses `repositoryOwner()` instead of `organization()` |
| `Synced 0 items` after a successful sync | Items in the GitHub Project are Draft Issues, not real Issues | Convert drafts to Issues (Step 3.5 Option B), then re-run sync |
| `API rate limit already exceeded` | Too many GraphQL requests in a short window | Wait for the reset window: <code>gh api rate_limit --jq '"resets at " + (.resources.graphql.reset &#124; strftime("%H:%M:%S"))'</code> |
