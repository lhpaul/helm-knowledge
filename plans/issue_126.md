# issue_126 — Implementation Plan

## Overview
Scope `ItemStore` by product slug and migrate legacy flat item files.

## Implementation Steps
1. `ItemStore(itemsRoot, productSlug)`: validate slug (`^[a-z0-9-]+$`), store files under `{itemsRoot}/{slug}/`, create the directory lazily, `create()` rejects a mismatching `productSlug`.
2. Add `migrateLegacyItems(itemsRoot)` (rename flat `*.json` into `{productSlug}/`, idempotent, conflict- and bad-file-safe, returns a report).
3. `getItemStore(productSlug)` in `services/index.ts`: per-slug cache, single-flight, runs the migration once per process before the first store is returned.
4. Update all callers (routes, webhooks, dispatch, scheduler, merge-reconciliation, item-service) to pass the slug they already hold.
5. Update tests/mocks; add item-store and migration tests.
6. Docs: ADR-004 note, `docs/local-dev.md`, CHANGELOG.

## Files to Touch
- `apps/api/src/services/item-store.ts`, `item-store-migration.ts` (new), `index.ts`, callers listed above, their tests.
- `docs/local-dev.md`, `CHANGELOG.md`, `decisions/004-multi-product-registry.md` (knowledge).

## Test Strategy
Vitest on temp dirs: two slugs same externalId, scoped list, invalid slug, migration scenarios, caller tests with updated mocks. `pnpm lint && pnpm test`.

## Risks
Medium: persisted-data change. Mitigated by non-overwriting rename, idempotency and tests; rollback documented.
