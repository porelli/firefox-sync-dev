#!/bin/bash
# End-to-end test of the firefox-sync stack (docker compose), isolated from anything
# else running on the host: own compose project, loopback-only port, own volumes.
#
# Usage: tests/e2e.sh <mysql|postgres>, SYNC_DB=mysql tests/e2e.sh mysql for MySQL 8.4
# Runs with the admin UI and the backups (COMPOSE_PROFILES=admin,backup, BACKUP_KEEP=1; with
# EXTERNAL_DB=1 the admin UI only, your own backups record their runs), with Mozilla's accounts
# (mock): Sync part only.
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
#   TEST_SUBNET     the stack's network, a /24 (default: 10.231.1.0/24 mysql, 10.231.2.0/24 postgres,
#                   10.231.4.0/24 SYNC_DB=mysql);
#                   its containers are in the upper half, the admin UI's trusted proxies, the
#                   gateway (the host) at .1 is not
#   SYNC_DB         mysql: the mysql backend on MySQL 8.4 containers (docker-compose.sync-mysql.yml)
#                   instead of MariaDB (default mariadb); own project, PORT 28654 and TEST_SUBNET 10.231.4.0/24
#   EXTERNAL_DB     set to 1 for a database server outside the stack (DB_CONTAINERS=0, DATABASES.md),
#                   created with only the grants of config/database/: MySQL 8.4 with binary logging
#                   for mysql, a PostgreSQL 18 owner that is no superuser for postgres; on its own
#                   network (EXTDB_SUBNET, default: 10.232.1.0/24 mysql, 10.232.2.0/24 postgres)
#   UPGRADE_FROM    a checkout of an earlier release (e.g. git worktree add /tmp/ffs-from <tag>):
#                   the install from before below runs its compose files, its admin UI and its
#                   init image (built from it), then upgrades to this tree. Default: this tree
#                   without ADMIN_DB_PASSWORD (and POSTGRES_SYNC_USER), the same layout
# The stack starts as an install from before ADMIN_DB_PASSWORD (the admin UI's tables in the
# tokenserver database, as the Sync server's user), then is upgraded: they move into the admin
# UI's own database, which the Sync server's users cannot read or change.
set -u

BACKEND=${1:?usage: $0 <mysql|postgres>}
TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
PROJECT=ffs-e2e-${BACKEND}
WORK=$(mktemp -d)
ENV_FILE=${WORK}/${BACKEND}.env

SYNC_DB=${SYNC_DB:-mariadb}
case ${BACKEND}:${SYNC_DB} in
  mysql:mariadb)    COMPOSE=${CODE}/docker-compose.yml;          PORT=${PORT:-28651}; NET=1 ;;
  postgres:mariadb) COMPOSE=${CODE}/docker-compose.postgres.yml; PORT=${PORT:-28652}; NET=2 ;;
  # (28653 is tests/e2e-fxa.sh's)
  mysql:mysql)      COMPOSE=${CODE}/docker-compose.yml;          PORT=${PORT:-28654}; NET=4; PROJECT=${PROJECT}-mysql84 ;;
  postgres:*) echo "SYNC_DB is for the mysql backend"; exit 2 ;;
  mysql:*) echo "SYNC_DB: mariadb or mysql"; exit 2 ;;
  *) echo "unknown backend ${BACKEND}"; exit 2 ;;
esac
if [ "${SYNC_DB}" = mysql ] && [ -n "${EXTERNAL_DB:-}" ]; then
  echo "SYNC_DB=mysql is for the database containers, EXTERNAL_DB=1 is already MySQL 8.4"; exit 2
fi
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
sed -e "s|^MARIADB_TOKENSERVER_PASSWORD=.*|MARIADB_TOKENSERVER_PASSWORD=$(rnd)|" \
    -e "s|^MARIADB_SYNCSTORAGE_PASSWORD=.*|MARIADB_SYNCSTORAGE_PASSWORD=$(rnd)|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(rnd)|" \
    -e "s|^SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=${MASTER_SECRET}|" \
    -e "s|^METRICS_HASH_SECRET=.*|METRICS_HASH_SECRET=${MASTER_SECRET}|" \
    -e "s|^SYNCSTORAGE_DOMAIN=.*|SYNCSTORAGE_DOMAIN=https://ffs-e2e.invalid|" \
    -e "s|^CONTAINER_EXPORT_PORT=.*|CONTAINER_EXPORT_PORT=127.0.0.1:${PORT}|" \
    -e "s|^MAX_USERS=.*|MAX_USERS=1|" \
    -e "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${PROFILES}|" \
    -e "s|^BACKUP_KEEP=.*|BACKUP_KEEP=1|" \
    -e "s|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=$(rnd)|" \
    -e "s|^ADMIN_EXPORT_PORT=.*|ADMIN_EXPORT_PORT=127.0.0.1:$((PORT + 20))|" \
    -e "s|^REPOSITORY=.*|REPOSITORY=${REPOSITORY}|" \
    -e "s|^SYNCSTORAGE_IMAGE=.*|SYNCSTORAGE_IMAGE=syncstorage-rs-${BACKEND}|" \
    -e "s|^SYNCSTORAGE_INIT_IMAGE=.*|SYNCSTORAGE_INIT_IMAGE=syncstorage-rs-${BACKEND}-init|" \
    -e "s|^SYNCSTORAGE_IMAGE_TAG=.*|SYNCSTORAGE_IMAGE_TAG=${TAG}|" \
    -e "s|^SYNCSTORAGE_INIT_IMAGE_TAG=.*|SYNCSTORAGE_INIT_IMAGE_TAG=${TAG}|" \
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
  sed -i -e "s|^POSTGRES_SYNC_USER=.*|POSTGRES_SYNC_USER=syncserver_app|" -e "s|^POSTGRES_SYNC_PASSWORD=.*|POSTGRES_SYNC_PASSWORD=$(rnd)|" "${ENV_FILE}"
