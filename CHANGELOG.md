# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.1] - 2026-10-24

### Fixed

- v0.5.0 OOM-killed the backend (384 MB heap) and the orchestrator (256 MB)
  at boot against the production database, so the API returned 502 until
  production was rolled back. Defaults are now backend 640, orchestrator 384
  and frontend 384.

### Added

- `POSTIZ_BACKEND_HEAP_MB`, `POSTIZ_FRONTEND_HEAP_MB` and
  `POSTIZ_ORCHESTRATOR_HEAP_MB` in `/etc/postiz/env` override the heap caps,
  so production can be retuned with a restart instead of a rebuild.

## [0.5.0] - 2026-10-24

### Changed

- Postiz rebased from a February 2026 base to upstream v2.25.3, on fork
  branch `crunchtools-v2.25.3`. This brings in upstream's responsive/mobile
  UI, the self-hosted MCP connector, and the v2.25.3 JWT bypass security fix.
- MCP post tools are now upstream's: `listPostsTool` is renamed
  `postsListTool`, and `deletePostTool` keeps its name. Callers of the old
  name must switch.
- The fork's patch stack drops from 10 commits to 6. Upstream absorbed the
  MCP list/delete tools, the schedule-post error wrapping, and the X
  280-character limit. Still carried: the LinkedIn and Mastodon OAuth scope
  fixes, no close-modal confirmations, the integrationList outputSchema fix
  (now also declaring `customer`), the X credits-depleted error, and the
  `POSTIZ_ACTIVE_PROVIDERS` worker allowlist, which now composes with
  upstream's `EXCLUDE_QUEUE`.

### Removed

- `patches/`: the MCP list/delete patch file. Nothing applied it, and
  upstream now ships equivalent tools.

## [0.4.1] - 2026-10-19

### Fixed

- X posts that fail for lack of API credits now say so instead of
  "Unknown Error" (fatherlinux/postiz-app#3). Posts failed this way from
  2026-09-10 to 2026-10-18 with no visible cause.
- The fork is now pinned by commit (`POSTIZ_COMMIT`). Cloning the branch by
  name let the gha layer cache serve stale source, so fork changes never
  reached the image.

### Changed

- Added `.specify/memory/constitution.md` as a v1.18.0 manifest: it holds
  only what is specific to this repo; fleet and profile rules apply by
  reference.
- Constitution validation is pinned to the inherited release via
  `.github/workflows/constitution.yml`.
- Dependabot auto-merges GitHub Actions minor and patch updates.

## [0.4.0] - 2026-09-20

### Added
- Nightly `pg_dumpall` of the whole cluster via `postiz-backup.timer`, written
  dated and gzipped to `/root/.backups` with 14-day retention (RT #1495). The
  host's weekly backup already took its own dump; this cuts worst-case RPO from
  seven days to one and keeps dated history, so a dump that goes bad cannot
  overwrite the last good one.
- Backup and restore gates in `tests/test-container.sh`: CI now runs the dump
  and restores it over the live CI cluster, asserting postiz, temporal and
  temporal_visibility all survive the round trip. 30 tests to 41.

## [0.3.0] - 2026-09-20

### Fixed
- Dual-push CI wiring reached this repo after v0.2.0 shipped; cutting the next
  release so the version already declared in README (v0.3.0, landed via the
  memory-footprint and heap-size fixes) actually lands in both registries.

### Changed
- Cut Postiz memory footprint for single-tenant use; raised backend heap to
  384MB after 256MB crash-looped in production; stopped lowering postgres
  max_connections.

### CI
- Dual-push to GHCR per constitution Section III (RT #1480).
