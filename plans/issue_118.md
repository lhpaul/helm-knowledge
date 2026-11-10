# issue_118 — Implementation Plan

## Overview
Add an optional per-specialist `timeout_sec` to the product schema and feed it into the spawn params of every specialist.

## Implementation Steps
1. `packages/shared/src/config/product-schema.ts`: add `timeout_sec: z.number().int().positive().max(7200).optional()` to `SpecialistSchema`.
2. New `packages/orchestrator/src/specialists/timeout.ts` with `resolveSpecialistTimeoutMs(product, specialistId, fallbackMs?)`.
3. Use it in the param builders: spec-writer and plan-writer (no fallback, so the runtime default applies), implementer, code-remediator, early remediators, review-adjudicator and reviewer-fanout (existing constants as fallback).
4. Document the field and the defaults in `docs/product-config.md`; CHANGELOG `[Unreleased]` entry.

## Files to Touch
- `packages/shared/src/config/product-schema.ts` (+ test)
- `packages/orchestrator/src/specialists/{timeout,spec-writer,plan-writer,implementer,remediation,early-remediator,review-adjudicator,reviewer-fanout}.ts`
- `docs/product-config.md`, `CHANGELOG.md` (helm repo)

## Test Strategy
Schema tests (absent, valid, invalid values); helper tests; spec-writer and plan-writer `SpawnParams.timeoutMs` undefined by default and equal to the configured value (ms) when set.

## Risks / Open Questions
- Low risk: optional field, defaults unchanged. The 7200 s cap bounds runaway sessions.
