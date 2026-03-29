default:
    just -l

services:
    process-compose up --detached
    mix ecto.setup

dev:
    if [ mix.exs -nt mix.lock ]; then mix deps.get; fi
    just services
    iex -S mix phx.server

format:
    mix format
    biome format --write priv/static/css/app.css

test:
    mix test

update-deps:
    mix deps.clean --unused --unlock
    mix deps.update --all
    mix deps.get
    mix hex.outdated
