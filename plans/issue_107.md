# issue_107 — Implementation Plan

## Overview

Five bounded changes to the existing code-review loop, all attached to seams
that already exist. Nothing here restructures the reviewer fan-out, the
adjudicator, or the stop rule.

Ship order is A1 → A2 → A3 → C → B. A1–A3 and C are contained in
`packages/orchestrator`. B is the only one that crosses into `apps/api`
(webhook, item store, dispatch), so it lands last and can be dropped without
invalidating the rest.

Spec: [`specs/issue_107.md`](../specs/issue_107.md).
Decision: [ADR-043](../decisions/043-sticky-fidelity-churn-controls.md).

## Implementation Steps

### A1 — Catalogued suppression at the code-review gate

1. In `code-review-loop.ts`, drop the `params.mode !== 'early-artifact'` early
   return from `buildFalsePositiveReviewerCommentTransform` and
   `suppressFalsePositiveReviewerResults`. Both already resolve the stage via
   `stageForLoopParams`, which returns `code-review` outside early-artifact
   mode, so stage scoping (`Applies to:`) starts working for free.
2. Thread a severity ceiling into `suppressFalsePositiveReviewerComment`. In
   `code-review` mode the transform only rewrites lines at MEDIUM/LOW/INFO; a
   CRITICAL or HIGH line is returned untouched even on a catalogue match. In
   `early-artifact` mode there is no ceiling (unchanged behavior).
3. Leave the existing `suppressedCount === 0` guard in place so a no-match cycle
   returns the reviewer's own `reviewContent` and status object by reference —
   that is what keeps `CHANGES_REQUESTED` from flipping to `APPROVED`.
4. Verify placement: `suppressFalsePositiveReviewerResults` already runs before
   `shouldRemediate`, `countBlockingFindings`, and
   `collectGateFindingFingerprints`, and its result feeds `gateFanoutResult`.
   No call-site reordering is needed.

### A2 — Sticky theme groups

5. In `finding-fingerprint.ts` add `STICKY_THEME_GROUPS`: an ordered list of
   `{ id, members: [{ id, pattern }] }`. First and only group is
   `test-fidelity` with members `e2e-coverage`, `expo-router`, `maestro`,
   `unit-smoke`.
6. Write the member patterns tight enough not to fire on generic prose:
   `expo-router` requires the router token pair, `unit-smoke` requires the
   smoke-test phrasing, `e2e-coverage` requires `e2e`/`end-to-end`, `maestro`
   requires the tool name.
7. In `fingerprintFindingTitle`, match groups **first** and short-circuit: on a
   hit return the group id alone, skipping theme, path, and token composition.
   Everything else keeps ADR-038 §2 behavior.
8. Export `matchStickyThemeGroup(title)` returning `{ groupId, memberIds }` so
   A3 and B can label and explain a sticky fingerprint without re-deriving it.

### A3 — Unresolved sticky findings in prompts

9. Extend `StickyLane` with a `seen: Map<string, number>` cycle counter and a
    `records: Map<string, ParsedFinding-like>` last-seen title/severity map;
    update both inside `observeStickyLane` so each lane maintains its own with
    no call-site change. Add `unresolvedStickyFindings(lane)` returning entries
    with `cyclesSeen >= 2`, sorted by severity then cycles-seen.
10. Add `collectGateFindings(results, severity)` next to the existing
    `collectGateFindingFingerprints`, returning `ParsedFinding[]` (fingerprint,
    severity, title) so the loop can feed titles into the lane. Keep the
    fingerprint-set helper — `stop-rule` call sites keep using it.
11. New module `review-loop/sticky-prompt.ts`, modeled on `catalog-prompt.ts`:
    `formatStickyFindingsSection(entries, role)` for roles `remediator` and
    `adjudicator`, emitting JSON inside
    `---BEGIN/END_UNRESOLVED_STICKY_FINDINGS---` with backticks and the closing
    delimiter neutralized, followed by the role's policy lines. Returns `''`
    when the entry list is empty.
12. Policy lines for the remediator: a sticky finding previously reported as
    `Applied` was not applied; changing a different kind of artifact than the
    finding asks for is not a fix (a unit-test rewrite does not answer an
    end-to-end ask); an uncloseable one goes under `Deferred` with a reason. For
    the adjudicator: mark it `DEFERRED` with the sticky reason rather than
    re-issuing an `AUTO` line the previous cycle already failed to close.
13. In `code-review-loop.ts`, compute the unresolved-sticky list from the lane
    that produced the current blockers (internal for the fan-out branch,
    external for the `needs_fixes` branch) and pass it through
    `runRemediationPass` → `runAdjudicationIfEnabled` →
    `buildReviewAdjudicatorParams` / `buildRemediationParams` as a new
    `stickyFindings` option, alongside the existing `catalogEntries`.