fi
EXTDB=
COMPOSE_EXTRA=()
DATABASE_SERVER=
# what the admin UI reports, and the database client in the database containers
DB_CLIENT=mariadb
if [ "${SYNC_DB}" = mysql ]; then
  COMPOSE_EXTRA=(-f "${CODE}/docker-compose.sync-mysql.yml")
  DATABASE_SERVER=MySQL DB_CLIENT=mysql
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
  sed -i -e "s|^DB_CONTAINERS=.*|DB_CONTAINERS=0|" -e "s|^MARIADB_TLS_VERIFY=.*|MARIADB_TLS_VERIFY=false|" \
      -e "s|^MARIADB_TOKENSERVER_SERVER=.*|MARIADB_TOKENSERVER_SERVER=${EXTDB}|" \
      -e "s|^MARIADB_SYNCSTORAGE_SERVER=.*|MARIADB_SYNCSTORAGE_SERVER=${EXTDB}|" \
      -e "s|^POSTGRES_SERVER=.*|POSTGRES_SERVER=${EXTDB}|" "${ENV_FILE}"
fi
set -a; source "${ENV_FILE}"; set +a
# the admin UI's own database users, the Sync server's role in the PostgreSQL container
# (set_env empties them until the upgrade)
ADMIN_DB_SECRET=${ADMIN_DB_PASSWORD} SYNC_ROLE=${POSTGRES_SYNC_USER} SYNC_ROLE_SECRET=${POSTGRES_SYNC_PASSWORD}
if [ "${BACKEND}" = mysql ]; then
  ADMIN_DB_URL=mysql://${ADMIN_DB_USER}:${ADMIN_DB_SECRET}@${MARIADB_TOKENSERVER_SERVER}:${MARIADB_TOKENSERVER_SERVER_PORT}/${ADMIN_DB_NAME}
else
  ADMIN_DB_URL=postgres://${ADMIN_DB_USER}:${ADMIN_DB_SECRET}@${POSTGRES_SERVER}:${POSTGRES_SERVER_PORT}/${ADMIN_DB_NAME}
fi
# the admin UI under test: ADMIN_IMAGE as is (pulled when missing), or built from admin/
ADMIN_GIVEN=${ADMIN_IMAGE:-}
export ADMIN_IMAGE=${ADMIN_IMAGE:-ffs-admin:test}

# the compose files of ROOT: this tree, or UPGRADE_FROM for the install from before
ROOT=${CODE}
dc() {
  docker compose -p "${PROJECT}" -f "${ROOT}/$(basename "${COMPOSE}")" -f "${ROOT}/tests/docker-compose.test.yml" \
    "${COMPOSE_EXTRA[@]/#"${CODE}"/${ROOT}}" --env-file "${ENV_FILE}" "$@"
}
FAILED=0
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
set_env() { sed -i "s|^$1=.*|$1=$2|" "${ENV_FILE}"; export "$1=$2"; }

