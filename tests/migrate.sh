#!/bin/bash
# Tests of docs/migrating.md (and of docs/upgrading.md for the older firefox-sync releases): an
# account's data written through another Sync server, moved the way docs/migrating.md says,
# then read back through firefox-sync with the same FxA uid and keys (upstream's mock FxA,
# tests/migrate_client.py).
#
# Usage: tests/migrate.sh <scenario>
#   upstream-mysql           Mozilla's docker-compose.one-shot.mysql.yaml (MySQL 8.0,
#                            syncserver-mysql 0.23.3) -> firefox-sync on MariaDB
#   upstream-mysql-to-mysql  the same -> firefox-sync on MySQL (SYNC_DB=mysql, mysql:lts)
#   upstream-mysql-testsetup Mozilla's docker-compose.mysql.yaml (its end-to-end test setup) -> MariaDB
#   upstream-postgres        Mozilla's docker-compose.one-shot.postgres.yaml (PostgreSQL 18,
#                            one database) -> firefox-sync on PostgreSQL
#   upstream-postgres-2db    Mozilla's docker-compose.postgres.yaml (two databases) -> PostgreSQL
#   dan-r                    dan-r/syncstorage-rs-docker's layout (linuxserver/mariadb:10.6.13,
#                            syncstorage_rs and tokenserver_rs, the schema of its pinned
#                            syncstorage-rs commit, its services and nodes rows) -> MariaDB
#   jeena                    jeena/fxsync-docker's docker-compose.yaml (syncstorage-rs 0.13.6,
#                            mariadb:10.11) -> MariaDB
#   nixos-mysql              NixOS' layout: one database firefox_syncserver on MariaDB 11.4 ->
#                            firefox-sync's two
#   nixos-postgres           NixOS' layout on PostgreSQL 17 -> PostgreSQL
#   yunohost                 YunoHost's layout: two databases of one owner on PostgreSQL 15 -> PostgreSQL
#   firefox-sync-2024-12     firefox-sync of December 2024 (4705bda, images 0.18.2), upgraded in place
#   firefox-sync-2024-07     the first release (7f52fa0, July 2024, image 0.17.1), upgraded in place
#
# The old stacks run their real compose files (fetched from GitHub at pinned commits, with
# only what the test needs changed in an override: the mock FxA as accounts server, a node
# URL, no published ports, a published image instead of a build), or reproduce the layout
# where the original builds from source. The commands of the guide are run as written there:
# each one must be found, verbatim, in docs/migrating.md or docs/upgrading.md (guide()), so a
# command changed in the guide must be changed here too.
# The new stack is a copy of this tree set up like a user's install (.env, COMPOSE_FILE),
# with SYNC_MAX_USERS=2 and the admin UI; checked: the init container, the SQL of "Checking the
# result", the client (same uids, on the new node, the data as written, writable), max users
# (a third account refused at 2, let in at 3), the admin UI's first page, a restart.
#
# Runs on Docker (amd64 images run emulated elsewhere: binfmt). Own compose projects
# (mig-src-*, mig-dst-*), ports on 127.0.0.1 (PORT, default 28661, and PORT+20 for the
# admin UI); the old stacks keep the container names of their files (the commands of the
# guide use them). Images pulled for a scenario are removed at the end, except those of
# KEEP_IMAGES.
# Environment:
#   REPOSITORY, TAG  firefox-sync images under test (default ghcr.io/porelli/firefox-sync-dev, latest)
#   ADMIN_IMAGE      the admin UI (default ffs-admin:test, built from admin/ when missing)
#   KEEP             1: leave the stacks running
#   SLOT             tests/slot.sh: 1, 2...: -s<SLOT> after the projects, PORT 28661 + 1000 * SLOT
#                    (the old stacks' container names are fixed: one run of a scenario at a time)
set -u

SCENARIO=${1:?usage: $0 <scenario>, see the top of $0}
TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
# the commands of the guide: moving from another server, and upgrading an older firefox-sync
GUIDE=("${CODE}/docs/migrating.md" "${CODE}/docs/upgrading.md")
# shellcheck source=tests/slot.sh
source "${TESTS}/slot.sh"
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync-dev}
TAG=${TAG:-latest}
ADMIN_IMAGE=${ADMIN_IMAGE:-ffs-admin:test}
PORT=${PORT:-$((28661 + SLOT_PORTS))}
TEST_IMAGE=${REPOSITORY}:syncstorage-rs-mysql-${TAG}
KEEP_IMAGES=${KEEP_IMAGES:-mariadb:lts mysql:lts mysql:8 postgres:latest}
OLD_DOMAIN=https://sync-old.ffs-e2e.invalid
NEW_DOMAIN=https://sync-new.ffs-e2e.invalid
# Mozilla's syncstorage-rs, docker/ at a commit of master (the one-shot files are not in 0.23.3)
UPSTREAM_COMMIT=530d0f05da74819a93b870ecc956a03fa3e81f5a
UPSTREAM_IMAGE_TAG=0.23.3
WORK=$(mktemp -d /tmp/ffs-mig.XXXXXX)
SRC=${WORK}/old
DST=${WORK}/firefox-sync
SRC_PROJECT=mig-src-${SCENARIO}${SLOT_SUFFIX}
DST_PROJECT=mig-dst-${SCENARIO}${SLOT_SUFFIX}
STATE=${WORK}/state
mkdir -p "${SRC}" "${STATE}"
chmod 777 "${STATE}"

FAILED=0
PULLED=()
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; return 1; }
check() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi; }
rnd() { tr -dc '[:alnum:]' < /dev/urandom | head -c 24; }

# a command (or lines run together in one shell) as the guide has it, in the current directory
guide() {
  local line
  for line in "$@"; do
    grep -qF -- "${line}" "${GUIDE[@]}" || { fail "command not in docs/migrating.md or docs/upgrading.md: ${line}"; return 1; }
    echo "  \$ ${line}"
  done
  # (not on stdin: docker compose exec -T would read the next lines)
  bash -o pipefail -c "$(printf '%s\n' "$@")" < /dev/null
}

# pulls an image if missing, to remove it at the end
need() {
  local img
  for img in "$@"; do
    docker image inspect "${img}" > /dev/null 2>&1 && continue
    echo "  pulling ${img}"
    # (amd64 only: run emulated)
    docker pull -q "${img}" > /dev/null 2>&1 || docker pull -q --platform linux/amd64 "${img}" > /dev/null || { fail "pull ${img}"; return 1; }
    case " ${KEEP_IMAGES} " in *" ${img} "*) ;; *) PULLED+=("${img}") ;; esac
  done
}

# the client of tests/migrate_client.py on a network: <network> <server URL> <public URL> <args>
client() {
  local net=$1 server=$2 domain=$3; shift 3
  docker run --rm --network "${net}" --user root --entrypoint sh \
    -v "${TESTS}:/tests:ro" -v "${STATE}:/state" \
    -e SYNC_SERVER_URL="${server}" -e SYNC_PUBLIC_URL="${domain}" -e ADMIN_URL=http://ffs-admin:8080 \
    -e PYTHONPATH=/app:/app/tools:/tests -e PYTHONDONTWRITEBYTECODE=1 \
    "${TEST_IMAGE}" -c "cd /app && python3 /tests/migrate_client.py $*" < /dev/null
}

