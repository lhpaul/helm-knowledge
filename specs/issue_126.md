# issue_126 — Specification

## Context
ADR-004 left item-store namespacing as a known v1 limitation. `ItemStore` writes `data/items/{externalId}.json` with no product namespace. Each GitHub Project has its own issue sequence, so two Products sharing one data root routinely produce the same `externalId` (`issue_1`, ...). The second write silently overwrites the first product's workflow state.

## Acceptance Criteria
- Items are persisted at `data/items/{productSlug}/{externalId}.json`; the flat `data/items/{externalId}.json` layout is no longer written.
- Two Products in the same data root with the same `externalId` keep independent state (create, transition, list, get never cross products).
- Existing flat files are migrated automatically and idempotently on first store access, each into the namespace named by the `productSlug` stored in the file. A single-product deployment with existing data keeps working with no operator action.
- Migration never overwrites an existing namespaced file, never deletes data it could not move, and skips (with a log line) files that are unparseable or whose `productSlug` is missing/unsafe.
- `ItemStore` is scoped to one product slug; `getItemStore(productSlug)` returns a per-slug store. Slugs are validated as safe path segments (path-traversal safe).
- Tests cover collision isolation, scoped list, slug validation, and the migration (happy path, idempotency, conflicts, bad files, single-product upgrade).
- ADR-004 limitation note, `docs/local-dev.md` data layout and CHANGELOG `[Unreleased]` are updated.

## Technical Notes
- Rename (not copy) on migration so there is a single source of truth; rollback is moving files back up one level (documented).
- Callers already know the product slug (product config or registry), so the slug is passed explicitly rather than inferred.
- No change to the `ItemState` shape or HTTP API.
