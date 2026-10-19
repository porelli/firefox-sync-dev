#!/bin/bash
# End-to-end test of the firefox-sync stack (docker compose), isolated from anything
# else running on the host: own compose project, loopback-only port, own volumes.
#
# Usage: tests/e2e.sh <mysql|postgres>, SYNC_DB=mysql tests/e2e.sh mysql for MySQL (SYNC_MYSQL_IMAGE)
# Runs with the admin UI and the backups (COMPOSE_PROFILES=admin,backup, BACKUP_KEEP=1; with
# EXTERNAL_DB=1 the admin UI only, your own backups record their runs), with Mozilla's accounts
# (mock): Sync part only. At the end a backup is restored as ADMIN.md#restoring says, into
# empty volumes (not with EXTERNAL_DB=1).
# The admin UI signs in with its password, Dex (OpenID Connect) and a trusted header.
# Environment:
#   REPOSITORY      image repository (default: ghcr.io/porelli/firefox-sync)
#   TAG             tag suffix of both the app and init images (default: latest)
#   PORT            host port, bound to 127.0.0.1 (default: 28651 mysql, 28652 postgres),
#                   the admin UI on PORT+20
#   ADMIN_IMAGE     admin UI image to test, used as is (default: built from admin/)
#   CLEANUP_IMAGES  set to 1 to remove the pulled images at the end
#   SKIP_PULL       set to 1 to use the local images (e.g. an init image built from this tree)
#   KEEP            set to 1 to leave the stack running
#   SLOT            runs next to each other on one host (tests/slot.sh): 0 (default) the project,
#                   ports and networks below; 1, 2...: -s<SLOT> after the project, 1000 * SLOT
#                   added to the ports, 10 * SLOT to the third byte of the networks
#   INIT_TAG        tag suffix of the init image (default: TAG), e.g. one built from this tree
#   TEST_SUBNET     the stack's network, a /24 (default: 10.231.1.0/24 mysql, 10.231.2.0/24 postgres,
#                   10.231.4.0/24 SYNC_DB=mysql);
#                   its containers are in the upper half, the admin UI's trusted proxies, the
#                   gateway (the host) at .1 is not
#   SYNC_DB         mysql: the mysql backend on MySQL containers (docker-compose.sync-mysql.yml)
#                   instead of MariaDB (default mariadb); own project, PORT 28654 and TEST_SUBNET 10.231.4.0/24
#   SYNC_MYSQL_IMAGE the MySQL of SYNC_DB=mysql and of EXTERNAL_DB=1 with mysql (default: mysql:lts);
#                   mysql:8 as the installs from before: SYNC_DB=mysql then also checks that
#                   without it (the default, lts) the containers refuse to upgrade the data, and that
#                   --upgrade pins it
#   EXTERNAL_DB     set to 1 for a database server outside the stack (SYNC_DB_CONTAINERS=0, DATABASES.md),
#                   created with only the grants of db/<engine>/sync.sql: MySQL with binary logging
#                   for mysql, a PostgreSQL (postgres:latest) owner that is no superuser for postgres; on its own
#                   network (EXTDB_SUBNET, default: 10.232.1.0/24 mysql, 10.232.2.0/24 postgres)
#   UPGRADE_FROM    a checkout of an earlier release (e.g. git worktree add /tmp/ffs-from <tag>):
#                   the install from before below runs its compose files, its admin UI and its
#                   init image (built from it), then upgrades to this tree. Default: this tree
#                   without ADMIN_DB_PASSWORD (and SYNC_POSTGRES_APP_USER), the same layout
#   DEMO            set to 1 for the demo of ADMIN.md's screenshots instead of the tests: a fresh
#                   stack of this tree seeded by tests/demo_seed.py (three accounts of Mozilla's,
#                   the mock FxA, with Sync data and notes; a backup run), kept running (KEEP=1);
#                   the admin UI on PORT+20
# The stack starts as an install from before ADMIN_DB_PASSWORD (the admin UI's tables in the
# tokenserver database, as the Sync server's user), then is upgraded: they move into the admin
# UI's own database, which the Sync server's users cannot read or change. That install's .env
# has the old names of the Sync settings (MIGRATING.md#renamed-settings), which compose still
# reads; the upgrade renames them with ./prepare_environment.sh --upgrade.
set -u

BACKEND=${1:?usage: $0 <mysql|postgres>}
TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
# shellcheck source=tests/slot.sh
source "${TESTS}/slot.sh"
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
INIT_TAG=${INIT_TAG:-${TAG}}
PROJECT=ffs-e2e-${BACKEND}
WORK=$(mktemp -d)
ENV_FILE=${WORK}/${BACKEND}.env

SYNC_DB=${SYNC_DB:-mariadb}
case ${BACKEND}:${SYNC_DB} in
  mysql:mariadb)    COMPOSE=${CODE}/docker-compose.yml;          PORT=${PORT:-$((28651 + SLOT_PORTS))}; NET=$((1 + SLOT_NET)) ;;
  postgres:mariadb) COMPOSE=${CODE}/docker-compose.sync-postgres.yml; PORT=${PORT:-$((28652 + SLOT_PORTS))}; NET=$((2 + SLOT_NET)) ;;
  # (28653 is tests/e2e-fxa.sh's)
  mysql:mysql)      COMPOSE=${CODE}/docker-compose.yml;          PORT=${PORT:-$((28654 + SLOT_PORTS))}; NET=$((4 + SLOT_NET)); PROJECT=${PROJECT}-mysqldb ;;
  postgres:*) echo "SYNC_DB is for the mysql backend"; exit 2 ;;
  mysql:*) echo "SYNC_DB: mariadb or mysql"; exit 2 ;;
  *) echo "unknown backend ${BACKEND}"; exit 2 ;;
esac
PROJECT=${PROJECT}${SLOT_SUFFIX}
if [ "${SYNC_DB}" = mysql ] && [ -n "${EXTERNAL_DB:-}" ]; then
  echo "SYNC_DB=mysql is for the database containers, EXTERNAL_DB=1 is already MySQL (SYNC_MYSQL_IMAGE)"; exit 2
fi
SYNC_MYSQL_IMAGE=${SYNC_MYSQL_IMAGE:-mysql:lts} MYSQL_TESTED=${SYNC_MYSQL_IMAGE:-mysql:lts}
case "${SYNC_MYSQL_IMAGE##*:}" in 8|8.*) MYSQL_PINNED=8 ;; *) MYSQL_PINNED="" ;; esac
# the admin UI trusts the X-Test-Email header of the containers (tests/docker-compose.test.yml),
# not of the gateway: what comes from the host
export TEST_SUBNET=${TEST_SUBNET:-10.231.${NET}.0/24}
export TEST_TRUSTED=${TEST_SUBNET%.0/24}.128/25 TEST_GATEWAY=${TEST_SUBNET%.0/24}.1

rnd() { tr -dc '[:alnum:]' < /dev/urandom | head -c 24; }
# the backup service is for the database containers: your own server has its own backups
PROFILES=admin,backup
[ -n "${EXTERNAL_DB:-}" ] && PROFILES=admin
MASTER_SECRET=$(rnd)
# upstream's tokenserver tests expect the stage FxA email domain, the mock FxA
# server and the metrics hash secret to be the master secret
sed -e "s|^SYNC_TOKENSERVER_DB_PASSWORD=.*|SYNC_TOKENSERVER_DB_PASSWORD=$(rnd)|" \
    -e "s|^SYNC_STORAGE_DB_PASSWORD=.*|SYNC_STORAGE_DB_PASSWORD=$(rnd)|" \
    -e "s|^SYNC_POSTGRES_PASSWORD=.*|SYNC_POSTGRES_PASSWORD=$(rnd)|" \
    -e "s|^SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=${MASTER_SECRET}|" \
    -e "s|^SYNC_METRICS_HASH_SECRET=.*|SYNC_METRICS_HASH_SECRET=${MASTER_SECRET}|" \
    -e "s|^SYNC_PUBLIC_URL=.*|SYNC_PUBLIC_URL=https://ffs-e2e.invalid|" \
    -e "s|^SYNC_EXPORT_PORT=.*|SYNC_EXPORT_PORT=127.0.0.1:${PORT}|" \
    -e "s|^SYNC_MAX_USERS=.*|SYNC_MAX_USERS=1|" \
    -e "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${PROFILES}|" \
    -e "s|^BACKUP_KEEP=.*|BACKUP_KEEP=1|" \
    -e "s|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=$(rnd)|" \
    -e "s|^ADMIN_EXPORT_PORT=.*|ADMIN_EXPORT_PORT=127.0.0.1:$((PORT + 20))|" \
    -e "s|^IMAGE_REPOSITORY=.*|IMAGE_REPOSITORY=${REPOSITORY}|" \
    -e "s|^SYNC_IMAGE=.*|SYNC_IMAGE=syncstorage-rs-${BACKEND}|" \
    -e "s|^SYNC_INIT_IMAGE=.*|SYNC_INIT_IMAGE=syncstorage-rs-${BACKEND}-init|" \
    -e "s|^SYNC_IMAGE_TAG=.*|SYNC_IMAGE_TAG=${TAG}|" \
    -e "s|^SYNC_INIT_IMAGE_TAG=.*|SYNC_INIT_IMAGE_TAG=${INIT_TAG}|" \
    -e "s|^FXA_EMAIL_DOMAIN=.*|FXA_EMAIL_DOMAIN=api-accounts.stage.mozaws.net|" \
    -e "s|^FXA_OAUTH_SERVER_URL=.*|FXA_OAUTH_SERVER_URL=http://mock_fxa:6000|" \
    -e "s|^FXA_SMTP_HOST=.*|FXA_SMTP_HOST=|" \
    -e "/^COMPOSE_FILE=/d" \
    -e "s|^SYNC_DB=.*|SYNC_DB=${SYNC_DB}|" \
    -e "s|<REPLACE_WITH_SOMETHING_SECURE>|$(rnd)|" \
    -e "s|<REPLACE_WITH_[A-Z_]*>|placeholder.invalid|g" \
    "${CODE}/.env-example" > "${ENV_FILE}"
# the stack's PostgreSQL container: the Sync server's own role, no superuser (DATABASES.md)
if [ "${BACKEND}" = postgres ] && [ -z "${EXTERNAL_DB:-}" ]; then
  sed -i -e "s|^SYNC_POSTGRES_APP_USER=.*|SYNC_POSTGRES_APP_USER=syncserver_app|" -e "s|^SYNC_POSTGRES_APP_PASSWORD=.*|SYNC_POSTGRES_APP_PASSWORD=$(rnd)|" "${ENV_FILE}"
fi
EXTDB=
COMPOSE_EXTRA=()
DATABASE_SERVER=
# what the admin UI reports, and the database client in the database containers
DB_CLIENT=mariadb
if [ "${SYNC_DB}" = mysql ]; then
  COMPOSE_EXTRA=(-f "${CODE}/docker-compose.sync-mysql.yml")
  DATABASE_SERVER=MySQL DB_CLIENT=mysql
  # written out, as prepare_environment.sh does
  sed -i "s|^# SYNC_MYSQL_IMAGE=.*|SYNC_MYSQL_IMAGE=${SYNC_MYSQL_IMAGE}|" "${ENV_FILE}"
fi
if [ -n "${EXTERNAL_DB:-}" ]; then
  # a server elsewhere: its own container and network, reached by name
  EXTDB=${PROJECT}-extdb
  EXTDB_SUBNET=${EXTDB_SUBNET:-10.232.${NET}.0/24}
  export EXTDB_NETWORK=${EXTDB}
  # the admin UI's peers come from either network
  export TEST_TRUSTED_PROXIES=${TEST_TRUSTED},${EXTDB_SUBNET%.0/24}.128/25
  COMPOSE_EXTRA=(-f "${TESTS}/docker-compose.external-db-test.yml")
  [ "${BACKEND}" = mysql ] && DATABASE_SERVER=MySQL
  sed -i -e "s|^SYNC_DB_CONTAINERS=.*|SYNC_DB_CONTAINERS=0|" -e "s|^SYNC_DB_TLS_VERIFY=.*|SYNC_DB_TLS_VERIFY=false|" \
      -e "s|^SYNC_TOKENSERVER_DB_HOST=.*|SYNC_TOKENSERVER_DB_HOST=${EXTDB}|" \
      -e "s|^SYNC_STORAGE_DB_HOST=.*|SYNC_STORAGE_DB_HOST=${EXTDB}|" \
      -e "s|^SYNC_POSTGRES_HOST=.*|SYNC_POSTGRES_HOST=${EXTDB}|" "${ENV_FILE}"
fi
if [ -n "${DEMO:-}" ]; then
  # and the password only: Dex and the trusted header of the tests need plain http cookies
  printf 'services:\n  ffs-admin:\n    environment:\n%s' "$(printf '      %s: ""\n' ADMIN_OIDC_ISSUER ADMIN_OIDC_CLIENT_ID \
    ADMIN_OIDC_CLIENT_SECRET ADMIN_OIDC_REDIRECT_URL ADMIN_OIDC_NAME ADMIN_AUTH_HEADER ADMIN_AUTH_GROUPS_HEADER ADMIN_TRUSTED_PROXIES \
    ADMIN_ALLOWED_USERS ADMIN_ALLOWED_GROUPS)" > "${WORK}/demo.yml"
  COMPOSE_EXTRA+=(-f "${TESTS}/docker-compose.demo.yml" -f "${WORK}/demo.yml")
  # a public URL that looks like one, the email domain of Mozilla's accounts
  sed -i -e "s|^SYNC_PUBLIC_URL=.*|SYNC_PUBLIC_URL=https://sync.example.org|" -e "s|^FXA_EMAIL_DOMAIN=.*|FXA_EMAIL_DOMAIN=api.accounts.firefox.com|" \
    -e "s|^SYNC_MAX_USERS=.*|SYNC_MAX_USERS=initial:10|" "${ENV_FILE}"
fi
set -a; source "${ENV_FILE}"; set +a
# the admin UI's own database users, the Sync server's role in the PostgreSQL container
# (set_env empties them until the upgrade)
ADMIN_DB_SECRET=${ADMIN_DB_PASSWORD} SYNC_ROLE=${SYNC_POSTGRES_APP_USER} SYNC_ROLE_SECRET=${SYNC_POSTGRES_APP_PASSWORD}
if [ "${BACKEND}" = mysql ]; then
  ADMIN_DB_URL=mysql://${ADMIN_DB_USER}:${ADMIN_DB_SECRET}@${SYNC_TOKENSERVER_DB_HOST}:${SYNC_TOKENSERVER_DB_PORT}/${ADMIN_DB_NAME}
else
  ADMIN_DB_URL=postgres://${ADMIN_DB_USER}:${ADMIN_DB_SECRET}@${SYNC_POSTGRES_HOST}:${SYNC_POSTGRES_PORT}/${ADMIN_DB_NAME}
fi
# the admin UI under test: ADMIN_IMAGE as is (pulled when missing), or built from admin/
ADMIN_GIVEN=${ADMIN_IMAGE:-}
export ADMIN_IMAGE=${ADMIN_IMAGE:-ffs-admin:test}

# the compose files of ROOT: this tree, or UPGRADE_FROM for the install from before
ROOT=${CODE}
# the healthchecks of this tree's stack every second while their containers start (start_interval,
# within start_period), then as set: what waits for "healthy" (docker compose up for the
# migrations, the checks below) waits a second, not the first interval (10 to 60 s)
{ echo "services:"
  for s in syncstorage ffs-admin backup $([ "${BACKEND}" = postgres ] && echo postgres_db || echo tokenserver_db syncstorage_db); do
    printf '  %s:\n    healthcheck:\n      start_period: 5m\n      start_interval: 1s\n' "${s}"
  done; } > "${WORK}/health-test.yml"
