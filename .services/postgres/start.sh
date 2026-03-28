#!/usr/bin/env bash
set -euo pipefail

DATADIR=.services/postgres/data
SOCKDIR="$PWD/.services/postgres"

if [ ! -d "$DATADIR" ]; then
  initdb --username=postgres --pgdata="$DATADIR"
  echo "unix_socket_directories = '$SOCKDIR'" >> "$DATADIR/postgresql.conf"
  echo "listen_addresses = ''" >> "$DATADIR/postgresql.conf"
fi

exec postgres -D "$DATADIR"