teardown() {
  if [ -n "${KEEP:-}" ]; then echo "keeping the stacks (${WORK})"; return; fi
  echo "== teardown"
  [ -f "${SRC}/.teardown" ] && (cd "${SRC}" && bash .teardown) > /dev/null 2>&1
  unset COMPOSE_PROJECT_NAME
  [ -f "${DST}/.env" ] && (cd "${DST}" && docker compose down -v --remove-orphans) > /dev/null 2>&1
  [ ${#PULLED[@]} -gt 0 ] && docker rmi "${PULLED[@]}" > /dev/null 2>&1
  # files of the database containers (other owners)
  sudo rm -rf "${WORK}" 2> /dev/null || rm -rf "${WORK}"
}
trap teardown EXIT

fetch() { curl -sfL --retry 3 -o "$2" "$1" || { fail "download $1"; exit 1; }; }

# ---------- the new stack: a copy of this tree, set up like a user's install ----------

# <mariadb|mysql|postgres>: .env as prepare_environment.sh would write it, then the test's lines
dst_prepare() {
  DST_DB=$1
  # the old stack's project name was in the environment, firefox-sync's is in its .env
  unset COMPOSE_PROJECT_NAME
  mkdir -p "${DST}/tests"
  cp -r "${CODE}"/docker-compose*.yml "${CODE}/.env-example" "${CODE}/config" "${CODE}/db" "${DST}/"
  cp "${TESTS}/docker-compose.migrate.yml" "${DST}/tests/"
  local backend=mysql files=docker-compose.yml
  case ${DST_DB} in
    mysql) files=docker-compose.yml:docker-compose.sync-mysql.yml ;;
    postgres) backend=postgres files=docker-compose.sync-postgres.yml ;;
  esac
  sed -e "s|^SYNC_TOKENSERVER_DB_PASSWORD=.*|SYNC_TOKENSERVER_DB_PASSWORD=$(rnd)|" \
      -e "s|^SYNC_STORAGE_DB_PASSWORD=.*|SYNC_STORAGE_DB_PASSWORD=$(rnd)|" \
      -e "s|^SYNC_POSTGRES_PASSWORD=.*|SYNC_POSTGRES_PASSWORD=$(rnd)|" \
      -e "s|^SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=$(rnd)|" \
      -e "s|^SYNC_METRICS_HASH_SECRET=.*|SYNC_METRICS_HASH_SECRET=$(rnd)|" \
      -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$(rnd)|" \
      -e "s|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=$(rnd)|" \
      -e "s|^SYNC_PUBLIC_URL=.*|SYNC_PUBLIC_URL=${NEW_DOMAIN}|" \
      -e "s|^SYNC_EXPORT_PORT=.*|SYNC_EXPORT_PORT=127.0.0.1:${PORT}|" \
      -e "s|^ADMIN_EXPORT_PORT=.*|ADMIN_EXPORT_PORT=127.0.0.1:$((PORT + 20))|" \
      -e "s|^SYNC_MAX_USERS=.*|SYNC_MAX_USERS=2|" \
      -e "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=admin|" \
      -e "s|^SYNC_DB=.*|SYNC_DB=$([ "${DST_DB}" = mysql ] && echo mysql || echo mariadb)|" \
      -e "s|^IMAGE_REPOSITORY=.*|IMAGE_REPOSITORY=${REPOSITORY}|" \
      -e "s|^SYNC_IMAGE=.*|SYNC_IMAGE=syncstorage-rs-${backend}|" \
      -e "s|^SYNC_INIT_IMAGE=.*|SYNC_INIT_IMAGE=syncstorage-rs-${backend}-init|" \
      -e "s|^SYNC_IMAGE_TAG=.*|SYNC_IMAGE_TAG=${TAG}|" \
      -e "s|^SYNC_INIT_IMAGE_TAG=.*|SYNC_INIT_IMAGE_TAG=${TAG}|" \
      -e "s|^FXA_SMTP_HOST=.*|FXA_SMTP_HOST=|" \
      -e "/^# COMPOSE_FILE=/d" \
      -e "s|<REPLACE_WITH_SOMETHING_SECURE>|$(rnd)|" \
      -e "s|<REPLACE_WITH_[A-Z_]*>|placeholder.invalid|g" \
      "${CODE}/.env-example" > "${DST}/.env"
  # the PostgreSQL container: the Sync server's own role, as prepare_environment.sh sets it
  [ "${DST_DB}" = postgres ] && sed -i -e "s|^SYNC_POSTGRES_APP_USER=.*|SYNC_POSTGRES_APP_USER=syncserver_app|" \
    -e "s|^SYNC_POSTGRES_APP_PASSWORD=.*|SYNC_POSTGRES_APP_PASSWORD=$(rnd)|" "${DST}/.env"
  dst_test_env "${files}"
}

# the test's lines of .env: own project, the mock FxA as Mozilla's accounts (same email
# domain, api.accounts.firefox.com), the admin UI image and its trusted header
dst_test_env() {
  cat >> "${DST}/.env" <<EOF
# tests/migrate.sh
COMPOSE_PROJECT_NAME=${DST_PROJECT}
COMPOSE_FILE=$1:tests/docker-compose.migrate.yml
FXA_OAUTH_SERVER_URL=http://mock_fxa:6000
ADMIN_IMAGE=${ADMIN_IMAGE}
MIG_TEST_IMAGE=${TEST_IMAGE}
MIG_TRUSTED=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
EOF
}

dst() { (cd "${DST}" && docker compose "$@"); }
dst_sql() {
  case ${DST_DB} in
    mariadb) dst exec -T tokenserver_db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE" -sN -e "$0"' "$1" ;;
    mysql) dst exec -T tokenserver_db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u"$MYSQL_USER" "$MYSQL_DATABASE" -sN -e "$0"' "$1" ;;
    # as the Sync server's role, the owner of the tables (never the superuser, docs/reference/database-users.md#postgresql)
    postgres) dst exec -T postgres_db sh -c 'PGPASSWORD="$1" psql -h 127.0.0.1 -U "$2" -d "$POSTGRES_DB" -tA -F "	" -c "$0"' "$1" \
      "$(grep '^SYNC_POSTGRES_APP_PASSWORD=' "${DST}/.env" | cut -d= -f2)" "$(grep '^SYNC_POSTGRES_APP_USER=' "${DST}/.env" | cut -d= -f2)" ;;
  esac < /dev/null 2> /dev/null
}
wait_init() { timeout 600 docker wait "$(dst ps -a -q tokenserver_db_init)"; }
dst_net() { echo "${DST_PROJECT}_default"; }

