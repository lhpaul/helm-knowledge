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
    - released
  designer_gate: skip          # skip | optional | required
  qa_gate: skip                # skip | smoke | regression

specialists:
  spec_writer:
    runtime: claude_code
    model: claude-sonnet-4-6
  plan_writer:
    runtime: claude_code
    model: claude-sonnet-4-6
  implementer:
    runtime: claude_code
    model: claude-opus-4-7
  code_reviewer:
    runtime: claude_code
    model: claude-sonnet-4-6
  security_reviewer:
    runtime: claude_code
    model: claude-sonnet-4-6
  test_reviewer:
    runtime: claude_code
    model: claude-sonnet-4-6
  remediation:
    runtime: claude_code
    model: claude-sonnet-4-6
```

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
  --single-select-options "discovery,spec-draft,spec-ready,plan-draft,plan-ready,in-development,code-review,remediation,released"
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
