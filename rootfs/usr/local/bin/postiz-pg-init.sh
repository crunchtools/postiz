#!/bin/bash
set -e

if [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
    echo "Initializing PostgreSQL data directory..."

    # Fix ownership on volume mount (created as root by podman)
    chown -R postgres:postgres /var/lib/pgsql/data

    # Run initdb as postgres user
    su - postgres -c '/usr/bin/initdb -D /var/lib/pgsql/data'

    # Trust auth for local connections (safe: port not exposed outside container)
    cat > /var/lib/pgsql/data/pg_hba.conf <<'PG'
local   all   all                 trust
host    all   all   127.0.0.1/32  trust
host    all   all   ::1/128       trust
PG

    # Tune for container use
    cat >> /var/lib/pgsql/data/postgresql.conf <<'PG'
listen_addresses = '127.0.0.1'
max_connections = 100
shared_buffers = 256MB
work_mem = 4MB
PG

    chown postgres:postgres /var/lib/pgsql/data/pg_hba.conf /var/lib/pgsql/data/postgresql.conf
    echo "PostgreSQL initialized."
fi
