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
    # shared_buffers drops to 128MB — 256MB is sized for a workload this
    # instance will never see.
    #
    # max_connections stays generous on purpose. Do NOT lower it without
    # doing this arithmetic first:
    #   - Prisma defaults to num_cpus*2+1 per client and DATABASE_URL sets no
    #     connection_limit, so on 6 vCPUs that is 13 each for the backend and
    #     the orchestrator = 26.
    #   - Temporal opens a pool PER SERVICE (frontend/history/matching/worker),
    #     not one global pool, so maxConns in config.yaml is not the ceiling.
    #     Measured ~13 at idle.
    #   - Background workers = 4.
    # Worst case is therefore ~43 against an idle baseline of ~22. Setting this
    # to 30 was measured to leave no headroom and is an outage waiting for load.
    #
    # NOTE: this block only runs on first init (guarded by the PG_VERSION
    # check above). Changing it here does not touch an existing data volume —
    # edit postgresql.conf on the volume directly and restart for that.
    cat >> /var/lib/pgsql/data/postgresql.conf <<'PG'
listen_addresses = '127.0.0.1'
max_connections = 60
shared_buffers = 128MB
work_mem = 4MB
PG

    chown postgres:postgres /var/lib/pgsql/data/pg_hba.conf /var/lib/pgsql/data/postgresql.conf
    echo "PostgreSQL initialized."
fi
