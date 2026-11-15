# ADR-022: kebab-case is canonical for specialist IDs

**Date:** 2026-05-31
**Status:** Accepted
**Context:** Session C1 — Cleanup post-piloto del producto privado

---

## Context

The `specialists` map in `.helm/product.yaml` originally used snake_case keys
(`spec_writer`, `plan_writer`, `code_reviewer`, `security_reviewer`,
`test_reviewer`, plus `implementer` / `remediation` which have no separator).

Every other workflow identifier in Helm is kebab-case:

- **Workflow stages** — `spec-draft`, `plan-ready`, `in-development`, `code-review`.
- **Artifact branches** — `helm/spec/*`, `helm/plan/*`.
- **GitHub/Linear labels** — `helm:spec-draft`, `helm:code-review`.
- **`specialistId` values** produced by `STAGE_TO_SPECIALIST` — already kebab-case
  (`spec-writer`, `plan-writer`, `code-reviewer`, …).

So the config keys were the lone snake_case island. The dispatcher had to bridge the
two conventions by hand (e.g. looking up `product.specialists.spec_writer` while
emitting a `spec-writer` specialistId), which was an easy place to introduce typos
and made the mapping harder to read.

This surfaced during the private-product pilot (LEA-103) while wiring the Linear
adapter: the config-key/identifier mismatch was a repeated small friction.

---

## Decision

**kebab-case is the canonical and only accepted form for specialist IDs in
`product.yaml`.** The accepted keys are:

```
spec-writer
plan-writer
implementer
code-reviewer
security-reviewer
test-reviewer
remediation
```

1. **Schema.** `SpecialistsSchema` in `packages/shared/src/config/product-schema.ts`
   uses the kebab keys above and is `.strict()` — unknown keys (including the old
   snake_case ones) are rejected.

2. **Actionable migration error.** Because `.strict()` strips unknown keys before
   `superRefine` runs, a raw snake_case config would otherwise fail with a generic
   "unrecognized key" message. `parseProductConfig` therefore detects legacy
   snake_case keys *before* schema validation and throws a `ProductConfigError`
   that names each rename, e.g.:

   > Invalid product.yaml — "specialists": specialist IDs must use kebab-case
   > (e.g. 'spec-writer'). Rename 'spec_writer' → 'spec-writer', …. See ADR-022 and
   > the migration script in helm-knowledge/operations/migrations/.

3. **Call sites.** The orchestrator specialists, `reviewer-fanout`, and
   `runtime-factory` read the kebab keys directly via bracket access
   (`product.specialists['spec-writer']`).

This is a **breaking change** to the `product.yaml` format. There is no
auto-migration at load time — configs must be updated once. The migration is
mechanical (rename five keys) and covered by the script in
`operations/migrations/2026-05-31-specialist-id-kebab.md`.

---

## Consequences

- **One naming convention** across stages, branches, labels, `specialistId`, and
  config keys. The dispatcher no longer translates between two conventions.
- **Existing `product.yaml` files break loudly**, not silently — the parser names
  the exact renames, so the fix is copy-paste.
- **Docs and onboarding** (`operations/onboarding-product.md`) now ship the
  kebab-case template.

---

## Alternatives considered

- **Accept both forms (alias snake → kebab at parse time).** Rejected: it keeps two
  conventions alive indefinitely and hides the inconsistency instead of fixing it.
  Helm v0 has a tiny set of products, so a one-time mechanical rename is cheap.
- **Switch everything to snake_case instead.** Rejected: stages, branches, and
  labels are kebab-case and surface in GitHub/Linear UIs; those are the
  higher-cardinality, externally-visible identifiers, so config keys move to match
  them.

---

## References

- `packages/shared/src/config/product-schema.ts` — `SpecialistsSchema`
- `packages/shared/src/config/product-parser.ts` — legacy-key detection
- `operations/migrations/2026-05-31-specialist-id-kebab.md` — migration script
- `operations/onboarding-product.md` — updated template
