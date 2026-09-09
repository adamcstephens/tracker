# Tracker

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:6950`](http://localhost:6950) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Signing in during development

GitHub OAuth is the only sign-in strategy, so logged-in pages (inbox,
subscriptions, account settings) need a local user:

```sh
mix tracker.dev_user.create [--username devuser] [--admin] [--notifications 12]
```

The task registers the user, writes a freshly minted token to `.dev-login.json`
(gitignored, mode 0600) and prints a `/dev/login/<token>` URL that signs the
browser in as them. Pass `--admin` to also unlock `/dev` and `/admin`. Re-run
the task to rotate the token, or delete the file to revoke it.

It also subscribes the user to a few packages, a channel and a change, and
back-fills notifications from what actually happened in the most recent
revisions, so the inbox is not empty. `--notifications 0` skips that; on a box
with nothing ingested yet the task says so and seeds nothing.

The route only exists when `dev_routes` is enabled, so it is never compiled
into a production build.

## Time zones

Absolute times use the browser's IANA time zone when available, otherwise UTC.
Signed-in users can select an explicit override from Account settings and reset
back to Browser timezone at any time. Deployments need an IANA zoneinfo
database; the NixOS module configures `TZDIR` from `tzdata`.

## Service accounts and API tokens

Tracker supports long-lived API bearer tokens for non-human callers. Service
accounts are users with no GitHub identity; an admin creates one, then issues
a token for it.

### Create a service account

```sh
mix tracker.service_account.create \
  --actor <admin-github-username> \
  --name <account-name> \
  --roles <comma-separated-roles>
```

`--actor` is the github_username of an existing admin user. `--name` becomes
`service:<name>` as the account's `github_username`. `--roles` is the
comma-separated role list (e.g. `user,maintainer`); the token will inherit
exactly these roles.

### Issue a token for the service account

```sh
mix tracker.api_token.issue \
  --actor <admin-github-username> \
  --user service:<account-name> \
  --label <human-readable-label> \
  --expires-in <seconds>
```

`--user` accepts either a UUID or a `github_username` (including the
`service:*` form). `--label` and `--expires-in` are optional (default
lifetime is one year). The token is printed to stdout once — it cannot
be retrieved later, only revoked.

Issued tokens are prefixed with `trk_` so they're easy to grep for in
logs and recognisable by secret scanners.

### Revoke a token

```sh
mix tracker.api_token.revoke \
  --actor <admin-github-username> \
  --jti <jti>
```

The JTI is printed alongside the JWT when the token is issued.

### Self-service for human users

Logged-in users can issue and revoke their own API tokens at
[`/account/tokens`](http://localhost:6950/account/tokens). Service account
management is admin-only and only available via the mix tasks above.

### Using a token

```
GET /your/api/endpoint
Authorization: Bearer trk_<jwt>
```

Send the full prefixed token in the `Authorization` header. Pipe a route
through `TrackerWeb.Plug.BearerAuth` to authenticate and
`TrackerWeb.Plug.RequireRole, role: :some_role` to gate by role.

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
