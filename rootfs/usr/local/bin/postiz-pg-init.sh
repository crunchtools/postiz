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

    # Tune for container use.
    #
    # Sized for a single-tenant install: the only clients are the Postiz apps
    # and the Temporal server's two connection pools (see
    # /etc/temporal/config.yaml). 100 connections at 256MB of shared_buffers is
    # sized for a workload this instance will never see, and postgres reserves
    # per-connection memory up front.
    #
    # NOTE: this block only runs on first init (guarded by the PG_VERSION
    # check above). Changing it here does not touch an existing data volume —
    # edit postgresql.conf on the volume directly and restart for that.
    cat >> /var/lib/pgsql/data/postgresql.conf <<'PG'
listen_addresses = '127.0.0.1'
max_connections = 30
shared_buffers = 128MB
work_mem = 4MB
PG

    chown postgres:postgres /var/lib/pgsql/data/pg_hba.conf /var/lib/pgsql/data/postgresql.conf
    echo "PostgreSQL initialized."
fi
