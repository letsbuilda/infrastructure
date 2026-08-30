# Ansible

Server configuration lives in `ansible/`. All commands below run from that directory.

## Running locally

```
uv sync --group ansible
uv run ansible-playbook --diff playbook.yaml
```

You connect as your own user and are prompted for your sudo (BECOME) password.

## CI deploys

Pushes to `main` that touch `ansible/**` (and manual `workflow_dispatch` runs) run the
playbook from GitHub Actions via the `ansible` GitHub Environment. CI connects as the
dedicated `ci` user (created by the `users` role) using the `SSH_PRIVATE_KEY`
environment secret, with passwordless sudo granted by `/etc/sudoers.d/ci`. The host
key is pinned in `ansible/known_hosts`, keeping strict host key checking enabled.

## Bootstrapping / key rotation

The `ci` user only exists after the playbook has run once, so a new host needs one
local run (as yourself, with your sudo password) before CI can deploy:

1. Generate the CI keypair:
   `ssh-keygen -t ed25519 -N '' -C 'ci@letsbuilda/infrastructure' -f ./ci_ed25519`
2. Put the public key in `ansible/roles/users/files/ci_ed25519.pub`.
3. Pin the host key: run `ssh-keyscan -t ed25519 microwave.box.letsbuilda.dev` from a
   trusted network, verify the fingerprint out-of-band, and add the output to
   `ansible/known_hosts`.
4. Add the private key as the `SSH_PRIVATE_KEY` secret in the `ansible` GitHub
   Environment (restrict the environment's deployment branches to `main`).
5. Run the playbook locally once to create the `ci` user, then verify the CI auth
   path:
   `ssh -i ./ci_ed25519 -o UserKnownHostsFile=ansible/known_hosts ci@microwave.box.letsbuilda.dev 'sudo -n true && echo sudo-ok'`
6. Shred the local private key copy.

To rotate the CI key: repeat with a new keypair, replacing the committed public key
and the `SSH_PRIVATE_KEY` secret, then run the playbook once (locally or via the old
key). If the host is reinstalled, refresh `ansible/known_hosts` the same way as step 3.
