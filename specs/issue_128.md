# issue_128 — Specification

## Context
The review loop's human merge gate depends on the GitHub label `ready-for-human-review` (ADR-040 §1, ADR-036). During #117 that label did not exist in the repository and had to be created by hand, so the gate could not be applied until someone intervened in GitHub.

## Acceptance Criteria
- A script in the Helm repo creates every label required by the merge gate when it is missing, including `ready-for-human-review`, and verifies it when present.
- The script is idempotent: running it twice changes nothing the second time.
- The script never edits, renames, recolors or deletes an existing label, and never touches branch protection or other repository settings.
- The required labels (name, color, description) are defined in one place and documented in the Helm repo docs.
- The docs name the script as the required preflight step for whoever applies the gate label (operator or runner), so no one has to create the label by hand. Today no Helm code applies the label (it is applied by the operator/runner after a clean reviewer loop), so there is no in-repo caller to wire; automating the application itself is out of scope.
- Which label enables the merge does not change.
- Unit tests cover create-when-missing, no-op-when-present and failure propagation using a fake `gh`, with no network.

## Technical Notes
- Required set for v0: `ready-for-human-review` only. Labels such as `review-loop` and `adr-036` are organizational, not gate-required.
- Implementation is a bash script using `gh label list/create`; no new secrets, no workflow changes. Permission needed: label write on the target repo (same token used to apply the label).
- Target repo defaults to `lhpaul/helm` and can be overridden with `--repo`.

## Out of Scope
- Changing gate semantics, branch protection, rulesets or repo settings.
- Adding a GitHub Actions workflow.
- Labels for other repos (helm-knowledge can reuse the script with `--repo`).
