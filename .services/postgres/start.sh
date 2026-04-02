#!/usr/bin/env bash
set -euo pipefail

DATADIR=.services/postgres/data
SOCKDIR="$PWD/.services/postgres"

if [ ! -d "$DATADIR" ]; then
  initdb --username=postgres --pgdata="$DATADIR"
  echo "unix_socket_directories = '$SOCKDIR'" >>"$DATADIR/postgresql.conf"
  echo "listen_addresses = ''" >>"$DATADIR/postgresql.conf"
fi

exec postgres -D "$DATADIR" \
  -c shared_buffers=2GB \
  -c effective_cache_size=4GB \
  -c maintenance_work_mem=512MB \
  -c work_mem=16MB \
  -c random_page_cost=1.1 \
  -c effective_io_concurrency=200
