#!/bin/bash
# postiz-backup.sh — nightly logical dump of the whole PostgreSQL cluster.
#
# Why this exists (RT #1495): pbs.sh already takes a pg_dumpall of this container
# from the host, but only on the weekly and monthly ServerBackups rotations. That
# leaves a 7-day worst-case RPO on scheduled posts and re-authed OAuth tokens,
# and it keeps exactly one file, overwritten in place, so a dump that went bad
# three cycles ago has already destroyed the good ones.
#
# This writes a dated, gzipped dump every night into /root/.backups, which the
# host bind-mounts from /srv/postiz.crunchtools.com/data/backups. pbs's weekly
# rclone sync of /srv carries that directory to pCloud untouched — */data/backups
# is not in its exclude list — so the dated history ships for free. The host-side
# weekly dump and its Nagios sentinel are unaffected; this layers on top.
#
# pg_dumpall, not pg_dump: the cluster holds postiz, temporal and
# temporal_visibility plus the temporal role, and a postiz-only dump restores
# into a stack that will not start.

set -u -o pipefail

BACKUP_DIR=${BACKUP_DIR:-/root/.backups}
RETAIN_DAYS=${RETAIN_DAYS:-14}
STAMP=$(date +%Y%m%d)
TARGET="$BACKUP_DIR/postiz-${STAMP}.sql.gz"
LATEST="$BACKUP_DIR/postiz-latest.sql.gz"
# Sanity floor only. A content check does the real work below: an absolute byte
# threshold tuned to production (~2 MB gzipped) would reject a legitimate dump
# from a fresh cluster in CI, and "big enough" was never good evidence anyway.
# The production shrinkage guard lives in nagios-agent's check_backup_freshness.sh.
MIN_BYTES=${MIN_BYTES:-1024}

mkdir -p "$BACKUP_DIR" || { echo "cannot create $BACKUP_DIR"; exit 1; }

if ! pg_isready -q; then
    echo "postgres not ready, refusing to dump"
    exit 1
fi

# Write to a temp file first. A half-written dump must never replace a good one,
# and must never be the newest file the retention sweep decides to keep.
TMP=$(mktemp "$BACKUP_DIR/.postiz-dump.XXXXXX") || exit 1
trap 'rm -f "$TMP"' EXIT

# -U postgres as root, not su: this is the exact invocation pbs.sh already uses
# against this container from the host, so it is the path known to work here.
if ! pg_dumpall -U postgres --clean --if-exists 2>/tmp/postiz-backup.err | gzip -c > "$TMP"; then
    echo "pg_dumpall failed: $(head -c 500 /tmp/postiz-backup.err)"
    exit 1
fi

SIZE=$(stat -c %s "$TMP")
if [ "$SIZE" -lt "$MIN_BYTES" ]; then
    echo "dump is ${SIZE}B, below the ${MIN_BYTES}B floor — treating as failed"
    exit 1
fi

# gzip -t catches truncation the exit code above can miss when the pipe breaks.
if ! gzip -t "$TMP"; then
    echo "dump failed gzip integrity check"
    exit 1
fi

# The dump has to actually contain the cluster. pg_dumpall exits 0 on a
# connection it can open but has no rights to read, which yields a syntactically
# valid file with nothing in it.
#
# One pass, and grep -o rather than a loop of grep -q: under `set -o pipefail`,
# grep -q closes the pipe the moment it matches, gunzip takes SIGPIPE, and the
# pipeline reports failure on a dump that was perfectly good.
FOUND=$(gunzip -c "$TMP" \
    | grep -oE 'CREATE DATABASE postiz|CREATE DATABASE temporal|CREATE ROLE temporal' \
    | sort -u | wc -l)
if [ "$FOUND" -ne 3 ]; then
    echo "dump matched only ${FOUND}/3 expected cluster markers — treating as failed"
    exit 1
fi

chmod 600 "$TMP"
mv "$TMP" "$TARGET"
trap - EXIT
cp -f "$TARGET" "$LATEST"

# Retention. Only ever deletes dated dumps this script wrote; postiz-latest and
# anything else in the directory are left alone.
find "$BACKUP_DIR" -maxdepth 1 -name 'postiz-20*.sql.gz' -type f \
    -mtime "+${RETAIN_DAYS}" -delete

echo "wrote $TARGET (${SIZE} bytes), retaining ${RETAIN_DAYS} days"