# (old releases: docker-compose.postgres.yml, the symlink of then)
dc() {
  local compose health=()
  compose=${ROOT}/$(basename "${COMPOSE}")
  [ -e "${compose}" ] || compose=${ROOT}/docker-compose.postgres.yml
  [ "${ROOT}" = "${CODE}" ] && health=(-f "${WORK}/health-test.yml")
  docker compose -p "${PROJECT}" -f "${compose}" -f "${ROOT}/tests/docker-compose.test.yml" \
    "${COMPOSE_EXTRA[@]/#"${CODE}"/${ROOT}}" "${health[@]}" --env-file "${ENV_FILE}" "$@"
}
FAILED=0
# compose_healthy, the healthchecks of the stack
# shellcheck source=tests/healthy.sh
source "${TESTS}/healthy.sh"
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; fi; }
state() { docker inspect -f "{{.State.$2}}" "$(dc ps -a -q "$1")" 2> /dev/null; }
hb() {
  local c
  for _ in $(seq 1 60); do
    c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")
    [ "${c}" = 200 ] && break
    sleep 1
  done
  echo "${c}"
}
wait_init() { timeout 300 docker wait "$(dc ps -a -q tokenserver_db_init)"; }
# Prometheus metrics of the admin UI
metrics() { curl -s -H 'Authorization: Bearer ffs-test-metrics-token' "http://127.0.0.1:$((PORT + 20))/metrics"; }
# retries until the metrics have this line (HEALTH_CHECK_SECONDS=5 in the tests)
metrics_show() {
  for _ in $(seq 1 20); do metrics | grep -qxF "$1" && { echo yes; return; }; sleep 1; done
}
# admin UI errors in the background (written to the logs only)
admin_errors() { dc logs ffs-admin 2>&1 | grep -E '(pruning|metrics|event log|database size|rendering [^:]*): '; }
admin_healthy() {
  for _ in $(seq 1 60); do [ "$(state ffs-admin Health.Status)" = healthy ] && break; sleep 1; done
  state ffs-admin Health.Status
}
# set a value in the env file and in this shell (the shell environment wins over --env-file)
# the lines of .env of the renamed settings: under their new names, under their old ones
NEW_RE="^($(IFS='|'; echo "${RENAMED_SETTINGS[*]%%=*}"))="
OLD_RE="^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))="
# (with OLD_NAMES=1, a renamed setting under its old name: the shell keeps the new one, not
# exported)
set_env() {
  local pair
  if [ -n "${OLD_NAMES:-}" ]; then
    for pair in "${RENAMED_SETTINGS[@]}"; do
      [ "${pair%%=*}" = "$1" ] || continue
      sed -i "s|^${pair#*=}=.*|${pair#*=}=$2|" "${ENV_FILE}"; export "${pair#*=}=$2"
      printf -v "$1" '%s' "$2"
      return
    done
  fi
  sed -i "s|^$1=.*|$1=$2|" "${ENV_FILE}"; export "$1=$2"
}
# the .env of an install from before the SYNC_ names: the old names in the env file and in
# compose's environment (not the new ones, which the shell keeps for the checks)
use_old_names() {
  local pair new old
  for pair in "${RENAMED_SETTINGS[@]}"; do
    new=${pair%%=*} old=${pair#*=}
    sed -i "s|^${new}=|${old}=|" "${ENV_FILE}"
    # shellcheck disable=SC2163 # (the variable named by new)
    export "${old}=${!new-}"; export -n "${new}"
  done
  OLD_NAMES=1
}

sql() {
  if [ -n "${EXTDB}" ] && [ "${BACKEND}" = mysql ]; then
    docker exec -i -e MYSQL_PWD="${SYNC_TOKENSERVER_DB_PASSWORD}" "${EXTDB}" mysql -u"${SYNC_TOKENSERVER_DB_USER}" "${SYNC_TOKENSERVER_DB_NAME}" -sN -e "$1" < /dev/null
  elif [ -n "${EXTDB}" ]; then
    docker exec -i -e PGPASSWORD="${SYNC_POSTGRES_PASSWORD}" "${EXTDB}" psql -h 127.0.0.1 -U "${SYNC_POSTGRES_USER}" -d "${SYNC_POSTGRES_NAME}" -tA -c "$1" < /dev/null
  elif [ "${BACKEND}" = mysql ]; then
    dc exec -T -e MYSQL_PWD="${SYNC_TOKENSERVER_DB_PASSWORD}" tokenserver_db "${DB_CLIENT}" -u"${SYNC_TOKENSERVER_DB_USER}" "${SYNC_TOKENSERVER_DB_NAME}" -sN -e "$1" < /dev/null
  else
    dc exec -T postgres_db psql -U "${SYNC_POSTGRES_USER}" -d "${SYNC_POSTGRES_NAME}" -tA -c "$1" < /dev/null
  fi
}

# SQL as the admin UI's own user, in its own database (the event log, the backup runs), or
# as user $3 in database $2; on the storage server with $4
db_as() { # user password database query [storage]
  if [ -n "${EXTDB}" ] && [ "${BACKEND}" = mysql ]; then
    docker exec -i -e MYSQL_PWD="$2" "${EXTDB}" mysql -u"$1" "$3" -sN -e "$4" < /dev/null
  elif [ -n "${EXTDB}" ]; then
    docker exec -i -e PGPASSWORD="$2" "${EXTDB}" psql -h 127.0.0.1 -U "$1" -d "$3" -tA -c "$4" < /dev/null
  elif [ "${BACKEND}" = mysql ]; then
    dc exec -T -e MYSQL_PWD="$2" "$([ -n "${5:-}" ] && echo syncstorage_db || echo tokenserver_db)" "${DB_CLIENT}" -u"$1" "$3" -sN -e "$4" < /dev/null
  else
    dc exec -T -e PGPASSWORD="$2" postgres_db psql -h 127.0.0.1 -U "$1" -d "$3" -tA -c "$4" < /dev/null
  fi
}
SYNC_DB_NAME=$([ "${BACKEND}" = mysql ] && echo "${SYNC_TOKENSERVER_DB_NAME}" || echo "${SYNC_POSTGRES_NAME}")
admin_sql() { db_as "${ADMIN_DB_USER}" "${ADMIN_DB_SECRET}" "${2:-${ADMIN_DB_NAME}}" "$1"; }
# the admin UI's reader of the Sync data (ADMIN_DB_SYNC_USER), on the Sync database and on
# the storage (MariaDB and MySQL)
admin_sync_sql() { db_as "${ADMIN_DB_SYNC_USER}" "${ADMIN_DB_SECRET}" "${2:-${SYNC_DB_NAME}}" "$1"; }
admin_storage_sql() { db_as "${ADMIN_DB_SYNC_USER}" "${ADMIN_DB_SECRET}" "${SYNC_STORAGE_DB_NAME}" "$1" storage; }
# the Sync server's own role in the PostgreSQL container (SYNC_POSTGRES_APP_USER), or SYNC_POSTGRES_USER
sync_role_sql() { db_as "${SYNC_ROLE:-${SYNC_POSTGRES_USER}}" "${SYNC_ROLE_SECRET:-${SYNC_POSTGRES_PASSWORD}}" "${2:-${SYNC_POSTGRES_NAME}}" "$1"; }
# no account and no Sync data, a new server: where tests/test_client_flow.py starts. Without
# the Sync data too, a new account can find someone else's: upstream's storage tests sign
# their own tokens for random uids (1 to 100000) and leave what they wrote, and the
# tokenserver's uids count up from 1 (DELETE does not reset them), so a later sign-in can be
# given one of them
new_server() {
  sql "DELETE FROM users;" > /dev/null
  if [ "${BACKEND}" = mysql ]; then
    db_as "${SYNC_STORAGE_DB_USER}" "${SYNC_STORAGE_DB_PASSWORD}" "${SYNC_STORAGE_DB_NAME}" \
      "DELETE FROM batch_upload_items; DELETE FROM batch_uploads; DELETE FROM bso; DELETE FROM user_collections;" storage > /dev/null
  else
    sync_role_sql "DELETE FROM batch_bsos; DELETE FROM batches; DELETE FROM bsos; DELETE FROM user_collections;" > /dev/null
  fi
}
# the admin UI's tables left in the tokenserver database
old_tables() {
  if [ "${BACKEND}" = mysql ]; then
    sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 'ffs\\_%';"
  else
    sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE 'ffs\\_%';"
  fi
}

# run a command in a one-off container of the app image, on the stack network
in_app() {
  dc run --rm -T --no-deps --user root \
    -v "${TESTS}:/tests:ro" -v "${WORK}:/state" \
    -e SYNC_SERVER_URL=http://syncstorage:8000 \
    -e TOKENSERVER_HOST=http://syncstorage:8000 \
    -e SYNC_MASTER_SECRET="${MASTER_SECRET}" \
    -e SYNC_PUBLIC_URL="${SYNC_PUBLIC_URL}" \
    -e SYNC_MAX_USERS="${SYNC_MAX_USERS#*:}" \
    -e MAX_USERS_SETTING="${SYNC_MAX_USERS}" \
    -e ADMIN_URL=http://ffs-admin:8080 \
    -e ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
    -e BACKEND="${BACKEND}" \
    -e DATABASE_SERVER="${DATABASE_SERVER}" \
    -e ADMIN_DB_URL="${ADMIN_DB_URL}" \
    -e PYTHONPATH=/app:/app/tools \
    -e PYTHONDONTWRITEBYTECODE=1 \
    --entrypoint /bin/sh syncstorage -c "cd /app && $1" < /dev/null
}
pytest_in_app() { in_app "python3 -m pytest -q -p no:cacheprovider $1 > /tmp/pytest.log 2>&1; rc=\$?; tail -25 /tmp/pytest.log; exit \$rc"; }

# EXTERNAL_DB=1: SQL as the administrator of the external server, on stdin
extdb_admin() {
  if [ "${BACKEND}" = mysql ]; then
    docker exec -i -e MYSQL_PWD="${EXTDB_ROOT}" "${EXTDB}" mysql -uroot -sN "$@"
  else
    docker exec -i -e PGPASSWORD="${EXTDB_ROOT}" "${EXTDB}" psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -tA "$@"
  fi
}
# the server, then the databases and users exactly as DATABASES.md says
start_extdb() {
  EXTDB_ROOT=$(rnd)
  docker rm -f "${EXTDB}" > /dev/null 2>&1
  docker network rm "${EXTDB}" > /dev/null 2>&1
  docker network create --subnet "${EXTDB_SUBNET}" --ip-range "${EXTDB_SUBNET%.0/24}.128/25" \
    --gateway "${EXTDB_SUBNET%.0/24}.1" "${EXTDB}" > /dev/null || return 1
  if [ "${BACKEND}" = mysql ]; then
    # binary logging is on by default: the trigger needs log_bin_trust_function_creators
    docker run -d --rm --name "${EXTDB}" --network "${EXTDB}" --tmpfs /var/lib/mysql \
      -e MYSQL_ROOT_PASSWORD="${EXTDB_ROOT}" "${SYNC_MYSQL_IMAGE}" --log-bin-trust-function-creators=ON > /dev/null || return 1
  else
    docker run -d --rm --name "${EXTDB}" --network "${EXTDB}" --tmpfs /var/lib/postgresql \
      -e POSTGRES_PASSWORD="${EXTDB_ROOT}" postgres:latest > /dev/null || return 1
  fi
  # over TCP: while the images initialize, a temporary server listens on the socket only
  for _ in $(seq 1 90); do
    if [ "${BACKEND}" = mysql ]; then
      extdb_admin -h 127.0.0.1 --protocol=tcp -e 'SELECT 1' < /dev/null > /dev/null 2>&1 && break
    else
      extdb_admin -c 'SELECT 1' < /dev/null > /dev/null 2>&1 && break
    fi
    sleep 2
  done
  if [ "${BACKEND}" = mysql ]; then
    sed -e "s|@SYNC_TOKENSERVER_DATABASE@|${SYNC_TOKENSERVER_DB_NAME}|g" -e "s|@SYNC_TOKENSERVER_USER@|${SYNC_TOKENSERVER_DB_USER}|g" \
        -e "s|@SYNC_TOKENSERVER_PASSWORD@|${SYNC_TOKENSERVER_DB_PASSWORD}|g" -e "s|@SYNC_STORAGE_DATABASE@|${SYNC_STORAGE_DB_NAME}|g" \
        -e "s|@SYNC_STORAGE_USER@|${SYNC_STORAGE_DB_USER}|g" -e "s|@SYNC_STORAGE_PASSWORD@|${SYNC_STORAGE_DB_PASSWORD}|g" \
        -e "s|@ADMIN_DATABASE@|${ADMIN_DB_NAME}|g" -e "s|@ADMIN_USER@|${ADMIN_DB_USER}|g" -e "s|@ADMIN_SYNC_USER@|${ADMIN_DB_SYNC_USER}|g" -e "s|@ADMIN_PASSWORD@|${ADMIN_DB_SECRET}|g" \
        "${CODE}/db/mysql/sync.sql"
  else
    sed -e "s|@SYNC_POSTGRES_DATABASE@|${SYNC_POSTGRES_NAME}|g" -e "s|@SYNC_POSTGRES_USER@|${SYNC_POSTGRES_USER}|g" \
        -e "s|@SYNC_POSTGRES_PASSWORD@|${SYNC_POSTGRES_PASSWORD}|g" -e "s|@ADMIN_DATABASE@|${ADMIN_DB_NAME}|g" \
        -e "s|@ADMIN_USER@|${ADMIN_DB_USER}|g" -e "s|@ADMIN_SYNC_USER@|${ADMIN_DB_SYNC_USER}|g" -e "s|@ADMIN_PASSWORD@|${ADMIN_DB_SECRET}|g" "${CODE}/db/postgres/sync.sql"
  fi > "${WORK}/database-setup.sql"
  check "$(grep -c '@[A-Z_]*@' "${WORK}/database-setup.sql")" 0 "external database: SQL template filled in"
  # run twice, first with other passwords: prepare_environment.sh run again makes new ones
  local real
  for real in "" 1; do
    if [ "${BACKEND}" = mysql ]; then
      if [ -n "${real}" ]; then cat "${WORK}/database-setup.sql"; else sed "s|IDENTIFIED BY '[^']*'|IDENTIFIED BY 'stale'|" "${WORK}/database-setup.sql"; fi \
        | extdb_admin > /dev/null || return 1
    else
      # as a role with CREATEROLE and CREATEDB, not a superuser: what managed services give;
      # the second time like psql -f, which goes on after "already exists"
      if [ -z "${real}" ]; then
        EXTDB_PG_ADMIN=$(rnd)
        extdb_admin -c "CREATE ROLE dbadmin LOGIN CREATEROLE CREATEDB PASSWORD '${EXTDB_PG_ADMIN}'" < /dev/null > /dev/null || return 1
        sed "s|PASSWORD '[^']*'|PASSWORD 'stale'|" "${WORK}/database-setup.sql" \
          | docker exec -i -e PGPASSWORD="${EXTDB_PG_ADMIN}" "${EXTDB}" psql -h 127.0.0.1 -U dbadmin -d postgres -v ON_ERROR_STOP=1 -q > /dev/null || return 1
      else
        docker exec -i -e PGPASSWORD="${EXTDB_PG_ADMIN}" "${EXTDB}" psql -h 127.0.0.1 -U dbadmin -d postgres -q < "${WORK}/database-setup.sql" > /dev/null 2>&1 || return 1
      fi
    fi
  done
}

teardown() {
  [ -n "${KEEP:-}" ] && { echo "keeping stack ${PROJECT} (env: ${ENV_FILE})${EXTDB:+ and its database server ${EXTDB}}"; return; }
  echo "== teardown"
  dc down -v --remove-orphans > /dev/null 2>&1
  # the backups volume put back by the restore test is not compose's
  docker volume rm -f "${PROJECT}_backups" > /dev/null 2>&1
  if [ -n "${EXTDB}" ]; then
    docker rm -f "${EXTDB}" > /dev/null 2>&1
    docker network rm "${EXTDB}" > /dev/null 2>&1
  fi
  if [ -n "${CLEANUP_IMAGES:-}" ]; then
    docker rmi "${REPOSITORY}:syncstorage-rs-${BACKEND}-${TAG}" "${REPOSITORY}:syncstorage-rs-${BACKEND}-init-${INIT_TAG}" > /dev/null 2>&1
    [ -n "${ADMIN_GIVEN}" ] && docker rmi "${ADMIN_GIVEN}" > /dev/null 2>&1
    [ "${BACKEND}" = mysql ] && [ "${SYNC_DB}" = mariadb ] && ! docker ps -a --format '{{.Image}}' | grep -qx 'mariadb:lts' && docker rmi mariadb:lts > /dev/null 2>&1
    [ "${SYNC_DB}" = mysql ] && ! docker ps -a --format '{{.Image}}' | grep -qx "${SYNC_MYSQL_IMAGE}" && docker rmi "${SYNC_MYSQL_IMAGE}" > /dev/null 2>&1
    docker rmi busybox > /dev/null 2>&1
  fi
  rm -rf "${WORK}"
}
trap teardown EXIT

if [ -z "${ADMIN_GIVEN}" ]; then
  # (one build of the tag at a time: the other tests build it too)
  COMPOSE_BAKE=false one_at_a_time admin-build docker compose -p ffs-admin-build -f "${TESTS}/docker-compose.admin-build.yml" build -q || { echo "FAIL: admin UI image built from admin/"; exit 1; }
fi
echo "== ${PROJECT}: pulling ${REPOSITORY} ${TAG}"
[ -n "${SKIP_PULL:-}" ] || dc pull -q || exit 1

if [ -n "${EXTDB}" ]; then
  echo "== external database server ${EXTDB} ($([ "${BACKEND}" = mysql ] && echo "${SYNC_MYSQL_IMAGE}" || echo postgres:latest))"
  start_extdb
  check "$?" 0 "external database server with the databases and users of db/${BACKEND}/sync.sql"
fi

# a stack of an earlier KEEP=1 run of this project would make the fail-closed check pass
# on its old containers: start from nothing
dc down -v --remove-orphans > /dev/null 2>&1
if [ -n "${DEMO:-}" ]; then
  echo "== demo: a fresh stack, tests/demo_seed.py sync, a backup run"
  KEEP=1
  dc up -d > "${WORK}/up.log" 2>&1 || { tail -20 "${WORK}/up.log"; exit 1; }
  check "$(wait_init) $(hb) $(admin_healthy)" "0 200 healthy" "the stack is up"
  in_app "python3 /tests/demo_seed.py sync"
  check "$?" 0 "demo seeded"
  [ -z "${EXTDB}" ] && { dc exec -T backup sh /ffs-backup/backup.sh now > "${WORK}/backup.log" 2>&1; check "$?" 0 "a backup of Sync"; }
  echo "the admin UI: http://127.0.0.1:$((PORT + 20)), its password ADMIN_PASSWORD in ${ENV_FILE} (tear down: docker compose -p ${PROJECT} down -v)"
  exit "${FAILED}"
fi
echo "== fail closed: a failing init must keep syncstorage down"
printf 'services:\n  tokenserver_db_init:\n    entrypoint: ["/bin/false"]\n' > "${WORK}/fail-init.yml"
dc -f "${WORK}/fail-init.yml" up -d > /dev/null 2>&1
check "$(state syncstorage_migrate ExitCode)" 0 "migrations completed"
check "$(state syncstorage Running || echo false)" false "syncstorage not started when init fails"
check "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")" 000 "port not reachable when init fails"
# a new install with ADMIN_DB_PASSWORD from the first start (new volumes): the database
# containers create the admin UI's users then (MySQL: through mysqld --initialize and the
# image's temporary server too), the PostgreSQL init container (it failed here) later
if [ -z "${EXTDB}" ] && [ "${BACKEND}" = mysql ]; then
  check "$(admin_sql "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '${ADMIN_DB_NAME}';") $(admin_sync_sql "SELECT 1;") $(admin_storage_sql "SELECT 1;")" "1 1 1" \
    "a new install: the admin UI's users and database from the first start of the database containers"
  check "$(dc logs tokenserver_db syncstorage_db 2>&1 | grep -ciE '\[ERROR\].*init.file|init_file')" 0 "no error of the init file in the database logs"
