#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FLAG=/etc/app_configured
CALLBACK_FLAG=/etc/appbox_callback_complete
SEAT_RELEASE_DIR=${SEAT_RELEASE_DIR:-/opt/seat-preinstall/seat}
SEAT_APP_DIR=${SEAT_APP_DIR:-/home/appbox/public_html/seat}
PUBLIC_HTML_DIR=/home/appbox/public_html
CONFIG_DIR=/home/appbox/config
LOG_DIR=/home/appbox/logs
MYSQL_DIR=/home/appbox/mysql
MYSQL_DATA_DIR=${MYSQL_DATA_DIR:-/home/appbox/mysql/data}
MYSQL_RUN_DIR=/run/mysqld
MYSQL_SOCKET=${MYSQL_SOCKET:-/run/mysqld/mysqld.sock}
MYSQLD_DEFAULTS=${MYSQLD_DEFAULTS:-/home/appbox/config/mysql/mysqld.cnf}
REDIS_CONF=${REDIS_CONF:-/etc/redis/redis.conf}
APP_USER=appbox
APP_UID=1000
APP_GID=1000
DB_NAME=${DB_NAME:-seat}
DB_USER=${DB_USER:-seat}
DB_PASS=${DB_PASS:-seat}
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS:-${MYSQL_ROOT_PASSWORD:-mysqlr00t}}
WEB_URL=${WEB_URL:-${APP_URL:-}}
APP_VERSION=${SEAT_IMAGE_VERSION:-5.0.1-2}
APP_RELEASE_MARKER=${SEAT_IMAGE_REVISION:-${APP_VERSION}}
UPGRADE_BACKUP_DIR=${SEAT_UPGRADE_BACKUP_DIR:-/home/appbox/public_html/.seat-upgrade-backups}
SDE_UPDATE_TIMEOUT_SECONDS=${SDE_UPDATE_TIMEOUT_SECONDS:-3600}
# How long to wait for MariaDB to answer, both for the setup instance and for
# the supervised one before the Appbox callback. On busy disks MariaDB can
# take several minutes to start.
MYSQL_WAIT_TIMEOUT_SECONDS=${MYSQL_WAIT_TIMEOUT_SECONDS:-900}
[[ "${MYSQL_WAIT_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]{0,5}$ ]] || MYSQL_WAIT_TIMEOUT_SECONDS=900
# How long the post-start callback keeps waiting for MariaDB, Redis and the
# web server before giving up until the next container start.
CALLBACK_READY_TIMEOUT_SECONDS=${CALLBACK_READY_TIMEOUT_SECONDS:-3600}
[[ "${CALLBACK_READY_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]{0,5}$ ]] || CALLBACK_READY_TIMEOUT_SECONDS=3600
TEMP_MYSQL_PID=""
TEMP_REDIS_PID=""
ADMIN_LOGIN_URL=""
MYSQL_ROOT_AUTH_MODE=""
SHOULD_CALLBACK=0

log() {
    printf '[eveseat] %s\n' "$*"
}

fatal() {
    printf '[eveseat] ERROR: %s\n' "$*" >&2
    exit 1
}

on_error() {
    local exit_code=$?
    printf '[eveseat] ERROR: setup failed at line %s with exit code %s\n' "${BASH_LINENO[0]:-unknown}" "${exit_code}" >&2
    stop_temporary_services || true
    exit "${exit_code}"
}
trap on_error ERR

require_file() {
    [[ -f "$1" ]] || fatal "Missing required file: $1"
}

normalize_web_url() {
    WEB_URL="${WEB_URL%/}"
    [[ -n "${WEB_URL}" ]] || fatal "WEB_URL or APP_URL must be provided"
    case "${WEB_URL}" in
        http://*|https://*) ;;
        *) fatal "WEB_URL must start with http:// or https://" ;;
    esac
}

require_inputs() {
    normalize_web_url
    [[ -n "${EVE_CLIENT_ID:-}" ]] || fatal "EVE_CLIENT_ID must be provided"
    [[ -n "${EVE_CLIENT_SECRET:-}" ]] || fatal "EVE_CLIENT_SECRET must be provided"
    [[ -n "${ADMIN_PASS:-}" ]] || fatal "ADMIN_PASS must be provided"
    require_file "${SEAT_RELEASE_DIR}/artisan"
    require_file "${SEAT_RELEASE_DIR}/public/index.php"
}

prepare_directories() {
    mkdir -p \
        "${PUBLIC_HTML_DIR}" \
        "${CONFIG_DIR}/nginx/sites-enabled" \
        "${CONFIG_DIR}/mysql" \
        "${LOG_DIR}/seat" \
        "${LOG_DIR}/mysql" \
        "${LOG_DIR}/redis" \
        "${MYSQL_DATA_DIR}" \
        "${MYSQL_RUN_DIR}" \
        /run/sshd \
        /run/php \
        /home/appbox/.ssh \
        "${UPGRADE_BACKUP_DIR}"

    chmod 700 /home/appbox/.ssh
    touch /home/appbox/.ssh/authorized_keys
    chmod 600 /home/appbox/.ssh/authorized_keys
    chown -R "${APP_UID}:${APP_GID}" /home/appbox /run/php "${MYSQL_RUN_DIR}"
}

install_configs() {
    cp /opt/eveseat/sources/eveseat.conf "${CONFIG_DIR}/nginx/sites-enabled/eveseat.conf"
    rm -f "${CONFIG_DIR}/nginx/sites-enabled/default-site.conf" /etc/nginx/sites-enabled/default || true
    ln -sf "${CONFIG_DIR}/nginx/sites-enabled/eveseat.conf" /etc/nginx/conf.d/eveseat.conf

    cp /opt/eveseat/sources/redis.conf "${REDIS_CONF}"
    chmod 755 "$(dirname "${REDIS_CONF}")"
    chmod 644 "${REDIS_CONF}"

    if [[ ! -f "${MYSQLD_DEFAULTS}" ]]; then
        cp /opt/eveseat/sources/mysqld.cnf "${MYSQLD_DEFAULTS}"
    fi
    chown -R "${APP_UID}:${APP_GID}" "${CONFIG_DIR}"
    chown -R "${APP_UID}:${APP_GID}" /home/appbox/logs/redis
}

configure_ssh() {
    usermod -s /bin/bash appbox
    if [[ -n "${ADMIN_PASS:-}" ]]; then
        printf 'appbox:%s\n' "${ADMIN_PASS}" | chpasswd
    fi
}

is_empty_dir() {
    [[ ! -d "$1" ]] && return 0
    [[ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

has_valid_seat_tree() {
    [[ -f "${SEAT_APP_DIR}/artisan" && -f "${SEAT_APP_DIR}/public/index.php" ]]
}

has_nested_seat_tree() {
    [[ -f "${SEAT_APP_DIR}/seat/artisan" && -f "${SEAT_APP_DIR}/seat/public/index.php" ]]
}

classify_install_state() {
    if has_valid_seat_tree; then
        echo existing
    elif is_empty_dir "${SEAT_APP_DIR}"; then
        echo fresh
    elif has_nested_seat_tree; then
        echo nested-partial
    else
        echo invalid
    fi
}

copy_release_to_fresh_tree() {
    local tmp_dir="${PUBLIC_HTML_DIR}/.seat-new-$$"
    rm -rf "${tmp_dir}"
    mkdir -p "${tmp_dir}"
    rsync -a --delete "${SEAT_RELEASE_DIR}/" "${tmp_dir}/"
    rm -rf "${SEAT_APP_DIR}"
    mv "${tmp_dir}" "${SEAT_APP_DIR}"
    chown -R "${APP_UID}:${APP_GID}" "${SEAT_APP_DIR}"
}

repair_nested_partial_tree() {
    local nested="${SEAT_APP_DIR}/seat"
    log "Repairing nested SeAT tree created by a malformed preinstall copy"
    shopt -s dotglob nullglob
    local item
    for item in "${nested}"/*; do
        mv "${item}" "${SEAT_APP_DIR}/"
    done
    shopt -u dotglob nullglob
    rmdir "${nested}" 2>/dev/null || true
}

sync_release_preserving_state() {
    local marker="${SEAT_APP_DIR}/.appbox-image-version"
    local current=""
    [[ -f "${marker}" ]] && current="$(<"${marker}")"

    if [[ "${current}" == "${APP_RELEASE_MARKER}" ]]; then
        log "SeAT release ${APP_RELEASE_MARKER} already applied"
        return 0
    fi

    log "Applying SeAT release ${APP_RELEASE_MARKER} to persisted application tree"
    local stamp backup_dir tmp_preserve
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_dir="${UPGRADE_BACKUP_DIR}/${stamp}"
    tmp_preserve="${PUBLIC_HTML_DIR}/.seat-preserve-$$"
    mkdir -p "${backup_dir}" "${tmp_preserve}"

    if [[ -f "${SEAT_APP_DIR}/.env" ]]; then
        cp -a "${SEAT_APP_DIR}/.env" "${backup_dir}/.env"
        cp -a "${SEAT_APP_DIR}/.env" "${tmp_preserve}/.env"
    fi
    if [[ -d "${SEAT_APP_DIR}/storage" ]]; then
        mkdir -p "${backup_dir}"
        cp -a "${SEAT_APP_DIR}/storage" "${backup_dir}/storage"
        mv "${SEAT_APP_DIR}/storage" "${tmp_preserve}/storage"
    fi

    rsync -a --delete \
        --exclude='.env' \
        --exclude='storage' \
        "${SEAT_RELEASE_DIR}/" "${SEAT_APP_DIR}/"

    if [[ -f "${tmp_preserve}/.env" ]]; then
        cp -a "${tmp_preserve}/.env" "${SEAT_APP_DIR}/.env"
    fi
    if [[ -d "${tmp_preserve}/storage" ]]; then
        rm -rf "${SEAT_APP_DIR}/storage"
        mv "${tmp_preserve}/storage" "${SEAT_APP_DIR}/storage"
    fi
    rm -rf "${tmp_preserve}"
    echo "${APP_RELEASE_MARKER}" > "${marker}.pending"
    chown -R "${APP_UID}:${APP_GID}" "${SEAT_APP_DIR}"
}

ensure_laravel_dirs() {
    mkdir -p \
        "${SEAT_APP_DIR}/bootstrap/cache" \
        "${SEAT_APP_DIR}/storage/app" \
        "${SEAT_APP_DIR}/storage/framework/cache" \
        "${SEAT_APP_DIR}/storage/framework/sessions" \
        "${SEAT_APP_DIR}/storage/framework/testing" \
        "${SEAT_APP_DIR}/storage/framework/views" \
        "${SEAT_APP_DIR}/storage/logs"
    chmod -R ug+rwX "${SEAT_APP_DIR}/storage" "${SEAT_APP_DIR}/bootstrap/cache"
    chown -R "${APP_UID}:${APP_GID}" "${SEAT_APP_DIR}/storage" "${SEAT_APP_DIR}/bootstrap/cache"
}

shell_quote_value() {
    local value="$1"
    if [[ "${value}" =~ ^[A-Za-z0-9_./:@%+=,-]+$ ]]; then
        printf '%s' "${value}"
    else
        printf "'%s'" "${value//\'/\'\\\'\'}"
    fi
}

set_env_var() {
    local key="$1" value="$2" quoted tmp
    quoted="$(shell_quote_value "${value}")"
    tmp="$(mktemp "${SEAT_APP_DIR}/.env.XXXXXX")"
    if [[ -f "${SEAT_APP_DIR}/.env" ]]; then
        grep -v -E "^${key}=" "${SEAT_APP_DIR}/.env" > "${tmp}" || true
    fi
    printf '%s=%s\n' "${key}" "${quoted}" >> "${tmp}"
    mv "${tmp}" "${SEAT_APP_DIR}/.env"
    chown "${APP_UID}:${APP_GID}" "${SEAT_APP_DIR}/.env"
    chmod 640 "${SEAT_APP_DIR}/.env"
}

ensure_env_file() {
    if [[ ! -f "${SEAT_APP_DIR}/.env" ]]; then
        if [[ -f "${SEAT_APP_DIR}/.env.example" ]]; then
            cp "${SEAT_APP_DIR}/.env.example" "${SEAT_APP_DIR}/.env"
        else
            cp /opt/eveseat/sources/eveconf "${SEAT_APP_DIR}/.env"
        fi
    fi

    set_env_var APP_ENV production
    set_env_var APP_DEBUG false
    set_env_var APP_URL "${WEB_URL}"
    set_env_var DB_CONNECTION mysql
    set_env_var DB_HOST 127.0.0.1
    set_env_var DB_PORT 3306
    set_env_var DB_DATABASE "${DB_NAME}"
    set_env_var DB_USERNAME "${DB_USER}"
    set_env_var DB_PASSWORD "${DB_PASS}"
    set_env_var CACHE_DRIVER redis
    set_env_var CACHE_STORE redis
    set_env_var QUEUE_CONNECTION redis
    set_env_var QUEUE_DRIVER redis
    set_env_var SESSION_DRIVER file
    set_env_var REDIS_HOST 127.0.0.1
    set_env_var REDIS_PASSWORD null
    set_env_var REDIS_PORT 6379
    set_env_var MAIL_MAILER smtp
    set_env_var MAIL_DRIVER smtp
    set_env_var EVE_CLIENT_ID "${EVE_CLIENT_ID}"
    set_env_var EVE_CLIENT_SECRET "${EVE_CLIENT_SECRET}"
    set_env_var EVE_CALLBACK_URL "${WEB_URL}/auth/eve/callback"

    chown "${APP_UID}:${APP_GID}" "${SEAT_APP_DIR}/.env"
    chmod 640 "${SEAT_APP_DIR}/.env"

    if ! grep -q '^APP_KEY=base64:' "${SEAT_APP_DIR}/.env"; then
        run_as_appbox php artisan key:generate --force --no-interaction
    fi
}

run_as_appbox() {
    gosu "${APP_UID}:${APP_GID}" "$@"
}

start_temporary_mariadb() {
    if mysqladmin --socket="${MYSQL_SOCKET}" ping --silent >/dev/null 2>&1; then
        return 0
    fi

    if [[ ! -d "${MYSQL_DATA_DIR}/mysql" ]]; then
        log "Initializing MariaDB data directory"
        install -d -o "${APP_UID}" -g "${APP_GID}" "${MYSQL_DATA_DIR}"
        if ! timeout 600 mariadb-install-db \
            --auth-root-authentication-method=normal \
            --datadir="${MYSQL_DATA_DIR}" \
            --user=appbox \
            --skip-test-db; then
            fatal "MariaDB data directory initialization failed or timed out"
        fi
        chown -R "${APP_UID}:${APP_GID}" "${MYSQL_DIR}" "${MYSQL_RUN_DIR}"
    fi

    log "Starting temporary MariaDB for setup"
    gosu "${APP_UID}:${APP_GID}" mariadbd \
        --defaults-file="${MYSQLD_DEFAULTS}" \
        --user=appbox \
        --datadir="${MYSQL_DATA_DIR}" \
        --socket="${MYSQL_SOCKET}" &
    TEMP_MYSQL_PID=$!
    wait_for_mysql
}

mysql_ready_within() {
    local deadline=$((SECONDS + $1))
    until mysqladmin --socket="${MYSQL_SOCKET}" ping --silent >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
            return 1
        fi
        sleep 2
    done
}

wait_for_mysql() {
    if ! mysql_ready_within "${MYSQL_WAIT_TIMEOUT_SECONDS}"; then
        fatal "Timed out waiting for MariaDB after ${MYSQL_WAIT_TIMEOUT_SECONDS} seconds"
    fi
}

mysql_root_without_password() {
    env -u MYSQL_PWD mysql \
        --protocol=socket \
        --socket="${MYSQL_SOCKET}" \
        --user=root \
        "$@"
}

mysql_root_with_password() {
    MYSQL_PWD="${MYSQL_ROOT_PASS}" mysql \
        --protocol=socket \
        --socket="${MYSQL_SOCKET}" \
        --user=root \
        "$@"
}

mysql_root() {
    case "${MYSQL_ROOT_AUTH_MODE}" in
        passwordless)
            mysql_root_without_password
            ;;
        password)
            mysql_root_with_password
            ;;
        *)
            fatal "MariaDB root authentication mode has not been established"
            ;;
    esac
}

mysqladmin_root() {
    case "${MYSQL_ROOT_AUTH_MODE}" in
        passwordless)
            env -u MYSQL_PWD mysqladmin \
                --protocol=socket \
                --socket="${MYSQL_SOCKET}" \
                --user=root \
                "$@"
            ;;
        password)
            MYSQL_PWD="${MYSQL_ROOT_PASS}" mysqladmin \
                --protocol=socket \
                --socket="${MYSQL_SOCKET}" \
                --user=root \
                "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

mysql_app() {
    MYSQL_PWD="${DB_PASS}" mysql \
        --protocol=TCP \
        --host=127.0.0.1 \
        --port=3306 \
        --user="${DB_USER}" \
        --database="${DB_NAME}" \
        "$@"
}

detect_mysql_root_auth() {
    if mysql_root_without_password --execute='SELECT 1' >/dev/null 2>&1; then
        MYSQL_ROOT_AUTH_MODE=passwordless
        return 0
    fi

    if [[ -n "${MYSQL_ROOT_PASS}" ]] \
        && mysql_root_with_password --execute='SELECT 1' >/dev/null 2>&1; then
        MYSQL_ROOT_AUTH_MODE=password
        return 0
    fi

    return 1
}

sql_identifier() {
    printf '%s' "$1" | sed 's/`/``/g'
}

sql_string() {
    printf '%s' "$1" | sed "s/'/''/g"
}

configure_database() {
    local db_name db_user db_pass

    if ! detect_mysql_root_auth; then
        if mysql_app --execute='SELECT 1' >/dev/null 2>&1; then
            log "MariaDB root authentication unavailable; existing ${DB_USER} database access is valid"
            return 0
        fi
        fatal "Unable to authenticate to MariaDB as root or as ${DB_USER}"
    fi

    db_name="$(sql_identifier "${DB_NAME}")"
    db_user="$(sql_string "${DB_USER}")"
    db_pass="$(sql_string "${DB_PASS}")"

    log "Configuring MariaDB using ${MYSQL_ROOT_AUTH_MODE} root authentication"
    mysql_root <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

start_temporary_redis() {
    if redis-cli -h 127.0.0.1 ping >/dev/null 2>&1; then
        return 0
    fi
    log "Starting temporary Redis for setup"
    gosu "${APP_UID}:${APP_GID}" redis-server "${REDIS_CONF}" &
    TEMP_REDIS_PID=$!
    local i
    for i in {1..30}; do
        if redis-cli -h 127.0.0.1 ping >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    fatal "Timed out waiting for Redis"
}

stop_temporary_services() {
    if [[ -n "${TEMP_REDIS_PID}" ]] && kill -0 "${TEMP_REDIS_PID}" 2>/dev/null; then
        redis-cli -h 127.0.0.1 shutdown nosave >/dev/null 2>&1 || kill "${TEMP_REDIS_PID}" 2>/dev/null || true
        wait "${TEMP_REDIS_PID}" 2>/dev/null || true
    fi
    TEMP_REDIS_PID=""

    if [[ -n "${TEMP_MYSQL_PID}" ]] && kill -0 "${TEMP_MYSQL_PID}" 2>/dev/null; then
        mysqladmin_root shutdown >/dev/null 2>&1 || kill "${TEMP_MYSQL_PID}" 2>/dev/null || true
        wait "${TEMP_MYSQL_PID}" 2>/dev/null || true
    fi
    TEMP_MYSQL_PID=""
}

artisan() {
    run_as_appbox php "${SEAT_APP_DIR}/artisan" "$@"
}

sde_is_ready() {
    local table_count counts
    local region_count constellation_count system_count
    local type_count map_count station_count

    if ! mysql_app --execute='SELECT 1' >/dev/null 2>&1; then
        fatal "Unable to authenticate to MariaDB as ${DB_USER} before checking EVE SDE data"
    fi

    if ! table_count="$(mysql_app \
        --batch \
        --skip-column-names \
        --execute="SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_schema = DATABASE()
              AND table_name IN (
                  'regions',
                  'constellations',
                  'solar_systems',
                  'invTypes',
                  'mapDenormalize',
                  'staStations'
              );")"; then
        fatal "Unable to inspect EVE SDE table availability"
    fi

    [[ "${table_count}" =~ ^[0-9]+$ ]] \
        || fatal "MariaDB returned an invalid EVE SDE table count: ${table_count}"
    if [[ "${table_count}" -ne 6 ]]; then
        return 1
    fi

    if ! counts="$(mysql_app \
        --batch \
        --skip-column-names \
        --execute='SELECT
            (SELECT COUNT(*) FROM regions),
            (SELECT COUNT(*) FROM constellations),
            (SELECT COUNT(*) FROM solar_systems),
            (SELECT COUNT(*) FROM invTypes),
            (SELECT COUNT(*) FROM mapDenormalize),
            (SELECT COUNT(*) FROM staStations);')"; then
        fatal "Unable to count EVE SDE rows"
    fi

    read -r region_count constellation_count system_count \
        type_count map_count station_count <<< "${counts}"
    if [[ ! "${region_count:-}" =~ ^[0-9]+$ ]] \
        || [[ ! "${constellation_count:-}" =~ ^[0-9]+$ ]] \
        || [[ ! "${system_count:-}" =~ ^[0-9]+$ ]] \
        || [[ ! "${type_count:-}" =~ ^[0-9]+$ ]] \
        || [[ ! "${map_count:-}" =~ ^[0-9]+$ ]] \
        || [[ ! "${station_count:-}" =~ ^[0-9]+$ ]]; then
        fatal "MariaDB returned invalid EVE SDE row counts"
    fi

    [[ "${region_count}" -gt 0 ]] \
        && [[ "${constellation_count}" -gt 0 ]] \
        && [[ "${system_count}" -gt 0 ]] \
        && [[ "${type_count}" -gt 0 ]] \
        && [[ "${map_count}" -gt 0 ]] \
        && [[ "${station_count}" -gt 0 ]]
}

ensure_sde() {
    log "Checking the current CCP EVE static-data build"
    if ! timeout "${SDE_UPDATE_TIMEOUT_SECONDS}" \
        gosu "${APP_UID}:${APP_GID}" \
        php "${SEAT_APP_DIR}/artisan" eve:update:sde --no-interaction; then
        fatal "EVE SDE update failed or timed out after ${SDE_UPDATE_TIMEOUT_SECONDS} seconds"
    fi

    if ! sde_is_ready; then
        fatal "EVE SDE update completed without populating all required raw and derived tables"
    fi
    log "EVE SDE import verified"
}

run_laravel_setup() {
    cd "${SEAT_APP_DIR}"
    artisan config:clear || true
    artisan cache:clear || true
    artisan migrate --force --no-interaction
    artisan db:seed --force --class='Seat\Services\Database\Seeders\PluginDatabaseSeeder' || true
    artisan vendor:publish --force --all || true
    ensure_sde
    artisan config:cache || true

    echo "${APP_RELEASE_MARKER}" > "${SEAT_APP_DIR}/.appbox-image-version"
    rm -f "${SEAT_APP_DIR}/.appbox-image-version.pending"
    chown "${APP_UID}:${APP_GID}" "${SEAT_APP_DIR}/.appbox-image-version"
}

generate_admin_login_url() {
    cd "${SEAT_APP_DIR}"
    if ADMIN_LOGIN_URL="$(artisan seat:admin:login 2>/dev/null | grep -Eo 'https?://[^[:space:]]+' | head -n 1)"; then
        :
    else
        ADMIN_LOGIN_URL=""
    fi
}

install_crontab() {
    crontab -u appbox /opt/eveseat/sources/crontab
}

callback_payload() {
    if [[ -n "${ADMIN_LOGIN_URL}" ]]; then
        ADMIN_LOGIN_URL="${ADMIN_LOGIN_URL}" php -r 'echo json_encode(["custom_fields" => [["key" => "ADMIN_LOGIN_URL", "value" => getenv("ADMIN_LOGIN_URL")]]], JSON_UNESCAPED_SLASHES);'
    else
        printf '{"custom_fields":[]}'
    fi
}

callback_installed() {
    if [[ "${SKIP_APPBOX_CALLBACK:-0}" == "1" ]]; then
        log "Skipping Appbox callback because SKIP_APPBOX_CALLBACK=1"
        return 0
    fi
    [[ -n "${INSTANCE_ID:-}" ]] || fatal "INSTANCE_ID is required for callback"
    [[ -n "${CALLBACK_TOKEN:-}" ]] || fatal "CALLBACK_TOKEN is required for authenticated callback"

    local url="${APPBOX_CALLBACK_URL:-https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}}"
    local payload
    payload="$(callback_payload)"

    local i
    for i in {1..120}; do
        if curl -fsS -o /dev/null \
            --connect-timeout 10 \
            --max-time 30 \
            -H 'Accept: application/json' \
            -H 'Content-Type: application/json' \
            -H "X-Cylo-Callback-Token: ${CALLBACK_TOKEN}" \
            -X POST \
            -d "${payload}" \
            "${url}"; then
            touch "${CALLBACK_FLAG}"
            return 0
        fi
        sleep 5
    done
    fatal "Timed out notifying Appbox installation callback"
}

wait_for_runtime_services() {
    mysql_ready_within "${MYSQL_WAIT_TIMEOUT_SECONDS}" || return 1
    local i
    for i in {1..60}; do
        if redis-cli -h 127.0.0.1 ping >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    for i in {1..120}; do
        if curl -fsS http://127.0.0.1/ >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

background_post_start_callback() {
    (
        set +e
        local deadline=$((SECONDS + CALLBACK_READY_TIMEOUT_SECONDS))
        until wait_for_runtime_services; do
            if (( SECONDS >= deadline )); then
                log "Runtime services did not become ready before callback timeout"
                exit 0
            fi
            log "Runtime services are not ready yet; still waiting to send the Appbox callback"
        done
        generate_admin_login_url
        callback_installed
    ) &
}

main() {
    require_inputs
    prepare_directories
    install_configs
    configure_ssh

    local state
    state="$(classify_install_state)"
    case "${state}" in
        fresh)
            log "Fresh SeAT install detected"
            copy_release_to_fresh_tree
            SHOULD_CALLBACK=1
            ;;
        nested-partial)
            repair_nested_partial_tree
            SHOULD_CALLBACK=1
            ;;
        existing)
            log "Existing SeAT install detected"
            if [[ ! -f "${CONFIG_FLAG}" ]]; then
                SHOULD_CALLBACK=1
                sync_release_preserving_state
            fi
            ;;
        invalid)
            fatal "${SEAT_APP_DIR} is non-empty but does not contain a valid SeAT install"
            ;;
    esac

    ensure_laravel_dirs
    cd "${SEAT_APP_DIR}"
    ensure_env_file
    start_temporary_mariadb
    configure_database
    start_temporary_redis

    if [[ "${SHOULD_CALLBACK}" == "1" ]]; then
        run_laravel_setup
    fi

    install_crontab
    stop_temporary_services
    touch "${CONFIG_FLAG}"

    if [[ "${SHOULD_CALLBACK}" == "1" || ! -f "${CALLBACK_FLAG}" ]]; then
        background_post_start_callback
    fi

    log "Starting supervised services"
    if [[ "$1" == "/init" && "$$" != "1" ]]; then
        log "Docker init is enabled; using fallback service supervisor because s6 requires PID 1"
        exec /run-services.sh
    fi
    exec "$@"
}

main "$@"
