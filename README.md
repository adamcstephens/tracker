# Tracker

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:6950`](http://localhost:6950) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

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
lifetime is one year). The JWT is printed to stdout once — it cannot be
retrieved later, only revoked.

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
Authorization: Bearer <jwt>
```

Pipe a route through `TrackerWeb.Plug.BearerAuth` to authenticate and
`TrackerWeb.Plug.RequireRole, role: :some_role` to gate by role.

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
