#!/usr/bin/env bash
set -euo pipefail

SOCKDIR="$PWD/.services/postgres"

if [ ! -d "$PGDATA" ]; then
  initdb --username=postgres --pgdata="$PGDATA"
  echo "unix_socket_directories = '$SOCKDIR'" >>"$PGDATA/postgresql.conf"
  echo "listen_addresses = ''" >>"$PGDATA/postgresql.conf"
fi

exec postgres -D "$PGDATA" \
  -c shared_buffers=2GB \
  -c effective_cache_size=4GB \
  -c maintenance_work_mem=512MB \
  -c work_mem=16MB \
  -c random_page_cost=1.1 \
  -c effective_io_concurrency=200
