# Production instance — 1Password service account for `sync-env`

How the owner sets up a 1Password service account on the production host so
`pnpm sync-env` can regenerate `apps/api/.env` there, without a signed-in
session and without generating the file on another machine. Closes the open half
of **TD-003** in the [tech-debt register](tech-debt.md), tracked as
[lhpaul/helm#138](https://github.com/lhpaul/helm/issues/138).

The owner runs this by hand. Agents do not run `op`, `sync-env` or anything
against 1Password or real secrets. This page keeps only the generic procedure:
real vault, item, service-account and token-file names, the host and its paths
stay in the owner's private operations notes. Placeholders used below:

| Placeholder | Meaning |
|---|---|
| `<vault>` | The vault(s) that hold only the secrets the env needs |
| `<service-account-name>` | The service account's name in 1Password |
| `<token-file>` | The `0600` file on the host that holds the service account token |
| `<helm-checkout>` | The Helm checkout that serves the instance |
| `<product>` | The product slug passed to `sync-env` |

Steps marked **Verify** only check state and change nothing.

## Decision (2026-11-16)

The owner confirmed that the 1Password plan can issue service accounts and
decided to adopt one. The owner creates it and configures it on the host by hand.
TD-003 stayed `In progress` until the setup was verified; it is `Resolved` since
2026-11-23 (see [Result](#result-2026-11-23)).

## How the script uses the CLI

`apps/api/scripts/sync-env-from-1password.sh` (on `develop` of `lhpaul/helm`):

1. validates the product slug and checks that `op` is installed;
2. runs `op account list` as a sign-in check and stops with
   "not signed in" if it fails;
3. checks that the input `apps/api/.env.<product>` exists;
4. runs `op inject -i apps/api/.env.<product> -o apps/api/.env --force`;
5. fails if a value is still an `op://` reference, or if
   `HELM_KNOWLEDGE_REPO_PATH`, `HELM_DATA_DIR` or `GITHUB_TOKEN` is empty.

According to the 1Password documentation, the CLI authenticates with a service
account when `OP_SERVICE_ACCOUNT_TOKEN` is set, and `op inject` supports
service accounts. So step 4 works with a service account without code changes.
The documentation does not say whether `op account list` succeeds under a
service account. Step 5 of the procedure checks this before the first run.

## Prerequisites

- 1Password CLI **2.18.0 or later** on the host. **Verify:** `op --version`.
- Every `op://` reference in `apps/api/.env.<product>` points at `<vault>`,
  and `<vault>` holds nothing else. A service account cannot be granted the
  Personal, Private or Employee vault or the default Shared vault. If the
  secrets live in one of those today, move them into a dedicated custom vault
  first. Moving items between vaults keeps them inside 1Password, so it does not
  duplicate secrets.
- `OP_CONNECT_HOST` and `OP_CONNECT_TOKEN` are not set in the shell that runs
  `sync-env`. They take precedence over the service-account token.

## Procedure

### 1. Create the service account (1Password.com)

1. Sign in to 1Password.com as an account administrator and open the service
   account wizard (Developer → Directory → Infrastructure Secrets Management →
   Other).
2. Name it `<service-account-name>`.
3. Leave **can create vaults** off.
4. Grant exactly one vault, `<vault>`, with **read items** only. Do not grant
   write or share permissions, and do not grant Environments.
5. Set an expiration if the wizard offers one, and note the date (see
   [Rotation](#rotation)).
6. Create it, then select **Save in 1Password**. The token is shown only once.
   Save it in a vault the service account cannot read (for example, the owner's
   Private vault), never in `<vault>`.

The vault list and permissions cannot be edited later. Changing them means
creating a new service account and revoking the old one.

Equivalent CLI command, run from a session signed in as the owner:
`op service-account create <service-account-name> --vault <vault>:read_items`
(add `--expires-in <duration>` for an expiration). The token is printed once,
so save it in 1Password right away and clear the terminal.

### 2. Store the token on the host

Store the token in a `0600` file owned by the host user, outside any repo:

```bash
install -m 600 /dev/null ~/.config/dev-session/<token-file>
# then paste the token into that file
```

Do not put the token in:

- any file in a repo, including `apps/api/.env*`;
- the shell profile (`export OP_SERVICE_ACCOUNT_TOKEN=…` in `~/.zshrc` exposes
  it to every process the shell starts);
- the API's service definition. The API never needs the token: it reads the
  generated `.env`.

**Why not the OS keychain.** The first version of this runbook used the login
keychain (`security add-generic-password`). It was dropped after testing on the
host: over SSH the keychain answers `User interaction is not allowed`, both when
writing an item and when reading it, so `sync-env` could only ever run from a
graphical session. A `0600` file works over SSH, which is how the host is
operated in practice, and matches the token file the ingress already keeps
there.

This does not conflict with TD-003's "no secrets outside 1Password" policy. The
env secrets (`GITHUB_TOKEN`, webhook secrets) stay only in 1Password and in the
generated `.env`, as today. The file holds only the token that lets the host
read them. That token is read-only, limited to `<vault>`, revocable at any
time, and its source of truth is the copy saved in 1Password in step 1.

### 3. Make `op` use the token after a reboot

A file survives reboots and needs nothing unlocked. Load the token into the
environment only for the command that needs it. A helper function in the
owner's shell config contains no secret:

```bash
helm_sync_env() {
  (
    unset OP_CONNECT_HOST OP_CONNECT_TOKEN
    OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.config/dev-session/<token-file>)" || exit 1
    export OP_SERVICE_ACCOUNT_TOKEN
    cd <helm-checkout> && pnpm sync-env -- "$1"
  )
}
```

The parentheses run it in a subshell, so the token is gone when the command
ends. Over SSH, run the checkout command through a login shell (`zsh -lc`) or
the CLI and `pnpm` may be missing from `PATH`.

### 4. Verify the service account

Run each check in a subshell with the token loaded, as in the helper:

```bash
(
  OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.config/dev-session/<token-file>)" || exit 1
  export OP_SERVICE_ACCOUNT_TOKEN
  op user get --me     # Verify: Type is SERVICE_ACCOUNT
  op vault list        # Verify: only <vault> is listed
)
```

If `Type` is not `SERVICE_ACCOUNT`, the CLI is using another account. Make
sure the Connect variables are unset and the token loaded.

### 5. Verify the script's sign-in check

In the same kind of subshell, run `op account list; echo "exit=$?"`.

- `exit=0`: the script's sign-in check passes. Continue.
- Non-zero: `sync-env` would stop with "not signed in" before `op inject`
  runs. Stop here and report it. The script needs a code change (see
  [Known gap](#known-gap-the-scripts-sign-in-check)), made as its own item in
  `lhpaul/helm`.

The script's input file `apps/api/.env.<product>` must also exist on the host;
it lives outside the public repos. **Verify** it before the first real run by
injecting it to a scratch path and confirming no `op://` reference remains:

```bash
op inject -i apps/api/.env.<product> -o /tmp/sync-env-check --force
grep -c 'op://' /tmp/sync-env-check   # Verify: 0
rm /tmp/sync-env-check
```

### 6. Regenerate the env on the host

```bash
helm_sync_env <product>
```

`--force` overwrites `apps/api/.env`. The running API keeps the env it loaded
at start until it restarts, so a failed run does not take it down. Fix the cause
and run again before restarting.

**Verify:** the script prints `Wrote …/apps/api/.env`, with no unresolved
references or empty required variables. Then restart the API **through its
supervised service** (not `pnpm dev`, and never a second copy by hand) and check
`/health` as in the [production-instance runbook](production-instance.md#smoke-checks).

### 7. Close TD-003

When steps 4 to 6 pass and the API is healthy after a restart, the owner
confirms on [lhpaul/helm#138](https://github.com/lhpaul/helm/issues/138). TD-003
is then marked `Resolved` with that reference.

## Risks

| Risk | Mitigation |
|---|---|
| Token leak (terminal, history, screenshot, backup) | Read-only scope on `<vault>` only limits the damage. Revoke at once (see [Revocation](#revocation)) and create a new token. Check the account's **Item Usage Report** for unexpected reads. |
| Scope too wide | Anything later added to `<vault>` becomes readable from the host. Keep `<vault>` to the env's secrets. Scope cannot be edited: create a new account and revoke the old one. |
| Token expiry or rotation | An expired token makes `sync-env` fail. The running API is not affected. See [Rotation](#rotation). |
| Wrong account used | `OP_CONNECT_*` take precedence, and the documentation does not say how the token ranks against the desktop app integration. Step 4 confirms `SERVICE_ACCOUNT` before relying on it. |
| Rate limits | Service accounts have hourly and daily request limits. `sync-env` makes a few reads per run, so it is not a concern for manual runs. Do not loop it from a script. |
| Token file readable by the host user's other processes | `0600` limits it to that user. The token is read-only, scoped and revocable, and it only unlocks env secrets already present on the host in the generated `.env`. Rotate it if the host user is suspected of compromise. |

### Rotation

In 1Password.com: Developer → Service accounts → `<service-account-name>` →
**Rotate Token**. Choose when the existing token expires (now, 1 hour or 3 days),
confirm, then **Save in 1Password**. Rewrite the host file with the new value,
keeping its mode:

```bash
umask 077 && cat > ~/.config/dev-session/<token-file>
```

Then repeat step 4. The new token keeps the same permissions. Rotate after any
suspected exposure, when the account's sign-in address changes, and before a
set expiration date.

### Revocation

In 1Password.com: Developer → Service accounts → `<service-account-name>` →
**Revoke Token**. Type the name to confirm. Access ends immediately. Then remove
the host copy:

```bash
rm ~/.config/dev-session/<token-file>
```

## Known gap: the script's sign-in check

## Known gap: the script's sign-in check

`sync-env` checks `op account list` before `op inject`. The service-account
documentation does not cover that command, and its error message points to
`op signin`, which does not apply to service accounts.

**Answered 2026-11-23: it passes.** With only `OP_SERVICE_ACCOUNT_TOKEN` set,
`op account list` exits `0` (printing no accounts). It was checked twice: on a
machine with no 1Password account configured at all, and on the host with the
real token. So the script needs **no code change**, and the feature item's
"no code changes unless needed" criterion holds. If a later CLI version makes
this check fail, the fix is a separate item: when `OP_SERVICE_ACCOUNT_TOKEN` is
set, check with `op user get --me` instead.

## Result (2026-11-23)

Verified on the production host, in this order:

1. The account authenticates as `SERVICE_ACCOUNT` and lists only the vaults it
   was granted, read-only.
2. The CLI on the host was upgraded (it was absent) to a version above the
   2.18.0 minimum.
3. `apps/api/.env.<product>` was created on the host from the env references;
   a dry inject left no `op://` reference.
4. `pnpm sync-env` regenerated `apps/api/.env` on the host itself: 6 variables,
   no unresolved references, mode `0600`, previous file kept as a backup.
5. The supervised service restarted and `/health` answered 200 locally and on
   the public ingress; `/api/products` and `/api/items` answered 200.

Not exercised: rotation and revocation (documented above), and a reboot after a
token rotation. Both are the same commands as a first-time setup.

## Rollback

Revoke the token, delete the host file and go back to generating
`apps/api/.env` on another machine, as described in the private runbook.
Nothing in Helm depends on the service account.

## References

- 1Password: [Get started with service accounts](https://www.1password.dev/service-accounts/get-started/)
- 1Password: [Use service accounts with 1Password CLI](https://www.1password.dev/service-accounts/use-with-1password-cli/)
- 1Password: [Manage service accounts](https://www.1password.dev/service-accounts/manage-service-accounts/)
- 1Password: [CLI environment variables](https://www.1password.dev/cli/environment-variables)
