# ==========================================================================
# Postiz - Self-hosted social media scheduler
# Single UBI 10 container with systemd
# Services: PostgreSQL 16, Valkey 8, Temporal 1.29.3, Node.js 22, nginx
# ==========================================================================
#
# Build:  podman build -t localhost/postiz:latest .
# Run:    See README.md for podman run command
# ==========================================================================

ARG TEMPORAL_VERSION=1.29.3
ARG TEMPORAL_TOOLS_VERSION=1.29
ARG POSTIZ_VERSION=latest

# --- Stage 1: Temporal admin tools (schema files + migration tool) ---
FROM docker.io/temporalio/admin-tools:${TEMPORAL_TOOLS_VERSION} AS temporal-tools

# --- Stage 2: Pre-built Postiz app ---
FROM ghcr.io/gitroomhq/postiz-app:${POSTIZ_VERSION} AS postiz-source

# --- Stage 3: Final UBI 10 image with all services ---
FROM registry.access.redhat.com/ubi10/ubi-init

ARG TEMPORAL_VERSION=1.29.3

LABEL maintainer="Scott McCarty <smccarty@redhat.com>" \
      description="Postiz social media scheduler on UBI 10 with systemd"

# ---- System packages ----
# RHEL 10 / UBI 10: modularity deprecated in DNF5, nodejs available directly
RUN dnf install -y \
        postgresql-server postgresql \
        valkey \
        nginx \
        nodejs npm \
        procps-ng hostname curl \
    && dnf clean all

# ---- Node.js tooling ----
RUN npm install -g pm2 && \
    npm cache clean --force

# ---- Temporal server binary ----
RUN curl -fsSL \
      "https://github.com/temporalio/temporal/releases/download/v${TEMPORAL_VERSION}/temporal_${TEMPORAL_VERSION}_linux_amd64.tar.gz" \
    | tar xz -C /usr/local/bin/ && \
    chmod +x /usr/local/bin/temporal-server

# Schema tools + migration SQL from temporal admin-tools
COPY --from=temporal-tools /usr/local/bin/temporal-sql-tool /usr/local/bin/
COPY --from=temporal-tools /etc/temporal/schema/postgresql /etc/temporal/schema/postgresql

# ---- Copy pre-built Postiz app from official image ----
COPY --from=postiz-source /app /app
# Rebuild native modules for RHEL glibc (bcrypt, sharp, etc.)
WORKDIR /app
RUN npm rebuild 2>/dev/null; true

# ---- Configuration files ----
COPY nginx.conf /etc/nginx/nginx.conf
COPY temporal-config.yaml /etc/temporal/config.yaml
RUN mkdir -p /etc/temporal/config/dynamicconfig
COPY dynamicconfig.yaml /etc/temporal/config/dynamicconfig/development-sql.yaml

# ---- PostgreSQL initialization script ----
RUN cat > /usr/local/bin/postiz-pg-init.sh <<'SCRIPT'
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
SCRIPT
RUN chmod +x /usr/local/bin/postiz-pg-init.sh

# ---- Database setup script (creates DBs + runs Temporal migrations) ----
RUN cat > /usr/local/bin/postiz-db-setup.sh <<'SCRIPT'
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
SCRIPT
RUN chmod +x /usr/local/bin/postiz-db-setup.sh

# ---- Postiz start script ----
RUN cat > /usr/local/bin/postiz-start.sh <<'SCRIPT'
#!/bin/bash
set -e

# Source environment file
if [ -f /etc/postiz/env ]; then
    set -a
    source /etc/postiz/env
    set +a
fi

# Wait for Temporal to be ready (gRPC on 7233)
for i in $(seq 1 60); do
    if timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/7233" 2>/dev/null; then
        echo "Temporal is ready"
        break
    fi
    echo "Waiting for Temporal... ($i/60)"
    sleep 2
done

cd /app
exec pm2-runtime ecosystem.config.js
SCRIPT
RUN chmod +x /usr/local/bin/postiz-start.sh

# ---- systemd service units ----

# PostgreSQL init (one-shot, first boot only)
RUN cat > /etc/systemd/system/postiz-pg-init.service <<'UNIT'
[Unit]
Description=Initialize PostgreSQL data directory
Before=postgresql.service
ConditionPathExists=!/var/lib/pgsql/data/PG_VERSION

[Service]
Type=oneshot
ExecStart=/usr/local/bin/postiz-pg-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# Database setup (after PostgreSQL is ready)
RUN cat > /etc/systemd/system/postiz-db-setup.service <<'UNIT'
[Unit]
Description=Create Postiz and Temporal databases
After=postgresql.service
Requires=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/postiz-db-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# Temporal server
RUN cat > /etc/systemd/system/temporal.service <<'UNIT'
[Unit]
Description=Temporal Server
After=postiz-db-setup.service
Requires=postiz-db-setup.service

[Service]
Type=simple
ExecStart=/usr/local/bin/temporal-server start --config /etc/temporal/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# Postiz application (PM2)
RUN cat > /etc/systemd/system/postiz-app.service <<'UNIT'
[Unit]
Description=Postiz Application (PM2)
After=temporal.service valkey.service nginx.service
Requires=temporal.service valkey.service

[Service]
Type=simple
WorkingDirectory=/app
EnvironmentFile=-/etc/postiz/env
ExecStart=/usr/local/bin/postiz-start.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

# Enable all services
RUN systemctl enable postiz-pg-init postgresql valkey nginx \
    postiz-db-setup temporal postiz-app

# Create required directories
RUN mkdir -p /uploads /etc/postiz && \
    chown -R postgres:postgres /var/lib/pgsql

EXPOSE 5000

VOLUME ["/var/lib/pgsql/data", "/uploads"]

ENTRYPOINT ["/sbin/init"]
