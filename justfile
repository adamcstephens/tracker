default:
    just -l

pc *ARGS:
    process-compose --use-uds {{ARGS}}

services:
    just pc up --detached
    mix ecto.setup

dev:
    if [ mix.exs -nt mix.lock ]; then mix deps.get; fi
    just services
    iex -S mix phx.server

format:
    mix format
    cargo fmt --manifest-path native/package_stream/Cargo.toml
    biome format --write priv/static/css/app.css

test:
    mix test

update-deps:
    mix deps.clean --unused --unlock
    mix deps.update --all
    mix deps.get
    mix hex.outdated
