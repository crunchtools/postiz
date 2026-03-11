# ==========================================================================
# Postiz - Self-hosted social media scheduler
# Single UBI 10 container with systemd
# Services: PostgreSQL 16, Valkey 8, Temporal 1.29.3, Node.js 22, nginx
# ==========================================================================
#
# Build:  podman build -t localhost/postiz:latest \
#           --secret id=activation_key,src=... --secret id=org_id,src=... .
# Run:    See README.md for podman run command
# ==========================================================================

ARG TEMPORAL_VERSION=1.29.3
ARG TCTL_VERSION=1.18.4

# --- Stage 1: Build Temporal server + sql-tool from source ---
FROM quay.io/hummingbird/go:1.25-builder AS temporal-build
ARG TEMPORAL_VERSION=1.29.3
RUN git clone --depth 1 --branch v${TEMPORAL_VERSION} \
        https://github.com/temporalio/temporal.git /src/temporal
WORKDIR /src/temporal
RUN CGO_ENABLED=0 go build -tags disable_grpc_modules -o /out/temporal-server ./cmd/server && \
    CGO_ENABLED=0 go build -tags disable_grpc_modules -o /out/temporal-sql-tool ./cmd/tools/sql

# --- Stage 2: Build tctl from source ---
FROM quay.io/hummingbird/go:1.25-builder AS tctl-build
ARG TCTL_VERSION=1.18.4
RUN git clone --depth 1 --branch v${TCTL_VERSION} \
        https://github.com/temporalio/tctl.git /src/tctl
WORKDIR /src/tctl
RUN CGO_ENABLED=0 go build -o /out/tctl ./cmd/tctl

# --- Stage 3: Build Postiz from source (UBI 10 for glibc match with final stage) ---
FROM registry.access.redhat.com/ubi10/ubi AS postiz-build
RUN dnf install -y nodejs npm git gcc g++ make python3 && dnf clean all
RUN git clone --depth 1 --branch crunchtools-patches \
        https://github.com/fatherlinux/postiz-app.git /src/postiz
WORKDIR /src/postiz
RUN npm install -g pnpm@10.6.1 && \
    echo 'onlyBuiltDependencies=*' >> .npmrc && \
    pnpm install && \
    NODE_OPTIONS="--max-old-space-size=4096" pnpm run build

# --- Stage 4: Final UBI 10 image with all services ---
# Inherits troubleshooting tools, cron, systemd hardening from ubi10-core
FROM quay.io/crunchtools/ubi10-core:latest

ARG TEMPORAL_VERSION=1.29.3

LABEL maintainer="Scott McCarty <smccarty@redhat.com>" \
      description="Postiz social media scheduler on UBI 10 with systemd"

# ---- Copy config files, scripts, and systemd units ----
COPY rootfs/ /

# ---- System packages ----
# postgresql-server requires RHSM — register, install, unregister in single layer
RUN --mount=type=secret,id=RHSM_ACTIVATION_KEY \
    --mount=type=secret,id=RHSM_ORG_ID \
    subscription-manager register \
      --activationkey="$(cat /run/secrets/RHSM_ACTIVATION_KEY)" \
      --org="$(cat /run/secrets/RHSM_ORG_ID)" \
    && dnf install -y \
        postgresql-server postgresql postgresql-contrib \
        valkey \
        nginx \
        nodejs npm \
        hostname curl \
    && dnf clean all \
    && subscription-manager unregister

# ---- Node.js tooling ----
RUN npm install -g pm2 pnpm && \
    npm cache clean --force

# ---- Temporal binaries (compiled from source) ----
COPY --from=temporal-build /out/temporal-server /usr/local/bin/
COPY --from=temporal-build /out/temporal-sql-tool /usr/local/bin/
COPY --from=tctl-build /out/tctl /usr/local/bin/

# Schema files (SQL migrations from source tree)
COPY --from=temporal-build /src/temporal/schema/postgresql /etc/temporal/schema/postgresql

# ---- Copy Postiz app built from source ----
COPY --from=postiz-build /src/postiz /app
WORKDIR /app

# ---- PM2 ecosystem config (after postiz-source copy since /app is overwritten) ----
COPY ecosystem.config.js /app/ecosystem.config.js

# ---- Self-signed cert for internal Next.js image optimization ----
# Next.js fetches absolute image URLs via HTTPS internally; nginx serves
# them on port 443 with this cert. Requires --add-host in podman run.
RUN openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout /etc/nginx/selfsigned.key \
      -out /etc/nginx/selfsigned.crt \
      -subj "/CN=postiz.crunchtools.com" 2>/dev/null

# Trust the self-signed cert in Node.js
ENV NODE_EXTRA_CA_CERTS=/etc/nginx/selfsigned.crt

# ---- Make scripts executable and enable services ----
RUN chmod +x /usr/local/bin/postiz-pg-init.sh \
              /usr/local/bin/postiz-db-setup.sh \
              /usr/local/bin/postiz-start.sh && \
    systemctl enable postiz-pg-init postgresql valkey nginx \
        postiz-db-setup temporal postiz-app

# Create required directories
RUN mkdir -p /uploads /etc/postiz && \
    chown -R postgres:postgres /var/lib/pgsql

EXPOSE 5000

VOLUME ["/var/lib/pgsql/data", "/uploads"]

ENTRYPOINT ["/sbin/init"]