elif [ -z "${EXTDB}" ]; then
  # the stack's PostgreSQL container: sync_role_init made the Sync server's role first, the
  # migrations ran as it (no superuser session on its tables)
  check "$(sql "SELECT DISTINCT pg_get_userbyid(relowner) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r';")" "${SYNC_ROLE}" \
    "a new install: the migrations created the tables as the Sync server's role"
fi
dc down -v > /dev/null 2>&1

echo "== starting, as an install from before ADMIN_DB_PASSWORD${UPGRADE_FROM:+ (${UPGRADE_FROM})}, with the old setting names"
use_old_names
# its layout: the admin UI connects as the Sync server's users, its tables in the tokenserver
# database; with PostgreSQL the Sync server connects as SYNC_POSTGRES_USER, the superuser
set_env ADMIN_DB_PASSWORD ""
set_env SYNC_POSTGRES_APP_USER ""
set_env SYNC_POSTGRES_APP_PASSWORD ""
if [ -n "${UPGRADE_FROM:-}" ]; then
  # that release itself: its compose files, its admin UI and its init container
  ROOT=$(cd -- "${UPGRADE_FROM}" && pwd) || exit 1
  ADMIN_NOW=${ADMIN_IMAGE} INIT_NOW=${SYNC_INIT_IMAGE_TAG}
  export ADMIN_IMAGE=ffs-admin:e2e-from${SLOT_SUFFIX}
  ADMIN_IMAGE=${ADMIN_IMAGE} COMPOSE_BAKE=false one_at_a_time admin-build docker compose -p ffs-admin-build-from -f "${ROOT}/tests/docker-compose.admin-build.yml" build -q ||
    { echo "FAIL: admin UI image built from ${UPGRADE_FROM}/admin"; exit 1; }
  # (releases before db/: syncstorage-rs-init, syncstorage-rs-init-postgres)
  init_dir=${ROOT}/db/${BACKEND}/init
  [ -d "${init_dir}" ] || init_dir=${ROOT}/syncstorage-rs-init$([ "${BACKEND}" = postgres ] && echo -postgres)
  docker build -q -t "${REPOSITORY}:syncstorage-rs-${BACKEND}-init-e2e-from${SLOT_SUFFIX}" "${init_dir}" > /dev/null || { echo "FAIL: init image of ${UPGRADE_FROM}"; exit 1; }
  set_env SYNC_INIT_IMAGE_TAG "e2e-from${SLOT_SUFFIX}"
fi
dc up -d > /dev/null 2>&1 || { dc logs; exit 1; }
check "$(wait_init)" 0 "init container exit code"
check "$(state syncstorage_migrate ExitCode)" 0 "migrate container exit code"
INIT_END=$(date -d "$(state tokenserver_db_init FinishedAt)" +%s%N)
APP_START=$(date -d "$(state syncstorage StartedAt)" +%s%N)
check "$([ "${APP_START}" -gt "${INIT_END}" ] && echo yes)" yes "syncstorage started only after the init finished"
check "$(hb)" 200 "/__heartbeat__"
dc logs syncstorage 2>&1 | grep -m1 "Server running"
check "$(grep -cE "${NEW_RE}" "${ENV_FILE}") $(grep -cE "${OLD_RE}" "${ENV_FILE}")" "0 $(grep -cE "${NEW_RE}" "${CODE}/.env-example")" \
  "the install of before runs with only the old setting names in .env"
if [ -z "${UPGRADE_FROM:-}" ]; then
  check "$(dc logs tokenserver_db_init 2>&1 | grep -c 'WARNING: settings under their old names, in .env or in the environment docker compose runs in') $(dc logs tokenserver_db_init 2>&1 | grep -c 'in a later release: .*MARIADB_TOKENSERVER_PASSWORD.* MAX_USERS ')" "1 1" \
    "the init container warns of the old setting names, and names them"
  check "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(dc ps -q ffs-admin)" | grep -c '^FFS_OLD_ENV_NAMES=.*SYNCSTORAGE_DOMAIN ')" 1 \
    "the admin UI gets the old setting names, for its setup check"
fi

echo "== the event log of before, then the upgrade: ADMIN_DB_PASSWORD set"
check "$(admin_healthy)" healthy "admin UI up, without ADMIN_DB_PASSWORD"
for _ in $(seq 1 30); do [ "$(sql "SELECT COUNT(*) FROM ffs_events;" 2> /dev/null)" -gt 0 ] 2> /dev/null && break; sleep 1; done
check "$([ "$(sql "SELECT COUNT(*) FROM ffs_events;")" -gt 0 ] && echo yes)" yes "the admin UI records its events in the tokenserver database"
[ -n "${UPGRADE_FROM:-}" ] ||
  check "$(dc logs ffs-admin 2>&1 | grep -c 'ADMIN_DB_PASSWORD is not set')" 1 "the admin UI says the event log is within the Sync server's reach"
# what an admin did before the upgrade, a note, a backup run: the audit trail must survive it
sql "INSERT INTO ffs_events (at, kind, detail) VALUES ($(date +%s)000, 'admin', 'ffs-e2e: before the upgrade by admin (password)');" > /dev/null
sql "INSERT INTO ffs_account_notes (uid, note, updated_at, updated_by) VALUES ('ffs-e2e-upgrade', 'kept across the upgrade', 1, 'admin (password)');" > /dev/null
sql "INSERT INTO ffs_backups (scope, started, finished, ok, bytes, location) VALUES ('sync', $(date +%s)000, $(date +%s)000, 1, 1, 'ffs-e2e: before the upgrade');" > /dev/null
OLD_EVENTS=$(sql "SELECT COUNT(*) FROM ffs_events;")
if [ -n "${UPGRADE_FROM:-}" ]; then
  # this tree from here on; with PostgreSQL through the upgraded stack
  ROOT=${CODE}
  [ "${BACKEND}" = postgres ] && COMPOSE=${CODE}/docker-compose.sync-postgres.yml
  export ADMIN_IMAGE=${ADMIN_NOW}
  set_env SYNC_INIT_IMAGE_TAG "${INIT_NOW}"
fi
echo "== the lines of .env-example added before --upgrade: both names, the migrations refuse to start"
# (MIGRATING.md: --upgrade first) the new names with their placeholders and defaults would
# win over the values of the old ones: a new server on empty databases, or none at all
grep -E "${NEW_RE}" "${CODE}/.env-example" >> "${ENV_FILE}"
# but the images under test (the defaults of .env-example are the published MySQL ones): as
# with the images of this release, whose init containers refuse to start
sed -i -e "s|^IMAGE_REPOSITORY=.*|IMAGE_REPOSITORY=${REPOSITORY}|" -e "s|^SYNC_IMAGE=.*|SYNC_IMAGE=syncstorage-rs-${BACKEND}|" \
  -e "s|^SYNC_INIT_IMAGE=.*|SYNC_INIT_IMAGE=syncstorage-rs-${BACKEND}-init|" -e "s|^SYNC_IMAGE_TAG=.*|SYNC_IMAGE_TAG=${TAG}|" \
  -e "s|^SYNC_INIT_IMAGE_TAG=.*|SYNC_INIT_IMAGE_TAG=${SYNCSTORAGE_INIT_IMAGE_TAG}|" "${ENV_FILE}"
dc stop > /dev/null 2>&1
dc up -d > "${WORK}/both.log" 2>&1
check "$([ $? != 0 ] && echo failed) $(state syncstorage Running || echo false) $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")" "failed false 000" \
  "with both names: docker compose up fails, the Sync server stays down"
# (PostgreSQL: sync_role_init, which runs first)
both=$([ "${BACKEND}" = mysql ] && echo "SYNC_TOKENSERVER_DB_PASSWORD and MARIADB_TOKENSERVER_PASSWORD" || echo "SYNC_POSTGRES_PASSWORD and POSTGRES_PASSWORD")
both_logs=$(dc logs "$([ "${BACKEND}" = postgres ] && echo sync_role_init || echo syncstorage_migrate)" 2>&1)
both_said=$(grep -c "ERROR: ${both} are both set (in .env or in the environment docker compose runs in): run ./prepare_environment.sh --upgrade for .env, or unset ${both##* } in your shell (MIGRATING.md#renamed-settings)" <<< "${both_logs}")
check "${both_said}" 1 "it names them, and what to run"
[ "${both_said}" = 1 ] || { tail -5 <<< "${both_logs}"; tail -5 "${WORK}/both.log"; }
echo "== ./prepare_environment.sh --upgrade renames the old setting names"
UP=${WORK}/upgrade
# SYNC_DB=mysql on mysql:8: as an install from before SYNC_MYSQL_IMAGE, which --upgrade pins
[ "${SYNC_DB}" = mysql ] && [ -n "${MYSQL_PINNED}" ] && sed -i '/^SYNC_MYSQL_IMAGE=/d' "${ENV_FILE}"
mkdir -p "${UP}" && cp -r "${CODE}/prepare_environment.sh" "${CODE}/.env-example" "${CODE}/db" "${UP}/" && cp "${ENV_FILE}" "${UP}/.env"
(cd "${UP}" && ./prepare_environment.sh --upgrade) > "${WORK}/upgrade.log" 2>&1
check "$?" 0 "./prepare_environment.sh --upgrade" || cat "${WORK}/upgrade.log"
[ "${SYNC_DB}" = mysql ] && [ -n "${MYSQL_PINNED}" ] && check "$(grep '^SYNC_MYSQL_IMAGE=' "${UP}/.env") $(grep -c 'the Sync databases stay on MySQL 8' "${WORK}/upgrade.log")" \
  "SYNC_MYSQL_IMAGE=mysql:8 1" "--upgrade pins the Sync databases of an install from before on MySQL 8"
