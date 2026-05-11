# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

channels = [
  "nixos-25.11",
  "nixos-25.11-small",
  "nixos-unstable",
  "nixos-unstable-small",
  "nixpkgs-unstable"
]

config :tracker,
  channels: channels

config :tracker, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [changes: 10, ingestion: 10],
  repo: Tracker.Repo,
  plugins: [
    Oban.Met,
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Tracker.Nixpkgs.ChangeDiscoveryWorker},
       {"*/3 * * * *", Tracker.Nixpkgs.ChangeRefreshWorker},
       {"*/2 * * * *", Tracker.Nixpkgs.ChangeArtifactReconcileWorker},
       {"15 * * * *", Tracker.Nixpkgs.ChangeReconcileWorker},
       {"0 */4 * * *", Tracker.Ingestion.CronWorker, queue: :ingestion}
     ]}
  ]

config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api, show_public_calculations_when_loaded?: false

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :admin,
        :authentication,
        :tokens,
        :postgres,
        :json_api,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [
        :admin,
        :json_api,
        :resources,
        :policies,
        :authorization,
        :domain,
        :execution
      ]
    ]
  ]

config :tracker,
  ecto_repos: [Tracker.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [Tracker.Nixpkgs, Tracker.Accounts, Tracker.Ingestion]

# Configures the endpoint
config :tracker, TrackerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TrackerWeb.ErrorHTML, json: TrackerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tracker.PubSub,
  live_view: [signing_salt: "ojJfEsFf"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :tracker, Tracker.Mailer, adapter: Swoosh.Adapters.Local

config :tracker, Tracker.GitServer,
  repo_url: "https://github.com/NixOS/nixpkgs.git",
  path: "data/nixpkgs.git",
  auto_start: true

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  tracker: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
