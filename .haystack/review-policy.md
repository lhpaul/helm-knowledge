# Review Policies

## Onboarding runbook command changes
- **Paths**: `operations/onboarding-product.md`
- **Severity**: high
- **Reason**: Command and workflow edits can look correct in docs but fail in real GitHub Projects environments due to account-type constraints and behavior differences that AI cannot validate end-to-end.

## Review automation policy files
- **Paths**: `.haystack/pr-rules.yml`, `.haystack/review-policy.md`, `.haystack.json`
- **Severity**: high
- **Reason**: Misconfigured review-policy and merge-automation settings can silently change repository gatekeeping behavior even when checks pass.

## ADR decision documents
- **Paths**: `decisions/**`
- **Severity**: medium
- **Reason**: ADR wording can encode incorrect operational assumptions or missing scope constraints that pass linting but misguide future implementation decisions.

## Instructions
- If a PR changes GitHub Projects onboarding commands or sequence, a human should judge whether the steps were validated with a realistic smoke-test mindset, including field creation behavior, item types, account constraints, and verification commands.
- If a PR changes ADR guidance about runtime or async dispatch behavior, a human should verify the claims match observed implementation behavior or companion implementation changes.
- If a PR alters `.haystack` policy semantics, a human should judge whether the new rules change merge/review strictness in an acceptable way.
