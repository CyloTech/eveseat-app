#!/usr/bin/env bash
# Regression test: the Appbox "installed" callback must still be sent when
# MariaDB starts long after /entrypoint.sh hands over to s6.
#
# Usage (on the builder host, needs docker):
#   release/slow-db-callback-test.sh <image> <hold-seconds> [mysql-wait-seconds]
#
# 1. A fixture container runs the image's own fresh install on an internal
#    Docker network (no internet). It copies the SeAT tree, creates the
#    database, runs the migrations and stops at the EVE SDE download.
# 2. The test container starts on the same volumes as a configured container
#    whose callback has not been sent yet (/etc/app_configured present,
#    /etc/appbox_callback_complete absent). /entrypoint.sh then starts the
#    post-start callback in the background and execs s6. A test-only
#    cont-init script holds the s6 services for <hold-seconds>, as the
#    recursive chown in 00-permissions did on busy nodes, so MariaDB answers
#    only after that. The callback goes to a local endpoint
#    (APPBOX_CALLBACK_URL) that checks the test token and the payload.
#    [mysql-wait-seconds] is passed as MYSQL_WAIT_TIMEOUT_SECONDS.
#
# Exit 0: the callback arrived with the right token after the hold, and the
#         app serves (/ redirects to the login page, which returns 200).
# Exit 1: no callback by the deadline although the app is up (the defect).
# Exit 2: the test could not run.
set -euo pipefail
LC_ALL=C
export LC_ALL

setup_fail() {
    echo "SETUP FAIL: $*" >&2
    exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] \
    || setup_fail "usage: $0 <image> <hold-seconds> [mysql-wait-seconds]"
image=$1
hold=$2
mysql_wait=${3:-}
case "$image" in ''|*[!A-Za-z0-9._/:@-]*) setup_fail "bad image reference" ;; esac
case "$hold" in ''|*[!0-9]*) setup_fail "bad hold seconds" ;; esac
case "$mysql_wait" in *[!0-9]*) setup_fail "bad MariaDB wait seconds" ;; esac
for tool in docker od date awk sed grep; do
    command -v "$tool" >/dev/null 2>&1 || setup_fail "missing tool: $tool"
done

run_id=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
prefix=seat-cbtest-$run_id
instance=cbtest-$run_id
token=cbtest-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
work=$(mktemp -d)
cleanup() {
    docker rm -f "$prefix-fixture" "$prefix-app" "$prefix-callback" >/dev/null 2>&1 || true
    for volume in public_html mysql config logs; do
        docker volume rm "$prefix-$volume" >/dev/null 2>&1 || true
    done
    docker network rm "$prefix-net" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 2' INT TERM

log() {
    printf '[%s %s] %s\n' "$(date -u +%H:%M:%S)" "$prefix" "$*"
}

docker image inspect "$image" >/dev/null 2>&1 || setup_fail "$image is not a local image"
log "image $image, hold ${hold}s, MYSQL_WAIT_TIMEOUT_SECONDS=${mysql_wait:-<unset>}"

docker network create --internal "$prefix-net" >/dev/null
# Production bind-mounts these four directories; volume-nocopy keeps the
# image's own content out of them in the same way.
mounts=()
for volume in public_html mysql config logs; do
    docker volume create "$prefix-$volume" >/dev/null
    mounts+=(--mount "type=volume,src=$prefix-$volume,dst=/home/appbox/$volume,volume-nocopy")
done
app_env=(-e WEB_URL=http://seat.cbtest.invalid -e EVE_CLIENT_ID=cbtest-client
    -e EVE_CLIENT_SECRET=cbtest-secret -e ADMIN_PASS=cbtest-admin-password)

cat > "$work/router.php" <<'PHP'
<?php
$body = json_decode(file_get_contents('php://input'), true);
$ok = $_SERVER['REQUEST_METHOD'] === 'POST'
    && parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) === '/v1/apps/installed/' . getenv('CBTEST_INSTANCE')
    && hash_equals((string) getenv('CBTEST_TOKEN'), $_SERVER['HTTP_X_CYLO_CALLBACK_TOKEN'] ?? '')
    && is_array($body['custom_fields'] ?? null);
$fields = is_array($body['custom_fields'] ?? null) ? array_column($body['custom_fields'], 'key') : [];
file_put_contents('/tmp/callbacks.log', json_encode([
    'time' => time(), 'ok' => $ok, 'fields' => $fields,
]) . "\n", FILE_APPEND);
http_response_code($ok ? 204 : 400);
PHP
chmod 644 "$work/router.php"
docker run -d --name "$prefix-callback" --network "$prefix-net" --network-alias callback \
    -e CBTEST_INSTANCE="$instance" -e CBTEST_TOKEN="$token" \
    -v "$work/router.php:/cbtest/router.php:ro" \
    --entrypoint php "$image" -S 0.0.0.0:8080 /cbtest/router.php >/dev/null

log "fixture: fresh install without internet (stops at the EVE SDE download)"
docker run -d --name "$prefix-fixture" --network "$prefix-net" "${mounts[@]}" "${app_env[@]}" \
    -e SKIP_APPBOX_CALLBACK=1 -e SDE_UPDATE_TIMEOUT_SECONDS=30 "$image" >/dev/null
fixture_state=
for _ in $(seq 1 240); do
    fixture_state=$(docker inspect -f '{{.State.Status}}' "$prefix-fixture")
    [ "$fixture_state" = exited ] && break
    sleep 5
