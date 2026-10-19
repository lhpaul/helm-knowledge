# #108 — Local external review after internals

Status: approved scope by LH, 2026-10-19 (devsession instructions).

## Problem and scope

Helm already invokes external review after internal fanout/remediation. CodeRabbit
App auto-review still bills on every push. Replace the dogfood external slot with
the ADF local AI reviewer, defaulting to the authenticated Codex CLI.

## Acceptance

- Add strict provider config: command, backend codex/http, timeout_sec, mode.
- Invoke the referenced ADF companion once per adapter call with bounded runtime.
- Normalize RESULT and BLOCKING\_\*; require exact reviewed_head == targetRevision.
- Missing/stale/malformed evidence, failed execution or timeout is unavailable,
  never clean. Preserve existing loop ordering and stop rules.
- Disable Helm CodeRabbit auto-review; document current-head local terminal evidence.
- Switch Helm knowledge config; keep codex-github/coderabbit rollback documented.
- Validate frozen install, lint, tests, and local review where viable; open PRs
  without merging. Propose #100 closure as superseded without closing it.

## Boundaries

No AF deployment, workflows, new secrets, internal reviewer replacement or loop
redesign. Refer to ADF scripts installed by the operator; no machine paths in git.
