import Config

config :tracker, TrackerWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Configures Swoosh API Client
config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: Tracker.Finch

# Disable Swoosh Local Memory Storage
config :swoosh, local: false

# Do not print debug messages in production
config :logger, level: :info

config :tracker,
  # loader_limit: 20,
  channels: [
    "nixos-24.11",
    "nixos-24.11-small",
    "nixos-unstable",
    "nixos-unstable-small",
    "nixpkgs-unstable"
  ]
