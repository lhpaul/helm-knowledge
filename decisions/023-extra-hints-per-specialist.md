# ADR-023: Per-specialist `extra_hints` in `product.yaml`

**Date:** 2026-05-31
**Status:** Accepted
**Context:** Session H4 — gaps de iteración y readiness del piloto Arriendo Fácil

---

## Context

Helm builds each specialist's prompt at dispatch time from a fixed template plus
product context (README + AGENT.md/CLAUDE.md via `fetch-product-context`). When a
specialist repeatedly misses a product-specific pattern, there was no structured
way to remind it *persistently for that product*.

The Arriendo Fácil pilot surfaced two concrete instances:

- The **plan-writer** did not pin exact dependency versions even though the README
  implied it.
- The **implementer** used double quotes in Prettier where the repo convention is
  single quotes.

Both required manual patches that persistent, per-specialist reminders would have
avoided.

The pre-existing options were both unsatisfying for this:

- **CLAUDE.md** — narrative prose; long, and the agent can fail to honour a buried
  line among paragraphs of context.
- **Prompt template** — edits there apply to *every* product, not just the one with
  the recurring miss.

What was missing is the intermediate level: reminders scoped to **one specialist,
one product**.

---

## Decision

Add an optional **`extra_hints`** field to `SpecialistSchema` in `product.yaml`.

```yaml
specialists:
  plan-writer:
    runtime: codex
    model: gpt-5.4-mini
    extra_hints:
      - "Pin exact versions for runtime deps (Node, pnpm, TS, frameworks)."
      - "Reference CLAUDE.md sections only after verifying they exist in main."
```

1. **Schema.** `extra_hints` is an optional `string[]` on `SpecialistSchema`
   (`packages/shared/src/config/product-schema.ts`). Each hint is 1–500 chars; a
   specialist may have at most 20 hints. The bounds keep prompts from inflating
   unboundedly.

2. **Helper.** `buildExtraHintsSection(hints?)` in
   `packages/orchestrator/src/specialists/extra-hints.ts` renders the hints as a
   `## Hints` markdown section (empty string when unset), preserving YAML order so
   the operator can encode priority.

3. **Injection.** The section is injected into all five specialist prompt builders
   (spec-writer, plan-writer, implementer, the three reviewers via
   `reviewer-fanout`, and remediation). Each reviewer reads its own
   `extra_hints`. Order in the prompt is **Product Context → Task → Hints → operative
   instructions**: the agent reads what product/task it is on, then the reminders,
   then the concrete instruction, so a hint is never applied to the wrong task.

This is a **backwards-compatible** change — `extra_hints` is optional, so existing
`product.yaml` files are unaffected.

---

## Consequences

- Prompts grow slightly for products that opt in. Observability follow-up: count
  prompt tokens in dispatch logs so abuse (over-long hint lists) is visible.
- Hints live in `product.yaml` and are versioned with the rest of product config —
  changes are reviewed like any other config change.
- No semantic validation of hint *content* — it is free-form prose, trusted to the
  operator (only length/count are enforced).

---

## Alternatives considered

- **Global per-specialist hints (not product-scoped).** Rejected: the whole point is
  product-specific reminders. A global hint belongs in the prompt template.
- **More prose in CLAUDE.md.** Rejected: long narrative dilutes the important lines
  and is exactly the failure mode the pilot exposed.

---

## Guidelines — `extra_hints` vs CLAUDE.md

- **CLAUDE.md** = canonical, prose, narrative context — *"what the product is"*.
- **`extra_hints`** = imperative, terse, reminders to the specialist — *"don't forget
  to do X"*.

---

## References

- `packages/shared/src/config/product-schema.ts` — `SpecialistSchema.extra_hints`
- `packages/orchestrator/src/specialists/extra-hints.ts` — `buildExtraHintsSection`
- `operations/onboarding-product.md` — "Extra hints" section