sql() {
  if [ -n "${EXTDB}" ] && [ "${BACKEND}" = mysql ]; then
    docker exec -i -e MYSQL_PWD="${MARIADB_TOKENSERVER_PASSWORD}" "${EXTDB}" mysql -u"${MARIADB_TOKENSERVER_USER}" "${MARIADB_TOKENSERVER_DATABASE}" -sN -e "$1" < /dev/null
  elif [ -n "${EXTDB}" ]; then
    docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" "${EXTDB}" psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d "${POSTGRES_DATABASE}" -tA -c "$1" < /dev/null
  elif [ "${BACKEND}" = mysql ]; then
    dc exec -T -e MYSQL_PWD="${MARIADB_TOKENSERVER_PASSWORD}" tokenserver_db "${DB_CLIENT}" -u"${MARIADB_TOKENSERVER_USER}" "${MARIADB_TOKENSERVER_DATABASE}" -sN -e "$1" < /dev/null
  else
    dc exec -T postgres_db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DATABASE}" -tA -c "$1" < /dev/null
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
SYNC_DB_NAME=$([ "${BACKEND}" = mysql ] && echo "${MARIADB_TOKENSERVER_DATABASE}" || echo "${POSTGRES_DATABASE}")
admin_sql() { db_as "${ADMIN_DB_USER}" "${ADMIN_DB_SECRET}" "${2:-${ADMIN_DB_NAME}}" "$1"; }
# the admin UI's reader of the Sync data (ADMIN_DB_SYNC_USER), on the Sync database and on
# the storage (MariaDB and MySQL)
admin_sync_sql() { db_as "${ADMIN_DB_SYNC_USER}" "${ADMIN_DB_SECRET}" "${2:-${SYNC_DB_NAME}}" "$1"; }
admin_storage_sql() { db_as "${ADMIN_DB_SYNC_USER}" "${ADMIN_DB_SECRET}" "${MARIADB_SYNCSTORAGE_DATABASE}" "$1" storage; }
# the Sync server's own role in the PostgreSQL container (POSTGRES_SYNC_USER), or POSTGRES_USER
sync_role_sql() { db_as "${SYNC_ROLE:-${POSTGRES_USER}}" "${SYNC_ROLE_SECRET:-${POSTGRES_PASSWORD}}" "${2:-${POSTGRES_DATABASE}}" "$1"; }
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
    -v "${TESTS}:/tests:ro" \
    -e SYNC_SERVER_URL=http://syncstorage:8000 \
    -e TOKENSERVER_HOST=http://syncstorage:8000 \
    -e SYNC_MASTER_SECRET="${MASTER_SECRET}" \
    -e SYNCSTORAGE_DOMAIN="${SYNCSTORAGE_DOMAIN}" \
    -e MAX_USERS="${MAX_USERS#*:}" \
    -e MAX_USERS_SETTING="${MAX_USERS}" \
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
      -e MYSQL_ROOT_PASSWORD="${EXTDB_ROOT}" mysql:8.4 --log-bin-trust-function-creators=ON > /dev/null || return 1
  else
    docker run -d --rm --name "${EXTDB}" --network "${EXTDB}" --tmpfs /var/lib/postgresql \
      -e POSTGRES_PASSWORD="${EXTDB_ROOT}" postgres:18 > /dev/null || return 1
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
    sed -e "s|@TOKENSERVER_DATABASE@|${MARIADB_TOKENSERVER_DATABASE}|g" -e "s|@TOKENSERVER_USER@|${MARIADB_TOKENSERVER_USER}|g" \
        -e "s|@TOKENSERVER_PASSWORD@|${MARIADB_TOKENSERVER_PASSWORD}|g" -e "s|@SYNCSTORAGE_DATABASE@|${MARIADB_SYNCSTORAGE_DATABASE}|g" \
        -e "s|@SYNCSTORAGE_USER@|${MARIADB_SYNCSTORAGE_USER}|g" -e "s|@SYNCSTORAGE_PASSWORD@|${MARIADB_SYNCSTORAGE_PASSWORD}|g" \
        -e "s|@ADMIN_DATABASE@|${ADMIN_DB_NAME}|g" -e "s|@ADMIN_USER@|${ADMIN_DB_USER}|g" -e "s|@ADMIN_SYNC_USER@|${ADMIN_DB_SYNC_USER}|g" -e "s|@ADMIN_PASSWORD@|${ADMIN_DB_SECRET}|g" \
        "${CODE}/config/database/sync-mariadb.sql"
  else
    sed -e "s|@POSTGRES_DATABASE@|${POSTGRES_DATABASE}|g" -e "s|@POSTGRES_USER@|${POSTGRES_USER}|g" \
        -e "s|@POSTGRES_PASSWORD@|${POSTGRES_PASSWORD}|g" -e "s|@ADMIN_DATABASE@|${ADMIN_DB_NAME}|g" \
        -e "s|@ADMIN_USER@|${ADMIN_DB_USER}|g" -e "s|@ADMIN_SYNC_USER@|${ADMIN_DB_SYNC_USER}|g" -e "s|@ADMIN_PASSWORD@|${ADMIN_DB_SECRET}|g" "${CODE}/config/database/sync-postgres.sql"
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
  if [ -n "${EXTDB}" ]; then
    docker rm -f "${EXTDB}" > /dev/null 2>&1
    docker network rm "${EXTDB}" > /dev/null 2>&1
  fi
  if [ -n "${CLEANUP_IMAGES:-}" ]; then
    docker rmi "${REPOSITORY}:syncstorage-rs-${BACKEND}-${TAG}" "${REPOSITORY}:syncstorage-rs-${BACKEND}-init-${TAG}" > /dev/null 2>&1
    [ -n "${ADMIN_GIVEN}" ] && docker rmi "${ADMIN_GIVEN}" > /dev/null 2>&1
    [ "${BACKEND}" = mysql ] && [ "${SYNC_DB}" = mariadb ] && ! docker ps -a --format '{{.Image}}' | grep -qx 'mariadb:lts' && docker rmi mariadb:lts > /dev/null 2>&1
    [ "${SYNC_DB}" = mysql ] && ! docker ps -a --format '{{.Image}}' | grep -qx 'mysql:8.4' && docker rmi mysql:8.4 > /dev/null 2>&1
  fi
  rm -rf "${WORK}"
}
trap teardown EXIT

