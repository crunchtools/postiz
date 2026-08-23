# Postiz - Self-Hosted Social Media Scheduler (v0.3.0)

Replaces Buffer with [Postiz](https://postiz.com), a self-hosted open-source social media scheduling tool. Deployed on sven as a single UBI 10 systemd container.

RT #1392

## Architecture

Single container running all services:

| Service | Port | Purpose |
|---------|------|---------|
| PostgreSQL 16 | 5432 | App DB + Temporal persistence + visibility |
| Redis 7 | 6379 | Caching/sessions |
| Temporal 1.29.3 | 7233 | Workflow orchestration (scheduled posts) |
| Node.js 22 (PM2) | 3000, 4200 | Backend + Frontend |
| nginx | 5000 | Internal reverse proxy |

External: port 8092 on sven -> container port 5000.

## Build

```bash
podman build -t localhost/postiz:latest .
```

Build requires ~4GB memory for the Node.js compilation step.

## Deploy

See `/srv/postiz.crunchtools.com/` on sven for the deployment configuration.

## Memory footprint

Upstream Postiz is built for multi-tenant SaaS. On a single-tenant install the
defaults are badly oversized, and the cost lands mostly outside the V8 heap
where `--max-old-space-size` cannot reach it. Three levers, in order of impact:

**1. Temporal worker fan-out (~700MB).** `temporal.module.ts` registers one
worker per *supported* provider, not per *connected* one — 31 workers, each
with its own `@temporalio/core-bridge` Rust core and thread pair. Set
`POSTIZ_ACTIVE_PROVIDERS` to the providers you actually use. Confirmed by
thread accounting: 31 `workflow-proces` + 31 `temporal-real-s` threads, exactly
one pair per worker.

**2. Wrapper processes (~195MB).** Upstream launches each app as
`pm2 -> pnpm start -> dotenv -> node`, costing two extra Node processes per
app. `dotenv -e ../../.env` reads a file this image never creates, so it is
pure overhead. `ecosystem.config.js` invokes `node` directly instead.

**3. Heap and pool sizing.** Per-app `--max-old-space-size` via PM2
`interpreter_args` (a CLI flag beats an inherited `NODE_OPTIONS`; the resulting
V8 ceiling is the flag + ~48MB). Temporal datastore pools and postgres
`max_connections` trimmed to match single-tenant reality.

Note that `maxCachedWorkflows` defaults to a value derived from
`v8.getHeapStatistics().heap_size_limit`, so the heap cap silently bounds the
sticky workflow cache too. We set it explicitly rather than relying on that
side effect.

## MCP Integration

Postiz exposes a Public API for scheduling posts. Due to [SSE transport issues behind nginx](https://github.com/gitroomhq/postiz-app/issues/984), use the REST API approach:

- **Base URL**: `https://postiz.crunchtools.com/api/public/v1`
- **Auth**: API key from Postiz Settings UI in `Authorization` header
- **Endpoints**: `GET /integrations`, `POST /posts`, `POST /upload`

## Fallback: Multi-Stage from Official Image

If building from source on UBI fails, replace the build section in the Containerfile:

```dockerfile
# Replace the git clone + pnpm install + pnpm build steps with:
FROM ghcr.io/gitroomhq/postiz-app:v2.19.0 AS postiz-source
# Then in the final stage:
COPY --from=postiz-source /app /app
RUN cd /app && npm rebuild
```
