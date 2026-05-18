# ADR-004: Multi-product registry via `products.yaml`

**Date:** 2026-05-17
**Status:** Accepted
**Context:** Session 7 — Multi-product end-to-end

---

## Context

Helm v0 started single-product: one `HELM_KNOWLEDGE_REPO_PATH` → one `product.yaml` → one
Item store. Session 7 introduces a second product (`helm-playground`) and requires the server
to discover and serve multiple Products without breaking existing single-product deployments.

---

## Decision

Add an optional `.helm/products.yaml` registry file to the primary knowledge repo. The server
reads this file to discover all registered Product knowledge repositories.

### Registry format

```yaml
# $HELM_KNOWLEDGE_REPO_PATH/.helm/products.yaml
products:
  - path: .                              # this repo itself
  - path: ../helm-playground-knowledge  # sibling repo (one level up, then into sibling)
```

Each `path` is resolved **relative to `HELM_KNOWLEDGE_REPO_PATH` itself** (the knowledge repo
root). `path: "."` resolves to the knowledge repo; `path: "../other"` resolves to a sibling
directory of the knowledge repo. Absolute paths are also accepted.

### Discovery algorithm (in `getProductRegistry()`)

1. Read `$HELM_KNOWLEDGE_REPO_PATH/.helm/products.yaml`.
2. For each `path`, resolve it to an absolute path and load `{path}/.helm/product.yaml`.
3. Return the ordered list of `Product` objects.
4. **If `products.yaml` is absent (ENOENT):** fall back to `[getProductConfig()]` — the
   existing single-product behavior. Zero breaking changes for single-product deployments.

### New API endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/products` | All registered Products |
| GET | `/api/products/:slug` | One Product by slug |
| GET | `/api/products/:slug/items` | Items for that Product |

Legacy endpoints (`/api/product`, `/api/items`) remain unchanged.

---

## Alternatives considered

### `data/products.json` in the operational data directory

Rejected: the data directory is ephemeral scratch space, not a source of truth. Product
configuration belongs with the knowledge repositories (version-controlled, auditable).

### Scan a `HELM_PRODUCTS_BASE_PATH` directory for `*/.helm/product.yaml`

Rejected for v0: directory scanning is implicit and hard to reason about ordering. An explicit
registry file is more predictable and easier to audit.

### Multi-value env var (`HELM_PRODUCT_REPOS=/path1:/path2`)

Rejected: env vars are not version-controlled. Operators can't review changes to the product
list via PR.

---

## Consequences

### Positive

- Zero breaking changes: existing single-product deployments work without adding `products.yaml`.
- All product configuration remains in version-controlled knowledge repos.
- Clear audit trail for adding/removing Products (git history on `products.yaml`).

### Negative / limitations

**Sibling layout assumption:** Paths in `products.yaml` are relative to the knowledge repo
root (`HELM_KNOWLEDGE_REPO_PATH`). The path `../helm-playground-knowledge` therefore resolves
to a directory that is a sibling of `helm-knowledge` — both repos must be cloned into the same
parent directory. If repos are in different locations, absolute paths must be used (those won't
be portable between machines). Future fix: support git URLs with clone-on-demand (v2+).

**externalId collision (Known Limitation):** The Item Store uses `data/items/{externalId}.json`
(flat, no product namespace). Because each GitHub Project has its own independent issue number
sequence, two Products will routinely have items with the same `externalId` (e.g., both will
have `issue_1`, `issue_2`, etc.). The second write to `data/items/issue_1.json` silently
overwrites the first, corrupting the earlier product's state. This is a real correctness risk,
not merely a theoretical one.

**v1 fix path:** Namespace item files as `data/items/{productSlug}/{externalId}.json`. A
migration script will rename existing files. The `ItemStore` constructor will accept a
`productSlug` scoping parameter.

---

## TODO (v1)

- [ ] Support optional `stage_labels` in `product.yaml` for per-product display names
      (e.g., `discovery` displays as "Backlog" in the UI). Internal stages remain canonical.
- [ ] Namespace item storage by productSlug to eliminate externalId collision risk.
- [ ] Support git URLs in `products.yaml` with local cache/clone-on-demand.
