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

# Create Temporal default namespace (idempotent)
tctl --address 127.0.0.1:7233 namespace register --desc 'Default namespace' --rd 1 default 2>/dev/null || true

# Run Prisma database migrations
pnpm dlx prisma@6.5.0 db push --accept-data-loss --schema ./libraries/nestjs-libraries/src/database/prisma/schema.prisma

exec pm2-runtime ecosystem.config.js