# "Loading into firefox-sync": the databases only, the dumps (in ${DST}), then the stack
dst_load() {
  echo "== loading into firefox-sync (${DST_DB})"
  cd "${DST}" || exit 1
  case ${DST_DB} in
    mariadb)
      guide "docker compose up -d --wait tokenserver_db syncstorage_db" > /dev/null 2>&1
      check "$?" 0 "database containers up"
      echo "  $(dst_sql 'SELECT VERSION()')"
      guide "docker compose exec -T tokenserver_db sh -c 'MYSQL_PWD=\"\$MARIADB_PASSWORD\" mariadb -u\"\$MARIADB_USER\" \"\$MARIADB_DATABASE\"' < tokenserver.sql"
      check "$?" 0 "tokenserver.sql loaded"
      guide "docker compose exec -T syncstorage_db sh -c 'MYSQL_PWD=\"\$MARIADB_PASSWORD\" mariadb -u\"\$MARIADB_USER\" \"\$MARIADB_DATABASE\"' < syncstorage.sql"
      check "$?" 0 "syncstorage.sql loaded" ;;
    mysql)
      guide "docker compose up -d --wait tokenserver_db syncstorage_db" > /dev/null 2>&1
      check "$?" 0 "database containers up"
      echo "  $(dst_sql 'SELECT VERSION()')"
      guide "docker compose exec -T tokenserver_db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysql -u\"\$MYSQL_USER\" \"\$MYSQL_DATABASE\"' < tokenserver.sql"
      check "$?" 0 "tokenserver.sql loaded"
      guide "docker compose exec -T syncstorage_db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysql -u\"\$MYSQL_USER\" \"\$MYSQL_DATABASE\"' < syncstorage.sql"
      check "$?" 0 "syncstorage.sql loaded" ;;
    postgres)
      guide "docker compose up -d --wait postgres_db" > /dev/null 2>&1
      check "$?" 0 "database container up"
      # the Sync server's role first: the dumps are loaded as it
      guide "docker compose run --rm sync_role_init" > "${WORK}/sync-role.log" 2>&1
      check "$?" 0 "the Sync server's role (sync_role_init)" || tail -5 "${WORK}/sync-role.log"
      echo "  $(dst_sql 'SELECT version()')"
      if [ -z "${PG_FILES:-}" ]; then
        guide "docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD=\"\$POSTGRES_SYNC_PASSWORD\" psql -h \"\$POSTGRES_SERVER\" -U \"\$POSTGRES_SYNC_USER\" -d \"\$POSTGRES_DATABASE\" -v ON_ERROR_STOP=1' < syncserver.sql" > "${WORK}/psql.log" 2>&1
        check "$?" 0 "syncserver.sql loaded" || tail -5 "${WORK}/psql.log"
      else
        # "with each file in turn", the command of the guide's comment
        local f line="# docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD=\"\$POSTGRES_SYNC_PASSWORD\" psql -h \"\$POSTGRES_SERVER\" -U \"\$POSTGRES_SYNC_USER\" -d \"\$POSTGRES_DATABASE\" -v ON_ERROR_STOP=1' < <file>"
        grep -qF -- "${line}" "${GUIDE[@]}" || fail "command not in docs/migrating.md or docs/upgrading.md: ${line}"
        for f in ${PG_FILES}; do
          line=${line#\# }
          echo "  \$ ${line%<file>}${f}"
          bash -c "${line%<file>}${f}" > "${WORK}/psql-${f}.log" 2>&1
          check "$?" 0 "${f} loaded" || tail -5 "${WORK}/psql-${f}.log"
        done
      fi ;;
  esac
  guide "docker compose up -d" > "${WORK}/up.log" 2>&1
  check "$?" 0 "docker compose up -d"
  check "$(wait_init)" 0 "init container exit code"
  check "$(state syncstorage_migrate ExitCode)" 0 "migrations of the newer syncstorage-rs"
  cd - > /dev/null || exit 1
}
state() { docker inspect -f "{{.State.$2}}" "$(dst ps -a -q "$1")" 2> /dev/null; }
hb() {
  for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")" = 200 ] && { echo 200; return; }
    sleep 1
  done
  echo down
}

# "Checking the result", the client, MAX_USERS, the admin UI, a restart. $1: the node URL
dst_verify() {
  local domain=${1:-${NEW_DOMAIN}} users
  echo "== checking the result"
  check "$(hb)" 200 "firefox-sync answers /__heartbeat__"
  check "$(dst logs tokenserver_db_init 2>&1 | grep -c 'Current users: 2$')" 1 "init container: Current users: 2"
  cd "${DST}" || exit 1
  case ${DST_DB} in
    mariadb)
      users=$(guide "docker compose exec tokenserver_db sh -c 'MYSQL_PWD=\"\$MARIADB_PASSWORD\" mariadb -u\"\$MARIADB_USER\" \"\$MARIADB_DATABASE\" -e \"SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL\"'" 2>&1) ;;
    mysql)
      users=$(guide "docker compose exec tokenserver_db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysql -u\"\$MYSQL_USER\" \"\$MYSQL_DATABASE\" -e \"SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL\"'" 2>&1) ;;
    postgres)
      users=$(guide "docker compose run --rm --no-deps -T --entrypoint sh sync_role_init -c 'PGPASSWORD=\"\$POSTGRES_SYNC_PASSWORD\" psql -h \"\$POSTGRES_SERVER\" -U \"\$POSTGRES_SYNC_USER\" -d \"\$POSTGRES_DATABASE\" -c \"SELECT u.uid, u.email, u.generation, u.keys_changed_at, u.client_state, n.node FROM users u JOIN nodes n ON n.id = u.nodeid WHERE u.replaced_at IS NULL\"'" 2>&1) ;;
  esac
  cd - > /dev/null || exit 1
  echo "${users}" | sed 's/^/    /'
  check "$(echo "${users}" | grep -E 'alice@|bob@' | grep -c "${domain}")" 2 "SQL of the guide: alice and bob on the node ${domain}"
  check "$(dst_sql "SELECT COUNT(*) FROM nodes WHERE node <> '${domain}' AND (downed = 0 OR available > 0)")" 0 "the old nodes are out of rotation"
  check "$(dst_sql "SELECT COUNT(*) FROM services WHERE service = 'sync-1.5'")" 1 "one sync-1.5 service"
  client "$(dst_net)" http://syncstorage:8000 "${domain}" check
  check "$?" 0 "the client reads its data back through firefox-sync"
  client "$(dst_net)" http://syncstorage:8000 "${domain}" new carol refused
  check "$?" 0 "SYNC_MAX_USERS=2 counts the moved accounts: a third one is refused"
  client "$(dst_net)" http://syncstorage:8000 "${domain}" admin 2
  check "$?" 0 "the admin UI lists the moved accounts"
  echo "== SYNC_MAX_USERS=3, restart"
  sed -i 's/^SYNC_MAX_USERS=.*/SYNC_MAX_USERS=3/' "${DST}/.env"
  dst up -d > /dev/null 2>&1
  check "$(wait_init)" 0 "init container exit code (restart)"
  check "$(hb)" 200 "/__heartbeat__ after the restart"
  client "$(dst_net)" http://syncstorage:8000 "${domain}" new carol ok
  check "$?" 0 "SYNC_MAX_USERS=3: the third account is let in"
  client "$(dst_net)" http://syncstorage:8000 "${domain}" check
  check "$?" 0 "the client reads its data back after the restart"
  check "$(dst logs syncstorage 2>&1 | grep -ciE 'panicked|"status":5[0-9][0-9]')" 0 "no panics or 5xx in the Sync server's logs"
}

# ---------- the old stacks ----------

# Mozilla's compose files, docker/ at UPSTREAM_COMMIT; <file> <mysql|postgres> [override]
upstream_src() {
  mkdir -p "${SRC}/docker"
  fetch "https://raw.githubusercontent.com/mozilla-services/syncstorage-rs/${UPSTREAM_COMMIT}/docker/$1" "${SRC}/docker/$1"
  cat > "${SRC}/docker/migrate-test.yaml"
  export COMPOSE_PROJECT_NAME=${SRC_PROJECT}
  echo "COMPOSE_PROJECT_NAME=${SRC_PROJECT} docker compose -f docker/$1 -f docker/migrate-test.yaml down -v --remove-orphans" > "${SRC}/.teardown"
  # and the database images of the file (docker.io/library/mysql:8.0, postgres:18 or 18.0)
  need "ghcr.io/mozilla-services/syncstorage-rs/syncserver-$2:${UPSTREAM_IMAGE_TAG}" \
    $(sed -n 's|^ *image: docker.io/library/||p' "${SRC}/docker/$1" | sort -u) || exit 1
  echo "== old stack: $1 (syncserver-$2:${UPSTREAM_IMAGE_TAG})"
  (cd "${SRC}" && docker compose -f "docker/$1" -f docker/migrate-test.yaml up -d --wait --wait-timeout 600) > "${WORK}/src-up.log" 2>&1
  check "$?" 0 "old stack up" || { tail -20 "${WORK}/src-up.log"; (cd "${SRC}" && docker compose -f "docker/$1" -f docker/migrate-test.yaml logs --tail 30); exit 1; }
}
src_stop() { (cd "${SRC}" && docker compose -f "docker/$1" -f docker/migrate-test.yaml stop "$2") > /dev/null 2>&1; }

