# Ansible

Server configuration lives in `ansible/`. All commands below run from that directory.

## Running locally

```
uv sync --group ansible
uv run ansible-playbook --diff playbook.yaml
```

You connect as your own user and are prompted for your sudo (BECOME) password.

## CI deploys

A cron runs the playbook from GitHub Actions every Sunday at 00:17 UTC, against
whatever is on `main` at that moment; a `workflow_dispatch` run applies batched
changes sooner. Merging does not deploy — dispatch a run when a change should land
before Sunday, and after any `ansible/**` change whose runtime behavior the PR's
`ansible-lint` and `--syntax-check` cannot prove. Both paths go through the `ansible`
GitHub Environment. CI connects as the dedicated `ci` user (created by the `users`
role) using the `SSH_PRIVATE_KEY` environment secret, with passwordless sudo granted
by `/etc/sudoers.d/ci`. The host key is pinned in `ansible/known_hosts`, keeping
strict host key checking enabled.

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
