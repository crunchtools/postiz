#!/bin/bash
set -e

# Wait for PostgreSQL
for i in $(seq 1 30); do
    pg_isready -q && break
    sleep 1
done

# Create databases
for db in postiz temporal temporal_visibility; do
    psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q 1 || \
        psql -U postgres -c "CREATE DATABASE ${db};"
done

# Create temporal user
psql -U postgres -tc "SELECT 1 FROM pg_roles WHERE rolname = 'temporal'" | grep -q 1 || \
    psql -U postgres -c "CREATE USER temporal WITH PASSWORD 'temporal';"

# Grant privileges
for db in temporal temporal_visibility; do
    psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${db} TO temporal;"
    psql -U postgres -d "${db}" -c "GRANT ALL ON SCHEMA public TO temporal;"
done

# Run Temporal schema setup (idempotent)
export SQL_PLUGIN=postgres12
export SQL_HOST=127.0.0.1
export SQL_PORT=5432
export SQL_USER=temporal
export SQL_PASSWORD=temporal

export SQL_DATABASE=temporal
if ! psql -U temporal -d temporal -tc "SELECT 1 FROM schema_version LIMIT 1" 2>/dev/null | grep -q 1; then
    temporal-sql-tool setup-schema -v 0.0
    temporal-sql-tool update-schema -d /etc/temporal/schema/postgresql/v12/temporal/versioned
fi

export SQL_DATABASE=temporal_visibility
if ! psql -U temporal -d temporal_visibility -tc "SELECT 1 FROM schema_version LIMIT 1" 2>/dev/null | grep -q 1; then
    temporal-sql-tool setup-schema -v 0.0
    temporal-sql-tool update-schema -d /etc/temporal/schema/postgresql/v12/visibility/versioned
fi

echo "Database setup complete."
