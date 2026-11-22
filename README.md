# Tracker

A nixpkgs and ecosystem tracking tool.

## NixOS deployment

Import `nixosModules.tracker` from the Tracker flake. Put non-secret
environment variables in `settings` and absolute runtime paths to secret
files in `credentials`. Both use the names Tracker reads:

```nix
services.tracker = {
  enable = true;
  database.createLocally = true;
  settings = {
    PHX_HOST = "tracker.example.org";
    TRACKER_GITHUB_CLIENT_ID = "your-oauth-client-id";
    TRACKER_GITHUB_APP_ID = "123";
    TRACKER_GITHUB_INSTALLATION_ID = "456";
    TRACKER_GITHUB_REDIRECT_URI = "https://tracker.example.org/auth/user/github/callback";
  };
  credentials = {
    SECRET_KEY_BASE_FILE = "/run/secrets/tracker/secret-key-base";
    TOKEN_SIGNING_SECRET_FILE = "/run/secrets/tracker/token-signing-secret";
    TRACKER_GITHUB_CLIENT_SECRET_FILE = "/run/secrets/tracker/github-client-secret";
    TRACKER_GITHUB_APP_PRIVATE_KEY_FILE = "/run/secrets/tracker/github-private-key";
  };
};
```

systemd loads the secret files for both migrations and server startup, and
Tracker reads them via the `_FILE` variables. The source files can be
root-only and must be outside the Nix store. For an external database, omit
`database.createLocally` and set `credentials.DATABASE_URL_FILE` to a file
containing the connection URL.

See [Environment variables](#environment-variables) for the full reference.

## Environment variables

### Server and database

| Variable | Purpose |
| --- | --- |
| `PHX_SERVER` | Starts the HTTP endpoint when set; the NixOS module sets it. |
| `PHX_HOST` | Public hostname for generated HTTPS URLs. Defaults to `example.com` in a standalone release and `localhost` on NixOS. |
| `PHX_IP` | HTTP bind address. Defaults to `::` in a standalone release and `127.0.0.1` on NixOS. |
| `PORT` | HTTP listen port. Defaults to `6950`. |
| `DATABASE_URL` / `DATABASE_URL_FILE` | PostgreSQL connection URL. Required in production; the NixOS module supplies a Unix-socket URL when provisioning PostgreSQL locally. |
| `POOL_SIZE` | PostgreSQL connection pool size. Defaults to `10`. |
| `ECTO_IPV6` | Enables IPv6 for PostgreSQL connections when set to `true` or `1`. |
| `SECRET_KEY_BASE` / `SECRET_KEY_BASE_FILE` | Phoenix signing and encryption secret. Required in production. Generate with `openssl rand -hex 64`. |
| `TOKEN_SIGNING_SECRET` / `TOKEN_SIGNING_SECRET_FILE` | Token signing secret. Required in production. Generate with `openssl rand -hex 64`. |
| `NIXPKGS_GIT_PATH` | Path to the local nixpkgs clone. The NixOS module defaults to `/var/lib/tracker/nixpkgs`. |
| `TZDIR` | Time-zone database directory. Defaults to `/usr/share/zoneinfo`; NixOS uses the packaged `tzdata` directory. |
| `https_proxy` | Optional HTTP or HTTPS proxy URL for Req, with optional basic authentication. |
| `no_proxy` | Comma-separated proxy bypass list for Req; used only when `https_proxy` is set. |

### Integrations

All GitHub settings are required outside the test environment. Set
`TRACKER_S3_BUCKET` to enable S3 caching; when enabled, all five S3 settings
are required.

| Variable | Purpose |
| --- | --- |
| `TRACKER_GITHUB_CLIENT_ID` | GitHub OAuth client ID. |
| `TRACKER_GITHUB_CLIENT_SECRET_FILE` | Path to the OAuth client secret generated in the GitHub App's settings. |
| `TRACKER_GITHUB_APP_ID` | Numeric GitHub App ID. |
| `TRACKER_GITHUB_APP_PRIVATE_KEY_FILE` | Path to the PEM private key generated and downloaded from the GitHub App's settings. |
| `TRACKER_GITHUB_INSTALLATION_ID` | Numeric GitHub App installation ID. |
| `TRACKER_GITHUB_REDIRECT_URI` | Registered GitHub OAuth callback URL. |
| `TRACKER_DISCORD_TOKEN` / `TRACKER_DISCORD_TOKEN_FILE` | Optional bot token from the Discord Developer Portal's **Bot** tab. |
| `TRACKER_METRICS_TOKEN` / `TRACKER_METRICS_TOKEN_FILE` | Optional bearer token for `/metrics`. Without it, the endpoint returns 404. Generate with `openssl rand -hex 64`. |
| `TRACKER_S3_BUCKET` | S3 cache bucket name. |
| `TRACKER_S3_ENDPOINT` | S3 endpoint URL. |
| `TRACKER_S3_REGION` | S3 region. |
| `TRACKER_S3_ACCESS_KEY` / `TRACKER_S3_ACCESS_KEY_FILE` | Access key ID issued by your S3 provider. |
| `TRACKER_S3_SECRET_KEY` / `TRACKER_S3_SECRET_KEY_FILE` | Matching secret access key issued by your S3 provider. |

`_FILE` variables take a file path, not a secret value. Where both forms
are supported, the file takes precedence; an unreadable file fails startup.

### Build and test

| Variable | Purpose |
| --- | --- |
| `ESBUILD_PATH` | Path to an esbuild executable; the Nix dev shell supplies it. |
| `PGHOST` | PostgreSQL socket directory for Mix tests. Defaults to `.services/postgres`. |
| `MIX_TEST_PARTITION` | Suffix appended to the `tracker_test` database name. |
| `PLAYWRIGHT_ASSETS_DIR` | Directory containing the Playwright assets. Defaults to `./assets`; the Nix dev shell supplies it. |
| `PLAYWRIGHT_BROWSERS_PATH` | Browser binary directory supplied by the Nix dev shell. |
| `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD` | Set to `1` by the Nix dev shell to use packaged browsers rather than downloading them. |

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

### Self-service in the UI

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