done
docker logs "$prefix-fixture" > "$work/fixture.log" 2>&1 || true
if [ "$fixture_state" != exited ] \
    || ! grep -q '\[eveseat\] Fresh SeAT install detected' "$work/fixture.log" \
    || ! grep -q '\[eveseat\] ERROR: EVE SDE update failed' "$work/fixture.log" \
    || grep -q '\[eveseat\] ERROR: setup failed' "$work/fixture.log"; then
    grep -E '\[eveseat\]' "$work/fixture.log" | tail -20 >&2 || true
    setup_fail "the fixture install did not reach the EVE SDE step (state $fixture_state)"
fi
docker rm "$prefix-fixture" >/dev/null
log "fixture ready: SeAT tree, .env and migrated database on the test volumes"

cat > "$work/50-cbtest-hold" <<EOF
#!/bin/sh
echo "[cbtest] holding the s6 services for $hold seconds"
sleep $hold
echo "[cbtest] releasing the s6 services"
EOF
chmod 755 "$work/50-cbtest-hold"
: > "$work/app_configured"
wait_env=()
[ -z "$mysql_wait" ] || wait_env=(-e "MYSQL_WAIT_TIMEOUT_SECONDS=$mysql_wait")
docker create --name "$prefix-app" --network "$prefix-net" "${mounts[@]}" "${app_env[@]}" \
    -e INSTANCE_ID="$instance" -e CALLBACK_TOKEN="$token" \
    -e APPBOX_CALLBACK_URL="http://callback:8080/v1/apps/installed/$instance" \
    "${wait_env[@]}" \
    -v "$work/50-cbtest-hold:/etc/cont-init.d/50-cbtest-hold:ro" \
    "$image" >/dev/null
docker cp "$work/app_configured" "$prefix-app:/etc/app_configured"
docker start "$prefix-app" >/dev/null
started=$(date +%s)
deadline=$((started + hold + 420))
log "test container started; waiting up to $((deadline - started))s for the callback"

app_logs() {
    docker logs -t "$prefix-app" 2>&1 \
        | grep -E '\[eveseat\]|\[cbtest\]|legacy-cont-init|legacy-services' | cut -c1-220 || true
}
log_time() {
    local stamp
    stamp=$(app_logs | grep -F -- "$1" | tail -n 1 | awk '{print $1}')
    [ -n "$stamp" ] || return 1
    date -u -d "$stamp" +%s
}
app_serves() {
    local headers code location path login_code
    headers=$(docker exec "$prefix-app" curl -s -o /dev/null -D - --max-time 20 http://127.0.0.1/ | tr -d '\r') \
        || return 1
    code=$(printf '%s\n' "$headers" | awk 'NR == 1 {print $2}')
    location=$(printf '%s\n' "$headers" | sed -n 's/^[Ll]ocation: //p' | head -n 1)
    [ "$code" = 302 ] && [ -n "$location" ] || return 1
    path=/${location#*://*/}
    login_code=$(docker exec "$prefix-app" curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        "http://127.0.0.1$path") || return 1
    echo "GET / -> 302 $path, GET $path -> $login_code"
    [ "$login_code" = 200 ]
}

callback_at=
while :; do
    now=$(date +%s)
    state=$(docker inspect -f '{{.State.Status}}' "$prefix-app" 2>/dev/null || echo missing)
    if [ "$state" != running ]; then
        app_logs | tail -n 30 >&2
        setup_fail "the test container is $state"
    fi
    if docker exec "$prefix-callback" grep -q '"ok":true' /tmp/callbacks.log 2>/dev/null; then
        callback_at=$now
        break
    fi
    [ "$now" -lt "$deadline" ] || break
    sleep 5
done

echo "--- entrypoint and s6 log"
app_logs
echo "--- callbacks received"
docker exec "$prefix-callback" cat /tmp/callbacks.log 2>/dev/null || echo "(none)"
echo "---"

handover=$(log_time '[eveseat] Starting supervised services') || setup_fail "no handover to s6 in the log"
released=$(log_time '[cbtest] releasing the s6 services') || setup_fail "the hold never ended"
held=$((released - handover))
log "s6 services held ${held}s after /entrypoint.sh handed over (5.0.1-3 waited 180s for MariaDB)"
[ "$held" -ge $((hold - 5)) ] || setup_fail "services were held only ${held}s, expected about ${hold}s"

if [ -z "$callback_at" ]; then
    if serving=$(app_serves); then
        log "app serves ($serving) but no callback arrived within $((deadline - started))s"
        echo "RESULT: FAIL (callback lost)"
        exit 1
    fi
    setup_fail "no callback and the app does not serve either"
fi

log "callback received $((callback_at - started))s after start, $((callback_at - released))s after the services were released"
[ "$callback_at" -ge "$released" ] || setup_fail "callback arrived before the services were released"
if [ -n "$mysql_wait" ] && [ "$mysql_wait" -lt "$hold" ]; then
    app_logs | grep -q 'Runtime services are not ready yet' \
        || { echo "RESULT: FAIL (no retry after the ${mysql_wait}s MariaDB wait ran out)"; exit 1; }
    log "the first ${mysql_wait}s MariaDB wait ran out and the callback was retried"
fi
serving=$(app_serves) || { echo "$serving"; echo "RESULT: FAIL (app does not serve)"; exit 1; }
log "app serves: $serving"
echo "RESULT: PASS"
