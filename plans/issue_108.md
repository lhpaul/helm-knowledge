# #108 — Implementation plan

Source: specs/issue_108.md; ADR-036 and review-loop addenda.

1. Extend ProductSchema with local-ai-reviewer and strict local_ai_reviewer block.
2. Add adapter and injectable executor. Run trusted configured shell command with
   positional PR identity and --timeout, and a fresh private evidence file passed
   through LOCAL_AI_REVIEWER_EVIDENCE_FILE. Forward backend/mode in environment.
   Reference the upstream ADF companion on PATH (default local-ai-reviewer.sh).
   Operators may configure a wrapper to select the appropriate checkout.
3. Bound execution with AbortController, terminate the subprocess group on expiry,
   cap captured output, read evidence only after completion, then remove temp files.
   Reject mismatching evidence/stdout heads, verdicts or blocker counts. Preserve
   blocker bodies/path as normalized high blockers, with stable content IDs.
4. Wire provider in run.ts without changing internal-first order or deferred paths.
5. Test schema rejection/defaults, provider dispatch, clean/blocking normalization,
   stale/missing/malformed output, execution failures and real subprocess timeout.
6. Disable CodeRabbit auto-review, replace the narrow reviewer-loop section of
   AGENT.md, add CHANGELOG Unreleased entry and ADR-036 addendum/config rollback.
7. Run frozen install, lint, full tests and build. Commit/push feature branches
   from develop/main respectively; open linked PRs, run ADF local review against
   current heads where viable and verify CI. Do not merge either PR.

Risk: medium, additive provider behind existing interface; no deployment or
workflow changes. A missing installation safely consumes existing skip budget.