if [ -z "${ADMIN_GIVEN}" ]; then
  COMPOSE_BAKE=false docker compose -p ffs-admin-build -f "${TESTS}/docker-compose.admin-build.yml" build -q || { echo "FAIL: admin UI image built from admin/"; exit 1; }
fi
echo "== ${PROJECT}: pulling ${REPOSITORY} ${TAG}"
[ -n "${SKIP_PULL:-}" ] || dc pull -q || exit 1

if [ -n "${EXTDB}" ]; then
  echo "== external database server ${EXTDB} ($([ "${BACKEND}" = mysql ] && echo mysql:8.4 || echo postgres:18))"
  start_extdb
  check "$?" 0 "external database server with the databases and users of config/database/"
fi

# a stack of an earlier KEEP=1 run of this project would make the fail-closed check pass
# on its old containers: start from nothing
dc down -v --remove-orphans > /dev/null 2>&1
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

echo "== starting, as an install from before ADMIN_DB_PASSWORD${UPGRADE_FROM:+ (${UPGRADE_FROM})}"
# its layout: the admin UI connects as the Sync server's users, its tables in the tokenserver
# database; with PostgreSQL the Sync server connects as POSTGRES_USER, the superuser
set_env ADMIN_DB_PASSWORD ""
set_env POSTGRES_SYNC_USER ""
set_env POSTGRES_SYNC_PASSWORD ""
if [ -n "${UPGRADE_FROM:-}" ]; then
  # that release itself: its compose files, its admin UI and its init container
  ROOT=$(cd -- "${UPGRADE_FROM}" && pwd) || exit 1
  ADMIN_NOW=${ADMIN_IMAGE} INIT_TAG=${SYNCSTORAGE_INIT_IMAGE_TAG}
  export ADMIN_IMAGE=ffs-admin:e2e-from
  ADMIN_IMAGE=${ADMIN_IMAGE} COMPOSE_BAKE=false docker compose -p ffs-admin-build-from -f "${ROOT}/tests/docker-compose.admin-build.yml" build -q ||
    { echo "FAIL: admin UI image built from ${UPGRADE_FROM}/admin"; exit 1; }
  docker build -q -t "${REPOSITORY}:syncstorage-rs-${BACKEND}-init-e2e-from" \
    "${ROOT}/syncstorage-rs-init$([ "${BACKEND}" = postgres ] && echo -postgres)" > /dev/null || { echo "FAIL: init image of ${UPGRADE_FROM}"; exit 1; }
  set_env SYNCSTORAGE_INIT_IMAGE_TAG e2e-from
fi
dc up -d > /dev/null 2>&1 || { dc logs; exit 1; }
check "$(wait_init)" 0 "init container exit code"
check "$(state syncstorage_migrate ExitCode)" 0 "migrate container exit code"
INIT_END=$(date -d "$(state tokenserver_db_init FinishedAt)" +%s%N)
APP_START=$(date -d "$(state syncstorage StartedAt)" +%s%N)
check "$([ "${APP_START}" -gt "${INIT_END}" ] && echo yes)" yes "syncstorage started only after the init finished"
check "$(hb)" 200 "/__heartbeat__"
dc logs syncstorage 2>&1 | grep -m1 "Server running"

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
  # this tree from here on
  ROOT=${CODE}
  export ADMIN_IMAGE=${ADMIN_NOW}
  set_env SYNCSTORAGE_INIT_IMAGE_TAG "${INIT_TAG}"
