#!/bin/bash
# End-to-end test of the firefox-sync stack (docker compose), isolated from anything
# else running on the host: own compose project, loopback-only port, own volumes.
#
# Usage: tests/e2e.sh <mysql|postgres>
# Runs with the admin UI (COMPOSE_PROFILES=admin), with Mozilla's accounts (mock): Sync part only.
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
#   TEST_SUBNET     the stack's network, a /24 (default: 10.231.1.0/24 mysql, 10.231.2.0/24 postgres);
#                   its containers are in the upper half, the admin UI's trusted proxies, the
#                   gateway (the host) at .1 is not
set -u

BACKEND=${1:?usage: $0 <mysql|postgres>}
TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
PROJECT=ffs-e2e-${BACKEND}
WORK=$(mktemp -d)
ENV_FILE=${WORK}/${BACKEND}.env

case ${BACKEND} in
  mysql)    COMPOSE=${CODE}/docker-compose.yml;          PORT=${PORT:-28651}; NET=1 ;;
  postgres) COMPOSE=${CODE}/docker-compose.postgres.yml; PORT=${PORT:-28652}; NET=2 ;;
  *) echo "unknown backend ${BACKEND}"; exit 2 ;;
esac
# the admin UI trusts the X-Test-Email header of the containers (tests/docker-compose.test.yml),
# not of the gateway: what comes from the host
export TEST_SUBNET=${TEST_SUBNET:-10.231.${NET}.0/24}
export TEST_TRUSTED=${TEST_SUBNET%.0/24}.128/25 TEST_GATEWAY=${TEST_SUBNET%.0/24}.1

rnd() { tr -dc '[:alnum:]' < /dev/urandom | head -c 24; }
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
    -e "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=admin|" \
    -e "s|^ADMIN_EXPORT_PORT=.*|ADMIN_EXPORT_PORT=127.0.0.1:$((PORT + 20))|" \
    -e "s|^REPOSITORY=.*|REPOSITORY=${REPOSITORY}|" \
    -e "s|^SYNCSTORAGE_IMAGE=.*|SYNCSTORAGE_IMAGE=syncstorage-rs-${BACKEND}|" \
    -e "s|^SYNCSTORAGE_INIT_IMAGE=.*|SYNCSTORAGE_INIT_IMAGE=syncstorage-rs-${BACKEND}-init|" \
    -e "s|^SYNCSTORAGE_IMAGE_TAG=.*|SYNCSTORAGE_IMAGE_TAG=${TAG}|" \
    -e "s|^SYNCSTORAGE_INIT_IMAGE_TAG=.*|SYNCSTORAGE_INIT_IMAGE_TAG=${TAG}|" \
    -e "s|^FXA_EMAIL_DOMAIN=.*|FXA_EMAIL_DOMAIN=api-accounts.stage.mozaws.net|" \
    -e "s|^FXA_OAUTH_SERVER_URL=.*|FXA_OAUTH_SERVER_URL=http://mock_fxa:6000|" \
    -e "/^COMPOSE_FILE=/d" \
    -e "s|<REPLACE_WITH_SOMETHING_SECURE>|$(rnd)|" \
    -e "s|<REPLACE_WITH_[A-Z_]*>|placeholder.invalid|g" \
    "${CODE}/.env-example" > "${ENV_FILE}"
set -a; source "${ENV_FILE}"; set +a
# the admin UI under test: ADMIN_IMAGE as is (pulled when missing), or built from admin/
ADMIN_GIVEN=${ADMIN_IMAGE:-}
export ADMIN_IMAGE=${ADMIN_IMAGE:-ffs-admin:test}

dc() { docker compose -p "${PROJECT}" -f "${COMPOSE}" -f "${TESTS}/docker-compose.test.yml" --env-file "${ENV_FILE}" "$@"; }
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
  if [ "${BACKEND}" = mysql ]; then
    dc exec -T tokenserver_db mariadb -u"${MARIADB_TOKENSERVER_USER}" -p"${MARIADB_TOKENSERVER_PASSWORD}" "${MARIADB_TOKENSERVER_DATABASE}" -sN -e "$1" < /dev/null
  else
    dc exec -T postgres_db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DATABASE}" -tA -c "$1" < /dev/null
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
    -e PYTHONPATH=/app:/app/tools \
    -e PYTHONDONTWRITEBYTECODE=1 \
    --entrypoint /bin/sh syncstorage -c "cd /app && $1" < /dev/null
}
pytest_in_app() { in_app "python3 -m pytest -q -p no:cacheprovider $1 > /tmp/pytest.log 2>&1; rc=\$?; tail -25 /tmp/pytest.log; exit \$rc"; }

