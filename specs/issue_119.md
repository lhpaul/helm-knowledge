# issue_119 — Specification

## Context
Writers on the `claude_code` runtime cannot read context outside their workdir or run read-only `gh api` calls, so they end in HUMAN_REQUIRED. The current workaround edits the operator's global CLI settings, which leaks into every session of that user. Separately, a runtime started under a service without `USER`/`LOGNAME` makes the Claude CLI report "Not logged in".

## Acceptance Criteria
- `product.yaml` accepts an optional `permissions` block per entry under `specialists:` with `add_dirs` (absolute paths, extra readable directories), `allowed_tools` (Claude tool rules) and `gh_api_read_only` (boolean).
- For `claude_code` specialists Helm applies them to the spawn as `--add-dir` and `--allowedTools` (plus `--disallowedTools` for the `gh api` guard). No global CLI settings file is read or written.
- Defaults are restrictive and backwards compatible: with no `permissions` block the CLI args are unchanged. Nothing here uses or enables `bypassPermissions`.
- `gh_api_read_only: true` allows `gh api` GET-style calls only; Helm denies method overrides, body/field flags, `--input` and `graphql`. Any other `gh` rule in `allowed_tools` is rejected by the schema unless the product sets `allow_gh_mutations: true` explicitly.
- Unrestricted shell rules (`Bash`, `Bash(*)`, `*`) are rejected by the schema.
- A `permissions` block on a `codex` specialist fails validation (it would be silently ignored).
- Helm guarantees `USER` and `LOGNAME` in the Claude subprocess env: a missing one is derived from the other or from the OS account; if neither is resolvable the spawn fails with a clear error instead of starting a session that ends in "Not logged in".

## Technical Notes
- Schema: `SpecialistSchema.permissions` (`.strict()`), validated in the schema; `resolveSpecialistPermissions(product, id)` maps it to `SpawnParams.permissions`.
- `ClaudeCodeRuntime.spawn` emits the flags; `ensureUserIdentityEnv` in `_env.ts` fills `USER`/`LOGNAME`.
- Every specialist builder passes the resolved permissions, as with `timeout_sec` (#118).