fi
set_env ADMIN_DB_PASSWORD "${ADMIN_DB_SECRET}"
set_env POSTGRES_SYNC_USER "${SYNC_ROLE}"
set_env POSTGRES_SYNC_PASSWORD "${SYNC_ROLE_SECRET}"
dc up -d > /dev/null 2>&1 || { dc logs; exit 1; }
check "$(wait_init)" 0 "init container exit code (ADMIN_DB_PASSWORD set)"
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
    check "$(denied "$(docker exec -i -e MYSQL_PWD="${MARIADB_SYNCSTORAGE_PASSWORD}" "${EXTDB}" mysql -u"${MARIADB_SYNCSTORAGE_USER}" -sN \
      -e "SELECT COUNT(*) FROM ${ADMIN_DB_NAME}.ffs_events;" < /dev/null 2>&1)")" denied "the storage user cannot read the event log"
  fi
  # the admin UI's two users: the reader of the Sync data writes the Sync tables only through
  # the init container's procedures and has nothing on the event log; the other one has the
  # event log only
  check "$(denied "$(admin_sync_sql "UPDATE nodes SET capacity = capacity;" 2>&1)")" denied "the admin UI's reader cannot change the tokenserver's tables"
  check "$(denied "$(admin_sync_sql "CREATE TABLE forged (id INT);" 2>&1)")" denied "the admin UI's reader cannot create tables in the tokenserver database"
  check "$(denied "$(admin_sync_sql "SELECT COUNT(*) FROM ${ADMIN_DB_NAME}.ffs_events;" 2>&1)")" denied "the admin UI's reader cannot read the event log"
  check "$(denied "$(admin_sql "SELECT COUNT(*) FROM ${MARIADB_TOKENSERVER_DATABASE}.users;" 2>&1)") $(denied "$(admin_sql "SELECT COUNT(*) FROM ${MARIADB_SYNCSTORAGE_DATABASE}.bso;" 2>&1)")" \
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
    "f ${SYNC_ROLE:-${POSTGRES_USER}}" "the Sync server's role is no superuser, and owns the Sync tables"
  check "$(denied "$(sync_role_sql "SELECT COUNT(*) FROM ffs_events;" "${ADMIN_DB_NAME}" 2>&1)")" denied "the Sync server's role cannot connect to the admin UI's database"
  check "$(admin_sql "SELECT pg_get_userbyid(datdba), has_database_privilege('public', datname, 'CONNECT'), has_database_privilege('${SYNC_ROLE:-${POSTGRES_USER}}', datname, 'CONNECT'), has_database_privilege('${ADMIN_DB_SYNC_USER}', datname, 'CONNECT') FROM pg_database WHERE datname = current_database();")" \
    "${ADMIN_DB_USER}|f|f|f" "the admin UI's database is its role's, closed to the others"
  check "$(admin_sql "SELECT rolsuper FROM pg_roles WHERE rolname = current_user;") $(admin_sync_sql "SELECT rolsuper FROM pg_roles WHERE rolname = current_user;")" "f f" "the admin UI's roles are no superusers"
  check "$(denied "$(admin_sync_sql "UPDATE nodes SET capacity = capacity;" 2>&1)")" denied "the admin UI's reader cannot change the tokenserver's nodes"
  check "$(denied "$(admin_sync_sql "CREATE TABLE forged (id INT);" 2>&1)")" denied "the admin UI's reader cannot create tables in the Sync database"
  check "$(denied "$(admin_sql "SELECT COUNT(*) FROM users;" "${POSTGRES_DATABASE}" 2>&1)")" denied "the admin UI's own role cannot read the Sync database"
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
    # (nodes: the node of SYNCSTORAGE_DOMAIN) write; config itself becomes a view over the
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
    if [ -n "${EXTDB}" ]; then extdb_admin -d "$1" -c "$2" < /dev/null; else dc exec -T postgres_db psql -U "${POSTGRES_USER}" -d "$1" -v ON_ERROR_STOP=1 -tA -c "$2" < /dev/null; fi
  }
  OTHER=${SYNC_ROLE:-${POSTGRES_USER}}
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
    grants=$(echo "SHOW GRANTS FOR '${MARIADB_TOKENSERVER_USER}'@'%'; SHOW GRANTS FOR '${MARIADB_SYNCSTORAGE_USER}'@'%';" | extdb_admin)
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
    check "$(echo "SELECT @@log_bin, (SELECT GROUP_CONCAT(DISTINCT plugin) FROM mysql.user WHERE user IN ('${MARIADB_TOKENSERVER_USER}', '${MARIADB_SYNCSTORAGE_USER}'));" | extdb_admin)" \
      "$(printf '1\tcaching_sha2_password')" "binary logging on, users with caching_sha2_password"
    check "$(sql "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_name = 'BeforeInsertUser';")" 1 "MAX_USERS trigger created by the init container"
  else
    check "$(echo "SELECT rolsuper, rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname = '${POSTGRES_USER}';" | extdb_admin)" "f|f|f" \
      "the database owner is no superuser"
    check "$(echo "SELECT has_database_privilege('dbadmin', '${POSTGRES_DATABASE}', 'TEMP'), has_database_privilege('public', '${POSTGRES_DATABASE}', 'CONNECT');" | extdb_admin)" "t|f" \
      "database created by a CREATEROLE CREATEDB role, closed to PUBLIC"
  fi
