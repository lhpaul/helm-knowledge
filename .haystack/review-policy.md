# Review Policies

## Onboarding and operations runbook changes
- **Paths**: `operations/**`
- **Severity**: high
- **Reason**: Runbook edits can appear correct in review but still fail in real environments due to account type differences, webhook behavior, ingestion edge cases, or missing field setup that AI cannot validate end-to-end.

## Architecture decision record changes
- **Paths**: `decisions/**`
- **Severity**: medium
- **Reason**: ADR wording drives future implementation choices; subtle ambiguity in scope, tradeoffs, or revisit triggers can create long-lived architectural drift that automated checks will not catch.

## Instructions
- If a PR removes verification commands, guardrails, or explicit caveats from onboarding or operations docs, require human judgment on whether operational risk is still acceptable.
- If a PR changes GitHub Project onboarding steps (field creation, issue ingestion, or webhook behavior), require human review for compatibility across organization and personal account setups.
- If an ADR change weakens or omits alternatives, consequences, or revisit criteria, require human review to confirm the decision remains auditable and operationally safe.
