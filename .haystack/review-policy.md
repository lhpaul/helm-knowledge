# Review Policies

## Onboarding runbook edits need human check
- **Paths**: `operations/onboarding-product.md`
- **Severity**: high
- **Reason**: Small doc mistakes here can cause operators to run commands in the wrong product or skip required setup values.

## Decision record changes need human review
- **Paths**: `decisions/**`
- **Severity**: medium
- **Reason**: These files define project rules and can introduce contradictions or risky assumptions that lint will not catch.

## Migration guide edits need manual validation
- **Paths**: `operations/migrations/**`
- **Severity**: high
- **Reason**: Migration instructions can cause irreversible naming or data handling mistakes if commands or sequencing are wrong.

## PR rule config changes are high impact
- **Paths**: `.haystack/pr-rules.yml`
- **Severity**: high
- **Reason**: Rule changes can hide real problems or create noisy false positives across every future pull request.

## Instructions
- If a change removes a fallback, rollback step, or safety warning in docs, a human should confirm the risk is still acceptable.
- If a change rewrites security or auth constraints, a human should check that the wording cannot be read in a way that weakens protections.
- If a change alters API status code meaning or stage transition error behavior, a human should confirm it still matches documented conventions.
