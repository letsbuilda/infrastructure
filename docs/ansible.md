# Ansible

Server configuration lives in `ansible/`. All commands below run from that directory.

## Running locally

```
uv sync --group ansible
uv run ansible-playbook --diff --vault-password-file vault_password playbook.yaml
```

You connect as your own user and are prompted for your sudo (BECOME) password.
`ansible/vault_password` is gitignored and holds the vault password (see
[Secrets](#secrets)); `--ask-vault-pass` works instead if you would rather type
it. Without one of the two the run fails at the first task that reads a vaulted
value.

## CI deploys

A cron runs the playbook from GitHub Actions every Sunday at 00:17 UTC, against
whatever is on `main` at that moment; a `workflow_dispatch` run applies batched
changes sooner. Merging does not deploy — dispatch a run when a change should land
before Sunday, and after any `ansible/**` change whose runtime behavior the PR's
`ansible-lint` and `--syntax-check` cannot prove. Both paths go through the `ansible`
GitHub Environment. CI connects as the dedicated `ci` user (created by the `users`
role) using the `SSH_PRIVATE_KEY` environment secret, with passwordless sudo granted
by `/etc/sudoers.d/ci`. The host key is pinned in `ansible/known_hosts`, keeping
strict host key checking enabled. The vault password comes from the
`ANSIBLE_VAULT_PASSWORD` environment secret, written to `$RUNNER_TEMP` and
passed via `ANSIBLE_VAULT_PASSWORD_FILE` so the `ansible-playbook` line stays
identical to the local one.

## Secrets

Secrets that have to reach a host live in `ansible/group_vars/all.yaml`,
encrypted individually with `ansible-vault encrypt_string` rather than by
encrypting the whole file.

Both forms survive CI — the `Lint` job has no vault password, and neither
`ansible-lint` nor `ansible-playbook --syntax-check` fails on encrypted content
without one. The difference is what they can still check. `ansible-lint` runs
with a dummy password, so against a whole-file vault it gives up on the file and
logs `Ignored exception from JinjaRule / VariableNamingRule ... Decryption
failed`, reporting a pass without having linted it. With inline values only the
ciphertext is opaque, so the rest of the file keeps getting checked. Inline also
keeps variable names greppable and diffs reviewable, and avoids `ansible-vault
edit`, which exposes plaintext through editor swap and backup files.

The cost is rotation: `ansible-vault rekey` does not work on inline values.

Do **not** put `vault_password_file` in `ansible.cfg`. Ansible resolves it
unconditionally, whether or not the run touches vaulted data, and a missing file
is a hard error — `The vault password file ... was not found`. That is exactly
why `9a65f59` removed it, and the gitignored `ansible/vault_password` path is
what remained. Pass `--vault-password-file` (or `ANSIBLE_VAULT_PASSWORD_FILE`)
per invocation instead. There is no `ANSIBLE_VAULT_PASSWORD` variable in
ansible-core; only a path to a file is supported.

To add a secret:

```
cd ansible
uv run ansible-vault encrypt_string \
  --vault-password-file vault_password --stdin-name my_secret
```

Paste the value, press Ctrl-D without a trailing newline, and put the output in
`group_vars/all.yaml`. Use the `--stdin-name` prompt form rather than passing
the value as an argument, which would leave it in your shell history.

Any task that writes a secret to a host needs `no_log: true`. CI runs with
`--diff`, this repository is public, and GitHub only masks the literal
`secrets.*` values it issued — a token decrypted from the vault is not one of
them and will be printed verbatim.

To rotate the vault password: re-run `encrypt_string` for every value in
`group_vars/all.yaml` with
the new password and update the `ANSIBLE_VAULT_PASSWORD` environment secret in
the same change. Changing the secret without re-encrypting leaves the next
unattended Sunday run failing with `Decryption failed`.

## Discord bridge

`smp-py` bridges in-game chat to Discord with
[DiscordSRV](https://modrinth.com/plugin/discordsrv), installed through
`MODRINTH_PROJECTS` like every other plugin. The bot token is vaulted and
reaches the container as `DISCORDSRV_TOKEN`; the channel mapping is not a
secret and lives in `roles/minecraft/files/patches/discordsrv.json`. The Discord
console channel is explicitly disabled — running server commands from Discord
would put a second, weaker path to the console next to SSH.

Nothing needs opening on the firewall: DiscordSRV only makes outbound
connections.

First-time setup, outside the repo:

1. Create an application at <https://discord.com/developers/applications>, add a
   bot, and enable **both** privileged gateway intents (SERVER MEMBERS and
   MESSAGE CONTENT). DiscordSRV does not work without them.
2. Under Installation, set Install Link to None and disable User Install.
3. Invite the bot with <https://scarsz.me/authorize> using the Application ID.
   It needs Manage Roles, Manage Channels, Manage Nicknames and Manage Webhooks
   on the server, plus View Channel, Send Messages, Manage Messages, Embed
   Links, Read Message History and Add Reactions on the bridged channel.
4. Put the bot token in the vault as `discordsrv_bot_token` (see
   [Secrets](#secrets)), and replace `REPLACE_WITH_DISCORD_CHANNEL_ID` in
   `ansible/roles/minecraft/files/patches/discordsrv.json` with the channel ID
   (right-click the channel with Developer Mode on, Copy Channel ID). The
   channel ID is not a secret; it is useless without the bot token.
5. Deploy, then **restart the container once**:

   ```
   ssh ci@microwave.box.letsbuilda.dev \
     'sudo docker compose -f /opt/letsbuilda/minecraft/compose.yaml restart minecraft'
   ```

   `plugins/DiscordSRV/config.yml` does not exist until DiscordSRV has enabled
   once, and patches are applied before the server starts, so on the first
   converge the patch logs `Unable to patch ... it is not an existing file` and
   does nothing. A repeat `workflow_dispatch` will not fix this on its own — the
   image digest is pinned, so Compose recreates nothing. Only the second
   container start applies the channel mapping.

## Bootstrapping / key rotation

The `ci` user only exists after the playbook has run once, so a new host needs one
local run (as yourself, with your sudo password) before CI can deploy:

1. Generate the CI keypair outside the repository tree, so it can never be staged:

   ```
   keydir="$(mktemp -d)"
   ssh-keygen -t ed25519 -N '' -C 'ci@letsbuilda/infrastructure' -f "$keydir/ci_ed25519"
   ```

2. Put the public key in `ansible/roles/users/files/ci_ed25519.pub`.
3. Pin the host key: run `ssh-keyscan -t ed25519 microwave.box.letsbuilda.dev` from a
   trusted network, verify the fingerprint out-of-band, and add the output to
   `ansible/known_hosts`.
4. Add the private key as the `SSH_PRIVATE_KEY` secret in the `ansible` GitHub
   Environment (restrict the environment's deployment branches to `main`).
5. Run the playbook locally once to create the `ci` user, then verify the CI auth
   path:
   `ssh -i "$keydir/ci_ed25519" -o UserKnownHostsFile=ansible/known_hosts ci@microwave.box.letsbuilda.dev 'sudo -n true && echo sudo-ok'`
6. Shred the local private key copy: `shred -u "$keydir/ci_ed25519" && rm -rf "$keydir"`.

To rotate the CI key: repeat with a new keypair, replacing the committed public key
and the `SSH_PRIVATE_KEY` secret, then run the playbook once (locally or via the old
key). If the host is reinstalled, refresh `ansible/known_hosts` the same way as step 3.

## Required repository settings

CI executes the playbook as root on production from whatever is on `main` when the
weekly cron fires, so the security boundary is who (and what) can land a commit
there, plus who can start a `workflow_dispatch` run. These settings live outside the
repo and nothing in CI fails when they drift — re-check them when auditing:

- A ruleset on `main`: require a pull request, require review from Code Owners
  (`.github/CODEOWNERS` routes to `@letsbuilda/devops`), require the `Lint` and
  `Ansible lint` status checks, block force pushes and deletions, no bypass actors.
- The `ansible` GitHub Environment: deployment branches restricted to `main`, and no
  required reviewers. The branch restriction is what keeps a workflow edit on a topic
  branch away from `SSH_PRIVATE_KEY`, and what stops a `workflow_dispatch` from any
  branch but `main`. A required reviewer would gate the weekly cron too — an
  unapproved Sunday run waits and GitHub fails it after 30 days — so the unattended
  schedule depends on there being none.
- The `ansible` GitHub Environment also holds `ANSIBLE_VAULT_PASSWORD`. Keep it
  an environment secret rather than a repository secret: the `main`-only branch
  restriction is what stops a workflow edit on a topic branch from reading it,
  and the `Lint` workflow must never be given access.
- The `cloudflare` GitHub Environment: deployment branches restricted to `main`.
- `CLOUDFLARE_RO_TOKEN` stays a plain repository secret so PR dry-runs work
  unattended. Moving it into an environment only makes sense with no required
  reviewers and an all-branches deployment policy, together with an `environment:`
  line on the job in `dns-dry-run.yaml` — those two changes must land together.
- A DigitalOcean cloud firewall attached to the droplet, allowing inbound 22/tcp and
  25565/tcp only (add 25565/udp if the Minecraft query protocol is ever enabled).
  Use the cloud firewall, not ufw: Docker publishes container ports through its own
  iptables chains, which are evaluated before ufw's rules — a host firewall silently
  does not cover port 25565.
