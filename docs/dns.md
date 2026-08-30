# DNS

DNS is managed as code in `dns/` with [octodns](https://github.com/octodns/octodns)
and synced to Cloudflare. PRs touching `dns/**` get a plan comment from the
`dns-dry-run` workflow; merges to `main` apply via the `dns-deploy` workflow.

## Tokens

Both are Cloudflare API tokens, scoped to the `letsbuilda.dev` zone only:

- `CLOUDFLARE_TOKEN` — Zone:Read + DNS:Edit. Lives in the `cloudflare` GitHub
  Environment; only the deploy job can read it.
- `CLOUDFLARE_RO_TOKEN` — Zone:Read + DNS:Read. A plain repository secret so PR
  dry-runs work unattended; keep it genuinely read-only, since it is exposed to
  every same-repo DNS PR.
- `CLOUDFLARE_ACCOUNT_ID` is a repository variable, not a secret.

Verify the scopes in the Cloudflare dashboard when rotating; nothing in the repo can.

## Safety threshold and `--force`

Deploys run without `--force`, so octodns refuses plans that update or delete more
than 30% of the zone's records (and a bad merge fails loudly instead of applying).
For an intentional bulk change, re-run the `Deploy DNS to providers` workflow via
`workflow_dispatch` with the `force` input set. The PR dry-run keeps `--force` so
reviewers always see the full plan.

## Rollback

The zone files are the source of truth: the normal rollback is `git revert` on
`main`, which re-syncs. Before a risky change, snapshot the live zone so there is a
diffable artifact:

```
CLOUDFLARE_TOKEN=... CLOUDFLARE_ACCOUNT_ID=... \
  uv run octodns-dump --config-file=dns/production.yaml --output-dir=/tmp/zonedump 'letsbuilda.dev.' cloudflare
```

## Known blind spot: value-based filters

`dns/production.yaml` ignores records whose *values* match Cloudflare-generated
placeholders (`100::/128`, `192.0.2.1/32`, targets ending in `.r2.dev.`) on both the
desired and existing sides. That keeps Worker/R2/rules records unmanaged
automatically — but it also means a record with one of those values at **any** name
(added via the dashboard or a leaked token) is invisible to plans and never cleaned
up. Periodically compare an `octodns-dump` against `dns/zones/` to catch drift.

## Adding a zone

1. Create the zone in Cloudflare and confirm both tokens' zone resources cover it.
2. Add `dns/zones/<zone>.zone/*.yaml` — the `"*"` entry in `dns/production.yaml`
   discovers it automatically.
3. Open a PR and read the plan comment before merging.

## GitHub Pages domain verification

`docs.letsbuilda.dev` points at GitHub Pages. Verify the domain for the org
(GitHub org settings → Pages → verified domains) so no other account can claim
`letsbuilda.dev` subdomains on Pages, and commit the resulting
`_github-pages-challenge-*` TXT record **into the zone files** — a record added only
in Cloudflare would be planned for deletion on the next sync.