fi

if [ "${SYNC_DB}" = mysql ]; then
  echo "== database containers on MySQL 8.4 (SYNC_DB=mysql)"
  for db in syncstorage_db tokenserver_db; do
    check "$(docker inspect -f '{{.Config.Image}}' "$(dc ps -a -q "${db}")")" mysql:8.4 "${db} runs mysql:8.4"
    check "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}' "$(dc ps -a -q "${db}")")" \
      "${PROJECT}_${db//_/-}-mysql" "${db} in its own volume, not MariaDB's"
  done
  # no binary logging (docker-compose.sync-mysql.yml), the trigger without log_bin_trust_function_creators
  check "$(sql "SELECT VERSION() LIKE '8.4.%', @@log_bin, @@log_bin_trust_function_creators;")" "$(printf '1\t0\t0')" "MySQL 8.4 without binary logging"
  check "$(sql "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_name = 'BeforeInsertUser';")" 1 "MAX_USERS trigger created by the init container"
fi

echo "== tokenserver node"
SVC=$(sql "SELECT id FROM services WHERE service='sync-1.5';")
echo "sync-1.5 service id: ${SVC}"
check "$(sql "SELECT COUNT(*) FROM nodes WHERE service=${SVC} AND node='${SYNCSTORAGE_DOMAIN}' AND available>0 AND downed=0;")" 1 "node for ${SYNCSTORAGE_DOMAIN} attached to sync-1.5"
NODE=$(sql "SELECT id FROM nodes WHERE service=${SVC} AND node='${SYNCSTORAGE_DOMAIN}';")

echo "== MAX_USERS=1 trigger (database level)"
ins() { sql "INSERT INTO users (service, email, generation, client_state, created_at, nodeid) VALUES (${SVC}, '$1', $2, '$3', 1, ${NODE});" > /dev/null 2>&1 && echo ok || echo rejected; }
check "$(ins a@ffs-e2e.invalid 1 aa)" ok "first account allowed"
check "$(ins a@ffs-e2e.invalid 2 bb)" ok "same account with new client state allowed"
check "$(ins b@ffs-e2e.invalid 1 aa)" rejected "second account rejected"

echo "== MAX_USERS=1 (plain): set again on every start, read-only in the admin UI"
max_users() { sql "SELECT config_value FROM config WHERE config_key = 'max_users';"; }
rerun_init() { dc up -d --no-deps --force-recreate tokenserver_db_init > /dev/null 2>&1; wait_init; }
# the whole stack with a new MAX_USERS: the init container and the admin UI
# not in $(...): set_env must change this shell's MAX_USERS (compose prefers it to the
# env file), the exit code of the init container is in INIT_CODE
redeploy_max_users() { set_env MAX_USERS "$1"; dc up -d > /dev/null 2>&1; INIT_CODE=$(wait_init); }
sql "UPDATE config SET config_value = '3' WHERE config_key = 'max_users';" > /dev/null
check "$(rerun_init)" 0 "init container exit code (rerun)"
check "$(max_users)" 1 "MAX_USERS=1 set again over a value changed in the database"
check "$(sql "SELECT COUNT(*) FROM config WHERE config_key = 'max_users_env';")" 0 "no max_users_env bookkeeping"
pytest_in_app "/tests/test_admin_sync.py -k read_only"
check "$?" 0 "admin UI: max users read-only with MAX_USERS=1"
check "$(max_users)" 1 "max users unchanged by the refused form"

echo "== MAX_USERS=initial:N: set only when there is none, then managed in the admin UI"
redeploy_max_users initial:2
check "${INIT_CODE}" 0 "init container exit code (MAX_USERS=initial:2)"
check "$(max_users)" 1 "switching to initial:2 keeps the value in the database"
sql "UPDATE config SET config_value = '3' WHERE config_key = 'max_users';" > /dev/null
rerun_init > /dev/null
check "$(max_users)" 3 "initial:2 keeps a value changed in the database (admin UI)"
sql "DELETE FROM config WHERE config_key = 'max_users';" > /dev/null
rerun_init > /dev/null
check "$(max_users)" 2 "initial:2 sets it when there is none (new database)"
redeploy_max_users 1
check "${INIT_CODE}" 0 "init container exit code (back to MAX_USERS=1)"
check "$(max_users)" 1 "switching back to a plain MAX_USERS=1 takes over"

echo "== MAX_USERS not valid: the init container fails, nothing changes"
for bad in lots initial: fixed:-1 infinite initial:Unlimited 2147483648; do
  set_env MAX_USERS "${bad}"
  check "$(rerun_init)" 1 "init container fails with MAX_USERS=${bad}"