# the client writes through the old server: <network> <server URL>
src_write() {
  echo "== writing through the old server"
  client "$1" "$2" "${OLD_DOMAIN}" write
  check "$?" 0 "alice and bob synced to the old server" || exit 1
}

# override of the one-shot files: the published image instead of a build, no published
# port (the test reaches it on its network), the mock FxA as accounts server, a node URL
oneshot_override() {
  cat <<EOF
services:
  syncserver:
    build: !reset null
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-$1:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
    ports: !reset []
    environment:
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock_fxa:6000
      SYNC_TOKENSERVER__INIT_NODE_URL: ${OLD_DOMAIN}
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
}

scenario_upstream_mysql() {
  local to=$1
  upstream_src docker-compose.one-shot.mysql.yaml mysql < <(oneshot_override mysql)
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  src_stop docker-compose.one-shot.mysql.yaml syncserver
  echo "== dumps (docs/migrating.md, Mozilla's compose files)"
  cd "${SRC}" || exit 1
  guide "docker exec syncserver-tokenserver-db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysqldump -u\"\$MYSQL_USER\" --single-transaction --no-tablespaces --set-gtid-purged=OFF tokenserver' > tokenserver.sql"
  check "$?" 0 "tokenserver dump"
  guide "docker exec syncserver-sync-db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysqldump -u\"\$MYSQL_USER\" --single-transaction --no-tablespaces --set-gtid-purged=OFF syncstorage' > syncstorage.sql"
  check "$?" 0 "syncstorage dump"
  echo "  source: MySQL $(docker exec syncserver-sync-db mysql -usync -psync -sN -e 'SELECT VERSION()' 2> /dev/null)"
  cd - > /dev/null || exit 1
  dst_prepare "${to}"
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  dst_verify
}

# the test setup docker-compose.mysql.yaml (users test), like upstream-postgres-2db
scenario_upstream_mysql_testsetup() {
  upstream_src docker-compose.mysql.yaml mysql <<EOF
services:
  sync-db:
    ports: !reset []
  tokenserver-db:
    ports: !reset []
  mock-fxa-server:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
  syncserver:
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-mysql:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
    ports: !reset []
    environment:
      SYNC_TOKENSERVER__ENABLED: "true"
      # its default is Mozilla's stage accounts (api-accounts.stage.mozaws.net), see docs/migrating.md
      SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN: api.accounts.firefox.com
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock-fxa-server:6000
      SYNC_TOKENSERVER__INIT_NODE_URL: ${OLD_DOMAIN}
EOF
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  src_stop docker-compose.mysql.yaml syncserver
  echo "== dumps (docs/migrating.md, Mozilla's test setup)"
  cd "${SRC}" || exit 1
  guide 'dc="docker compose -f docker/docker-compose.mysql.yaml exec -T"' \
    "\$dc tokenserver-db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysqldump -u\"\$MYSQL_USER\" --single-transaction --no-tablespaces --set-gtid-purged=OFF tokenserver' > tokenserver.sql" \
    "\$dc sync-db sh -c 'MYSQL_PWD=\"\$MYSQL_PASSWORD\" mysqldump -u\"\$MYSQL_USER\" --single-transaction --no-tablespaces --set-gtid-purged=OFF syncstorage' > syncstorage.sql"
  check "$?" 0 "two dumps"
  cd - > /dev/null || exit 1
  dst_prepare mariadb
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  dst_verify
}

scenario_upstream_postgres() {
  upstream_src docker-compose.one-shot.postgres.yaml postgres < <(oneshot_override postgres)
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  src_stop docker-compose.one-shot.postgres.yaml syncserver
  echo "== dump (docs/migrating.md, Mozilla's compose files)"
  cd "${SRC}" || exit 1
  guide "docker exec syncserver-postgres pg_dump -U sync --no-owner --no-acl syncserver > syncserver.sql"
  check "$?" 0 "syncserver dump"
  cd - > /dev/null || exit 1
  dst_prepare postgres
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  dst_verify
}

