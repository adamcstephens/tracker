import Config
config :tracker, Oban, testing: :manual
config :tracker, token_signing_secret: "thIXDz5NECPXPg1mNAqRn8lxdK3Jre7j"
config :ash, disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :tracker, Tracker.Repo,
  username: "postgres",
  socket_dir: System.get_env("PGHOST", Path.expand("../.services/postgres", __DIR__)),
  database: "tracker_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :tracker, TrackerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "WqdxLnwcONLhSyGcqDcDTUU8CcoSD35IqOWwEuVbRCc1jR8Ph4S+fsMDXi0ExrsD",
  server: true

config :tracker, sql_sandbox: true

config :phoenix_test,
  otp_app: :tracker,
  playwright: [
    assets_dir: System.get_env("PLAYWRIGHT_ASSETS_DIR", "./assets"),
    headless: true,
    trace: false,
    timeout: to_timeout(second: 2)
  ]

# In test we don't send emails
config :tracker, Tracker.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

config :tracker, Tracker.GitServer, auto_start: false

# Compiles the /dev/login route so it can be tested.
config :tracker, dev_routes: true

# Tests that exercise ChangeArtifactRefreshWorker without explicitly stubbing
# `:files_fetcher` should not hit the GitHub REST API. Tests covering
# changed_files persistence pass an explicit `:files_fetcher` opt.
config :tracker, changed_files_fetcher: nil

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
