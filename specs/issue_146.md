# issue_146 — Specification

## Context

[lhpaul/helm#145](https://github.com/lhpaul/helm/issues/145) removed private
operational detail from the documentation of both public repos. The same sweep
found detail of the same kind in code and configuration files of
`lhpaul/helm`, which that item did not touch.
[lhpaul/helm#146](https://github.com/lhpaul/helm/issues/146) generalizes it.

## Acceptance Criteria

- No current code or configuration file of `lhpaul/helm` contains private
  operational detail or private product names: product slugs and input file
  names, secrets-manager vault and item references, example paths with private
  organization names, links to private repositories, or captured runtime data
  that names private connectors.
- `apps/api/.env.example` documents a generic `.env.<product>` input with
  placeholder references (`op://<vault>/<item>/<field>`).
- `sync-env` accepts any product slug that matches
  `^[a-z0-9][a-z0-9-]*$` (at most 64 characters) instead of a fixed list, and
  rejects everything else before calling the secrets manager. Existing input
  files keep working with the same command.
- The `.gitignore` comment is generic; the ignored patterns do not change.
- `pnpm lint` and `pnpm test` pass.

## Technical Notes

- Sweep with `git grep -niE` over the whole repo, not only the files the issue
  names, and check the visibility of every linked repository.
- `sync-env` tests copy the script to a temporary directory and stub the
  secrets-manager CLI, so they never read or write a real `.env` or call the
  real CLI.
- Opaque tracker keys used as test identifiers stay, as in #145.

## Out of Scope

- Rewriting git history, real `.env` files, secrets and the production
  instance.
- Documentation, already covered by #145.
