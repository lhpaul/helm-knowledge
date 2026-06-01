# Migration: specialist IDs → kebab-case (ADR-022)

**Date:** 2026-05-31
**Breaking:** yes — affects every `.helm/product.yaml`
**See:** [ADR-022](../../decisions/022-specialist-id-naming.md)

---

## What changed

The `specialists` map keys in `.helm/product.yaml` moved from snake_case to
kebab-case. Helm now **rejects** the old keys at load time with a message that names
each rename.

| Old (snake_case) | New (kebab-case) |
|---|---|
| `spec_writer` | `spec-writer` |
| `plan_writer` | `plan-writer` |
| `code_reviewer` | `code-reviewer` |
| `security_reviewer` | `security-reviewer` |
| `test_reviewer` | `test-reviewer` |
| `implementer` | `implementer` (unchanged) |
| `remediation` | `remediation` (unchanged) |

## How to migrate

For each `.helm/product.yaml` you own, rename the five keys. Only the keys directly
under `specialists:` change — values are untouched.

### One-liner (GNU sed / Linux)

```bash
sed -i -E 's/^( +)(spec|plan)_(writer):/\1\2-\3:/; s/^( +)(code|security|test)_(reviewer):/\1\2-\3:/' \
  .helm/product.yaml
```

### macOS (BSD sed)

```bash
sed -i '' -E 's/^( +)(spec|plan)_(writer):/\1\2-\3:/; s/^( +)(code|security|test)_(reviewer):/\1\2-\3:/' \
  .helm/product.yaml
```

> The leading-space anchor (`^ +`) keeps the substitution scoped to indented map
> keys, so it won't touch a `spec_writer` substring elsewhere in the file.

### Verify

```bash
# Should print nothing — no snake_case specialist keys remain
grep -nE '^ +(spec_writer|plan_writer|code_reviewer|security_reviewer|test_reviewer):' \
  .helm/product.yaml

# Confirm Helm accepts it (no ProductConfigError on startup / sync)
pnpm --filter @helm/api sync <product-slug>
```

If you skip the migration, Helm fails fast with:

> Invalid product.yaml — "specialists": specialist IDs must use kebab-case
> (e.g. 'spec-writer'). Rename 'spec_writer' → 'spec-writer', … . See ADR-022 …

## Scope

Only LH-owned products are migrated as part of Session C1. Other products migrate
on their own schedule — they will get the actionable error above until they do.
