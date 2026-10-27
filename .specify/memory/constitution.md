# postiz Constitution

> **Version:** 1.1.0
> **Ratified:** 2026-10-02
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.27.0
> **Profile:** Container Image

This file holds what is specific to the postiz image. The fleet rules and the
Container Image profile apply at the inherited version and are checked against
this repo's files by `constitution.yml`. They are not restated here.

## Image Purpose

Self-hosted [Postiz](https://postiz.com) social media scheduler, replacing
Buffer (RT #1392). One UBI 10 systemd container runs every service Postiz
needs. Published to `quay.io/crunchtools/postiz` and
`ghcr.io/crunchtools/postiz`.

## Build Stages

| Stage | Image | Builds |
|-------|-------|--------|
| `temporal-build` | `quay.io/hummingbird/go:1.25-builder` | `temporal-server` and `temporal-sql-tool` from the `v${TEMPORAL_VERSION}` tag (1.29.3), `CGO_ENABLED=0` |
| `tctl-build` | `quay.io/hummingbird/go:1.25-builder` | `tctl` from the `v${TCTL_VERSION}` tag (1.18.4) |
| `postiz-build` | `registry.access.redhat.com/ubi10/ubi` | Postiz from source with pnpm 10.6.1; UBI so glibc matches the final stage. Needs ~4 GB memory |
| final | `quay.io/crunchtools/ubi10-core:latest` | runtime; rebuilds when the parent does |

The final stage registers with RHSM because `postgresql-server` needs it, and
unregisters in the same layer.

## Postiz Source

Postiz is built from a pinned commit (`POSTIZ_COMMIT`) on a
`crunchtools-<upstream tag>` branch of `github.com/fatherlinux/postiz-app`,
currently `crunchtools-v2.25.3`: upstream's release tag plus a thin stack of
crunchtools patches. Upstream does not merge outside PRs, so the stack is
rebased onto each upstream release we adopt, and patches upstream absorbs are
dropped. Older branches stay for rollback. If building from source on UBI fails, the README documents a
fallback that copies `/app` from the official upstream image.

## Services and Ports

`ENTRYPOINT ["/sbin/init"]`; one container, these units enabled:
`postiz-pg-init`, `postgresql`, `valkey`, `nginx`, `postiz-db-setup`,
`temporal`, `postiz-app`, `postiz-backup.timer`.

| Service | Port | Purpose |
|---------|------|---------|
| PostgreSQL | 5432 | Postiz DB plus Temporal persistence and visibility |
| Valkey | 6379 | caching and sessions |
| Temporal | 7233 | workflow orchestration for scheduled posts |
| Node.js under PM2 | 3000, 4200 | backend and frontend (plus the orchestrator) |
| nginx | 5000 | the only exposed port; reverse proxy to 3000 and 4200 |
| nginx | 443 | internal only, self-signed, for Next.js image optimization |

Only 5000 is published; the host maps 8092 to it. The self-signed certificate
(`NODE_EXTRA_CA_CERTS`) exists because Next.js fetches absolute image URLs
over HTTPS internally, which requires `--add-host` at run time.

## Memory Budget

Upstream Postiz is sized for multi-tenant SaaS; this image is single-tenant.

- **Temporal workers:** set `POSTIZ_ACTIVE_PROVIDERS` to the connected
  providers. Unset, the orchestrator starts one worker per supported provider
  (31, ~700 MB native memory). A provider missing from the list gets no worker
  and its posts never execute, so connecting a provider means adding it here.
- **No wrapper processes:** `ecosystem.config.js` runs `node` directly, not
  upstream's `pnpm start -> dotenv -> node` chain (~195 MB saved). The
  environment comes from `--env-file` and `postiz-app.service`.
- **Per-app heap caps** via PM2 `interpreter_args`: defaults backend 640 MB,
  frontend 384 MB, orchestrator 384 MB, each overridable with
  `POSTIZ_{BACKEND,FRONTEND,ORCHESTRATOR}_HEAP_MB` in `/etc/postiz/env`. Every
  app has crash-looped at a lower value (backend at 256 and, on v2.25.3, at
  384; orchestrator at 256 on v2.25.3); do not lower one without watching
  `pm2 list` restart counts under real traffic. The container's `--memory=2g`
  is the hard ceiling on their sum plus native memory.

## Backups

`postiz-backup.timer` runs nightly at 04:00 container-local. It takes a
`pg_dumpall` of the whole cluster (postiz, temporal, temporal_visibility and
the `temporal` role), because a postiz-only dump restores into a stack that
will not start. Dumps land gzipped and dated in `/root/.backups` (mode 0700,
bind-mounted from the host), kept 14 days, with `postiz-latest.sql.gz`
refreshed.

The script writes to a temp file, checks gzip integrity and greps for three
cluster markers before it replaces yesterday's dump: a bad dump is worse than
a missing one. CI runs the dump and restores it, asserting all three
databases survive the round trip (RT #1495). This is a second layer; the
host's own weekly and monthly `pg_dumpall` is the first.

## Data Persistence

Volumes: `/var/lib/pgsql/data` and `/uploads`. Configuration and secrets
(`JWT_SECRET`, social provider API keys) come from an env file shaped like
`.env.example`; the live deployment configuration lives in the private host
repo, not here.

## History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-10-02 | Initial constitution, written as a v1.18.0 manifest |
| 1.1.0 | 2026-10-24 | Postiz source is a `crunchtools-<upstream tag>` fork branch pinned by commit; heap caps raised for v2.25.3 and made env-overridable |