done
check "$(dc logs tokenserver_db_init 2>&1 | grep -c "MAX_USERS='2147483648' is not valid")" 1 "init container says why"
check "$(max_users)" 1 "max users unchanged by a MAX_USERS not valid"

echo "== MAX_USERS=unlimited: no limit, by the trigger itself; 0: no new account at all"
redeploy_max_users unlimited
check "${INIT_CODE}" 0 "init container exit code (MAX_USERS=unlimited)"
check "$(max_users)" unlimited "MAX_USERS=unlimited in the database"
check "$(ins c@ffs-e2e.invalid 1 aa) $(ins d@ffs-e2e.invalid 1 aa)" "ok ok" "new accounts allowed with no limit"
sql "DELETE FROM users WHERE email IN ('c@ffs-e2e.invalid', 'd@ffs-e2e.invalid');" > /dev/null
redeploy_max_users initial:5
check "$(max_users)" unlimited "MAX_USERS=initial:5 keeps unlimited in the database"
redeploy_max_users fixed:0
check "$(max_users) $(ins e@ffs-e2e.invalid 1 aa) $(ins a@ffs-e2e.invalid 3 cc)" "0 rejected ok" "MAX_USERS=0: no new account, the existing one still changes its keys"
redeploy_max_users 1
check "$(max_users)" 1 "back to MAX_USERS=1"

# the admin UI tests change max users on the page: initial:1 for the rest, until the
# upstream tokenserver tests (the Python tests get the number, see in_app)
redeploy_max_users initial:1
check "${INIT_CODE}" 0 "init container exit code (MAX_USERS=initial:1)"
check "$(max_users)" 1 "max users 1 for the following tests"
check "$(hb)" 200 "/__heartbeat__ after the MAX_USERS changes"

echo "== domain change"
OLD_DOMAIN=${SYNCSTORAGE_DOMAIN}
NEW_DOMAIN=https://ffs-e2e-new.invalid
redeploy() { set_env SYNCSTORAGE_DOMAIN "$1"; dc up -d > /dev/null 2>&1; wait_init > /dev/null; }
node_of_user() { sql "SELECT DISTINCT n.node FROM users u JOIN nodes n ON u.nodeid = n.id WHERE u.email = 'a@ffs-e2e.invalid';"; }
active_nodes() { sql "SELECT node FROM nodes WHERE service=${SVC} AND downed=0 AND available>0 ORDER BY node;" | tr '\n' ' '; }
redeploy "${NEW_DOMAIN}"
check "$(active_nodes)" "${NEW_DOMAIN} " "only the new domain is in rotation"
check "$(node_of_user)" "${NEW_DOMAIN}" "users moved to the new domain"
redeploy "${OLD_DOMAIN}"
check "$(active_nodes)" "${OLD_DOMAIN} " "switching back re-enables the old node"
check "$(node_of_user)" "${OLD_DOMAIN}" "users moved back"
check "$(hb)" 200 "/__heartbeat__ after redeploy"
sql "DELETE FROM users;" > /dev/null

