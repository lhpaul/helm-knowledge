# issue_129 — Specification

## Context
TD-001 (`operations/tech-debt.md`) is still open: the `externalId` validation regex `/^(?!\.)[A-Za-z0-9._-]+$/` is duplicated across `apps/api`, `@helm/orchestrator` and `@helm/shared`. Independent copies can drift, and the failure mode is a path-traversal validation gap on whichever surface lags behind.

## Acceptance Criteria
- A single implementation of `externalId` validation exists in `@helm/shared` (`EXTERNAL_ID_REGEX` and `isValidExternalId()`).
- `apps/api` and `@helm/orchestrator` use that implementation and keep no local copy of the regex.
- Validation behavior is unchanged: the same values are accepted and rejected.
- Existing tests stay green; error messages and API contracts do not change.
- TD-001 can be closed once this is merged. It is not closed by this item; it is closed after the merge.

## Technical Notes
- `@helm/shared` is the lowest-level package, so it is the source of truth. Both `apps/api` and `@helm/orchestrator` already depend on it.
- `apps/api/src/services/types.ts` re-exports `EXTERNAL_ID_REGEX` from `@helm/shared` so existing route and store imports keep working; the re-export is not a copy.
- The orchestrator's local `EXTERNAL_ID_SAFE` constants (including the one exported from `code-workspace.ts`) and the inline regex in the dispatcher are replaced by `isValidExternalId()`.

## Out of Scope
- Changing the accepted character set or error messages.
- Other validators (`JOB_ID_REGEX`, `SAFE_FS_PATH_REGEX`).
- Closing TD-001 (done after merge).