# each value under its new name, as it was under the old one (the empty ones it may fill in)
moved=all
for pair in "${RENAMED_SETTINGS[@]}"; do
  [ -n "$(grep "^${pair#*=}=" "${ENV_FILE}" | cut -d= -f2-)" ] || continue
  [ "$(grep "^${pair%%=*}=" "${UP}/.env" | cut -d= -f2-)" = "$(grep "^${pair#*=}=" "${ENV_FILE}" | cut -d= -f2-)" ] || moved=${pair}
done
check "$(grep -cE "${OLD_RE}" "${UP}/.env") ${moved} $(grep -c '^  [A-Z_]* -> [A-Z_]*$' "${WORK}/upgrade.log") $(cmp -s "${ENV_FILE}" "${UP}/.env.before-upgrade" && echo kept)" \
  "0 all $(grep -cE "${OLD_RE}" "${ENV_FILE}") kept" "--upgrade: no old name left, every value under its new name, each rename said, the old .env kept"
cp "${UP}/.env" "${ENV_FILE}"
# the old names gone from this shell too (REPOSITORY and POSTGRES_IMAGE are the test's own,
# kept but not exported, tests/slot.sh)
for pair in "${RENAMED_SETTINGS[@]}"; do
  case "${pair#*=}" in REPOSITORY|POSTGRES_IMAGE) export -n "${pair#*=}" ;; *) unset "${pair#*=}" ;; esac
done
OLD_NAMES=
set -a; source "${ENV_FILE}"; set +a
set_env ADMIN_DB_PASSWORD "${ADMIN_DB_SECRET}"
set_env SYNC_POSTGRES_APP_USER "${SYNC_ROLE}"
set_env SYNC_POSTGRES_APP_PASSWORD "${SYNC_ROLE_SECRET}"
dc up -d > /dev/null 2>&1 || { dc logs; exit 1; }
check "$(wait_init)" 0 "init container exit code (ADMIN_DB_PASSWORD set)"
check "$(dc logs tokenserver_db_init 2>&1 | grep -c 'old names') $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(dc ps -q ffs-admin)" | grep -cx 'FFS_OLD_ENV_NAMES=')" "0 1" \
  "the new setting names: no warning of the init container, no old names for the admin UI"
check "$(admin_healthy)" healthy "admin UI up with its own database"
for _ in $(seq 1 30); do [ "$(old_tables)" = 0 ] && break; sleep 1; done
check "$(old_tables)" 0 "the admin UI's tables gone from the tokenserver database"
check "$(admin_sql "SELECT COUNT(*) FROM ffs_events WHERE detail = 'ffs-e2e: before the upgrade by admin (password)';")" 1 "the audit trail of before in the admin UI's database"
check "$([ "$(admin_sql "SELECT COUNT(*) FROM ffs_events WHERE kind <> 'update' OR detail NOT LIKE 'Moved the admin UI%';")" -ge "${OLD_EVENTS}" ] && echo yes)" yes \
  "every event of before moved (${OLD_EVENTS})"
check "$(admin_sql "SELECT note FROM ffs_account_notes WHERE uid = 'ffs-e2e-upgrade';") $(admin_sql "SELECT COUNT(*) FROM ffs_backups WHERE location = 'ffs-e2e: before the upgrade';")" \
  "kept across the upgrade 1" "the notes and the backup runs of before moved"
check "$(admin_sql "SELECT COUNT(*) FROM ffs_events WHERE kind = 'update' AND detail LIKE 'Moved the admin UI''s tables of the tokenserver database into ${ADMIN_DB_NAME}%';")" 1 "the move is in the event log"
# a restart: nothing copied twice
dc restart ffs-admin > /dev/null 2>&1
check "$(admin_healthy)" healthy "admin UI restarted"
check "$(admin_sql "SELECT COUNT(*) FROM ffs_events WHERE detail = 'ffs-e2e: before the upgrade by admin (password)' OR detail LIKE 'Moved the admin UI%';")" 2 "moved once"
check "$(hb)" 200 "/__heartbeat__ after the upgrade"
# (this tree's compose files from here on, also with UPGRADE_FROM)
check "$(docker inspect -f '{{.HostConfig.CapDrop}}' "$(dc ps -q syncstorage)") $(docker inspect -f '{{.HostConfig.CapDrop}}' "$(dc ps -a -q syncstorage_migrate)")" \
  "[CAP_NET_RAW] [CAP_NET_RAW]" "the Sync server and its migrations without raw sockets (cap_drop)"
if [ "${BACKEND}" = postgres ] && [ -z "${EXTERNAL_DB:-}" ]; then
  # postgres_db and backup use SYNC_POSTGRES_IMAGE from .env (postgres:latest by default)
  pg_image=$(grep "^SYNC_POSTGRES_IMAGE=" "${ENV_FILE}" | cut -d= -f2)
  pg_image=${pg_image:-postgres:latest}
  check "$(docker inspect -f '{{.Config.Image}}' "$(dc ps -q postgres_db)")" \
    "${pg_image}" "postgres_db uses SYNC_POSTGRES_IMAGE from .env"
  # backup service: check the compose config (not running unless COMPOSE_PROFILES=backup was used)
  check "$(dc config | sed -n '/^  backup:/,/^  [a-z]/p' | grep "image:" | awk '{print $2}')" \
    "${pg_image}" "backup service configured with SYNC_POSTGRES_IMAGE from .env"
fi

echo "== the migrations step ends when syncstorage-rs does not stop on SIGTERM"
# its graceful shutdown can hang for good: the step kills it 30 s after SIGTERM, and still
# succeeds (it answered its heartbeat: the migrations ran)
T0=$(date +%s)
# (timeout: without the kill it never ends)
OUT=$(timeout 120 docker compose -p "${PROJECT}" -f "${COMPOSE}" -f "${TESTS}/docker-compose.test.yml" "${COMPOSE_EXTRA[@]}" --env-file "${ENV_FILE}" \
  run --rm --no-deps -v "${TESTS}/hung_syncserver.sh:/app/bin/syncserver:ro" syncstorage_migrate 2>&1)
RC=$? SECS=$(($(date +%s) - T0))
check "${RC} $(grep -c 'still running 30 s after SIGTERM, killed' <<< "${OUT}") $(grep -c 'Migrations completed' <<< "${OUT}")" "0 1 1" \
  "a syncstorage-rs that ignores SIGTERM is killed, the migrations step exits 0"
check "$([ "${SECS}" -lt 60 ] && echo yes)" yes "within a minute (${SECS} s)"

echo "== the Sync server's users cannot read or change the event log"
denied() { if grep -qiE 'denied|permission' <<< "$1"; then echo denied; else echo "allowed: $1"; fi; }
init_again() { dc up -d --no-deps --force-recreate tokenserver_db_init > /dev/null 2>&1; wait_init; }
if [ "${BACKEND}" = mysql ]; then
  check "$(denied "$(sql "SELECT COUNT(*) FROM ${ADMIN_DB_NAME}.ffs_events;" 2>&1)")" denied "the tokenserver user cannot read the event log"
  check "$(denied "$(sql "INSERT INTO ${ADMIN_DB_NAME}.ffs_events (at, kind, detail) VALUES (1, 'admin', 'forged');" 2>&1)")" denied "the tokenserver user cannot add to the event log"
  check "$(denied "$(sql "DELETE FROM ${ADMIN_DB_NAME}.ffs_events;" 2>&1)")" denied "the tokenserver user cannot delete from the event log"
  check "$(denied "$(sql "CREATE TABLE ${ADMIN_DB_NAME}.forged (id INT);" 2>&1)")" denied "the tokenserver user cannot create tables there"
  if [ -n "${EXTDB}" ]; then
    # the storage user, on the same server here
    check "$(denied "$(docker exec -i -e MYSQL_PWD="${SYNC_STORAGE_DB_PASSWORD}" "${EXTDB}" mysql -u"${SYNC_STORAGE_DB_USER}" -sN \
      -e "SELECT COUNT(*) FROM ${ADMIN_DB_NAME}.ffs_events;" < /dev/null 2>&1)")" denied "the storage user cannot read the event log"
  fi
  # the admin UI's two users: the reader of the Sync data writes the Sync tables only through
  # the init container's procedures and has nothing on the event log; the other one has the
  # event log only
  check "$(denied "$(admin_sync_sql "UPDATE nodes SET capacity = capacity;" 2>&1)")" denied "the admin UI's reader cannot change the tokenserver's tables"
  check "$(denied "$(admin_sync_sql "CREATE TABLE forged (id INT);" 2>&1)")" denied "the admin UI's reader cannot create tables in the tokenserver database"
  check "$(denied "$(admin_sync_sql "SELECT COUNT(*) FROM ${ADMIN_DB_NAME}.ffs_events;" 2>&1)")" denied "the admin UI's reader cannot read the event log"
  check "$(denied "$(admin_sql "SELECT COUNT(*) FROM ${SYNC_TOKENSERVER_DB_NAME}.users;" 2>&1)") $(denied "$(admin_sql "SELECT COUNT(*) FROM ${SYNC_STORAGE_DB_NAME}.bso;" 2>&1)")" \
    "denied denied" "the admin UI's own user cannot read the Sync databases"
  check "$(admin_sync_sql "SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = DATABASE() AND routine_name IN ('ffs_set_max_users', 'ffs_delete_user_row', 'ffs_drop_admin_tables');")" 3 \
    "the init container's procedures for the admin UI"
  # the Sync server's user puts its own procedure there, which runs with the privileges of
  # the caller (SQL SECURITY INVOKER) and deletes the audit trail: the admin UI calls it as
  # its reader, which cannot
  AUDIT=$(admin_sql "SELECT COUNT(*) FROM ffs_events WHERE kind = 'admin';")
  sql "DROP PROCEDURE ffs_set_max_users;" > /dev/null
  sql "CREATE PROCEDURE ffs_set_max_users(IN v VARCHAR(255)) SQL SECURITY INVOKER DELETE FROM ${ADMIN_DB_NAME}.ffs_events WHERE kind = 'admin';"
  check "$?" 0 "the tokenserver user replaces ffs_set_max_users with its own, SQL SECURITY INVOKER"
  check "$(denied "$(admin_sync_sql "CALL ffs_set_max_users('1');" 2>&1)") $(admin_sql "SELECT COUNT(*) FROM ffs_events WHERE kind = 'admin';")" "denied ${AUDIT}" \
    "a procedure of the Sync server's user, run by the admin UI, cannot delete the audit trail"
  check "$(init_again) $(sql "SELECT security_type FROM information_schema.routines WHERE routine_schema = DATABASE() AND routine_name = 'ffs_set_max_users';")" "0 DEFINER" \
    "the init container puts its procedure back"
else
  check "$(sync_role_sql "SELECT rolsuper OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname = current_user;") $(sync_role_sql "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname = 'users' AND relnamespace = 'public'::regnamespace;")" \
    "f ${SYNC_ROLE:-${SYNC_POSTGRES_USER}}" "the Sync server's role is no superuser, and owns the Sync tables"
  check "$(denied "$(sync_role_sql "SELECT COUNT(*) FROM ffs_events;" "${ADMIN_DB_NAME}" 2>&1)")" denied "the Sync server's role cannot connect to the admin UI's database"
  check "$(admin_sql "SELECT pg_get_userbyid(datdba), has_database_privilege('public', datname, 'CONNECT'), has_database_privilege('${SYNC_ROLE:-${SYNC_POSTGRES_USER}}', datname, 'CONNECT'), has_database_privilege('${ADMIN_DB_SYNC_USER}', datname, 'CONNECT') FROM pg_database WHERE datname = current_database();")" \
    "${ADMIN_DB_USER}|f|f|f" "the admin UI's database is its role's, closed to the others"
  check "$(admin_sql "SELECT rolsuper FROM pg_roles WHERE rolname = current_user;") $(admin_sync_sql "SELECT rolsuper FROM pg_roles WHERE rolname = current_user;")" "f f" "the admin UI's roles are no superusers"
  check "$(denied "$(admin_sync_sql "UPDATE nodes SET capacity = capacity;" 2>&1)")" denied "the admin UI's reader cannot change the tokenserver's nodes"
  check "$(denied "$(admin_sync_sql "CREATE TABLE forged (id INT);" 2>&1)")" denied "the admin UI's reader cannot create tables in the Sync database"
  check "$(denied "$(admin_sql "SELECT COUNT(*) FROM users;" "${SYNC_POSTGRES_NAME}" 2>&1)")" denied "the admin UI's own role cannot read the Sync database"
  # the owner of the Sync tables replaces the function the admin UI calls with its own, which
  # runs as the caller (SECURITY INVOKER) and opens the admin UI's database: its reader cannot
  sync_role_sql "CREATE OR REPLACE FUNCTION ffs_drop_admin_tables() RETURNS void LANGUAGE plpgsql SECURITY INVOKER AS \$f\$ BEGIN EXECUTE 'GRANT ALL ON DATABASE ${ADMIN_DB_NAME} TO PUBLIC'; END \$f\$;" > /dev/null
  check "$?" 0 "the Sync server's role replaces ffs_drop_admin_tables with its own, SECURITY INVOKER"
  admin_sync_sql "SELECT ffs_drop_admin_tables();" > /dev/null 2>&1
  check "$(admin_sql "SELECT has_database_privilege('public', current_database(), 'CONNECT');")" f "a function of the Sync server's role, run by the admin UI, cannot open its database"
  check "$(init_again) $(sql "SELECT prosecdef FROM pg_proc WHERE proname = 'ffs_drop_admin_tables';")" "0 t" "the init container puts its function back"
  if [ -n "${SYNC_ROLE}" ]; then
    # the Sync server's role plants code that would make it a superuser if a superuser ran
    # it (also after SET ROLE: RESET ROLE goes back), each run recorded with who ran it and
    # how: triggers on the tables the init container (config: max users) and the migrations
    # (nodes: the node of SYNC_PUBLIC_URL) write; config itself becomes a view over the
    # table, which calls it on every read and write (the init's upsert, the counts); and an
    # operator <> (oid, regrole) in public, which a superuser statement with public in its
    # search path would pick over pg_catalog's (sync_owner.sql compares relowner <> the role)
    sync_role_sql "CREATE TABLE ffs_e2e_ran (by_session TEXT, by_current TEXT, via TEXT);
      GRANT INSERT ON ffs_e2e_ran TO PUBLIC;
      CREATE FUNCTION ffs_e2e_note(via TEXT) RETURNS boolean LANGUAGE plpgsql AS \$f\$
      BEGIN
        INSERT INTO public.ffs_e2e_ran VALUES (session_user, current_user, via);
        BEGIN
          RESET ROLE;
          EXECUTE 'ALTER ROLE ${SYNC_ROLE} SUPERUSER';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RETURN true;
      END \$f\$;
      CREATE FUNCTION ffs_e2e_plant() RETURNS trigger LANGUAGE plpgsql AS \$f\$
      BEGIN PERFORM public.ffs_e2e_note('trigger ' || TG_TABLE_NAME); RETURN NULL; END \$f\$;
      CREATE FUNCTION ffs_e2e_ne(oid, regrole) RETURNS boolean LANGUAGE plpgsql STRICT AS \$f\$
      BEGIN PERFORM public.ffs_e2e_note('operator'); RETURN \$1 <> \$2::oid; END \$f\$;
      CREATE OPERATOR public.<> (LEFTARG = oid, RIGHTARG = regrole, FUNCTION = public.ffs_e2e_ne);
      ALTER TABLE config RENAME TO config_r;
      CREATE VIEW config AS SELECT * FROM config_r WHERE public.ffs_e2e_note('view config');
      GRANT SELECT, UPDATE (config_value) ON config TO ${ADMIN_DB_SYNC_USER};
      CREATE TRIGGER ffs_e2e_plant AFTER INSERT OR UPDATE OR DELETE ON config_r FOR EACH STATEMENT EXECUTE FUNCTION ffs_e2e_plant();
      CREATE TRIGGER ffs_e2e_plant AFTER INSERT OR UPDATE OR DELETE ON nodes FOR EACH STATEMENT EXECUTE FUNCTION ffs_e2e_plant();" > /dev/null
    check "$?" 0 "the Sync server's role plants triggers on config and nodes, a view as config, an operator <>"
    # the start of the stack again, in its order: the role, the migrations, the init container
    one_shot() { dc up -d --no-deps --force-recreate "$1" > /dev/null 2>&1; timeout 300 docker wait "$(dc ps -a -q "$1")"; }
    check "$(one_shot sync_role_init) $(one_shot syncstorage_migrate) $(one_shot tokenserver_db_init)" "0 0 0" "the role, the migrations and the init container again"
    check "$(sql "SELECT rolsuper FROM pg_roles WHERE rolname = '${SYNC_ROLE}';")" f "the Sync server's role is still no superuser"
    # (the admin UI's reader reads max users through the view too: no superuser either)
    check "$(sql "SELECT COUNT(*) FROM ffs_e2e_ran r JOIN pg_roles o ON o.rolname IN (r.by_session, r.by_current) WHERE o.rolsuper;")" 0 \
      "the planted code never ran as a superuser"
    check "$(sql "SELECT COUNT(DISTINCT via) FROM ffs_e2e_ran WHERE by_session = '${SYNC_ROLE}' AND via IN ('view config', 'trigger config_r');")" 2 \
      "the init container read and wrote config through the view and its trigger, as the Sync server's role"
    sync_role_sql "DROP TRIGGER ffs_e2e_plant ON config_r; DROP TRIGGER ffs_e2e_plant ON nodes; DROP VIEW config; ALTER TABLE config_r RENAME TO config;
      DROP OPERATOR public.<> (oid, regrole); DROP FUNCTION ffs_e2e_ne(oid, regrole), ffs_e2e_plant(), ffs_e2e_note(TEXT); DROP TABLE ffs_e2e_ran;" > /dev/null
    check "$? $(sql "SELECT relkind FROM pg_class WHERE relname = 'config' AND relnamespace = 'public'::regnamespace;")" "0 r" "the planted code removed, config a table again"
    check "$(hb)" 200 "/__heartbeat__ after the planted code"
  fi
  # the admin UI's database holds only what its role owns: a table ffs_events of the Sync
  # server's role there, in a schema of the admin UI's role's name (first in its search
  # path), as a database copied from a template1 of PostgreSQL 11 to 14 could hold it; and an
  # operator >= (oid, integer) of that role in public, which would answer false to the
  # check's "oid >= 16384" were it not run with pg_catalog alone in its search path
  pg_super() { # database query, as a superuser of the server
    if [ -n "${EXTDB}" ]; then extdb_admin -d "$1" -c "$2" < /dev/null; else dc exec -T postgres_db psql -U "${SYNC_POSTGRES_USER}" -d "$1" -v ON_ERROR_STOP=1 -tA -c "$2" < /dev/null; fi
  }
  OTHER=${SYNC_ROLE:-${SYNC_POSTGRES_USER}}
  pg_super "${ADMIN_DB_NAME}" "CREATE SCHEMA ${ADMIN_DB_USER} AUTHORIZATION ${OTHER};
    CREATE TABLE ${ADMIN_DB_USER}.ffs_events (id BIGINT, at BIGINT, kind TEXT, detail TEXT); ALTER TABLE ${ADMIN_DB_USER}.ffs_events OWNER TO ${OTHER};
    CREATE FUNCTION public.ffs_e2e_ge(oid, integer) RETURNS boolean LANGUAGE sql AS 'SELECT false';
    CREATE OPERATOR public.>= (LEFTARG = oid, RIGHTARG = integer, FUNCTION = public.ffs_e2e_ge);
    ALTER FUNCTION public.ffs_e2e_ge(oid, integer) OWNER TO ${OTHER}; ALTER OPERATOR public.>= (oid, integer) OWNER TO ${OTHER};" > /dev/null
  check "$?" 0 "a table ffs_events and an operator >= of ${OTHER} planted in the admin UI's database"
  dc restart ffs-admin > /dev/null 2>&1
  refused() { dc logs ffs-admin 2>&1 | grep -c "holds what its role ADMIN_DB_USER does not own: .*table ${ADMIN_DB_USER}.ffs_events of ${OTHER}"; }
  for _ in $(seq 1 30); do [ "$(refused)" -gt 0 ] && break; sleep 1; done
  check "$([ "$(refused)" -gt 0 ] && echo yes) $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$((PORT + 20))/login")" "yes 000" \
    "the admin UI does not start, and says why"
  pg_super "${ADMIN_DB_NAME}" "DROP SCHEMA ${ADMIN_DB_USER} CASCADE; DROP OPERATOR public.>= (oid, integer); DROP FUNCTION public.ffs_e2e_ge(oid, integer);" > /dev/null
  dc restart ffs-admin > /dev/null 2>&1
  check "$(admin_healthy)" healthy "admin UI up again once it is gone"
