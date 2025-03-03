default:
    just -l

dev:
    iex -S mix phx.server

update-deps:
    mix deps.clean --unused --unlock
    mix deps.update --all
    mix deps.get
    mix hex.outdated
