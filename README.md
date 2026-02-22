# Postiz - Self-Hosted Social Media Scheduler

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
