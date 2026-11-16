# issue_138 — Specification

## Context

[TD-003](../operations/tech-debt.md) is the last open item in the tech-debt
register: after a reboot the production host has no secrets-manager session, so
regenerating `apps/api/.env` (secret rotation, a new key) is done on another
machine and copied over.
[lhpaul/helm#138](https://github.com/lhpaul/helm/issues/138) tracks it.

The first step the register asked for was to confirm whether the 1Password plan
can issue a service account. On 2026-11-16 the owner confirmed that it can and
decided to adopt one. The owner will set it up by hand on the production host.
This item documents that decision and the procedure. It does not change code or
touch the host.

## Acceptance Criteria

- TD-003 records the decision (dated 2026-11-16): a 1Password service account
  is adopted and the owner configures it by hand. TD-003 is `In progress`,
  pending the owner, not `Resolved`. It becomes `Resolved` when the owner
  confirms the setup on the host.
- A runbook under `operations/` gives the owner a step-by-step procedure:
  1. create the service account with read-only access to the smallest vault
     that holds the secrets the env needs;
  2. store the token on the host securely, without writing it to a repo file
     and without copying the env secrets out of 1Password;
  3. make `op` use the token across reboots;
  4. regenerate the env locally with the existing
     `apps/api/scripts/sync-env-from-1password.sh`.
- The runbook marks which steps are verification and lists the risks: token
  rotation, vault scope and revocation.
- The procedure follows the official 1Password documentation on service
  accounts and `OP_SERVICE_ACCOUNT_TOKEN`, and the current behavior of the
  script. The script is read, not run.
- The runbook is linked from TD-003 and from the generic production-instance
  runbook.
- Any code change the script would need is described in the PR, not made here.
- No private detail: vault and item names, hostnames, paths, URLs and tokens are
  placeholders such as `<vault>` and `<product>`.

## Technical Notes

- Service accounts need 1Password CLI 2.18.0 or later and are configured with
  the `OP_SERVICE_ACCOUNT_TOKEN` environment variable. `OP_CONNECT_HOST` and
  `OP_CONNECT_TOKEN` take precedence over it.
- A service account cannot be granted the Personal, Private or Employee vault
  or the default Shared vault, and its vaults and permissions cannot be
  changed after creation.
- The script resolves secrets with `op inject`, which service accounts support.
  Before that it checks `op account list`, which the service-account
  documentation does not cover. That check is the one part of the script that
  may need a change.

## Out of Scope

- Running `op`, `sync-env` or anything against 1Password or real secrets.
- Code changes to `lhpaul/helm`, including the script.
- The host's service definitions, ingress and private runbook.
