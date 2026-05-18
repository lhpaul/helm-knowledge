# Onboarding a new Product into Helm

This runbook covers how to register a second (or third, etc.) Product in Helm v0.
Follow these steps in order. Estimated time: 30–60 minutes.

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
  org: <github-org>
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

## Step 3 — Set up the GitHub Project custom field

Run `ensureSubStages` to create the "Helm Stage" single-select field in the GitHub Project:

```bash
curl -X POST http://localhost:4000/api/admin/ensure-substages \
  -H "Content-Type: application/json" \
  -d '{ "productSlug": "<product-slug>" }'
```

> **Note:** The `/api/admin/ensure-substages` endpoint will be added in a future session.
> For now, manually create the "Helm Stage" single-select field in the GitHub Project UI
> with these 9 options (exact spelling matters):
> `discovery`, `spec-draft`, `spec-ready`, `plan-draft`, `plan-ready`,
> `in-development`, `code-review`, `remediation`, `released`

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

# Should return an empty array (no items yet)
curl http://localhost:4000/api/products/<product-slug>/items
```

---

## Step 7 — Create seed items (optional, primary product only)

> **Warning:** `POST /api/items` currently writes items for the **primary product**
> (`getProductConfig()` slug), not the newly-onboarded product. Using this step for
> a newly-registered product will place items under the wrong `productSlug` and produce
> misleading validation results. Multi-product item creation will be added in Session 8.
>
> To verify the new product is registered, skip to the `curl` commands in Step 6 above
> (`GET /api/products` and `GET /api/products/<product-slug>/items`).

If you specifically want to seed the **primary** product for other reasons:

```bash
curl -X POST http://localhost:4000/api/items \
  -H "Content-Type: application/json" \
  -d '{
    "externalId": "issue_1",
    "triggeredBy": "human:<your-github-handle>"
  }'
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `GET /api/products` only returns one product | `products.yaml` not found or empty | Check the file exists at `$HELM_KNOWLEDGE_REPO_PATH/.helm/products.yaml` |
| New product returns 404 | Slug in products.yaml path doesn't match `product.slug` in its `product.yaml` | Verify the slug in both files matches |
| "Cannot read file" error on startup | Sibling layout broken — repos not in same parent dir | Check `dirname($HELM_KNOWLEDGE_REPO_PATH)/<product>-knowledge/.helm/product.yaml` exists |
| "Invalid product.yaml" error | Schema validation failure | Run the product.yaml through the Helm validator (v1 TODO) or check all required fields |
