default:
    just -l

dev:
    if [ mix.exs -nt mix.lock ]; then mix deps.get; fi
    iex -S mix phx.server

format:
    mix format

test:
    mix test

update-deps:
    mix deps.clean --unused --unlock
    mix deps.update --all
    mix deps.get
    mix hex.outdated
