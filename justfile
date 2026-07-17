default:
    just -l

pc *ARGS:
    process-compose --use-uds {{ ARGS }}

services:
    just pc up --detached
    mix ecto.setup

dev:
    if [ ! -d deps ]; then mix deps.get; fi
    if [ mix.exs -nt mix.lock ]; then mix deps.get; fi
    just services
    iex -S mix phx.server

format:
    mix format
    cargo fmt --manifest-path native/package_stream/Cargo.toml
    biome format --write priv/static/css/app.css

mix-nix-lock:
    #!/usr/bin/env bash
    set -euo pipefail
    mix deps.get
    mix deps.nix --output deps.nix --env prod --env test
    # lumis's published Cargo.lock pins the lumis crates as path deps it doesn't
    # ship, so re-resolve them from crates.io before vendoring for the nix build.
    crate=deps/lumis/native/lumis_nif
    awk 'BEGIN{RS="";ORS="\n\n"} { if (($0 ~ /name = "lumis"\n/ || $0 ~ /name = "lumis-core"\n/ || $0 ~ /name = "lumis-build"\n/) && $0 !~ /source = /) next; print }' "$crate/Cargo.lock" > "$crate/Cargo.lock.tmp"
    mv "$crate/Cargo.lock.tmp" "$crate/Cargo.lock"
    (cd "$crate" && cargo metadata --format-version 1 > /dev/null)
    cp "$crate/Cargo.lock" nix/lumis_nif-Cargo.lock

test:
    mix test

update-deps: update-elixir update-rust

update-elixir:
    mix deps.clean --unused --unlock
    mix deps.update --all
    mix deps.get
    mix hex.outdated
    mix hex.audit

[working-directory('native/package_stream')]
update-rust:
    cargo update

icons:
    mkdir -p priv/static/images/.tmp
    nix run nixpkgs#librsvg -- --width 16 --height 16 --output priv/static/images/.tmp/16.png priv/static/images/tracker-16.svg
    nix run nixpkgs#librsvg -- --width 32 --height 32 --output priv/static/images/.tmp/32.png priv/static/images/tracker-32.svg
    nix run nixpkgs#librsvg -- --width 48 --height 48 --output priv/static/images/.tmp/48.png priv/static/images/tracker-64.svg
    nix run nixpkgs#librsvg -- --width 180 --height 180 --output priv/static/images/apple-touch-icon.png priv/static/images/tracker-64.svg
    nix run nixpkgs#librsvg -- --width 192 --height 192 --output priv/static/images/icon-192.png priv/static/images/tracker-64.svg
    nix run nixpkgs#librsvg -- --width 512 --height 512 --output priv/static/images/icon-512.png priv/static/images/tracker-64.svg
    nix run nixpkgs#imagemagick -- priv/static/images/.tmp/16.png priv/static/images/.tmp/32.png priv/static/images/.tmp/48.png priv/static/images/favicon.ico
    rm -rf priv/static/images/.tmp