echo "== client flow through the tokenserver (mock FxA), MAX_USERS=1"
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
backup_event() {
  for _ in $(seq 1 30); do
    [ "$(admin_sql "SELECT COUNT(*) FROM ffs_events WHERE kind = 'backup' AND detail LIKE '$1';")" -gt 0 ] && { echo yes; return; }
    sleep 1
  done
}
if [ -z "${EXTDB}" ]; then
  backup_run() { dc exec -T "$@" backup sh /ffs-backup/backup.sh now >> "${WORK}/backup.log" 2>&1; }
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
  [ "${BACKEND}" = mysql ] && expected="${ADMIN_DB_NAME}.sql.gz ${MARIADB_SYNCSTORAGE_DATABASE}.sql.gz ${MARIADB_TOKENSERVER_DATABASE}.sql.gz" || expected="${ADMIN_DB_NAME}.sql.gz ${POSTGRES_DATABASE}.sql.gz"
  check "$(dc exec -T backup sh -c 'for f in /backups/sync/*/*.sql.gz; do gzip -t "$f" && basename "$f"; done' | LC_ALL=C sort | paste -sd' ')" "${expected}" "the dumps pass gzip -t"
  check "$(dc exec -T backup sh -c 'stat -c %a /backups/sync/*/*.sql.gz' | sort -u)" 600 "the dumps are for root only (0600)"
  check "$(dc exec -T backup sh -c 'gunzip -c /backups/sync/*/*.sql.gz' | grep -cE 'CREATE TABLE [`"]?(public\.)?users[`"]? ')" 1 "the dump has the tokenserver's users table"
  check "$(dc exec -T backup sh -c "gunzip -c /backups/sync/*/${ADMIN_DB_NAME}.sql.gz" | grep -c 'ffs-e2e: before the upgrade by admin')" 1 "the dump of the admin UI's database has the audit trail"
  # a run that fails (nowhere to write): recorded, alerted, nothing left
  backup_run -e BACKUP_DIR=/proc/ffs-none
  check "$?" 1 "a failed backup run exits with an error"
  check "$(backups_of "ok = 0 AND error LIKE 'cannot write to /proc/ffs-none%'")" 1 "the failed run in ffs_backups"
  check "$(backup_event 'The backup of the Sync databases failed on %')" yes "admin UI: event and alert for the failed backup"
  # runs are named by the second: not the one of the run before
  sleep 1.1
  backup_run
  check "$(backup_event 'The backup of the Sync databases works again%')" yes "admin UI: event when the backups work again"
  echo "== restoring the dumps as ADMIN.md#restoring says"
  dump() { dc exec -T backup sh -c "gunzip -c /backups/sync/*/$1.sql.gz"; }
  if [ "${BACKEND}" = postgres ]; then
    # no owner and no grant in the dump of the Sync database: they name roles a new server
    # has only after the init container (it gives them again at every start)
    check "$(dump "${POSTGRES_DATABASE}" | grep -cE '^(GRANT|REVOKE|ALTER .* OWNER TO) ')" 0 "the dump of the Sync database names no role"
    # as the Sync server's role, the owner of what the dump holds (ADMIN.md#restoring), never
    # the superuser: into a database of its own
    check "$(dc exec -T backup printenv TOKENSERVER_DB_USER)" "${SYNC_ROLE}" "the backups dump the Sync database as the Sync server's role"
    sql "DROP DATABASE IF EXISTS ffs_restore_test;" > /dev/null 2>&1 && sql "CREATE DATABASE ffs_restore_test OWNER ${SYNC_ROLE} TEMPLATE template0;" > /dev/null
    dump "${POSTGRES_DATABASE}" | dc exec -T -e PGPASSWORD="${SYNC_ROLE_SECRET}" postgres_db psql -q -h 127.0.0.1 -U "${SYNC_ROLE}" -d ffs_restore_test -v ON_ERROR_STOP=1 > /dev/null
    check "$?" 0 "the dump of the Sync database restores into an empty database (ON_ERROR_STOP)"
    check "$(sql "SELECT COUNT(*) FROM users;")" "$(sync_role_sql 'SELECT COUNT(*) FROM users;' ffs_restore_test)" "every row of users restored"
    sql "DROP DATABASE ffs_restore_test;" > /dev/null
  fi
  dc logs backup 2>&1 | grep -m1 'every day at'
else
  # your own backups: the INSERT of ADMIN.md#backups, as the admin UI's user
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

echo "== upstream tokenserver integration tests (MAX_USERS raised, they create many users)"
set_env MAX_USERS 1000000
dc up -d > /dev/null 2>&1
check "$(wait_init)" 0 "init container exit code (MAX_USERS=1000000)"
hb > /dev/null
# test_e2e.py needs real accounts on Mozilla's FxA stage environment
UPSTREAM_TS="tools/integration_tests/tokenserver --ignore=tools/integration_tests/tokenserver/test_e2e.py"
if [ "${BACKEND}" = mysql ] && [ "${DATABASE_SERVER}" != MySQL ]; then
  # with several empty nodes the tokenserver orders them by LOG(0) (NULL), MySQL 8
  # (upstream CI, EXTERNAL_DB=1 and SYNC_DB=mysql here, where it runs) returns them in id
  # order, MariaDB does not: this stack has one node
  # (node ids are relative to tools/integration_tests, pytest's rootdir in the image)
  T=test_node_assignment.py::test_user_creation
  UPSTREAM_TS="${UPSTREAM_TS} --deselect tokenserver/${T} --deselect tools/integration_tests/tokenserver/${T}"
fi
pytest_in_app "${UPSTREAM_TS}"
check "$?" 0 "upstream tokenserver tests"

echo "== admin UI"
check "$(admin_healthy)" healthy "admin UI container healthcheck"
check "$(admin_errors | wc -l)" 0 "no background errors in the admin UI logs"
admin_errors | tail -5

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
sql "DELETE FROM users;" > /dev/null
pytest_in_app "/tests/test_client_flow.py -k first_sign_in"
check "$?" 0 "a first sign-in and sync without the admin UI"

RESULT=${BACKEND}$([ "${SYNC_DB}" = mysql ] && echo " (MySQL 8.4)")
[ ${FAILED} = 0 ] && echo "RESULT ${RESULT}: all checks passed" || echo "RESULT ${RESULT}: some checks FAILED"
exit ${FAILED}