14. For the external branch, build the same entry shape from
    `NormalizedFinding` (`id` as fingerprint, `summary` as title). Keep the two
    lanes' entries separate — never concatenate baselines (ADR-038 §3).

### C — Test-reviewer contract

15. In `reviewer-fanout.ts`, `case 'test'`, add the AC-citation requirement and
    the fidelity ceiling to `kindSpecificInstructions`: cite the AC a finding
    maps to or file it at LOW/INFO; a request for a higher-fidelity artifact
    than the AC requires (real device, end-to-end harness, framework runtime) is
    capped at LOW unless an AC names it. `code` and `security` prompts are not
    touched.

### B — Operator accept-finding

16. New module `review-loop/accept-finding.ts`:
    `parseAcceptFindingComment(body)` → `{ findingTitle, severity?, rationale,
    fingerprint }` or `null`. Accepts the `<!-- helm:accept-finding -->` marker
    plus labeled fields, tolerating the same field-name variants the
    product-decision parser tolerates. Fingerprint comes from
    `fingerprintFindingTitle`, so an accept covers reworded restatements — and,
    for a sticky theme group, the whole group.
17. Enforce the severity ceiling in the parser's consumer, not the parser:
    reject CRITICAL/HIGH before storage so an out-of-policy comment is ignored
    rather than half-recorded.
18. Add `AcceptedFinding` to `apps/api/src/services/types.ts` and
    `acceptedFindings?: AcceptedFinding[]` to `ItemState`. Add
    `ItemStore.upsertAcceptedFinding` mirroring `upsertResolvedProductDecision`:
    same `withItemLock`, idempotent by fingerprint, appends a history event with
    an `accepted-finding:<fingerprint>` idempotency key.
19. Add an `else if` branch to the `pull_request_comment_created` handler in
    `apps/api/src/routes/webhooks.ts`, after the product-decision branch and
    reusing its checks in the same order: repo match →
    `readGitHubTokenFromEnv` → author present → `authorHasWriteAccess` →
    `resolveOpenPrMetadata` → `parseArtifactBranch` is `impl` → item belongs to
    this product. Then `upsertAcceptedFinding`, and — only when the post-upsert
    stage is `code-review` — `scheduleItemDispatch('reviewer-fanout')` at the
    current head with `persistReviewDispatchIntent` fallback, exactly as the
    decision path does. Unauthorized/unmatched → `processed: true` with an info
    log; transient failure after an authorized accept → 503 so GitHub retries.
20. Plumb `acceptedFindings` / `loadAcceptedFindings` from
    `dispatch-scheduler.ts` through `dispatcher.ts` into
    `RunCodeReviewLoopParams`, mirroring the decision plumbing (snapshot plus
    per-cycle reload from the store).
21. In the loop, apply accepted findings alongside the catalogue: a matching
    internal finding is rewritten to `**INFO** · Accepted by operator:
    <summary>` with the same recount and status rewrite, and matching external
    blockers move into the advisory set. Match by comparing the accepted
    fingerprint against `fingerprintFindingTitle(summary)`.
22. In `advisory-disposition.ts`, resolve an accepted finding to disposition
    `Accepted` with the operator's rationale, ahead of the catalogue `Rejected`
    branch and the `Deferred` default.
23. Document the marker: `false-positives.md` header note pointing at it as the
    per-item alternative to a catalogue entry, and the review-loop runbook.

### Wrap-up

24. `CHANGELOG.md` under `[Unreleased]`.
25. `pnpm turbo run lint test build` green before the PR is marked ready.

## Files to Touch

**`packages/orchestrator`**

- `src/review-loop/code-review-loop.ts` — mode guards (A1), severity ceiling
  (A1), sticky list assembly and threading (A3), accepted-finding suppression
  (B).
- `src/review-loop/finding-fingerprint.ts` — sticky theme groups, group-first
  fingerprinting, `collectGateFindings`, lane cycle/record tracking,
  `unresolvedStickyFindings` (A2, A3).
- `src/review-loop/sticky-prompt.ts` — **new**, sticky prompt block (A3).
- `src/review-loop/accept-finding.ts` — **new**, marker parser (B).
- `src/review-loop/advisory-disposition.ts` — `Accepted` disposition (B).
- `src/specialists/remediation.ts` — `stickyFindings` option and section (A3).
- `src/specialists/review-adjudicator.ts` — same (A3).
- `src/specialists/reviewer-fanout.ts` — test-reviewer contract (C).
- `src/dispatcher.ts`, `src/index.ts` — accepted-finding plumbing and exports (B).
- Tests: `finding-fingerprint.test.ts`, `code-review-loop.test.ts`,
  `sticky-prompt.test.ts` (new), `accept-finding.test.ts` (new),
  `advisory-disposition.test.ts`.

