# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
