# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