scenario_upstream_postgres_2db() {
  # app:build is upstream's locally built image: the published one instead; the file sets
  # no node, no tokenserver (they come from its e2e override files)
  upstream_src docker-compose.postgres.yaml postgres <<EOF
services:
  sync-db:
    ports: !reset []
  tokenserver-db:
    ports: !reset []
  sync-db-setup:
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-postgres:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
  mock-fxa-server:
    image: ${TEST_IMAGE}
  syncserver:
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-postgres:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
    ports: !reset []
    environment:
      SYNC_TOKENSERVER__ENABLED: "true"
      # its default is Mozilla's stage accounts (api-accounts.stage.mozaws.net), see docs/migrating.md
      SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN: api.accounts.firefox.com
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock-fxa-server:6000
      SYNC_TOKENSERVER__INIT_NODE_URL: ${OLD_DOMAIN}
EOF
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  src_stop docker-compose.postgres.yaml syncserver
  echo "== dumps (docs/migrating.md, two PostgreSQL databases)"
  cd "${SRC}" || exit 1
  guide 'dc="docker compose -f docker/docker-compose.postgres.yaml exec -T"' \
    '$dc tokenserver-db pg_dump -U test --no-owner --no-acl tokenserver > syncserver.sql' \
    '$dc sync-db pg_dump -U test --no-owner --no-acl --exclude-table=__diesel_schema_migrations syncstorage > syncstorage.sql' \
    '$dc sync-db pg_dump -U test --data-only --table=__diesel_schema_migrations syncstorage > syncstorage-migrations.sql'
  check "$?" 0 "three dumps"
  local migrations
  migrations=$(docker compose -f docker/docker-compose.postgres.yaml exec -T sync-db psql -U test -d syncstorage -tA -c 'SELECT COUNT(*) FROM __diesel_schema_migrations' < /dev/null)
  migrations=$((migrations + $(docker compose -f docker/docker-compose.postgres.yaml exec -T tokenserver-db psql -U test -d tokenserver -tA -c 'SELECT COUNT(*) FROM __diesel_schema_migrations' < /dev/null)))
  cd - > /dev/null || exit 1
  dst_prepare postgres
  cp "${SRC}"/*.sql "${DST}/"
  PG_FILES="syncserver.sql syncstorage.sql syncstorage-migrations.sql" dst_load
  check "$([ "$(dst_sql 'SELECT COUNT(*) FROM __diesel_schema_migrations')" -ge "${migrations}" ] && echo yes)" yes \
    "the migrations of both databases in firefox-sync's one (${migrations} before)"
  dst_verify
}

# dan-r/syncstorage-rs-docker builds syncstorage-rs from commit 1dc4214 (June 2025, 0.18.3
# and 8 commits without migrations): firefox-sync's build of 0.18.3 instead, migrating
# like its entrypoint (diesel, here the server's own migrations), then the entrypoint's
# SQL for services and nodes, with its compose file's database container and names
DANR_COMMIT=main
scenario_dan_r() {
  local root=$(rnd) pw=$(rnd)
  mkdir -p "${SRC}/data/initdb.d" "${SRC}/data/config"
  fetch "https://raw.githubusercontent.com/dan-r/syncstorage-rs-docker/${DANR_COMMIT}/data/initdb.d/init.sql" "${SRC}/data/initdb.d/init.sql"
  fetch "https://raw.githubusercontent.com/dan-r/syncstorage-rs-docker/${DANR_COMMIT}/docker-compose.yaml" "${SRC}/upstream-docker-compose.yaml"
  grep -q 'linuxserver/mariadb:10.6.13' "${SRC}/upstream-docker-compose.yaml" || fail "dan-r's compose file no longer runs linuxserver/mariadb:10.6.13"
  local app=ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-0.18.3
  need linuxserver/mariadb:10.6.13 "${app}" || exit 1
  cat > "${SRC}/docker-compose.yaml" <<EOF
services:
  mariadb:
    container_name: firefox_mariadb
    image: linuxserver/mariadb:10.6.13
    volumes:
      - ./data/config:/config
      - ./data/initdb.d/init.sql:/config/initdb.d/init.sql
    environment:
      MYSQL_DATABASE: syncstorage
      MYSQL_USER: sync
      MYSQL_PASSWORD: ${pw}
      MYSQL_ROOT_PASSWORD: ${root}
  syncserver:
    container_name: firefox_syncserver
    image: ${app}
    environment:
      SYNC_HOST: 0.0.0.0
      SYNC_MASTER_SECRET: $(rnd)
      SYNC_SYNCSTORAGE__DATABASE_URL: mysql://sync:${pw}@mariadb:3306/syncstorage_rs
      SYNC_TOKENSERVER__DATABASE_URL: mysql://sync:${pw}@mariadb:3306/tokenserver_rs
      SYNC_TOKENSERVER__ENABLED: "true"
      SYNC_TOKENSERVER__RUN_MIGRATIONS: "true"
      SYNC_TOKENSERVER__NODE_TYPE: mysql
      SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN: api.accounts.firefox.com
      SYNC_TOKENSERVER__FXA_METRICS_HASH_SECRET: $(rnd)
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock_fxa:6000
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
  export COMPOSE_PROJECT_NAME=${SRC_PROJECT}
  echo "COMPOSE_PROJECT_NAME=${SRC_PROJECT} docker compose down -v --remove-orphans" > "${SRC}/.teardown"
  cd "${SRC}" || exit 1
  echo "== old stack: dan-r's layout (linuxserver/mariadb:10.6.13, syncstorage-rs 0.18.3)"
  docker compose up -d mariadb mock_fxa > /dev/null 2>&1
  for _ in $(seq 1 90); do
    docker exec firefox_mariadb mysql -usync -p"${pw}" -e 'SELECT 1' tokenserver_rs > /dev/null 2>&1 && break
    sleep 2
  done
  check "$(docker exec firefox_mariadb mysql -usync -p"${pw}" -sN -e 'SHOW DATABASES' 2> /dev/null | grep -cE '^(syncstorage_rs|tokenserver_rs)$')" 2 "init.sql: syncstorage_rs and tokenserver_rs"
  # the migrations, then the entrypoint's SQL, then the server
  docker compose run --rm --no-deps -T --entrypoint sh syncserver -c '
    /app/bin/syncserver & pid=$!
    for i in $(seq 1 180); do curl -sf http://localhost:8000/__heartbeat__ > /dev/null && break; sleep 1; done
    kill $pid; wait $pid; true' > "${WORK}/src-migrate.log" 2>&1
  docker exec -i firefox_mariadb mysql -usync -p"${pw}" tokenserver_rs <<EOF
DELETE FROM services;
INSERT INTO services (id, service, pattern) VALUES
    (1, "sync-1.5", "{node}/1.5/{uid}");
INSERT INTO nodes (id, service, node, capacity, available, current_load, downed, backoff) VALUES
    (1, 1, "${OLD_DOMAIN}", 10, 10, 0, 0, 0)
    ON DUPLICATE KEY UPDATE node = "${OLD_DOMAIN}", capacity = 10, available = (SELECT 10 - current_load from (SELECT * FROM nodes) as n2 where id = 1);
EOF
  check "$?" 0 "dan-r's entrypoint SQL: service and node 1"
  docker compose up -d syncserver > /dev/null 2>&1
  for _ in $(seq 1 120); do
    docker compose exec -T syncserver curl -sf http://localhost:8000/__heartbeat__ > /dev/null 2>&1 && break
    sleep 2
  done
  cd - > /dev/null || exit 1
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  (cd "${SRC}" && docker compose stop syncserver) > /dev/null 2>&1
  echo "== dumps (docs/migrating.md, dan-r)"
  cd "${SRC}" || exit 1
  guide "docker exec firefox_mariadb sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mariadb-dump -uroot --single-transaction --no-tablespaces tokenserver_rs' > tokenserver.sql"
  check "$?" 0 "tokenserver_rs dump"
  guide "docker exec firefox_mariadb sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mariadb-dump -uroot --single-transaction --no-tablespaces syncstorage_rs' > syncstorage.sql"
  check "$?" 0 "syncstorage_rs dump"
  echo "  source: MariaDB $(docker exec firefox_mariadb mysql -usync -p"${pw}" -sN -e 'SELECT VERSION()' 2> /dev/null)"
  cd - > /dev/null || exit 1
  dst_prepare mariadb
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  check "$(dst_sql "SELECT COUNT(*) FROM __diesel_schema_migrations WHERE version LIKE '20260226185317%'")" 1 "firefox-sync added the migrations dan-r's syncstorage-rs did not have"
  dst_verify
}

# jeena/fxsync-docker: its compose file as it is, with the mock FxA as accounts server
JEENA_COMMIT=main
scenario_jeena() {
  fetch "https://raw.githubusercontent.com/jeena/fxsync-docker/${JEENA_COMMIT}/docker-compose.yaml" "${SRC}/docker-compose.yaml"
  need mozilla/syncstorage-rs:0.13.6 mariadb:10.11 || exit 1
  cat > "${SRC}/.env" <<EOF
MARIADB_USER=sync
MARIADB_PASSWORD=$(rnd)
SYNC_MASTER_SECRET=$(rnd)
METRICS_HASH_SECRET=$(rnd)
DOMAIN=${OLD_DOMAIN}
EOF
  cat > "${SRC}/migrate-test.yaml" <<EOF
services:
  syncstorage:
    platform: linux/amd64
    ports: !reset []
    environment:
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock_fxa:6000/v1
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
  export COMPOSE_PROJECT_NAME=${SRC_PROJECT}
  echo "COMPOSE_PROJECT_NAME=${SRC_PROJECT} docker compose -f docker-compose.yaml -f migrate-test.yaml down -v --remove-orphans" > "${SRC}/.teardown"
  cd "${SRC}" || exit 1
  echo "== old stack: jeena/fxsync-docker (syncstorage-rs 0.13.6, mariadb:10.11)"
  docker compose -f docker-compose.yaml -f migrate-test.yaml up -d > "${WORK}/src-up.log" 2>&1
  timeout 600 docker wait firefox_tokenserver_db_init > /dev/null
  check "$(docker inspect -f '{{.State.ExitCode}}' firefox_tokenserver_db_init)" 0 "its tokenserver_db_init"
  cd - > /dev/null || exit 1
  src_write "${SRC_PROJECT}_default" http://syncstorage:8000
  (cd "${SRC}" && docker compose -f docker-compose.yaml -f migrate-test.yaml stop syncstorage) > /dev/null 2>&1
  echo "== dumps (docs/migrating.md, jeena)"
  cd "${SRC}" || exit 1
  guide "docker exec firefox_tokenserver_db sh -c 'MYSQL_PWD=\"\$MARIADB_PASSWORD\" mariadb-dump -u\"\$MARIADB_USER\" --single-transaction --no-tablespaces tokenserver' > tokenserver.sql"
  check "$?" 0 "tokenserver dump"
  guide "docker exec firefox_syncstorage_db sh -c 'MYSQL_PWD=\"\$MARIADB_PASSWORD\" mariadb-dump -u\"\$MARIADB_USER\" --single-transaction --no-tablespaces syncstorage' > syncstorage.sql"
  check "$?" 0 "syncstorage dump"
  cd - > /dev/null || exit 1
  dst_prepare mariadb
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  dst_verify
}

# NixOS' module: one database for both, on the host's server (here a container, as root
# without a password like the unix socket of NixOS' root)
scenario_nixos() {
  local db=$1 image ctr=mig-nixos-db
  case ${db} in
    mysql) image=mariadb:11.4 ;;
    postgres) image=postgres:17 ;;
  esac
  need "${image}" "ghcr.io/mozilla-services/syncstorage-rs/syncserver-${db}:${UPSTREAM_IMAGE_TAG}" || exit 1
  local url
  if [ "${db}" = mysql ]; then
    url="mysql://firefox_syncserver:pw@db:3306/firefox_syncserver"
  else
    url="postgres://firefox_syncserver:pw@db:5432/firefox_syncserver"
  fi
  cat > "${SRC}/docker-compose.yaml" <<EOF
services:
  db:
    container_name: ${ctr}
    image: ${image}
    environment:
      MARIADB_ALLOW_EMPTY_ROOT_PASSWORD: "1"
      MARIADB_DATABASE: firefox_syncserver
      MARIADB_USER: firefox_syncserver
      MARIADB_PASSWORD: pw
      POSTGRES_PASSWORD: rootpw
      POSTGRES_HOST_AUTH_METHOD: trust
    healthcheck:
      test: ["CMD-SHELL", "$([ "${db}" = mysql ] && echo 'healthcheck.sh --connect --innodb_initialized' || echo 'pg_isready -U postgres')"]
      interval: 5s
      retries: 30
  syncserver:
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-${db}:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
    depends_on:
      db:
        condition: service_healthy
    environment:
      SYNC_HOST: 0.0.0.0
      SYNC_MASTER_SECRET: $(rnd)
      SYNC_SYNCSTORAGE__DATABASE_URL: ${url}
      SYNC_TOKENSERVER__DATABASE_URL: ${url}
      SYNC_TOKENSERVER__ENABLED: "true"
      SYNC_TOKENSERVER__RUN_MIGRATIONS: "true"
      SYNC_TOKENSERVER__NODE_TYPE: ${db}
      SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN: api.accounts.firefox.com
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock_fxa:6000
      SYNC_TOKENSERVER__INIT_NODE_URL: ${OLD_DOMAIN}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/__heartbeat__"]
      interval: 5s
      retries: 60
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
  if [ "${db}" = postgres ]; then
    # the database and its owner, as the module creates them (ensureDatabases, ensureUsers)
    mkdir -p "${SRC}/initdb"
    printf "CREATE ROLE firefox_syncserver LOGIN PASSWORD 'pw';\nCREATE DATABASE firefox_syncserver OWNER firefox_syncserver;\n" > "${SRC}/initdb/init.sql"
    sed -i "s|    healthcheck:|    volumes: [\"./initdb:/docker-entrypoint-initdb.d:ro\"]\n    healthcheck:|" "${SRC}/docker-compose.yaml"
  fi
  export COMPOSE_PROJECT_NAME=${SRC_PROJECT}
  echo "COMPOSE_PROJECT_NAME=${SRC_PROJECT} docker compose down -v --remove-orphans" > "${SRC}/.teardown"
  echo "== old stack: NixOS' layout, one database firefox_syncserver on ${image}"
  (cd "${SRC}" && docker compose up -d --wait --wait-timeout 600) > "${WORK}/src-up.log" 2>&1
  check "$?" 0 "old stack up" || { tail -20 "${WORK}/src-up.log"; exit 1; }
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  (cd "${SRC}" && docker compose stop syncserver) > /dev/null 2>&1
  echo "== dumps (docs/migrating.md, NixOS, as root on the host: here in the database container)"
  cd "${SRC}" || exit 1
  if [ "${db}" = mysql ]; then
    local tables listed="users nodes services __diesel_schema_migrations bso collections user_collections batch_uploads batch_upload_items"
    tables=$(docker exec "${ctr}" mariadb -uroot -sN -e 'SHOW TABLES' firefox_syncserver | sort | paste -sd' ')
    check "${tables}" "$(echo "${listed}" | tr ' ' '\n' | sort -u | paste -sd' ')" "the guide's table lists cover every table of the database"
    local cmd
    for cmd in "sudo mariadb-dump --single-transaction --no-tablespaces firefox_syncserver users nodes services __diesel_schema_migrations > tokenserver.sql" \
               "sudo mariadb-dump --single-transaction --no-tablespaces firefox_syncserver bso collections user_collections batch_uploads batch_upload_items __diesel_schema_migrations > syncstorage.sql"; do
      grep -qF -- "${cmd}" "${GUIDE[@]}" || { fail "command not in docs/migrating.md or docs/upgrading.md: ${cmd}"; continue; }
      echo "  \$ ${cmd}   (in the container, without sudo)"
      bash -o pipefail -c "docker exec ${ctr} ${cmd#sudo }"
      check "$?" 0 "dump: ${cmd##*> }"
    done
  else
    local cmd="sudo -u postgres pg_dump --no-owner --no-acl firefox_syncserver > syncserver.sql"
    grep -qF -- "${cmd}" "${GUIDE[@]}" || fail "command not in docs/migrating.md or docs/upgrading.md: ${cmd}"
    echo "  \$ ${cmd}   (in the container: docker exec -u postgres)"
    docker exec -u postgres "${ctr}" pg_dump --no-owner --no-acl firefox_syncserver > syncserver.sql
    check "$?" 0 "dump: syncserver.sql"
  fi
  cd - > /dev/null || exit 1
  dst_prepare "$([ "${db}" = mysql ] && echo mariadb || echo postgres)"
  cp "${SRC}"/*.sql "${DST}/"
  dst_load
  dst_verify
}

# YunoHost's syncserver-rs_ynh (0.23.3~ynh9 and later): upstream 0.23.3 on the server's
# PostgreSQL (15 on bookworm), two databases of one owner, syncserver_rs (storage) and
# syncserver_rs_tokenserver
scenario_yunohost() {
  local ctr=mig-yunohost-db image=postgres:15
  need "${image}" "ghcr.io/mozilla-services/syncstorage-rs/syncserver-postgres:${UPSTREAM_IMAGE_TAG}" || exit 1
  mkdir -p "${SRC}/initdb"
  cat > "${SRC}/initdb/init.sql" <<EOF
CREATE ROLE syncserver_rs LOGIN PASSWORD 'pw';
CREATE DATABASE syncserver_rs OWNER syncserver_rs;
CREATE DATABASE syncserver_rs_tokenserver OWNER syncserver_rs;
EOF
  cat > "${SRC}/docker-compose.yaml" <<EOF
services:
  db:
    container_name: ${ctr}
    image: ${image}
    environment:
      POSTGRES_PASSWORD: rootpw
    volumes: ["./initdb:/docker-entrypoint-initdb.d:ro"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      retries: 30
  syncserver:
    image: ghcr.io/mozilla-services/syncstorage-rs/syncserver-postgres:${UPSTREAM_IMAGE_TAG}
    platform: linux/amd64
    depends_on:
      db:
        condition: service_healthy
    environment:
      SYNC_HOST: 0.0.0.0
      SYNC_MASTER_SECRET: $(rnd)
      SYNC_SYNCSTORAGE__DATABASE_URL: postgres://syncserver_rs:pw@db/syncserver_rs
      SYNC_TOKENSERVER__DATABASE_URL: postgres://syncserver_rs:pw@db/syncserver_rs_tokenserver
      SYNC_TOKENSERVER__ENABLED: "true"
      SYNC_TOKENSERVER__RUN_MIGRATIONS: "true"
      SYNC_TOKENSERVER__NODE_TYPE: postgres
      SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN: api.accounts.firefox.com
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock_fxa:6000
      SYNC_TOKENSERVER__INIT_NODE_URL: ${OLD_DOMAIN}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/__heartbeat__"]
      interval: 5s
      retries: 60
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
  export COMPOSE_PROJECT_NAME=${SRC_PROJECT}
  echo "COMPOSE_PROJECT_NAME=${SRC_PROJECT} docker compose down -v --remove-orphans" > "${SRC}/.teardown"
  echo "== old stack: YunoHost's layout, syncserver_rs and syncserver_rs_tokenserver on ${image}"
  (cd "${SRC}" && docker compose up -d --wait --wait-timeout 600) > "${WORK}/src-up.log" 2>&1
  check "$?" 0 "old stack up" || { tail -20 "${WORK}/src-up.log"; exit 1; }
  src_write "${SRC_PROJECT}_default" http://syncserver:8000
  (cd "${SRC}" && docker compose stop syncserver) > /dev/null 2>&1
  echo "== dumps (docs/migrating.md, YunoHost, as root on the server: here in the database container)"
  cd "${SRC}" || exit 1
  local cmd
  for cmd in "sudo -u postgres pg_dump --no-owner --no-acl syncserver_rs_tokenserver > syncserver.sql" \
             "sudo -u postgres pg_dump --no-owner --no-acl --exclude-table=__diesel_schema_migrations syncserver_rs > syncstorage.sql" \
             "sudo -u postgres pg_dump --data-only --table=__diesel_schema_migrations syncserver_rs > syncstorage-migrations.sql"; do
    grep -qF -- "${cmd}" "${GUIDE[@]}" || { fail "command not in docs/migrating.md or docs/upgrading.md: ${cmd}"; continue; }
    echo "  \$ ${cmd}   (docker exec -u postgres)"
    bash -o pipefail -c "docker exec -u postgres ${ctr} ${cmd#sudo -u postgres }" < /dev/null
    check "$?" 0 "dump: ${cmd##*> }"
  done
  cd - > /dev/null || exit 1
  dst_prepare postgres
  cp "${SRC}"/*.sql "${DST}/"
  PG_FILES="syncserver.sql syncstorage.sql syncstorage-migrations.sql" dst_load
  dst_verify
}

# an older firefox-sync, upgraded in place (the same directory, its .env kept)
# <commit> <first|dec2024>
scenario_firefox_sync_old() {
  local commit=$1 kind=$2
  # the directory gives the compose project and the volume names, as with a clone
  DST=${WORK}/${DST_PROJECT}
  mkdir -p "${DST}"
  curl -sfL "https://codeload.github.com/porelli/firefox-sync/tar.gz/${commit}" | tar -xz -C "${DST}" --strip-components=1 \
    || { fail "download of ${commit}"; exit 1; }
  local old_app old_init=
  cp "${DST}/.env-example" "${DST}/.env"
  if [ "${kind}" = first ]; then
    # docker-compose.yml names its image (syncstorage-rs-mysql-latest, then 0.17.x)
    old_app=ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-0.17.1
    need "${old_app}" mariadb:11.4 || exit 1
    sed -i -e "s|^SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=$(rnd)|" -e "s|^METRICS_HASH_SECRET=.*|METRICS_HASH_SECRET=$(rnd)|" \
        -e "s|^SYNCSTORAGE_DOMAIN=.*|SYNCSTORAGE_DOMAIN=${OLD_DOMAIN}|" -e "s|^CONTAINER_EXPORT_PORT=.*|CONTAINER_EXPORT_PORT=127.0.0.1:${PORT}|" \
        -e "s|^MARIADB_PASSWORD=.*|MARIADB_PASSWORD=$(rnd)|" "${DST}/.env"
    cat > "${DST}/migrate-test.yml" <<EOF
services:
  syncstorage:
    image: ${old_app}
    environment:
      SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL: http://mock_fxa:6000
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
  else
    old_app=ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-0.18.2
    old_init=ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-init-0.18.2
    need "${old_app}" "${old_init}" || exit 1
    sed -i -e "s|^MARIADB_TOKENSERVER_PASSWORD=.*|MARIADB_TOKENSERVER_PASSWORD=$(rnd)|" -e "s|^MARIADB_SYNCSTORAGE_PASSWORD=.*|MARIADB_SYNCSTORAGE_PASSWORD=$(rnd)|" \
        -e "s|^SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=$(rnd)|" -e "s|^METRICS_HASH_SECRET=.*|METRICS_HASH_SECRET=$(rnd)|" \
        -e "s|^SYNCSTORAGE_DOMAIN=.*|SYNCSTORAGE_DOMAIN=${OLD_DOMAIN}|" -e "s|^CONTAINER_EXPORT_PORT=.*|CONTAINER_EXPORT_PORT=127.0.0.1:${PORT}|" \
        -e "s|^MAX_USERS=.*|MAX_USERS=2|" -e "s|^SYNCSTORAGE_IMAGE_TAG=.*|SYNCSTORAGE_IMAGE_TAG=0.18.2|" \
        -e "s|^SYNCSTORAGE_INIT_IMAGE_TAG=.*|SYNCSTORAGE_INIT_IMAGE_TAG=0.18.2|" \
        -e "s|^FXA_OAUTH_SERVER_URL=.*|FXA_OAUTH_SERVER_URL=http://mock_fxa:6000|" "${DST}/.env"
    cat > "${DST}/migrate-test.yml" <<EOF
services:
  mock_fxa:
    image: ${TEST_IMAGE}
    entrypoint: ["sh", "/app/scripts/start_mock_fxa_server.sh"]
    environment:
      MOCK_FXA_SERVER_HOST: 0.0.0.0
      MOCK_FXA_SERVER_PORT: 6000
EOF
  fi
  # (the first .env-example has no newline at its end)
  sed -i -e '$a\' "${DST}/.env"
  printf '# tests/migrate.sh\nCOMPOSE_FILE=docker-compose.yml:migrate-test.yml\n' >> "${DST}/.env"
  echo "== old stack: firefox-sync at ${commit} (${old_app##*:})"
  dst up -d > "${WORK}/src-up.log" 2>&1
  check "$?" 0 "old stack up" || { tail -20 "${WORK}/src-up.log"; exit 1; }
  local init
  init=$(dst ps -a -q tokenserver_db_init)
  timeout 600 docker wait "${init}" > /dev/null
  check "$(docker inspect -f '{{.State.ExitCode}}' "${init}")" 0 "its init container"
  for _ in $(seq 1 120); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")" = 200 ] && break
    sleep 2
  done
  src_write "${DST_PROJECT}_default" http://syncstorage:8000
  local volumes_before
  volumes_before=$(docker volume ls -q --filter "label=com.docker.compose.project=${DST_PROJECT}" | sort | paste -sd' ')
  echo "  volumes: ${volumes_before}"

  echo "== upgrade in place (docs/upgrading.md#older-firefox-sync-releases, older firefox-sync releases)"
  # "Get the new files": this tree over the old one, the .env kept
  local f
  # (docker-compose.postgres.yml: old releases need the symlink copied too;
  # syncstorage-rs-init*: the init folders of the old release, now db/)
  for f in docker-compose.yml docker-compose.sync-postgres.yml docker-compose.postgres.yml docker-compose.sync-mysql.yml docker-compose.podman.yml docker-compose.fxa.yml docker-compose.fxa-mariadb.yml .env-example; do
    rm -f "${DST}/${f}" && cp -P "${CODE}/${f}" "${DST}/${f}"
  done
  rm -rf "${DST}/config" "${DST}/db" "${DST}/syncstorage-rs-init" "${DST}/syncstorage-rs-init-postgres"
  cp -r "${CODE}/config" "${CODE}/db" "${DST}/"
  mkdir -p "${DST}/tests" && cp "${TESTS}/docker-compose.migrate.yml" "${DST}/tests/"
  # "./prepare_environment.sh --upgrade": the old names of the settings renamed (the values
  # as they are), the passwords of the admin UI's database users. Before the lines of
  # .env-example: added first, their new names would hide the values under the old ones
  local renamed
  renamed=$(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" "${DST}/.env")
  cp "${CODE}/prepare_environment.sh" "${DST}/"
  (cd "${DST}" && ./prepare_environment.sh --upgrade) > "${WORK}/upgrade.log" 2>&1
  check "$? $(grep -cE '^ADMIN_DB_PASSWORD=[A-Za-z0-9]{32}$' "${DST}/.env")" "0 1" "./prepare_environment.sh --upgrade sets ADMIN_DB_PASSWORD" || cat "${WORK}/upgrade.log"
  check "$(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" "${DST}/.env") $(grep -c '^  [A-Z_]* -> [A-Z_]*$' "${WORK}/upgrade.log")" "0 ${renamed}" \
    "./prepare_environment.sh --upgrade renames the ${renamed} old setting names of that .env" || cat "${WORK}/upgrade.log"
  # "Add the lines of .env-example that your .env lacks, with their default values"
  local key added=0
  while IFS= read -r line; do
    key=${line%%=*}
    grep -q "^${key}=" "${DST}/.env" || { echo "${line}" >> "${DST}/.env"; added=$((added + 1)); }
  done < <(grep -E '^[A-Z_]+=' "${CODE}/.env-example")
  echo "  ${added} lines added from .env-example"
  if [ "${kind}" = first ]; then
    # the first release: one user and password for both databases, no MAX_USERS
    local user pass
    user=$(sed -n 's/^MARIADB_USER=//p' "${DST}/.env") pass=$(sed -n 's/^MARIADB_PASSWORD=//p' "${DST}/.env")
    sed -i -e "s|^SYNC_TOKENSERVER_DB_USER=.*|SYNC_TOKENSERVER_DB_USER=${user}|" -e "s|^SYNC_STORAGE_DB_USER=.*|SYNC_STORAGE_DB_USER=${user}|" \
        -e "s|^SYNC_TOKENSERVER_DB_PASSWORD=.*|SYNC_TOKENSERVER_DB_PASSWORD=${pass}|" -e "s|^SYNC_STORAGE_DB_PASSWORD=.*|SYNC_STORAGE_DB_PASSWORD=${pass}|" \
        -e "s|^SYNC_MAX_USERS=.*|SYNC_MAX_USERS=2|" "${DST}/.env"
  fi
  # the images under test instead of the published ones, the admin UI, the mock FxA
  sed -i -e "s|^IMAGE_REPOSITORY=.*|IMAGE_REPOSITORY=${REPOSITORY}|" -e "s|^SYNC_IMAGE_TAG=.*|SYNC_IMAGE_TAG=${TAG}|" \
      -e "s|^SYNC_INIT_IMAGE_TAG=.*|SYNC_INIT_IMAGE_TAG=${TAG}|" \
      -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$(rnd)|" -e "s|^ADMIN_EXPORT_PORT=.*|ADMIN_EXPORT_PORT=127.0.0.1:$((PORT + 20))|" \
      -e "s|^FXA_SMTP_HOST=.*|FXA_SMTP_HOST=|" -e "/^COMPOSE_FILE=/d" -e "/^# tests\/migrate.sh/d" "${DST}/.env"
  sed -i "/^FXA_OAUTH_SERVER_URL=/d" "${DST}/.env"
  echo "COMPOSE_PROFILES=admin" >> "${DST}/.env"
  dst_test_env docker-compose.yml
  sed -i "/^COMPOSE_PROJECT_NAME=/d" "${DST}/.env"
  DST_DB=mariadb
  # docker compose pull would replace the init image built from this tree with the published one
  local init_image=${REPOSITORY}:syncstorage-rs-mysql-init-${TAG} init_id
  init_id=$(docker image inspect -f '{{.Id}}' "${init_image}" 2> /dev/null)
  cd "${DST}" || exit 1
  guide "docker compose pull && docker compose up -d" > "${WORK}/up.log" 2>&1
  check "$?" 0 "docker compose pull && docker compose up -d" || tail -20 "${WORK}/up.log"
  if [ -n "${init_id}" ] && [ "$(docker image inspect -f '{{.Id}}' "${init_image}")" != "${init_id}" ]; then
    docker tag "${init_id}" "${init_image}"
    docker compose up -d > /dev/null 2>&1
  fi
  cd - > /dev/null || exit 1
  check "$(wait_init)" 0 "init container exit code"
  check "$(state syncstorage_migrate ExitCode)" 0 "migrations of the newer syncstorage-rs"
  check "$(docker volume ls -q --filter "label=com.docker.compose.project=${DST_PROJECT}" | grep -E 'tokenserver-db|syncstorage-db' | sort | paste -sd' ')" \
    "$(echo "${volumes_before}" | tr ' ' '\n' | grep -E 'tokenserver-db|syncstorage-db' | paste -sd' ')" "the same volumes"
  dst_verify "${OLD_DOMAIN}"
  [ -n "${old_init}" ] && PULLED+=("${old_init}")
}

# ---------- run ----------

docker image inspect "${TEST_IMAGE}" > /dev/null 2>&1 || need "${TEST_IMAGE}" || exit 1
if ! docker image inspect "${ADMIN_IMAGE}" > /dev/null 2>&1; then
  ADMIN_IMAGE=${ADMIN_IMAGE} COMPOSE_BAKE=false one_at_a_time admin-build docker compose -p ffs-admin-build -f "${TESTS}/docker-compose.admin-build.yml" build -q \
    || { fail "admin UI image built from admin/"; exit 1; }
fi
echo "== ${SCENARIO} (firefox-sync: ${REPOSITORY} ${TAG})"
case ${SCENARIO} in
  upstream-mysql) scenario_upstream_mysql mariadb ;;
  upstream-mysql-to-mysql) scenario_upstream_mysql mysql ;;
  upstream-mysql-testsetup) scenario_upstream_mysql_testsetup ;;
  upstream-postgres) scenario_upstream_postgres ;;
  upstream-postgres-2db) scenario_upstream_postgres_2db ;;
  dan-r) scenario_dan_r ;;
  jeena) scenario_jeena ;;
  nixos-mysql) scenario_nixos mysql ;;
  nixos-postgres) scenario_nixos postgres ;;
  yunohost) scenario_yunohost ;;
  firefox-sync-2024-12) scenario_firefox_sync_old 4705bda dec2024 ;;
  firefox-sync-2024-07) scenario_firefox_sync_old 7f52fa0 first ;;
  *) echo "unknown scenario ${SCENARIO}"; exit 2 ;;
esac
[ ${FAILED} = 0 ] && echo "RESULT ${SCENARIO}: all checks passed" || echo "RESULT ${SCENARIO}: some checks FAILED"
exit ${FAILED}