fi

if [ -n "${EXTDB}" ]; then
  echo "== external database server: nothing more than the documented grants"
  check "$(dc ps -a --format '{{.Service}}' | grep -cxE 'syncstorage_db|tokenserver_db|postgres_db')" 0 "no database container in the project"
  if [ "${BACKEND}" = mysql ]; then
    grants=$(echo "SHOW GRANTS FOR '${SYNC_TOKENSERVER_DB_USER}'@'%'; SHOW GRANTS FOR '${SYNC_STORAGE_DB_USER}'@'%';" | extdb_admin)
    echo "${grants}" | sed 's/^/  /'
    check "$(echo "${grants}" | grep -cE 'ALL PRIVILEGES|SUPER')" 0 "no ALL PRIVILEGES or SUPER for the Sync users"
    check "$(echo "${grants}" | grep -c "${ADMIN_DB_NAME}")" 0 "no grant for the Sync users on the admin UI's database"
    admin_grants=$(echo "SHOW GRANTS FOR '${ADMIN_DB_USER}'@'%'; SHOW GRANTS FOR '${ADMIN_DB_SYNC_USER}'@'%';" | extdb_admin)
    echo "${admin_grants}" | sed 's/^/  /'
    check "$(echo "${admin_grants}" | grep -vc '^GRANT USAGE ON \*\.\*') $(echo "${admin_grants}" | grep -cE 'ALL PRIVILEGES|SUPER|GRANT OPTION')" "3 0" \
      "the admin UI's users: its database; SELECT and EXECUTE on the tokenserver, SELECT and DELETE on the storage"
    check "$(echo "${admin_grants}" | grep -cF "\`${ADMIN_DB_NAME}\`.") $(echo "${admin_grants}" | grep -F "\`${ADMIN_DB_NAME}\`." | grep -cF "TO \`${ADMIN_DB_USER}\`@")" "1 1" \
      "only the admin UI's own user has a grant on its database"
    # what the test is about: binary logging (triggers), caching_sha2_password without TLS
    check "$(echo "SELECT @@log_bin, (SELECT GROUP_CONCAT(DISTINCT plugin) FROM mysql.user WHERE user IN ('${SYNC_TOKENSERVER_DB_USER}', '${SYNC_STORAGE_DB_USER}'));" | extdb_admin)" \
      "$(printf '1\tcaching_sha2_password')" "binary logging on, users with caching_sha2_password"
    check "$(sql "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_name = 'BeforeInsertUser';")" 1 "SYNC_MAX_USERS trigger created by the init container"
  else
    check "$(echo "SELECT rolsuper, rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname = '${SYNC_POSTGRES_USER}';" | extdb_admin)" "f|f|f" \
      "the database owner is no superuser"
    check "$(echo "SELECT has_database_privilege('dbadmin', '${SYNC_POSTGRES_NAME}', 'TEMP'), has_database_privilege('public', '${SYNC_POSTGRES_NAME}', 'CONNECT');" | extdb_admin)" "t|f" \
      "database created by a CREATEROLE CREATEDB role, closed to PUBLIC"
  fi
fi

if [ "${SYNC_DB}" = mysql ]; then
  echo "== database containers on MySQL ${SYNC_MYSQL_IMAGE} (SYNC_DB=mysql)"
  for db in syncstorage_db tokenserver_db; do
    check "$(docker inspect -f '{{.Config.Image}}' "$(dc ps -a -q "${db}")")" "${SYNC_MYSQL_IMAGE}" "${db} runs ${SYNC_MYSQL_IMAGE}"
    check "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}' "$(dc ps -a -q "${db}")")" \
      "${PROJECT}_${db//_/-}-mysql" "${db} in its own volume, not MariaDB's"
  done
  # no binary logging (docker-compose.sync-mysql.yml), the trigger without log_bin_trust_function_creators
  mysql_version=$(sql "SELECT VERSION();")
  check "$(sql "SELECT @@log_bin, @@log_bin_trust_function_creators;") $([ -z "${MYSQL_PINNED}" ] || [[ "${mysql_version}" == "${MYSQL_PINNED}".* ]] && echo yes)" "$(printf '0\t0') yes" \
    "MySQL ${mysql_version} without binary logging"
  check "$(sql "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_name = 'BeforeInsertUser';")" 1 "SYNC_MAX_USERS trigger created by the init container"
  if [ -n "${MYSQL_PINNED}" ]; then
    echo "== without SYNC_MYSQL_IMAGE (the default, mysql:lts): the MySQL ${MYSQL_PINNED} data is not upgraded"
    # an install from before SYNC_MYSQL_IMAGE with the new files, without --upgrade
    sed -i '/^SYNC_MYSQL_IMAGE=/d' "${ENV_FILE}"; unset SYNC_MYSQL_IMAGE
    dc up -d --no-deps --force-recreate tokenserver_db > /dev/null 2>&1
    for _ in $(seq 1 60); do dc logs tokenserver_db 2>&1 | grep -q 'keep-major.sh: ' && break; sleep 2; done
    # (said at each of its restarts)
    check "$(docker inspect -f '{{.Config.Image}}' "$(dc ps -a -q tokenserver_db)") $(dc logs tokenserver_db 2>&1 | grep -q "keep-major.sh: this database is MySQL ${MYSQL_PINNED}, the image is MySQL" && echo said)" "mysql:lts said" \
      "tokenserver_db on mysql:lts refuses the MySQL ${MYSQL_PINNED} data, and says why"
    check "$(dc logs tokenserver_db 2>&1 | grep -ciE 'upgrad(e|ing) (the )?(data dictionary|server)|Server upgrade from')" 0 "the data not upgraded"
    printf 'SYNC_MYSQL_IMAGE=mysql:%s\n' "${MYSQL_PINNED}" >> "${ENV_FILE}"; export SYNC_MYSQL_IMAGE=mysql:${MYSQL_PINNED}
    dc up -d --no-deps --force-recreate tokenserver_db > /dev/null 2>&1
    for _ in $(seq 1 60); do [ "$(state tokenserver_db Health.Status)" = healthy ] && break; sleep 2; done
    check "$(state tokenserver_db Health.Status) $(sql "SELECT VERSION();" | cut -d. -f1)" "healthy ${MYSQL_PINNED}" "back on mysql:${MYSQL_PINNED}: its data as it was"
    dc up -d > /dev/null 2>&1
    check "$(hb)" 200 "/__heartbeat__ again"
    echo "== MIGRATING.md#mysql-lts: SYNC_MYSQL_IMAGE=mysql:lts, MySQL upgrades the data"
    users_before=$(sql "SELECT COUNT(*) FROM users;")
    sed -i '/^SYNC_MYSQL_IMAGE=/d' "${ENV_FILE}"; printf 'SYNC_MYSQL_IMAGE=mysql:lts\n' >> "${ENV_FILE}"; export SYNC_MYSQL_IMAGE=mysql:lts
    dc up -d > "${WORK}/up-mysql-lts.log" 2>&1 || tail -5 "${WORK}/up-mysql-lts.log"
    for _ in $(seq 1 90); do [ "$(state tokenserver_db Health.Status)" = healthy ] && [ "$(state syncstorage_db Health.Status)" = healthy ] && break; sleep 2; done
    check "$(hb) $(docker inspect -f '{{.Config.Image}}' "$(dc ps -a -q tokenserver_db)") $(docker inspect -f '{{.Config.Image}}' "$(dc ps -a -q syncstorage_db)")" "200 mysql:lts mysql:lts" \
      "the Sync databases on mysql:lts"
    check "$([ "$(sql "SELECT VERSION();" | cut -d. -f1)" != "${MYSQL_PINNED}" ] && echo newer) $(sql "SELECT COUNT(*) FROM users;")" "newer ${users_before}" \
      "MySQL $(sql "SELECT VERSION();") on the data of MySQL ${MYSQL_PINNED}, every user kept"
  fi
fi

echo "== tokenserver node"
SVC=$(sql "SELECT id FROM services WHERE service='sync-1.5';")
echo "sync-1.5 service id: ${SVC}"
check "$(sql "SELECT COUNT(*) FROM nodes WHERE service=${SVC} AND node='${SYNC_PUBLIC_URL}' AND available>0 AND downed=0;")" 1 "node for ${SYNC_PUBLIC_URL} attached to sync-1.5"
NODE=$(sql "SELECT id FROM nodes WHERE service=${SVC} AND node='${SYNC_PUBLIC_URL}';")

echo "== SYNC_MAX_USERS=1 trigger (database level)"
ins() { sql "INSERT INTO users (service, email, generation, client_state, created_at, nodeid) VALUES (${SVC}, '$1', $2, '$3', 1, ${NODE});" > /dev/null 2>&1 && echo ok || echo rejected; }
check "$(ins a@ffs-e2e.invalid 1 aa)" ok "first account allowed"
check "$(ins a@ffs-e2e.invalid 2 bb)" ok "same account with new client state allowed"
check "$(ins b@ffs-e2e.invalid 1 aa)" rejected "second account rejected"

echo "== SYNC_MAX_USERS=1 (plain): set again on every start, read-only in the admin UI"
max_users() { sql "SELECT config_value FROM config WHERE config_key = 'max_users';"; }
rerun_init() { dc up -d --no-deps --force-recreate tokenserver_db_init > /dev/null 2>&1; wait_init; }
# the whole stack with a new SYNC_MAX_USERS: the init container and the admin UI
# not in $(...): set_env must change this shell's SYNC_MAX_USERS (compose prefers it to the
# env file), the exit code of the init container is in INIT_CODE
redeploy_max_users() { set_env SYNC_MAX_USERS "$1"; dc up -d > /dev/null 2>&1; INIT_CODE=$(wait_init); }
sql "UPDATE config SET config_value = '3' WHERE config_key = 'max_users';" > /dev/null
check "$(rerun_init)" 0 "init container exit code (rerun)"
check "$(max_users)" 1 "SYNC_MAX_USERS=1 set again over a value changed in the database"
check "$(sql "SELECT COUNT(*) FROM config WHERE config_key = 'max_users_env';")" 0 "no max_users_env bookkeeping"
pytest_in_app "/tests/test_admin_sync.py -k read_only"
check "$?" 0 "admin UI: max users read-only with SYNC_MAX_USERS=1"
check "$(max_users)" 1 "max users unchanged by the refused form"

echo "== SYNC_MAX_USERS=initial:N: set only when there is none, then managed in the admin UI"
redeploy_max_users initial:2
check "${INIT_CODE}" 0 "init container exit code (SYNC_MAX_USERS=initial:2)"
check "$(max_users)" 1 "switching to initial:2 keeps the value in the database"
sql "UPDATE config SET config_value = '3' WHERE config_key = 'max_users';" > /dev/null
rerun_init > /dev/null
check "$(max_users)" 3 "initial:2 keeps a value changed in the database (admin UI)"
sql "DELETE FROM config WHERE config_key = 'max_users';" > /dev/null
rerun_init > /dev/null
check "$(max_users)" 2 "initial:2 sets it when there is none (new database)"
redeploy_max_users 1
check "${INIT_CODE}" 0 "init container exit code (back to SYNC_MAX_USERS=1)"
check "$(max_users)" 1 "switching back to a plain SYNC_MAX_USERS=1 takes over"

echo "== SYNC_MAX_USERS not valid: the init container fails, nothing changes"
for bad in lots initial: fixed:-1 infinite initial:Unlimited 2147483648; do
  set_env SYNC_MAX_USERS "${bad}"
  check "$(rerun_init)" 1 "init container fails with SYNC_MAX_USERS=${bad}"
done
check "$(dc logs tokenserver_db_init 2>&1 | grep -c "SYNC_MAX_USERS='2147483648' is not valid")" 1 "init container says why"
check "$(max_users)" 1 "max users unchanged by a SYNC_MAX_USERS not valid"

echo "== SYNC_MAX_USERS=unlimited: no limit, by the trigger itself; 0: no new account at all"
redeploy_max_users unlimited
check "${INIT_CODE}" 0 "init container exit code (SYNC_MAX_USERS=unlimited)"
check "$(max_users)" unlimited "SYNC_MAX_USERS=unlimited in the database"
check "$(ins c@ffs-e2e.invalid 1 aa) $(ins d@ffs-e2e.invalid 1 aa)" "ok ok" "new accounts allowed with no limit"
sql "DELETE FROM users WHERE email IN ('c@ffs-e2e.invalid', 'd@ffs-e2e.invalid');" > /dev/null
redeploy_max_users initial:5
check "$(max_users)" unlimited "SYNC_MAX_USERS=initial:5 keeps unlimited in the database"
redeploy_max_users fixed:0
check "$(max_users) $(ins e@ffs-e2e.invalid 1 aa) $(ins a@ffs-e2e.invalid 3 cc)" "0 rejected ok" "SYNC_MAX_USERS=0: no new account, the existing one still changes its keys"
redeploy_max_users 1
check "$(max_users)" 1 "back to SYNC_MAX_USERS=1"

# the admin UI tests change max users on the page: initial:1 for the rest, until the
# upstream tokenserver tests (the Python tests get the number, see in_app)
redeploy_max_users initial:1
check "${INIT_CODE}" 0 "init container exit code (SYNC_MAX_USERS=initial:1)"
check "$(max_users)" 1 "max users 1 for the following tests"
check "$(hb)" 200 "/__heartbeat__ after the SYNC_MAX_USERS changes"

echo "== domain change"
OLD_DOMAIN=${SYNC_PUBLIC_URL}
NEW_DOMAIN=https://ffs-e2e-new.invalid
redeploy() { set_env SYNC_PUBLIC_URL "$1"; dc up -d > /dev/null 2>&1; wait_init > /dev/null; }
node_of_user() { sql "SELECT DISTINCT n.node FROM users u JOIN nodes n ON u.nodeid = n.id WHERE u.email = 'a@ffs-e2e.invalid';"; }
active_nodes() { sql "SELECT node FROM nodes WHERE service=${SVC} AND downed=0 AND available>0 ORDER BY node;" | tr '\n' ' '; }
redeploy "${NEW_DOMAIN}"
check "$(active_nodes)" "${NEW_DOMAIN} " "only the new domain is in rotation"
check "$(node_of_user)" "${NEW_DOMAIN}" "users moved to the new domain"
redeploy "${OLD_DOMAIN}"
check "$(active_nodes)" "${OLD_DOMAIN} " "switching back re-enables the old node"
check "$(node_of_user)" "${OLD_DOMAIN}" "users moved back"
check "$(hb)" 200 "/__heartbeat__ after redeploy"

echo "== placeholders and empty values: the init container refuses them, the Sync server stays down"
set_env SYNC_PUBLIC_URL "https://<REPLACE_WITH_YOUR_DOMAIN>"
dc up -d > /dev/null 2>&1
check "$(state syncstorage_migrate ExitCode) $(state syncstorage Running || echo false) $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")" "1 false 000" \
  "the public URL still the placeholder of .env-example: the migrations stop first, nothing answers"
check "$(dc logs syncstorage_migrate 2>&1 | grep -c 'ERROR: the public Sync URL (SYNC_PUBLIC_URL) is empty or still the placeholder of .env-example')" 1 "the migrations say why"
# the init container refuses it too (the Quadlets, a stack without these migrations): a run of its own
out=$(dc run --rm --no-deps -T -e DOMAIN="https://<REPLACE_WITH_YOUR_DOMAIN>" tokenserver_db_init 2>&1); rc=$?
check "${rc} $(grep -c 'ERROR: the public Sync URL (SYNC_PUBLIC_URL) is still the placeholder of .env-example' <<< "${out}")" "1 1" "the init container refuses the placeholder"
[ "${rc}" = 1 ] || tail -5 <<< "${out}"
# an empty password of the Sync database: the migrations cannot connect either, the init
# container alone says it (a run of its own, the stack as it is)
if [ "${BACKEND}" = mysql ]; then empty=(-e MARIADB_PASSWORD=) what="the tokenserver database password (SYNC_TOKENSERVER_DB_PASSWORD)"
else empty=(-e POSTGRES_PASSWORD=) what="the PostgreSQL password (SYNC_POSTGRES_PASSWORD)"; fi
out=$(dc run --rm --no-deps -T -e DOMAIN="${OLD_DOMAIN}" "${empty[@]}" tokenserver_db_init 2>&1); rc=$?
check "${rc} $(grep -c "ERROR: ${what} is empty: set it in .env" <<< "${out}")" "1 1" "an empty Sync database password: the init container refuses it"
grep -q "ERROR: ${what} is empty" <<< "${out}" || tail -5 <<< "${out}"
redeploy "${OLD_DOMAIN}"
check "$(state tokenserver_db_init ExitCode) $(hb)" "0 200" "the public URL set again: the init container and the Sync server run"
new_server
check "$?" 0 "no account and no Sync data before the client flow"

echo "== client flow through the tokenserver (mock FxA), SYNC_MAX_USERS=1"
pytest_in_app /tests/test_client_flow.py
check "$?" 0 "client flow tests"

echo "== admin UI drops what is older than ADMIN_RETENTION_DAYS, the audit trail after ADMIN_AUDIT_RETENTION_DAYS"
admin_sql "INSERT INTO ffs_events (at, kind, detail) VALUES (1, 'test', 'old');" > /dev/null
admin_sql "INSERT INTO ffs_metrics VALUES (60000, 'old.metric', 1, 0);" > /dev/null
days_ago() { echo $(( ($(date +%s) - $1 * 86400) * 1000 )); }
admin_sql "INSERT INTO ffs_events (at, kind, detail) VALUES ($(days_ago 60), 'admin', 'audit kept'), ($(days_ago 400), 'admin', 'audit old'), ($(days_ago 60), 'health', 'health old');" > /dev/null
# pruned on the first flush after the start (METRICS_FLUSH_SECONDS=5)
dc restart ffs-admin > /dev/null 2>&1
for _ in $(seq 1 30); do
  [ "$(admin_sql "SELECT (SELECT COUNT(*) FROM ffs_events WHERE kind = 'test') + (SELECT COUNT(*) FROM ffs_metrics WHERE name = 'old.metric');")" = 0 ] && break
  sleep 1
done
check "$(admin_sql "SELECT COUNT(*) FROM ffs_events WHERE kind = 'test';")" 0 "old events pruned"
check "$(admin_sql "SELECT COUNT(*) FROM ffs_metrics WHERE name = 'old.metric';")" 0 "old metrics pruned"
check "$(admin_sql "SELECT detail FROM ffs_events WHERE detail IN ('audit kept', 'audit old', 'health old');")" "audit kept" "admin events of 60 days kept (365), others pruned (30)"
admin_sql "DELETE FROM ffs_events WHERE detail = 'audit kept';" > /dev/null
# the Sync server restarts with the admin UI (restart: true), for the metrics
check "$(hb)" 200 "/__heartbeat__ after the admin UI restart"

echo "== backups"
backups_of() { admin_sql "SELECT COUNT(*) FROM ffs_backups WHERE scope = 'sync' AND $1;"; }
# the admin UI sees a change within HEALTH_CHECK_SECONDS (5): its event, alerted
# (more than $2 of them: a new one)
backup_events() { admin_sql "SELECT COUNT(*) FROM ffs_events WHERE kind = 'backup' AND detail LIKE '$1';"; }
backup_event() {
  for _ in $(seq 1 30); do
    [ "$(backup_events "$1")" -gt "${2:-0}" ] && { echo yes; return; }
    sleep 1
  done
}
if [ -z "${EXTDB}" ]; then
  backup_run() { dc exec -T "$@" backup sh /ffs-backup/backup.sh now >> "${WORK}/backup.log" 2>&1; }
  # the run of the loop at the start met the upgrade, which moves the admin UI's tables out
  # of the tokenserver database: a dump then fails with error 1412, done again once
  check "$(backups_of "ok = 0")" 0 "no backup failed so far (the loop's run at the start, during the upgrade)"
  good=$(backups_of "ok = 1 AND bytes > 0 AND location LIKE '/backups/sync/%'")
  backup_run
  check "$?" 0 "a backup run (COMPOSE_PROFILES=backup)"
  # a second one, a second later: BACKUP_KEEP=1 keeps only it. What a killed run left goes
  dc exec -T backup sh -c 'mkdir -p /backups/sync/.20200101T000000Z.partial'
  sleep 1.1
  backup_run
  check "$?" 0 "another backup run"
  check "$(dc exec -T backup sh -c 'ls -a /backups/sync | grep -c partial')" 0 "the leftover of a killed run removed"
  check "$(backups_of "ok = 1 AND bytes > 0 AND location LIKE '/backups/sync/%'")" $((good + 2)) "each run recorded in ffs_backups, with its size and place"
  check "$(dc exec -T backup sh -c 'ls /backups/sync | wc -l')" 1 "BACKUP_KEEP=1: older copies removed"
  # with the admin UI's own database (the event log), dumped as its user
  [ "${BACKEND}" = mysql ] && expected="${ADMIN_DB_NAME}.sql.gz ${SYNC_STORAGE_DB_NAME}.sql.gz ${SYNC_TOKENSERVER_DB_NAME}.sql.gz" || expected="${ADMIN_DB_NAME}.sql.gz ${SYNC_POSTGRES_NAME}.sql.gz"
  check "$(dc exec -T backup sh -c 'for f in /backups/sync/*/*.sql.gz; do gzip -t "$f" && basename "$f"; done' | LC_ALL=C sort | paste -sd' ')" "${expected}" "the dumps pass gzip -t"
  check "$(dc exec -T backup sh -c 'stat -c %a /backups/sync/*/*.sql.gz' | sort -u)" 600 "the dumps are for root only (0600)"
  check "$(dc exec -T backup sh -c 'gunzip -c /backups/sync/*/*.sql.gz' | grep -cE 'CREATE TABLE [`"]?(public\.)?users[`"]? ')" 1 "the dump has the tokenserver's users table"
  check "$(dc exec -T backup sh -c "gunzip -c /backups/sync/*/${ADMIN_DB_NAME}.sql.gz" | grep -c 'ffs-e2e: before the upgrade by admin')" 1 "the dump of the admin UI's database has the audit trail"
  # a run that fails (nowhere to write): recorded, alerted, nothing left. "Works again" is a
  # change the admin UI sees in a round (every 5 s): first it must have seen the good runs
  # (a run that failed before, e.g. that of the loop at the start during the upgrade, is
  # over: its last backup event is not a failure), then the failure, a new event, before
  # the next run. An event of before does not do: the failure and the run after it can fit
  # in one round, with no event at all. (Not by Prometheus: it would read the Sync totals
  # now, cached for a minute, which tests/test_admin_sync.py checks later)
  backup_ok() {
    for _ in $(seq 1 30); do
      case "$(admin_sql "SELECT detail FROM ffs_events WHERE kind = 'backup' ORDER BY id DESC LIMIT 1;")" in
        ''|'The backup of the Sync databases works again'*) echo yes; return ;;
      esac
      sleep 1
    done
  }
  check "$(backup_ok)" yes "the admin UI sees the last backup worked"
  FAILS=$(backup_events 'The backup of the Sync databases failed on %') AGAINS=$(backup_events 'The backup of the Sync databases works again%')
  backup_run -e BACKUP_DIR=/proc/ffs-none
  check "$?" 1 "a failed backup run exits with an error"
  check "$(backups_of "ok = 0 AND error LIKE 'cannot write to /proc/ffs-none%'")" 1 "the failed run in ffs_backups"
  check "$(backup_event 'The backup of the Sync databases failed on %' "${FAILS}")" yes "admin UI: event and alert for the failed backup"
  backup_run
  check "$?" 0 "a backup run after the failed one"
  AGAIN=$(backup_event 'The backup of the Sync databases works again%' "${AGAINS}")
  check "${AGAIN}" yes "admin UI: event when the backups work again"
  # what the runs recorded and the admin UI wrote, for a run where the event did not come
  if [ "${AGAIN}" != yes ]; then
    admin_sql "SELECT id, started, finished, ok, error FROM ffs_backups ORDER BY id DESC LIMIT 3;"
    admin_sql "SELECT id, at, detail FROM ffs_events WHERE kind = 'backup' ORDER BY id DESC LIMIT 3;"
    tail -5 "${WORK}/backup.log"
    dc logs --tail 20 ffs-admin backup
  fi

  echo "== one backup run at a time (the lock in the backups volume)"
  # a run holding the lock, as backup.sh writes it: host, pid and its start time, when
  hold_lock() { dc exec -T -d backup sh -c "mkdir /backups/.lock-sync && echo \"\$(cat /proc/sys/kernel/hostname) \$\$ \$(cut -d' ' -f22 /proc/\$\$/stat) \$(date +%s)\" > /backups/.lock-sync/owner && exec sleep $1"; }
  lock_owner() { dc exec -T backup sh -c 'cat /backups/.lock-sync/owner 2> /dev/null'; }
  wait_lock() { for _ in $(seq 1 20); do [ -n "$(lock_owner)" ] && return; sleep 0.5; done; }
  run_log() { dc exec -T "$@" backup sh /ffs-backup/backup.sh now 2>&1; }
  hold_lock 60; wait_lock
  OUT=$(run_log -e BACKUP_LOCK_WAIT=2)
  check "$? $(grep -c 'FAILED: another backup run of the sync databases was still going on after 2 s' <<< "${OUT}")" "1 1" \
    "a run while another one holds the lock waits BACKUP_LOCK_WAIT, then fails"
  check "$(backups_of "ok = 0 AND error = 'another backup run of the sync databases was still going on after 2 s (BACKUP_LOCK_WAIT)'")" 1 "and is recorded"
  # the run holding it killed (SIGKILL: no EXIT trap), its lock left: taken over
  # shellcheck disable=SC2016 # (in the container)
  dc exec -T backup sh -c 'kill -9 $(cut -d" " -f2 /backups/.lock-sync/owner)'
  OUT=$(run_log)
  check "$? $(grep -c 'took over the lock of a run that is gone' <<< "${OUT}") $(lock_owner | wc -c)" "0 1 0" \
    "the lock of a killed run is taken over, the run works and leaves no lock"
  # runs are named by the second: one of the same second as a folder there takes the next
  NOW=$(date -u +%s) TAKEN=""
  for i in 0 1 2; do TAKEN="${TAKEN} $(date -u -d "@$((NOW + i))" +%Y%m%dT%H%M%SZ)"; done
  dc exec -T backup sh -c "cd /backups/sync && mkdir -p ${TAKEN}"
  OUT=$(run_log -e BACKUP_KEEP=10)
  WHERE=$(sed -n 's|.*ok: /backups/sync/\([0-9TZ]*\),.*|\1|p' <<< "${OUT}")
  check "$? $([ -n "${WHERE}" ] && ! grep -qw "${WHERE}" <<< "${TAKEN}" && echo another)" "0 another" "a run in the second of an existing folder writes into its own (${WHERE})"
  # (not the run before, when it was in the same second)
  dc exec -T backup sh -c "cd /backups/sync && rmdir ${TAKEN} 2> /dev/null"
  # two at once, while a third holds the lock: they wait, then run one after the other,
  # both recorded, each dump whole
  BEFORE_OK=$(backups_of "ok = 1")
  hold_lock 3; wait_lock
  run_log -e BACKUP_KEEP=3 -e BACKUP_LOCK_WAIT=60 > "${WORK}/run-a.log" & A=$!
  run_log -e BACKUP_KEEP=3 -e BACKUP_LOCK_WAIT=60 > "${WORK}/run-b.log" & B=$!
  wait ${A}; RA=$?
  wait ${B}; RB=$?
  RUNS=$(sed -n 's|.*ok: /backups/sync/\([0-9TZ]*\),.*|\1|p' "${WORK}/run-a.log" "${WORK}/run-b.log" | sort -u)
  check "${RA} ${RB} $(wc -w <<< "${RUNS}") $(($(backups_of "ok = 1") - BEFORE_OK))" "0 0 2 2" "two runs at once: both work, in two folders, both recorded"
  [ "${BACKEND}" = mysql ] && expected="${ADMIN_DB_NAME}.sql.gz ${SYNC_STORAGE_DB_NAME}.sql.gz ${SYNC_TOKENSERVER_DB_NAME}.sql.gz" || expected="${ADMIN_DB_NAME}.sql.gz ${SYNC_POSTGRES_NAME}.sql.gz"
  for r in ${RUNS}; do
    check "$(dc exec -T backup sh -c "for f in /backups/sync/${r}/*.sql.gz; do gzip -t \"\$f\" && basename \"\$f\"; done" | LC_ALL=C sort | paste -sd' ')" "${expected}" "every dump of ${r} there and passing gzip -t"
  done
  check "$(lock_owner | wc -c) $(dc exec -T backup sh -c 'ls -a /backups/sync | grep -c partial')" "0 0" "no lock and no partial run left"
  if [ "${BACKEND}" = mysql ]; then
    echo "== a dump that meets a table changing (error 1412) is done again, once"
    dc exec -T backup sh -c 'mkdir -p /tmp/ffs-1412 && cat > /tmp/ffs-1412/fake && for n in mariadb-dump mysqldump; do [ ! -x /usr/bin/$n ] || install -m 755 /tmp/ffs-1412/fake /tmp/ffs-1412/$n; done' < "${TESTS}/fake_dump_1412.sh"
    fake_run() { # times it fails
      dc exec -T backup rm -f /tmp/ffs-1412/count
      dc exec -T -e PATH=/tmp/ffs-1412:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin -e BACKUP_RETRY_PAUSE=1 -e FAKE_1412="$1" \
        backup sh /ffs-backup/backup.sh now 2>&1
    }
    calls() { dc exec -T backup cat /tmp/ffs-1412/count; }
    OUT=$(fake_run 1)
    check "$? $(grep -c 'Table definition has changed.*once more in 1 s' <<< "${OUT}") $(calls)" "0 1 4" \
      "a dump failing once with error 1412 is done again and the run works (3 dumps, 4 calls)"
    check "$(admin_sql "SELECT ok FROM ffs_backups WHERE scope = 'sync' ORDER BY id DESC LIMIT 1;")" 1 "recorded as a good run"
    OUT=$(fake_run 2)
    check "$? $(calls)" "1 4" "failing again, the run fails (one retry only)"
    check "$(admin_sql "SELECT ok FROM ffs_backups WHERE scope = 'sync' AND error LIKE '%Error 1412: Table definition has changed%' ORDER BY id DESC LIMIT 1;")" 0 "recorded with the error"
  fi
  # BACKUP_KEEP=1 again: the restore below takes the one run left
  backup_run
  check "$? $(dc exec -T backup sh -c 'ls /backups/sync | wc -l')" "0 1" "a run with BACKUP_KEEP=1 keeps only itself"
  echo "== restoring the dumps as ADMIN.md#restoring says"
  dump() { dc exec -T backup sh -c "gunzip -c /backups/sync/*/$1.sql.gz"; }
  if [ "${BACKEND}" = postgres ]; then
    # no owner and no grant in the dump of the Sync database: they name roles a new server
    # has only after the init container (it gives them again at every start)
    check "$(dump "${SYNC_POSTGRES_NAME}" | grep -cE '^(GRANT|REVOKE|ALTER .* OWNER TO) ')" 0 "the dump of the Sync database names no role"
    # as the Sync server's role, the owner of what the dump holds (ADMIN.md#restoring), never
    # the superuser: into a database of its own
    check "$(dc exec -T backup printenv TOKENSERVER_DB_USER)" "${SYNC_ROLE}" "the backups dump the Sync database as the Sync server's role"
    sql "DROP DATABASE IF EXISTS ffs_restore_test;" > /dev/null 2>&1 && sql "CREATE DATABASE ffs_restore_test OWNER ${SYNC_ROLE} TEMPLATE template0;" > /dev/null
    dump "${SYNC_POSTGRES_NAME}" | dc exec -T -e PGPASSWORD="${SYNC_ROLE_SECRET}" postgres_db psql -q -h 127.0.0.1 -U "${SYNC_ROLE}" -d ffs_restore_test -v ON_ERROR_STOP=1 > /dev/null
    check "$?" 0 "the dump of the Sync database restores into an empty database (ON_ERROR_STOP)"
    check "$(sql "SELECT COUNT(*) FROM users;")" "$(sync_role_sql 'SELECT COUNT(*) FROM users;' ffs_restore_test)" "every row of users restored"
    sql "DROP DATABASE ffs_restore_test;" > /dev/null
  fi
  dc logs backup 2>&1 | grep -m1 'every day at'