teardown() {
  [ -n "${KEEP:-}" ] && { echo "keeping stack ${PROJECT} (env: ${ENV_FILE})"; return; }
  echo "== teardown"
  dc down -v --remove-orphans > /dev/null 2>&1
  if [ -n "${CLEANUP_IMAGES:-}" ]; then
    docker rmi "${REPOSITORY}:syncstorage-rs-${BACKEND}-${TAG}" "${REPOSITORY}:syncstorage-rs-${BACKEND}-init-${TAG}" > /dev/null 2>&1
    [ -n "${ADMIN_GIVEN}" ] && docker rmi "${ADMIN_GIVEN}" > /dev/null 2>&1
    [ "${BACKEND}" = mysql ] && ! docker ps -a --format '{{.Image}}' | grep -qx 'mariadb:lts' && docker rmi mariadb:lts > /dev/null 2>&1
  fi
  rm -rf "${WORK}"
}
trap teardown EXIT

if [ -z "${ADMIN_GIVEN}" ]; then
  COMPOSE_BAKE=false docker compose -p ffs-admin-build -f "${TESTS}/docker-compose.admin-build.yml" build -q || { echo "FAIL: admin UI image built from admin/"; exit 1; }
fi
echo "== ${PROJECT}: pulling ${REPOSITORY} ${TAG}"
[ -n "${SKIP_PULL:-}" ] || dc pull -q || exit 1

echo "== fail closed: a failing init must keep syncstorage down"
printf 'services:\n  tokenserver_db_init:\n    entrypoint: ["/bin/false"]\n' > "${WORK}/fail-init.yml"
dc -f "${WORK}/fail-init.yml" up -d > /dev/null 2>&1
check "$(state syncstorage_migrate ExitCode)" 0 "migrations completed"
check "$(state syncstorage Running || echo false)" false "syncstorage not started when init fails"
check "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")" 000 "port not reachable when init fails"
dc down -v > /dev/null 2>&1

echo "== starting"
dc up -d > /dev/null 2>&1 || { dc logs; exit 1; }
check "$(wait_init)" 0 "init container exit code"
check "$(state syncstorage_migrate ExitCode)" 0 "migrate container exit code"
INIT_END=$(date -d "$(state tokenserver_db_init FinishedAt)" +%s%N)
APP_START=$(date -d "$(state syncstorage StartedAt)" +%s%N)
check "$([ "${APP_START}" -gt "${INIT_END}" ] && echo yes)" yes "syncstorage started only after the init finished"
check "$(hb)" 200 "/__heartbeat__"
dc logs syncstorage 2>&1 | grep -m1 "Server running"

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
for bad in lots initial: fixed:-1 2147483648; do
  set_env MAX_USERS "${bad}"
  check "$(rerun_init)" 1 "init container fails with MAX_USERS=${bad}"
done
check "$(dc logs tokenserver_db_init 2>&1 | grep -c "MAX_USERS='2147483648' is not valid")" 1 "init container says why"
check "$(max_users)" 1 "max users unchanged by a MAX_USERS not valid"

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

echo "== admin UI drops what is older than ADMIN_RETENTION_DAYS"
sql "INSERT INTO ffs_events (at, kind, detail) VALUES (1, 'test', 'old');" > /dev/null
sql "INSERT INTO ffs_metrics VALUES (60000, 'old.metric', 1, 0);" > /dev/null
# pruned on the first flush after the start (METRICS_FLUSH_SECONDS=5)
dc restart ffs-admin > /dev/null 2>&1
for _ in $(seq 1 30); do
  [ "$(sql "SELECT (SELECT COUNT(*) FROM ffs_events WHERE kind = 'test') + (SELECT COUNT(*) FROM ffs_metrics WHERE name = 'old.metric');")" = 0 ] && break
  sleep 1
done
check "$(sql "SELECT COUNT(*) FROM ffs_events WHERE kind = 'test';")" 0 "old events pruned"
check "$(sql "SELECT COUNT(*) FROM ffs_metrics WHERE name = 'old.metric';")" 0 "old metrics pruned"
# the Sync server restarts with the admin UI (restart: true), for the metrics
check "$(hb)" 200 "/__heartbeat__ after the admin UI restart"

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
health_events() { sql "SELECT COUNT(*) FROM ffs_events WHERE kind = 'health' AND detail LIKE '$1';"; }
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
if [ "${BACKEND}" = mysql ]; then
  # with several empty nodes the tokenserver orders them by LOG(0) (NULL), MySQL 8
  # (upstream CI) returns them in id order, MariaDB does not: this stack has one node
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

[ ${FAILED} = 0 ] && echo "RESULT ${BACKEND}: all checks passed" || echo "RESULT ${BACKEND}: some checks FAILED"
exit ${FAILED}
