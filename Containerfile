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

# ---- RHEL subscription for CI builds ----
# On RHEL hosts (e.g. sven), buildah shares host subscriptions — no args needed.
# In CI, pass --secret id=activation_key,src=... --secret id=org_id,src=...
RUN --mount=type=secret,id=activation_key \
    --mount=type=secret,id=org_id \
    if [ -f /run/secrets/activation_key ] && [ -f /run/secrets/org_id ]; then \
        subscription-manager register \
            --activationkey="$(cat /run/secrets/activation_key)" \
            --org="$(cat /run/secrets/org_id)"; \
    fi

# ---- Copy config files, scripts, and systemd units ----
COPY rootfs/ /

# ---- System packages ----
RUN dnf install -y \
        postgresql-server postgresql postgresql-contrib \
        valkey \
        nginx \
        nodejs npm \
        procps-ng hostname curl \
    && dnf clean all

# ---- Unregister from RHSM (if registered above) ----
RUN subscription-manager unregister 2>/dev/null || true

# ---- Node.js tooling ----
RUN npm install -g pm2 pnpm && \
    npm cache clean --force

# ---- Temporal server binary ----
RUN curl -fsSL \
      "https://github.com/temporalio/temporal/releases/download/v${TEMPORAL_VERSION}/temporal_${TEMPORAL_VERSION}_linux_amd64.tar.gz" \
    | tar xz -C /usr/local/bin/ && \
    chmod +x /usr/local/bin/temporal-server

# Schema tools + migration SQL + CLI from temporal admin-tools
COPY --from=temporal-tools /usr/local/bin/temporal-sql-tool /usr/local/bin/
COPY --from=temporal-tools /usr/local/bin/tctl /usr/local/bin/
COPY --from=temporal-tools /etc/temporal/schema/postgresql /etc/temporal/schema/postgresql

# ---- Copy pre-built Postiz app from official image ----
COPY --from=postiz-source /app /app
# Rebuild native modules for RHEL glibc (bcrypt, sharp, etc.)
WORKDIR /app
RUN npm rebuild 2>/dev/null; true

# ---- Patch social provider scopes ----
# LinkedIn: Remove org scopes that require Community Management API product
RUN sed -i "s/'openid', 'profile', 'w_member_social', 'r_basicprofile', 'rw_organization_admin', 'w_organization_social', 'r_organization_social'/'openid', 'profile', 'w_member_social'/" \
    /app/apps/backend/dist/libraries/nestjs-libraries/src/integrations/social/linkedin.provider.js

# Mastodon: Replace 'profile' scope with 'read:accounts' (noc.social compatibility)
RUN sed -i "s/'write:statuses', 'profile', 'write:media'/'write:statuses', 'read:accounts', 'write:media'/" \
    /app/apps/backend/dist/libraries/nestjs-libraries/src/integrations/social/mastodon.provider.js

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