else
  # your own backups: run a backup using the database client (no backup service with EXTERNAL_DB),
  # test that the dumps restore with only the documented grants
  echo "== backup and restore with EXTERNAL_DB (only documented grants)"
  if [ "${BACKEND}" = mysql ]; then
    BACKUP_IMAGE="${SYNC_MYSQL_IMAGE}"
    BACKUP_VOL="${PROJECT}_backups-extdb"
  else
    BACKUP_IMAGE="${SYNC_POSTGRES_IMAGE:-postgres:latest}"
    BACKUP_VOL="${PROJECT}_backups-extdb"
  fi
  docker volume create "${BACKUP_VOL}" > /dev/null
  # run backup.sh in the database client image with the external server's credentials
  backup_extdb() {
    local db_port db_user db_password db_name storage_host
    if [ "${BACKEND}" = postgres ]; then
      db_port=5432
      db_user="${SYNC_POSTGRES_USER}"
      db_password="${SYNC_POSTGRES_PASSWORD}"
      db_name="${SYNC_POSTGRES_NAME}"
      storage_host=""
    else
      db_port=3306
      db_user="${SYNC_TOKENSERVER_DB_USER}"
      db_password="${SYNC_TOKENSERVER_DB_PASSWORD}"
      db_name="${SYNC_TOKENSERVER_DB_NAME}"
      storage_host="${EXTDB}"
    fi
    docker run --rm --network "${EXTDB}" \
      -v "${BACKUP_VOL}:/backups" \
      -v "${CODE}/config/backup/backup.sh:/ffs-backup/backup.sh:ro" \
      -e BACKUP_SCOPE=sync \
      -e BACKUP_DIR=/backups \
      -e BACKUP_KEEP=1 \
      -e TOKENSERVER_DB_TYPE="${BACKEND}" \
      -e TOKENSERVER_DB_HOST="${EXTDB}" \
      -e TOKENSERVER_DB_PORT="${db_port}" \
      -e TOKENSERVER_DB_USER="${db_user}" \
      -e TOKENSERVER_DB_PASSWORD="${db_password}" \
      -e TOKENSERVER_DB_NAME="${db_name}" \
      -e STORAGE_DB_HOST="${storage_host}" \
      -e STORAGE_DB_USER="${SYNC_STORAGE_DB_USER:-}" \
      -e STORAGE_DB_PASSWORD="${SYNC_STORAGE_DB_PASSWORD:-}" \
      -e STORAGE_DB_NAME="${SYNC_STORAGE_DB_NAME:-}" \
      -e ADMIN_DB_PASSWORD="${ADMIN_DB_SECRET}" \
      -e ADMIN_DB_USER="${ADMIN_DB_USER}" \
      -e ADMIN_DB_NAME="${ADMIN_DB_NAME}" \
      "${BACKUP_IMAGE}" sh /ffs-backup/backup.sh now >> "${WORK}/backup-extdb.log" 2>&1
  }
  backup_extdb
  check "$?" 0 "a backup run with EXTERNAL_DB (as database client)"
  # check the dumps exist and pass gzip -t
  if [ "${BACKEND}" = mysql ]; then
    expected="${ADMIN_DB_NAME}.sql.gz ${SYNC_STORAGE_DB_NAME}.sql.gz ${SYNC_TOKENSERVER_DB_NAME}.sql.gz"
  else
    expected="${ADMIN_DB_NAME}.sql.gz ${SYNC_POSTGRES_NAME}.sql.gz"
  fi
  DUMPS=$(docker run --rm -v "${BACKUP_VOL}:/backups:ro" "${BACKUP_IMAGE}" sh -c 'for f in /backups/sync/*/*.sql.gz; do gzip -t "$f" 2>/dev/null && basename "$f"; done' | LC_ALL=C sort | paste -sd' ')
  check "${DUMPS}" "${expected}" "the dumps of EXTERNAL_DB pass gzip -t"
  # test restore into scratch databases with only the documented grants
  echo "== restore the dumps as ADMIN.md#restoring says (EXTERNAL_DB, documented grants only)"
  dump_extdb() { docker run --rm -v "${BACKUP_VOL}:/backups:ro" "${BACKUP_IMAGE}" sh -c "gunzip -c /backups/sync/*/$1.sql.gz"; }
  if [ "${BACKEND}" = postgres ]; then
    # PostgreSQL: test restoring as the Sync role (documented grants) into a scratch database
    extdb_admin -c "DROP DATABASE IF EXISTS ffs_restore_test" > /dev/null 2>&1
    extdb_admin -c "CREATE DATABASE ffs_restore_test OWNER ${SYNC_POSTGRES_USER} TEMPLATE template0" > /dev/null
    dump_extdb "${SYNC_POSTGRES_NAME}" | docker exec -i -e PGPASSWORD="${SYNC_POSTGRES_PASSWORD}" "${EXTDB}" psql -q -h 127.0.0.1 -U "${SYNC_POSTGRES_USER}" -d ffs_restore_test -v ON_ERROR_STOP=1 > /dev/null 2>&1
    check "$?" 0 "the dump of the Sync database restores with documented grants (PostgreSQL, ON_ERROR_STOP)"
    check "$(sql "SELECT COUNT(*) FROM users;")" "$(extdb_admin -d ffs_restore_test -c "SELECT COUNT(*) FROM users;")" "every row of users restored"
    extdb_admin -c "DROP DATABASE ffs_restore_test" > /dev/null
  else
    # MySQL: test restoring as tokenserver and syncstorage users into their databases (documented
    # grants, no LOCK TABLES needed). The dumps DROP and CREATE each table, so clear the database
    # first (a row added after the dump: it goes), then restore over it
    USERS_BEFORE=$(sql "SELECT COUNT(*) FROM users;")
    extdb_admin -D "${SYNC_TOKENSERVER_DB_NAME}" -e "DROP TABLE IF EXISTS users;" > /dev/null
    dump_extdb "${SYNC_TOKENSERVER_DB_NAME}" | docker exec -i -e MYSQL_PWD="${SYNC_TOKENSERVER_DB_PASSWORD}" "${EXTDB}" mysql -h 127.0.0.1 -u"${SYNC_TOKENSERVER_DB_USER}" "${SYNC_TOKENSERVER_DB_NAME}" > /dev/null 2>&1
    check "$?" 0 "the tokenserver dump restores with documented grants (no LOCK TABLES needed)"
    check "$(sql "SELECT COUNT(*) FROM users;")" "${USERS_BEFORE}" "every row of tokenserver users restored"
    if [ -n "${SYNC_STORAGE_DB_NAME:-}" ]; then
      # storage database exists: test it too (typically empty in these tests, check it restores)
      dump_extdb "${SYNC_STORAGE_DB_NAME}" | docker exec -i -e MYSQL_PWD="${SYNC_STORAGE_DB_PASSWORD}" "${EXTDB}" mysql -h 127.0.0.1 -u"${SYNC_STORAGE_DB_USER}" "${SYNC_STORAGE_DB_NAME}" > /dev/null 2>&1
      check "$?" 0 "the syncstorage dump restores with documented grants (no LOCK TABLES needed)"
    fi
  fi
  # admin DB restores as its user. PostgreSQL: --clean --if-exists, into a scratch database (the
  # admin user owns it). MySQL: DROP TABLE IF EXISTS (default), into the original database
  if [ "${BACKEND}" = postgres ]; then
    extdb_admin -c "DROP DATABASE IF EXISTS ffs_restore_test_admin" > /dev/null 2>&1
    extdb_admin -c "CREATE DATABASE ffs_restore_test_admin OWNER ${ADMIN_DB_USER}" > /dev/null
    dump_extdb "${ADMIN_DB_NAME}" | docker exec -i -e PGPASSWORD="${ADMIN_DB_SECRET}" "${EXTDB}" psql -q -h 127.0.0.1 -U "${ADMIN_DB_USER}" -d ffs_restore_test_admin -v ON_ERROR_STOP=1 > /dev/null 2>&1
    check "$?" 0 "the admin UI's database dump restores as its user (PostgreSQL)"
    extdb_admin -c "DROP DATABASE ffs_restore_test_admin" > /dev/null
  else
    # MySQL: the dump has DROP TABLE IF EXISTS, restore into the original database
    dump_extdb "${ADMIN_DB_NAME}" | docker exec -i -e MYSQL_PWD="${ADMIN_DB_SECRET}" "${EXTDB}" mysql -h 127.0.0.1 -u"${ADMIN_DB_USER}" "${ADMIN_DB_NAME}" > /dev/null 2>&1
    check "$?" 0 "the admin UI's database dump restores as its user (MySQL)"
  fi
  docker volume rm "${BACKUP_VOL}" > /dev/null 2>&1
  # the INSERT of your own backups record (tested before the fix: ADMIN.md#backups)
  admin_sql "INSERT INTO ffs_backups (scope, started, finished, ok, bytes, location) VALUES ('sync', $(date +%s)000, $(date +%s)000, 1, 123456, 'my own backup');"
  check "$?" 0 "the INSERT of your own backups (EXTERNAL_DB)"
  check "$(backups_of "ok = 1 AND location = 'my own backup'")" 1 "your own backup in ffs_backups"