**`apps/api`**

- `src/services/types.ts` — `AcceptedFinding`, `ItemState.acceptedFindings` (B).
- `src/services/item-store.ts` — `upsertAcceptedFinding` (B).
- `src/services/dispatch-scheduler.ts` — snapshot + per-cycle reload (B).
- `src/routes/webhooks.ts` — accept-finding branch (B).
- Tests: `item-store.test.ts`, `webhooks` route tests.

**Docs**

- `CHANGELOG.md`.
- `helm-knowledge/false-positives.md` — pointer to the per-item accept path.
- `helm-knowledge/operations/review-loop-smoke-test.md` — operator steps.

## Test Strategy

- **A1** — catalogued MEDIUM on a `code-review` fan-out result is demoted to
  INFO, blocker count drops, `shouldRemediate` returns false, no remediation
  dispatch; catalogued HIGH on the same PR is **not** demoted and still gates;
  the same catalogued HIGH in `early-artifact` mode is still demoted; a no-match
  cycle preserves the reviewer's `CHANGES_REQUESTED` verbatim; a stage-scoped
  entry (`Applies to: spec-draft`) does not fire on a code PR.
- **A2** — `fingerprintFindingTitle` returns `test-fidelity` for each of the
  four member phrasings; an Expo Router title and a Maestro title produce an
  identical fingerprint; a path in the title does not change it; existing
  tenant-isolation composition is unchanged; generic titles mentioning "unit" or
  "Expo" alone do not match.
- **A3** — nothing sticky on cycle 1; a finding present in two cycles appears
  once with `cyclesSeen: 2`; the block is absent from the prompt when the set is
  empty and present with the delimiters when not; a title containing the closing
  delimiter or backticks is neutralized; internal and external lanes render
  disjoint entry sets from the same loop run.
- **B** — parser accepts the marker with field variants and returns `null` for
  a comment missing title or rationale; CRITICAL/HIGH is refused; webhook
  ignores comments from a non-write-access author, a non-impl head ref, and a
  foreign repo, each without a 5xx; an authorized accept stores exactly one
  record and is idempotent on redelivery; recorded at stage `code-review`
  dispatches `reviewer-fanout`, at any other stage does not; a matching finding
  is demoted before `shouldRemediate`; a matching external blocker resolves to
  disposition `Accepted`.
- **C** — snapshot of the `test` reviewer prompt contains the AC-citation and
  LOW-ceiling lines; `code` and `security` prompts do not.
- **Regression** — full `packages/orchestrator` and `apps/api` suites; a product
  with no catalogue, no accepted findings, and no test-fidelity findings
  produces byte-identical prompts and identical loop behavior.

## Rollout

- Single app PR against `develop`, no feature flag. Every control is inert
  without a catalogue entry, a test-fidelity finding, or an operator comment, so
  the blast radius on a quiet product is zero.
- No `product.yaml` change is required. Arriendo Fácil's existing catalogue
  entry starts taking effect at the code-review gate the moment this merges —
  that is the intended outcome, and it is the one behavior change a product
  operator will notice without opting in.
- ADR-043 moves from `Proposed` to `Accepted` when the app PR merges.

## Risks / Open Questions

- **The MEDIUM cap is a judgment call, not a derivation.** #107 as filed asked
  for uncapped parity with `early-artifact`; the cap is what makes A1 an
  amendment to ADR-041 §4 rather than an override. If review prefers uncapped,
  it is a one-line change and an ADR-043 §1 edit — but ADR-041 §4's rationale
  then needs a different answer.
- **Group collapse is coarse by design.** Two unrelated coverage gaps report as
  one sticky item, so `no_progress` can fire while one of them is genuinely
  improving. ADR-038 §2 accepts this direction; the escalation still lands on a
  human.
- **An accept is a real dismissal.** A maintainer can silence a MEDIUM the
  reviewer was right about. Mitigations: write access required, MEDIUM ceiling,
  stored with author and timestamp, and item-scoped rather than product-wide.
- **Fingerprint reach of an accept is wider than one finding** when the title
  matches a sticky theme group — accepting one test-fidelity MEDIUM accepts the
  group for that item. Intended (that is what ends the churn), but it must be
  said plainly in the operator docs.
- **Webhook branch ordering** — the accept branch must not swallow comments the
  product-decision branch should handle. Both parsers require their own required
  fields, so a comment matching neither is ignored by both; the tests pin it.
- Related but out of scope: **lhpaul/helm#108** (external on-demand review /
  CodeRabbit cost). It touches the same loop and should not be folded in here.
