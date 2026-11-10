# issue_119 — Implementation Plan

## Overview
Add per-specialist `permissions` to the product schema, pass them through `SpawnParams` to `ClaudeCodeRuntime`, and guarantee `USER`/`LOGNAME` in its env.

## Implementation Steps
1. `product-schema.ts`: `permissions` object (`add_dirs`, `allowed_tools`, `gh_api_read_only`, `allow_gh_mutations`) with refinements (absolute dirs, no `..`, no unrestricted Bash, gh rules need explicit opt-in, claude_code only).
2. `runtime.ts`: `SpawnParams.permissions` (`addDirs`, `allowedTools`, `disallowedTools`).
3. New `specialists/permissions.ts` with `resolveSpecialistPermissions`; use it in all SpawnParams builders.
4. `claude-code.ts`: emit `--add-dir`, `--allowedTools`, `--disallowedTools`; `_env.ts`: `ensureUserIdentityEnv`, called in `spawn`.
5. Docs (`docs/product-config.md`) and CHANGELOG `[Unreleased]`.

## Files to Touch
- `packages/shared/src/config/product-schema.ts` (+ test)
- `packages/orchestrator/src/{runtime.ts,runtimes/_env.ts,runtimes/claude-code.ts}` (+ tests)
- `packages/orchestrator/src/specialists/{permissions,spec-writer,plan-writer,implementer,remediation,early-remediator,review-adjudicator,reviewer-fanout}.ts`
- `docs/product-config.md`, `CHANGELOG.md`

## Test Strategy
Schema accept/reject cases; resolver mapping; Claude runtime args with and without permissions; USER/LOGNAME derivation and failure.

## Risks / Open Questions
- Risk medium: touches permissions, but opt-in, no bypass, no global settings, gh mutations need explicit opt-in.