fi

echo "== admin UI, Sync only (Mozilla's accounts)"
pytest_in_app /tests/test_admin_sync.py
check "$?" 0 "admin UI tests"

echo "== admin UI single sign-on: OpenID Connect (Dex) and a trusted proxy's header"
pytest_in_app /tests/test_admin_auth.py
check "$?" 0 "admin UI sign-in tests"
# from the host (the gateway, not a trusted proxy) the header is ignored
check "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'X-Test-Email: admin@ffs-e2e.invalid' \
  "http://127.0.0.1:$((PORT + 20))/")" "303 http://127.0.0.1:$((PORT + 20))/login" "admin UI ignores the header of an untrusted peer"

echo "== admin UI sees the Sync server go down and back up"
health_events() { admin_sql "SELECT COUNT(*) FROM ffs_events WHERE kind = 'health' AND detail LIKE '$1';"; }
# the start already has one of each (the admin UI starts first): more than before
DOWN=$(health_events 'Sync server is down%')
UP=$(health_events 'Sync server is back up')
dc stop syncstorage > /dev/null 2>&1
check "$(metrics_show 'ffs_up{component="Sync server"} 0')" yes "ffs_up 0 with the Sync server stopped"
dc start syncstorage > /dev/null 2>&1
check "$(hb)" 200 "/__heartbeat__ after the restart"
check "$(metrics_show 'ffs_up{component="Sync server"} 1')" yes "ffs_up 1 with the Sync server back"
check "$([ "$(health_events 'Sync server is down%')" -gt "${DOWN}" ] && [ "$(health_events 'Sync server is back up')" -gt "${UP}" ] && echo yes)" yes \
  "'is down' and 'is back up' in the event log"

echo "== upstream storage integration tests"
pytest_in_app tools/integration_tests/test_storage.py
check "$?" 0 "upstream storage tests"

echo "== errors in syncstorage logs"
check "$(dc logs syncstorage 2>&1 | grep -ciE 'panicked|"status":5[0-9][0-9]')" 0 "no panics or 5xx in syncstorage logs"

echo "== upstream tokenserver integration tests (SYNC_MAX_USERS raised, they create many users)"
set_env SYNC_MAX_USERS 1000000
dc up -d > /dev/null 2>&1
check "$(wait_init)" 0 "init container exit code (SYNC_MAX_USERS=1000000)"
hb > /dev/null
# test_e2e.py needs real accounts on Mozilla's FxA stage environment
UPSTREAM_TS="tools/integration_tests/tokenserver --ignore=tools/integration_tests/tokenserver/test_e2e.py"
# the upstream pull requests built into the image under test (upstream-patches.yml), none
# for images from before it
UPSTREAM_PATCHES=$(docker inspect -f '{{index .Config.Labels "org.firefox-sync.upstream-patches"}}' "$(dc ps -q syncstorage)" 2> /dev/null)
echo "upstream patches of the image: ${UPSTREAM_PATCHES:-none (no label)}"
if [ "${BACKEND}" = mysql ] && [ "${DATABASE_SERVER}" != MySQL ] && [[ " ${UPSTREAM_PATCHES} " != *" mozilla-services/syncstorage-rs#2638@"* ]]; then
  # with several empty nodes the tokenserver orders them by LOG(0) (NULL), MySQL 8
  # (upstream CI, EXTERNAL_DB=1 and SYNC_DB=mysql here, where it runs) returns them in id
  # order, MariaDB does not: this stack has one node. Fixed by mozilla-services/syncstorage-rs#2638,
  # in our images since upstream-patches.yml: deselected only for the images without it
  # (node ids are relative to tools/integration_tests, pytest's rootdir in the image)
  T=test_node_assignment.py::test_user_creation
  UPSTREAM_TS="${UPSTREAM_TS} --deselect tokenserver/${T} --deselect tools/integration_tests/tokenserver/${T}"
