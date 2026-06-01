# Migration: `remediation` → `code-remediator` + add spec/plan remediators (ADR-024)

**Date:** 2026-06-01
**Breaking:** yes — affects every `.helm/product.yaml`
**See:** [ADR-024](../../decisions/024-spec-plan-remediator.md)

---

## What changed

The `specialists` map in `.helm/product.yaml` grows from **seven to nine** entries:

1. The code-review remediator key is **renamed** `remediation` → `code-remediator`.
   Helm now **rejects** the old `remediation` key at load time with a message that
   names the rename (same mechanism as ADR-022).
2. Two **new** specialists are added: `spec-remediator` and `plan-remediator`. The
   nine-entry schema means a config missing them fails validation.

The `remediation` **workflow stage** (`workflow.stages_enabled`) is **unchanged** —
only the specialist *config key* moves. Do **not** rename the stage.

| Old specialist key | New specialist key |
|---|---|
| `remediation` | `code-remediator` |
| _(none)_ | `spec-remediator` (new) |
| _(none)_ | `plan-remediator` (new) |

> Reminder: all nine specialists must share one `runtime` (all `claude_code` or all
> `codex`) — the schema rejects mixed runtimes.

## How to migrate

For each `.helm/product.yaml` you own:

1. Rename the `remediation:` specialist key to `code-remediator:` (value untouched).
2. Add `spec-remediator` and `plan-remediator` entries.

### Step 1 — rename `remediation` → `code-remediator`

Only the key directly under `specialists:` changes — the value (runtime/model/hints)
is untouched. The address range `/^specialists:/,/^[^[:space:]]/` confines the
substitution to the `specialists:` block (from that line until the next top-level
key), and the leading-space anchor (`^ +`) restricts it to an indented map key.
Together they leave the `remediation` **stage** line under `stages_enabled` alone
(it's a list item `- remediation`, not a `remediation:` key) and won't touch any
indented `remediation:` key that might live in another block.

#### GNU sed (Linux)

```bash
sed -i -E '/^specialists:/,/^[^[:space:]]/ s/^( +)remediation:/\1code-remediator:/' .helm/product.yaml
```

#### macOS (BSD sed)

```bash
sed -i '' -E '/^specialists:/,/^[^[:space:]]/ s/^( +)remediation:/\1code-remediator:/' .helm/product.yaml
```

### Step 2 — add the two new remediators

`sed` is the wrong tool for inserting structured blocks; add these by hand under
`specialists:` (cheaper models are fine — remediators apply targeted edits, not
whole artifacts):

```yaml
  spec-remediator:
    runtime: claude_code        # must match every other specialist's runtime
    model: claude-haiku-4-5
  plan-remediator:
    runtime: claude_code
    model: claude-haiku-4-5
```

> If your product uses `codex`, set `runtime: codex` (and a codex model) on **all
> nine** specialists — the schema rejects a mixed-runtime map.

### Verify

```bash
# Should print nothing — no `remediation:` specialist key remains
# (the `- remediation` stage line is fine and will NOT match).
grep -nE '^ +remediation:' .helm/product.yaml

# Should print all three remediators
grep -nE '^ +(spec|plan|code)-remediator:' .helm/product.yaml

# Confirm Helm accepts it (no ProductConfigError on sync)
pnpm --filter @helm/api sync <product-slug>
```

If you skip the rename, Helm fails fast with:

> Invalid product.yaml — "specialists": specialist IDs must use kebab-case
> (e.g. 'spec-writer'). Rename 'remediation' → 'code-remediator'. See ADR-022 …

If you skip adding the new remediators, the schema rejects the config for the
missing required keys.

## Scope

Only LH-owned products are migrated as part of Session H2. Other products migrate on
their own schedule — they will get the actionable errors above until they do.
