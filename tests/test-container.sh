#!/bin/bash
# ==========================================================================
# tests/test-container.sh — Validate Postiz container image
# Usage: tests/test-container.sh <image-name>
# Outputs TAP-format results, exits non-zero on any failure.
# ==========================================================================
set -uo pipefail

IMAGE="${1:?Usage: $0 <image-name>}"
ENGINE="${CONTAINER_ENGINE:-podman}"
CTR="postiz-test-$$"
FAIL=0
N=0
ENVFILE=""

# --- TAP helpers ---
tap() {
    local result="$1" desc="$2"
    ((N++))
    if [ "$result" = "PASS" ]; then
        echo "ok $N - $desc"
    else
        echo "not ok $N - $desc"
        ((FAIL++))
    fi
}

cleanup() {
    echo "# Cleanup: removing $CTR"
    $ENGINE stop -t5 "$CTR" &>/dev/null || true
    $ENGINE rm -f "$CTR" &>/dev/null || true
    [ -n "$ENVFILE" ] && rm -f "$ENVFILE"
}
trap cleanup EXIT

echo "TAP version 13"
echo "1..30"
echo "# Image: $IMAGE"
echo "# Engine: $ENGINE"

# ==================================================================
# Phase 1: Static image checks (single container, no systemd)
# ==================================================================
echo "# --- Phase 1: Static image checks ---"

while IFS='|' read -r result desc; do
    tap "$result" "$desc"
done < <($ENGINE run --rm --entrypoint /bin/bash "$IMAGE" -c '
    ok()   { echo "PASS|$1"; }
    nok()  { echo "FAIL|$1"; }

    # Required files
    for f in /etc/nginx/nginx.conf /etc/temporal/config.yaml \
             /usr/local/bin/temporal-server /usr/local/bin/postiz-start.sh \
             /app/ecosystem.config.js /etc/nginx/selfsigned.crt \
             /etc/nginx/selfsigned.key; do
        [ -f "$f" ] && ok "$f exists" || nok "$f exists"
    done

    # Executables
    for f in /usr/local/bin/temporal-server /usr/local/bin/postiz-start.sh \
             /usr/local/bin/postiz-pg-init.sh /usr/local/bin/postiz-db-setup.sh; do
        [ -x "$f" ] && ok "$f is executable" || nok "$f is executable"
    done

    # Systemd units enabled
    for s in postgresql valkey nginx temporal postiz-app postiz-pg-init postiz-db-setup; do
        systemctl is-enabled "$s" >/dev/null 2>&1 \
            && ok "$s service enabled" || nok "$s service enabled"
    done

    # nginx SSL block
    grep -q "listen 443 ssl" /etc/nginx/nginx.conf \
        && ok "nginx.conf has SSL server block" || nok "nginx.conf has SSL server block"
')

# NODE_EXTRA_CA_CERTS (via image inspect — cannot check inside non-running container)
if $ENGINE image inspect "$IMAGE" 2>/dev/null | grep -q NODE_EXTRA_CA_CERTS; then
    tap "PASS" "NODE_EXTRA_CA_CERTS set in image config"
else
    tap "FAIL" "NODE_EXTRA_CA_CERTS set in image config"
fi

# Phase 1 total: 7 files + 4 exec + 7 systemd + 1 SSL + 1 env = 20 tests

# ==================================================================
# Phase 2: Runtime service checks (systemd container)
# ==================================================================
echo "# --- Phase 2: Runtime service checks ---"

# Minimal .env for CI testing
ENVFILE=$(mktemp)
cat > "$ENVFILE" <<'ENV'
JWT_SECRET=ci-test-secret-not-for-production
DATABASE_URL=postgresql://postgres@127.0.0.1:5432/postiz
REDIS_URL=redis://127.0.0.1:6379
TEMPORAL_ADDRESS=127.0.0.1:7233
MAIN_URL=http://localhost:5000
FRONTEND_URL=http://localhost:5000
NEXT_PUBLIC_BACKEND_URL=http://localhost:5000/api
BACKEND_INTERNAL_URL=http://localhost:3000
STORAGE_PROVIDER=local
UPLOAD_DIRECTORY=/uploads
NEXT_PUBLIC_UPLOAD_DIRECTORY=/uploads
IS_GENERAL=true
NX_ADD_PLUGINS=false
DISABLE_REGISTRATION=true
ENV

echo "# Starting systemd container..."
$ENGINE run -d \
    --name "$CTR" \
    --systemd=always \
    --privileged \
    --add-host=postiz.crunchtools.com:127.0.0.1 \
    -v "$ENVFILE":/etc/postiz/env:Z \
    "$IMAGE"

# Wait for PostgreSQL (up to 120s)
echo "# Waiting for PostgreSQL (up to 120s)..."
for i in $(seq 1 60); do
    if $ENGINE exec "$CTR" pg_isready -q 2>/dev/null; then
        echo "# PostgreSQL ready after $((i * 2))s"
        break
    fi
    sleep 2
done

# Wait for Temporal (up to 60s after PG)
echo "# Waiting for Temporal (up to 60s)..."
for i in $(seq 1 30); do
    if $ENGINE exec "$CTR" bash -c "timeout 1 bash -c 'echo > /dev/tcp/127.0.0.1/7233'" &>/dev/null; then
        echo "# Temporal ready after $((i * 2))s"
        break
    fi
    sleep 2
done

# Brief pause for nginx to finish starting
sleep 5

# Runtime check helper
run_check() {
    local desc="$1"; shift
    if $ENGINE exec "$CTR" "$@" &>/dev/null; then
        tap "PASS" "$desc"
    else
        tap "FAIL" "$desc"
    fi
}

run_check "PostgreSQL is ready" pg_isready
run_check "Valkey responds to PING" valkey-cli PING
run_check "Temporal port 7233 listening" \
    bash -c "timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/7233'"
run_check "nginx port 5000 listening" \
    bash -c "timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/5000'"
run_check "nginx port 443 listening" \
    bash -c "timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/443'"
run_check "postiz database exists" \
    bash -c "psql -U postgres -lqt | grep -qw postiz"
run_check "temporal database exists" \
    bash -c "psql -U postgres -lqt | grep -qw temporal"
run_check "temporal_visibility database exists" \
    bash -c "psql -U postgres -lqt | grep -qw temporal_visibility"
run_check "HTTP response on port 5000" \
    bash -c "curl -s -o /dev/null http://localhost:5000/"
run_check "HTTPS response on port 443" \
    bash -c "curl -sk -o /dev/null https://localhost:443/"

# Phase 2 total: 10 tests
# Grand total: 30 tests

# ==================================================================
# Summary
# ==================================================================
echo "#"
if [ "$FAIL" -eq 0 ]; then
    echo "# All $N tests passed"
else
    echo "# $FAIL of $N tests FAILED"
    echo "# --- Service status ---"
    $ENGINE exec "$CTR" systemctl --no-pager status \
        postgresql valkey nginx temporal postiz-app 2>&1 | sed 's/^/# /'
    echo "# --- Journal (last 50 lines) ---"
    $ENGINE exec "$CTR" journalctl --no-pager -n 50 2>&1 | sed 's/^/# /'
fi

exit $((FAIL > 0 ? 1 : 0))