fi
# test_misc.py::test_user_updates_with_new_client_state creates its old row at the current
# millisecond, and the tokenserver replaces only the rows created strictly before the new
# one (created_at < its timestamp): when both fall in the same millisecond (about 1 in 100
# here, the request takes about 1 ms) nothing is replaced and the test fails. Upstream's
# race, not this stack's, fixed by mozilla-services/syncstorage-rs#2671 (upstream-patches.yml):
# for the images without it, run on its own, once more when it fails
RACY=test_misc.py::test_user_updates_with_new_client_state
if [[ " ${UPSTREAM_PATCHES} " != *" mozilla-services/syncstorage-rs#2671@"* ]]; then
  UPSTREAM_TS="${UPSTREAM_TS} --deselect tokenserver/${RACY} --deselect tools/integration_tests/tokenserver/${RACY}"
fi
pytest_in_app "${UPSTREAM_TS}"
check "$?" 0 "upstream tokenserver tests"
if [[ " ${UPSTREAM_PATCHES} " != *" mozilla-services/syncstorage-rs#2671@"* ]]; then
  pytest_in_app "tools/integration_tests/tokenserver/${RACY}" > /dev/null ||
    { echo "  ${RACY} failed, once more"; pytest_in_app "tools/integration_tests/tokenserver/${RACY}"; }
  check "$?" 0 "upstream ${RACY} (once more when it fails: the same millisecond)"
fi

echo "== admin UI"
check "$(admin_healthy)" healthy "admin UI container healthcheck"
check "$(admin_errors | wc -l)" 0 "no background errors in the admin UI logs"
admin_errors | tail -5
# ADMIN_NOTIFY of the test stack: said at the start as scheme://host, its tokens never logged
admin_logs=$(dc logs ffs-admin 2>&1)
check "$(grep -qF 'alerts also to webhook+http://notify-sink:8000, slack+http://notify-sink:8000 (ADMIN_NOTIFY)' <<< "${admin_logs}" && echo named) $(grep -c 'ffs-test-hook-secret\|ffs-test-hook-token\|ffs-test-slack-secret' <<< "${admin_logs}")" \
  "named 0" "the admin UI names the destinations of the alerts, never their tokens"

echo "== the Sync server without the admin UI (ADMIN_UI=n: no ffs-admin to resolve)"
dc stop ffs-admin > /dev/null 2>&1 && dc rm -f ffs-admin > /dev/null 2>&1
if [ -z "${EXTDB}" ]; then
  # the admin UI's database restored from the last backup, as its user, over the tables it
  # has (the admin UI stopped, ADMIN.md#restoring): what was written after the dump goes
  admin_sql "INSERT INTO ffs_events (at, kind, detail) VALUES ($(date +%s)000, 'admin', 'ffs-e2e: after the backup');" > /dev/null
  if [ "${BACKEND}" = postgres ]; then
    dump "${ADMIN_DB_NAME}" | dc exec -T -e PGPASSWORD="${ADMIN_DB_SECRET}" postgres_db psql -q -h 127.0.0.1 -U "${ADMIN_DB_USER}" -d "${ADMIN_DB_NAME}" -v ON_ERROR_STOP=1 > /dev/null 2>&1
  else
    dump "${ADMIN_DB_NAME}" | dc exec -T -e MYSQL_PWD="${ADMIN_DB_SECRET}" tokenserver_db "${DB_CLIENT}" -u"${ADMIN_DB_USER}" "${ADMIN_DB_NAME}"
  fi
  check "$?" 0 "the dump of the admin UI's database restores as its user"
  check "$(admin_sql "SELECT COUNT(*) FROM ffs_events WHERE detail = 'ffs-e2e: before the upgrade by admin (password)';") $(admin_sql "SELECT COUNT(*) FROM ffs_events WHERE detail = 'ffs-e2e: after the backup';")" \
    "1 0" "the restored event log is that of the dump"
fi
dc up -d --no-deps --force-recreate syncstorage > /dev/null 2>&1
check "$(hb)" 200 "/__heartbeat__ without the admin UI"
check "$(dc logs syncstorage 2>&1 | grep -c 'Sending metrics to the admin UI')" 0 "no metrics host without the admin UI"
# (the upstream tests ran since the last new_server)
new_server
check "$?" 0 "no account and no Sync data before the first sign-in without the admin UI"
pytest_in_app "/tests/test_client_flow.py -k first_sign_in"
check "$?" 0 "a first sign-in and sync without the admin UI"

if [ -z "${EXTDB}" ]; then
  echo "== a backup restores, the way ADMIN.md#restoring says, on a new host (empty volumes)"
  # the storage database (MariaDB, MySQL): PostgreSQL has one database, sql's
  sql_storage() { dc exec -T -e MYSQL_PWD="${SYNC_STORAGE_DB_PASSWORD}" syncstorage_db "${DB_CLIENT}" -u"${SYNC_STORAGE_DB_USER}" "${SYNC_STORAGE_DB_NAME}" -sN -e "$1" < /dev/null; }
  # every table of a database with its rows, its triggers and procedures: <sql function>
  inventory() {
    local q t
    if [ "${BACKEND}" = mysql ]; then
      q="SELECT 'triggers', COUNT(*) FROM information_schema.triggers WHERE trigger_schema = DATABASE()
         UNION ALL SELECT 'routines', COUNT(*) FROM information_schema.routines WHERE routine_schema = DATABASE()"
      for t in $("$1" "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE';"); do
        q="${q} UNION ALL SELECT '${t}', COUNT(*) FROM \`${t}\`"
      done
    else
      q="SELECT 'triggers', COUNT(*) FROM information_schema.triggers WHERE trigger_schema = 'public'
         UNION ALL SELECT 'routines', COUNT(*) FROM information_schema.routines WHERE routine_schema = 'public'"
      for t in $("$1" "SELECT tablename FROM pg_tables WHERE schemaname = 'public';"); do
        q="${q} UNION ALL SELECT '${t}', COUNT(*) FROM \"${t}\""
      done
    fi
    "$1" "${q} ORDER BY 1;" | tr '\t|' '  '
  }
  databases() {
    inventory sql | sed 's/^/tokenserver /'
    [ "${BACKEND}" = mysql ] && inventory sql_storage | sed 's/^/storage /'
  }
  # Sync data of two accounts (tests/migrate_client.py: their uids and collections to
  # /state), then nothing writes: the databases hold what the dump holds. Without the
  # tokenserver rows of before (alice signed in with other keys), their storage stays
  sql "DELETE FROM users;" > /dev/null
  in_app "python3 /tests/migrate_client.py write"
  check "$?" 0 "Sync data of two accounts before the backup"
  dc stop ffs-admin syncstorage > /dev/null 2>&1
  BEFORE=$(databases) EVENTS=$(admin_sql "SELECT COUNT(*) FROM ffs_events;")
  echo "${BEFORE}" | paste -sd' ' | fold -s -w 110 | sed 's/^/  /'
  check "$(echo "${BEFORE}" | grep -cE '^tokenserver users [1-9]|^(tokenserver|storage) bsos? [1-9]')" 2 "tokenserver users and Sync items to back up"
  dc exec -T backup sh /ffs-backup/backup.sh now >> "${WORK}/backup.log" 2>&1
  check "$?" 0 "the backup of the Sync data"
  # copied off the host, as ADMIN.md#copy-them-off-the-host says, put back on the new one
  docker run --rm -v "${PROJECT}_backups:/backups:ro" -v "${WORK}:/out" busybox tar -C /backups -czf /out/ffs-backups.tar.gz . > /dev/null 2>&1
  check "$?" 0 "the backups volume copied off the host"

  # the commands of ADMIN.md#restoring, as it writes them (firefox-sync_ the project,
  # 20261013T030000Z the run): each is checked to be there word for word, then run
  ADMIN_MD=$(sed 's/^ *//' "${CODE}/ADMIN.md")
  # shellcheck disable=SC2001
  documented() { [[ "${ADMIN_MD}" == *"$(sed 's/^ *//' <<< "$1")"* ]] && echo yes || echo "not in ADMIN.md: $1"; }
  as_here() { sed -e "s/firefox-sync_/${PROJECT}_/g" -e "s/20261013T030000Z/${2:-${RUN:-}}/g" -e 's/^docker compose /dc /' <<< "$1"; }
  # 1. the stack down, the databases' volumes gone (a new host), the copy of the backups
  # volume put back, the databases alone
  if [ "${BACKEND}" = postgres ]; then
    DBS=(postgres_db) VOLUMES=(postgres-db)
  elif [ "${SYNC_DB}" = mysql ]; then
    DBS=(tokenserver_db syncstorage_db) VOLUMES=(tokenserver-db-mysql syncstorage-db-mysql)
  else
    DBS=(tokenserver_db syncstorage_db) VOLUMES=(tokenserver-db syncstorage-db)
  fi
  RM="docker volume rm ${VOLUMES[*]/#/firefox-sync_}"
  # shellcheck disable=SC2016 # (expanded where they run: by eval here, in the container)
  PUT_BACK='docker run --rm -v firefox-sync_backups:/backups -v "$PWD":/in busybox tar -C /backups -xzf /in/ffs-backups.tar.gz'
  UP="docker compose up -d --wait ${DBS[*]}"
  LS='docker compose run --rm --no-deps --entrypoint ls backup /backups/sync'
  for c in "${RM}" "${PUT_BACK}" "${UP}" "${LS}"; do check "$(documented "\`${c}\`")" yes "ADMIN.md#restoring says \`${c}\`"; done
  dc down > /dev/null 2>&1
  eval "$(as_here "${RM}")" > /dev/null && docker volume rm "${PROJECT}_backups" > /dev/null
  check "$?" 0 "the volumes of the databases removed (${RM}), and the backups' (a new host)"
  (cd "${WORK}" && eval "$(as_here "${PUT_BACK}")") > /dev/null 2>&1
  check "$?" 0 "the copy put back into a new backups volume"
  eval "$(as_here "${UP}")" > /dev/null 2>&1
  check "$?" 0 "the databases alone, empty (${UP})"
  check "$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'users' AND table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys', 'pg_catalog');")" 0 "no tokenserver tables before the restore"
  # 2. the run
  RUN=$(eval "$(as_here "${LS}")" < /dev/null 2> /dev/null | tail -1)
  check "$(echo "${RUN}" | grep -cE '^[0-9]{8}T[0-9]{6}Z$')" 1 "a run to restore in the backups volume: ${RUN}"
  # 4. the tokenserver (with PostgreSQL the one database), 6. the storage: "as in step 4 with
  # $STORAGE_DB_NAME..."; with SYNC_DB=mysql "mysql instead of mariadb"
  # shellcheck disable=SC2016
  if [ "${BACKEND}" = postgres ]; then
    LOAD='PGPASSWORD="$TOKENSERVER_DB_PASSWORD" psql -h "$TOKENSERVER_DB_HOST" -U "$TOKENSERVER_DB_USER" -d "$TOKENSERVER_DB_NAME" -v ON_ERROR_STOP=1'
  else
    LOAD='mariadb -h "$TOKENSERVER_DB_HOST" -u"$TOKENSERVER_DB_USER" -p"$TOKENSERVER_DB_PASSWORD" "$TOKENSERVER_DB_NAME"'
  fi
  RESTORE="docker compose run --rm --no-deps --entrypoint sh backup -c '
    f=/backups/sync/20261013T030000Z/\$TOKENSERVER_DB_NAME.sql.gz
    gunzip -t \"\$f\" && gunzip -c \"\$f\" |
      ${LOAD}'"
  check "$(documented "${RESTORE}")" yes "ADMIN.md#restoring step 4 as run here"
  if [ "${BACKEND}" = postgres ]; then
    # the dump is loaded as the Sync server's role (TOKENSERVER_DB_USER of the backups): first
    # the role, in the empty database
    ROLE='docker compose run --rm sync_role_init'
    check "$(documented "${ROLE}")" yes "ADMIN.md#restoring says \`${ROLE}\`"
    eval "$(as_here "${ROLE}")" < /dev/null >> "${WORK}/restore.log" 2>&1
    check "$?" 0 "the Sync server's role in the empty database"
  fi
  restore() { # TOKENSERVER|STORAGE [run]
    local c
    c=$(as_here "${RESTORE}" "${2:-}" | sed -e "s/TOKENSERVER_DB_/$1_DB_/g" -e "s/^\( *\)mariadb /\1${DB_CLIENT} /")
    eval "${c}" < /dev/null >> "${WORK}/restore.log" 2>&1
  }
  # a run that is not there (pruned, mistyped) fails, nothing loaded
  restore TOKENSERVER 20000101T000000Z || echo failed > "${WORK}/missing-run"
  check "$(cat "${WORK}/missing-run" 2> /dev/null)" failed "a restore of a run that is not there fails"
  check "$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'users' AND table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys', 'pg_catalog');")" 0 "and loads nothing"
  restore TOKENSERVER
  check "$?" 0 "the tokenserver restored as its user"
  if [ "${BACKEND}" = mysql ]; then
    restore STORAGE
    check "$?" 0 "the storage restored as its user"
  fi
  [ "${FAILED}" = 0 ] || tail -20 "${WORK}/restore.log"
  # what the dump had, before the init container and the admin UI touch it
  AFTER=$(databases)
  check "${AFTER}" "${BEFORE}" "the same rows in every table, the same triggers and procedures"
  # 5. the admin UI's database, as its user: the database containers made it empty at their
  # start, with PostgreSQL the init container does, once the tokenserver is back
  # shellcheck disable=SC2016
  if [ "${BACKEND}" = postgres ]; then
    INIT='docker compose run --rm tokenserver_db_init'
    check "$(documented "${INIT}")" yes "ADMIN.md#restoring says \`${INIT}\`"
    eval "$(as_here "${INIT}")" < /dev/null >> "${WORK}/restore.log" 2>&1
    check "$?" 0 "the init container makes the admin UI's database again"
    LOAD='PGPASSWORD="$ADMIN_DB_PASSWORD" psql -h "$TOKENSERVER_DB_HOST" -U "$ADMIN_DB_USER" -d "$ADMIN_DB_NAME" -v ON_ERROR_STOP=1'
  else
    LOAD='mariadb -h "$TOKENSERVER_DB_HOST" -u"$ADMIN_DB_USER" -p"$ADMIN_DB_PASSWORD" "$ADMIN_DB_NAME"'
  fi
  RESTORE="docker compose run --rm --no-deps --entrypoint sh backup -c '
    f=/backups/sync/20261013T030000Z/\$ADMIN_DB_NAME.sql.gz
    gunzip -t \"\$f\" && gunzip -c \"\$f\" |
      ${LOAD}'"
  check "$(documented "${RESTORE}")" yes "ADMIN.md#restoring step 5 as run here"
  eval "$(as_here "${RESTORE}" | sed "s/^\( *\)mariadb /\1${DB_CLIENT} /")" < /dev/null >> "${WORK}/restore.log" 2>&1
  check "$?" 0 "the admin UI's database restored as its user"
  check "$(admin_sql "SELECT COUNT(*) FROM ffs_events;")" "${EVENTS}" "the event log of the dump"
  # 7. the whole stack
  dc up -d > /dev/null 2>&1
  check "$(wait_init)" 0 "init container exit code (restored)"
  check "$(state syncstorage_migrate ExitCode)" 0 "migrate container exit code (restored)"
  check "$(hb)" 200 "/__heartbeat__ after the restore"
  in_app "python3 /tests/migrate_client.py check"
  check "$?" 0 "the same accounts, uids and items after the restore"
  check "$(admin_healthy)" healthy "admin UI healthy after the restore"
fi

echo "== every container that keeps running healthy, the one-shot ones exited 0"
# (your own server: no restore above, the admin UI is still removed)
[ -z "${EXTDB}" ] || dc up -d > /dev/null 2>&1
check "$(compose_healthy 300 dc)" "all healthy" "every long-running container healthy (docker compose ps), the one-shot ones exited 0"

RESULT=${BACKEND}$([ "${SYNC_DB}" = mysql ] && echo " (MySQL, ${MYSQL_TESTED})")
[ ${FAILED} = 0 ] && echo "RESULT ${RESULT}: all checks passed" || echo "RESULT ${RESULT}: some checks FAILED"
exit ${FAILED}
