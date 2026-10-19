#!/bin/bash
# Rootless podman test: docker compose on the Podman socket (MariaDB and PostgreSQL) and
# quadlets (MariaDB; MySQL rendered only), set up with prepare_environment.sh exactly like a user would.
# Needs rootless podman, docker compose (v2, no Docker daemon) and a systemd user session.
#
# Usage: tests/podman.sh
# Environment:
#   REPOSITORY  image repository (default: ghcr.io/porelli/firefox-sync)
#   TAG         tag suffix of both the app and init images (default: latest)
#   PORT        host port (default: 28660)
#   SLOT        runs next to each other on one host (tests/slot.sh): 1000 * SLOT added to the
#               ports (default 0). The Quadlets' units, containers and volumes have the names
#               of a user's install: one run of this test at a time per user in any case
#   INIT_TAG    tag suffix of the init images (default: TAG), e.g. ones built from this tree
#   SKIP_FXA    set to 1 to skip the quadlets with self-hosted accounts
#   FXA_DB      mysql (default) or mariadb: the accounts database of the quadlets with accounts
#   SYNC_DB     mariadb (default) or mysql: the Sync databases of the compose and quadlet phases
#               (MySQL, docker-compose.sync-mysql.yml and config/quadlet/sync-mysql/: compose as an
#               install from before on mysql:8, pinned by --upgrade; the quadlets on mysql:lts); the
#               MySQL quadlets are rendered and checked in any case
#   ADMIN_IMAGE     admin UI image to test, used as is, pulled when not here (default: built from admin/)
#   FXA_TEST_IMAGE  accounts image to test with the quadlets (a local one of podman used as it is), e.g.
#                   ghcr.io/porelli/firefox-sync:fxa-mono-v1.347.1, or a digest (default: REPOSITORY:fxa-mono-latest)
#   UPGRADE_FROM    a checkout of an earlier release (e.g. git worktree add /tmp/ffs-from <tag>):
#                   the quadlets (SYNC_DB=mariadb) start as an install of it, its files, admin UI
#                   and init image (built from it), then are upgraded to this tree as docs/upgrading.md#with-quadlets
#                   says for the Quadlets, and checked as a new install
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
# shellcheck source=tests/slot.sh
source "${TESTS}/slot.sh"
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
INIT_TAG=${INIT_TAG:-${TAG}}
PORT=${PORT:-$((28660 + SLOT_PORTS))}
# the admin UI, the sign-up gate, the accounts' pages and API
ADMIN_PORT=$((28690 + SLOT_PORTS)) GATE_PORT=$((28691 + SLOT_PORTS)) CONTENT_PORT=$((28630 + SLOT_PORTS)) AUTH_PORT=$((28600 + SLOT_PORTS))
WORK=$(mktemp -d)
export QUADLET_DIR=${WORK}/quadlets-unused  # replaced below for the quadlet phase
# the backup timer: a plain systemd unit
SYSTEMD_USER_DIR=${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user
FAILED=0
# compose_healthy, quadlets_healthy, health_parity: the healthchecks of the stack
# shellcheck source=tests/healthy.sh
source "${TESTS}/healthy.sh"

check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; fi; }
hb() {
  local c
  for _ in $(seq 1 90); do
    c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/__heartbeat__")
    [ "${c}" = 200 ] && break
    sleep 2
  done
  echo "${c}"
}
ctr() { podman ps -a -q --filter "label=com.docker.compose.service=$1" | head -1; }
started() { date -d "$(podman inspect -f "{{.State.$2}}" "$1" | sed 's/ +0000 UTC//; s/ [A-Z]*$//')" +%s%N; }

diagnose() {
  echo "---- diagnostics"
  [ -n "${1:-}" ] && tail -40 "$1"
  podman ps -a --format '{{.Names}} {{.Status}}'
  for c in $(podman ps -a --format '{{.Names}}'); do
    echo "---- ${c} (health: $(podman inspect -f '{{.State.Health.Status}}' "${c}" 2> /dev/null))"
    podman logs --tail 15 "${c}" 2>&1
  done
  systemctl --user list-timers --all --no-pager 2> /dev/null | head -10
}

podman --version
systemctl --user enable --now podman.socket > /dev/null 2>&1
export DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/podman/podman.sock
docker compose version
podman info --format 'rootless={{.Host.Security.Rootless}} selinux={{.Host.Security.SELinuxEnabled}} cgroups={{.Host.CgroupsVersion}}'

# a copy of the repository, configured by prepare_environment.sh
cp -r "${CODE}" "${WORK}/ffs" && cd "${WORK}/ffs" || exit 1
rm -f .env
# ports of its own, next to whatever else runs on this host
# (UPGRADE_FROM: a release from before the SYNC_ names, REPOSITORY and SYNCSTORAGE_INIT_IMAGE_TAG)
example() { sed -i -e "s|^IMAGE_REPOSITORY=.*|IMAGE_REPOSITORY=${REPOSITORY}|" -e "s|^REPOSITORY=.*|REPOSITORY=${REPOSITORY}|" \
       -e "s|^SYNC_INIT_IMAGE_TAG=.*|SYNC_INIT_IMAGE_TAG=${INIT_TAG}|" -e "s|^SYNCSTORAGE_INIT_IMAGE_TAG=.*|SYNCSTORAGE_INIT_IMAGE_TAG=${INIT_TAG}|" \
       -e "s|^ADMIN_EXPORT_PORT=.*|ADMIN_EXPORT_PORT=127.0.0.1:${ADMIN_PORT}|" \
       -e "s|^ADMIN_GATE_EXPORT_PORT=.*|ADMIN_GATE_EXPORT_PORT=127.0.0.1:${GATE_PORT}|" \
       -e "s|^ADMIN_METRICS_TOKEN=.*|ADMIN_METRICS_TOKEN=ffs-test-metrics-token|" \
       -e "s|^ADMIN_UPDATE_CHECK=.*|ADMIN_UPDATE_CHECK=false|" \
       -e "s|^ADMIN_PUBLIC_CHECK=.*|ADMIN_PUBLIC_CHECK=false|" \
       -e "s|^FXA_CONTENT_EXPORT_PORT=.*|FXA_CONTENT_EXPORT_PORT=127.0.0.1:${CONTENT_PORT}|" \
       -e "s|^FXA_AUTH_EXPORT_PORT=.*|FXA_AUTH_EXPORT_PORT=127.0.0.1:${AUTH_PORT}|" \
       -e "s|^FXA_PROFILE_EXPORT_PORT=.*|FXA_PROFILE_EXPORT_PORT=127.0.0.1:$((28611 + SLOT_PORTS))|" \
       -e "s|^FXA_PROFILE_STATIC_EXPORT_PORT=.*|FXA_PROFILE_STATIC_EXPORT_PORT=127.0.0.1:$((28612 + SLOT_PORTS))|" \
       -e "s|^FXA_PAIRING_EXPORT_PORT=.*|FXA_PAIRING_EXPORT_PORT=127.0.0.1:$((28658 + SLOT_PORTS))|" "$1/.env-example"; }
example .
# the admin UI under test, where compose and the quadlets look for it
if [ -n "${ADMIN_IMAGE:-}" ]; then
  { podman image exists "${ADMIN_IMAGE}" || podman pull -q "${ADMIN_IMAGE}" > build-admin.log 2>&1; } && podman tag "${ADMIN_IMAGE}" "${REPOSITORY}:admin-latest" >> build-admin.log 2>&1
else
  podman build -q --format docker -t "${REPOSITORY}:admin-latest" admin > build-admin.log 2>&1
fi
rc=$?; check "${rc}" 0 "admin UI image"; [ "${rc}" = 0 ] || tail -5 build-admin.log
# answers: domain, compose dir, port, max users, backend, deploy method, user, image tag, admin UI
setup() { printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 "$1" "$2" "" "${TAG}" "" | ./prepare_environment.sh > "setup-$1-$2.log" 2>&1; }
admin_up() {
  local c
  for _ in $(seq 1 30); do
    c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ADMIN_PORT}$1")
    [ "${c}" = 200 ] && break
    sleep 2
  done
  echo "${c}"
}
# the admin UI checks the components every 5 s here, as in the other tests
# (HEALTH_CHECK_SECONDS, a minute by default): what it sees is there within seconds, not at
# its next round a minute later. For compose an override (ADMIN_TEST_COMPOSE), for the
# Quadlets a line in the admin UI's unit once its checks are done (fast_admin_checks)
ADMIN_TEST_COMPOSE=(-f "${WORK}/admin-test.yml")
printf 'services:\n  ffs-admin:\n    environment:\n      HEALTH_CHECK_SECONDS: 5\n' > "${WORK}/admin-test.yml"
fast_admin_checks() {
  sed -i '/^\[Container\]$/a Environment=HEALTH_CHECK_SECONDS=5' "${QUADLET_DIR}/firefox-sync-admin.container" && systemctl --user daemon-reload
}
# Prometheus metrics of the admin UI, retried until they have every line given (its first
# check of the Quadlets runs before the Sync server is up; a check can take 10 s more on a
# timeout): "all", or the first missing
metrics_show() {
  local m line missing
  for _ in $(seq 1 75); do
    m=$(curl -s -H 'Authorization: Bearer ffs-test-metrics-token' http://127.0.0.1:${ADMIN_PORT}/metrics)
    missing=""
    for line in "$@"; do grep -qxF "${line}" <<< "${m}" || { missing=${line}; break; }; done
    [ -z "${missing}" ] && break
    sleep 2
  done
  echo "${missing:-all}"
}
SYNC_DB=${SYNC_DB:-mariadb}
case "${SYNC_DB}" in mariadb|mysql) ;; *) echo "SYNC_DB: mariadb or mysql"; exit 2 ;; esac
SYNC_UP=('ffs_up{component="Sync server"} 1' 'ffs_up{component="Tokenserver database"} 1')
# signed in with the default Secure cookie over plain http: curl, like browsers, keeps
# it for localhost
admin_sign_in() {
  local jar=${WORK}/cookies-$1
  curl -s -o /dev/null -c "${jar}" --data-urlencode "password=$(grep '^ADMIN_PASSWORD=' .env | cut -d= -f2)" http://localhost:${ADMIN_PORT}/login
  curl -s -b "${jar}" http://localhost:${ADMIN_PORT}/ | grep -q 'Sign out' && echo yes
}

env_of() { grep "^$1=" .env | cut -d= -f2; }
# SQL in the tokenserver database (MariaDB, MySQL, PostgreSQL), as the user given
compose_sql() { # backend user password database query
  if [ "$1" = postgres ]; then
    podman exec -e PGPASSWORD="$3" "$(ctr postgres_db)" psql -h 127.0.0.1 -U "$2" -d "$4" -tA -c "$5"
  else
    podman exec -e MYSQL_PWD="$3" "$(ctr tokenserver_db)" sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql -u"$2" "$4" -sN -e "$5"
  fi
}

compose_test() {
  local backend=$1 sync_user sync_password sync_db admin_password sync_role sync_role_password; shift
  echo "== docker compose on the Podman socket (${backend})"
  setup "${backend}" 2
  check "$?" 0 "prepare_environment.sh (${backend}, compose)"
  check "$(grep -c "docker compose $* up -d" "setup-${backend}-2.log")" 1 "prepare_environment.sh prints the compose command (${backend})"
  # first as an install from before ADMIN_DB_PASSWORD (the admin UI's tables in the
  # tokenserver database), then upgraded below
  admin_password=$(env_of ADMIN_DB_PASSWORD)
  check "$(echo "${admin_password}" | grep -cE '^[A-Za-z0-9]{32}$')" 1 "prepare_environment.sh generates ADMIN_DB_PASSWORD (${backend})"
  sed -i 's|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=|' .env
  # PostgreSQL: a new install is pinned to the major of postgres:latest; one from before ran 18
  # without SYNC_POSTGRES_IMAGE (--upgrade pins it below)
  if [ "${backend}" = postgres ]; then
    pg_major=$(podman run --rm --entrypoint postgres docker.io/library/postgres:latest --version 2> /dev/null | sed -n 's/^postgres (PostgreSQL) \([0-9]*\)[^0-9].*/\1/p')
    check "$(env_of SYNC_POSTGRES_IMAGE)" "postgres:${pg_major}" "prepare_environment.sh pins PostgreSQL to the major of postgres:latest (postgres, compose)"
    sed -i 's|^SYNC_POSTGRES_IMAGE=.*|SYNC_POSTGRES_IMAGE=postgres:18|' .env
  fi
  # MariaDB: a new install is on mariadb:lts; one from before ran it without SYNC_MARIADB_IMAGE
  if [ "${backend}" = mariadb ]; then
    check "$(env_of SYNC_MARIADB_IMAGE)" mariadb:lts "prepare_environment.sh writes SYNC_MARIADB_IMAGE=mariadb:lts (mariadb, compose)"
    sed -i '/^SYNC_MARIADB_IMAGE=/d' .env
  fi
  # MySQL: a new install is on mysql:lts; one from before ran mysql:8 without SYNC_MYSQL_IMAGE
  # (--upgrade pins it below)
  if [ "${backend}" = mysql ]; then
    check "$(env_of SYNC_MYSQL_IMAGE)" mysql:lts "prepare_environment.sh writes SYNC_MYSQL_IMAGE=mysql:lts (mysql, compose)"
    sed -i 's|^SYNC_MYSQL_IMAGE=.*|SYNC_MYSQL_IMAGE=mysql:8|' .env
  fi
  # PostgreSQL: before, the Sync server connected as SYNC_POSTGRES_USER, the container's superuser
  sync_role=$(env_of SYNC_POSTGRES_APP_USER) sync_role_password=$(env_of SYNC_POSTGRES_APP_PASSWORD)
  if [ "${backend}" = postgres ]; then
    check "${sync_role} $(echo "${sync_role_password}" | grep -cE '^[A-Za-z0-9]{32}$')" "syncserver_app 1" "prepare_environment.sh gives the Sync server a role of its own (postgres)"
    sed -i -e 's|^SYNC_POSTGRES_APP_USER=.*|SYNC_POSTGRES_APP_USER=|' -e 's|^SYNC_POSTGRES_APP_PASSWORD=.*|SYNC_POSTGRES_APP_PASSWORD=|' .env
  fi
  if [ "${backend}" = postgres ]; then
    sync_user=$(env_of SYNC_POSTGRES_USER) sync_password=$(env_of SYNC_POSTGRES_PASSWORD) sync_db=$(env_of SYNC_POSTGRES_NAME)
  else
    sync_user=$(env_of SYNC_TOKENSERVER_DB_USER) sync_password=$(env_of SYNC_TOKENSERVER_DB_PASSWORD) sync_db=$(env_of SYNC_TOKENSERVER_DB_NAME)
  fi
  # and from before the SYNC_ names of the settings (docs/upgrading.md#renamed-settings): the old
  # ones only, which compose still reads
  local pair old_lines
  for pair in "${RENAMED_SETTINGS[@]}"; do sed -i "s|^${pair%%=*}=|${pair#*=}=|" .env; done
  old_lines=$(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" .env)
  timeout 600 docker compose "$@" "${ADMIN_TEST_COMPOSE[@]}" up -d > "compose-${backend}.log" 2>&1
  check "$?" 0 "docker compose up, before ADMIN_DB_PASSWORD, with the old setting names (${backend})"
  check "$(podman logs "$(ctr tokenserver_db_init)" 2>&1 | grep -c 'WARNING: settings under their old names, in .env or in the environment docker compose runs in')" 1 "the init container warns of the old setting names (${backend})"
  check "$(admin_up /login)" 200 "admin UI before ADMIN_DB_PASSWORD (compose, ${backend})"
  compose_sql "${backend}" "${sync_user}" "${sync_password}" "${sync_db}" \
    "INSERT INTO ffs_events (at, kind, detail) VALUES ($(date +%s)000, 'admin', 'ffs-podman: before the upgrade by admin (password)')" > /dev/null
  check "$?" 0 "an audit event in the tokenserver database, as before (${backend})"
  # an install from before docker-compose.sync-postgres.yml had the old name in COMPOSE_FILE
  [ "${backend}" = postgres ] && sed -i 's|^COMPOSE_FILE=docker-compose.sync-postgres.yml$|COMPOSE_FILE=docker-compose.postgres.yml|' .env
  [ "${backend}" != mysql ] || sed -i '/^SYNC_MYSQL_IMAGE=/d' .env
  # (the old names left, as counted for the rename below)
  if [ "${backend}" = postgres ]; then
    sed -i '/^\(SYNC_\)\{0,1\}POSTGRES_IMAGE=/d' .env
    old_lines=$(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" .env)
  fi
  # the upgrade, as docs/upgrading.md#with-docker-compose says: prepare_environment.sh --upgrade fills in what is missing
  ./prepare_environment.sh --upgrade > "upgrade-${backend}.log" 2>&1
  check "$?" 0 "prepare_environment.sh --upgrade (${backend})"
  check "$(grep -cE "^($(IFS='|'; echo "${RENAMED_SETTINGS[*]#*=}"))=" .env) $(grep -c '^Renamed in .env' "upgrade-${backend}.log") $(grep -c '^  [A-Z_]* -> [A-Z_]*$' "upgrade-${backend}.log")" \
    "0 1 ${old_lines}" "--upgrade renames the old setting names, and says so (${backend})"
  [ "${backend}" != postgres ] || check "$(grep -cx 'COMPOSE_FILE=docker-compose.sync-postgres.yml' .env) $(grep -c '^COMPOSE_FILE: docker-compose.postgres.yml renamed to docker-compose.sync-postgres.yml' "upgrade-${backend}.log")" \
    "1 1" "--upgrade renames docker-compose.postgres.yml in COMPOSE_FILE, and says so (postgres)"
  check "$(env_of ADMIN_DB_PASSWORD | grep -cE '^[A-Za-z0-9]{32}$') $([ "${backend}" != postgres ] || env_of SYNC_POSTGRES_APP_USER)" \
    "1 $([ "${backend}" != postgres ] || echo syncserver_app)" "--upgrade generates the missing passwords (${backend})"
  [ "${backend}" != postgres ] || check "$(env_of SYNC_POSTGRES_IMAGE)" "postgres:18" "--upgrade writes SYNC_POSTGRES_IMAGE=postgres:18 for PostgreSQL (postgres)"
  [ "${backend}" != mysql ] || check "$(env_of FXA_DB | grep -c mariadb)" "0" "no FXA_MARIADB_IMAGE for MariaDB backend without accounts (${backend})"
  # MariaDB: an install from before SYNC_MARIADB_IMAGE, pinned to the major of its data
  if [ "${backend}" = mariadb ]; then
    mariadb_major=$(podman exec "$(ctr tokenserver_db)" mariadbd --version 2> /dev/null | sed -n 's/.* Ver \([0-9]*\)\..*/\1/p')
    check "$(env_of SYNC_MARIADB_IMAGE) $(grep -c "Sync databases stay on MariaDB ${mariadb_major}," "upgrade-${backend}.log")" "mariadb:${mariadb_major} 1" \
      "--upgrade pins the Sync MariaDB of an install from before to the major of its data (mariadb)"
  fi
  [ "${backend}" != mysql ] || check "$(env_of SYNC_MYSQL_IMAGE) $(grep -c 'Sync databases stay on MySQL 8' "upgrade-${backend}.log") $(env_of FXA_MYSQL_IMAGE)" "mysql:8 1 " \
    "--upgrade pins the Sync databases of an install from before on MySQL 8, nothing for the accounts it has not (mysql)"
  admin_password=$(env_of ADMIN_DB_PASSWORD)
  timeout 600 docker compose "$@" "${ADMIN_TEST_COMPOSE[@]}" up -d >> "compose-${backend}.log" 2>&1
  check "$?" 0 "docker compose up (${backend})"
  check "$(hb)" 200 "/__heartbeat__ (compose, ${backend})"
  check "$(podman inspect -f '{{.State.ExitCode}}' "$(ctr syncstorage_migrate)")" 0 "migrate container exit code (${backend})"
  check "$(podman inspect -f '{{.State.ExitCode}}' "$(ctr tokenserver_db_init)")" 0 "init container exit code (${backend})"
  check "$([ "$(started "$(ctr syncstorage)" StartedAt)" -gt "$(started "$(ctr tokenserver_db_init)" FinishedAt)" ] && echo yes)" yes \
    "syncstorage started after the init (compose, ${backend})"
  check "$(admin_up /login)" 200 "admin UI (compose, ${backend})"
  check "$(admin_sign_in "${backend}")" yes "admin UI sign-in over http://localhost (compose, ${backend})"
  if [ "${backend}" != postgres ]; then
    check "$(metrics_show "${SYNC_UP[@]}" 'ffs_up{component="Storage database"} 1')" all "admin UI reaches the Sync server and its databases (compose, ${backend})"
  else
    check "$(metrics_show "${SYNC_UP[@]}")" all "admin UI reaches the Sync server and its database (compose, ${backend})"
  fi
  # (once more, restarted with the admin UI of the upgrade)
  check "$([ "$(podman logs "$(ctr syncstorage)" 2>&1 | grep -c 'Sending metrics to the admin UI')" -ge 1 ] && echo yes)" yes "Sync server sends metrics to the admin UI (compose, ${backend})"
  # the upgrade moved the event log into the admin UI's own database, out of the Sync user's reach
  admin_events() { compose_sql "${backend}" "$(env_of ADMIN_DB_USER)" "${admin_password}" "$(env_of ADMIN_DB_NAME)" "SELECT COUNT(*) FROM ffs_events WHERE detail LIKE '$1'"; }
  for _ in $(seq 1 30); do [ "$(admin_events 'ffs-podman: before the upgrade%' 2> /dev/null)" = 1 ] && break; sleep 2; done
  check "$(admin_events 'ffs-podman: before the upgrade%') $(admin_events 'Moved the admin UI%')" "1 1" "the audit trail of before moved into the admin UI's database (compose, ${backend})"
  check "$([ "$(admin_events '%')" -gt 2 ] && echo yes)" yes "the admin UI records its events there (compose, ${backend})"
  if [ "${backend}" = postgres ]; then
    # the Sync server's own role, no superuser, owns the Sync tables and cannot reach ffs_admin
    sync_role=$(env_of SYNC_POSTGRES_APP_USER) sync_role_password=$(env_of SYNC_POSTGRES_APP_PASSWORD)
    check "$(compose_sql postgres "${sync_role}" "${sync_role_password}" "${sync_db}" "SELECT rolsuper || ' ' || (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname = 'users' AND relnamespace = 'public'::regnamespace) FROM pg_roles WHERE rolname = current_user")" \
      "false ${sync_role}" "the Sync server's role is no superuser and owns the Sync tables (compose, postgres)"
    check "$(compose_sql postgres "${sync_role}" "${sync_role_password}" "$(env_of ADMIN_DB_NAME)" "SELECT 1" 2>&1 | grep -c 'permission denied')" 1 \
      "the Sync server's role cannot connect to the admin UI's database (compose, postgres)"
    check "$(compose_sql postgres "$(env_of ADMIN_DB_USER)" "${admin_password}" "$(env_of ADMIN_DB_NAME)" "SELECT pg_get_userbyid(datdba) || ' ' || has_database_privilege('public', datname, 'CONNECT') FROM pg_database WHERE datname = current_database()")" \
      "$(env_of ADMIN_DB_USER) false" "the admin UI's database is its role's, closed to PUBLIC (compose, postgres)"
  else
    check "$(compose_sql "${backend}" "${sync_user}" "${sync_password}" "${sync_db}" "SELECT COUNT(*) FROM $(env_of ADMIN_DB_NAME).ffs_events" 2>&1 | grep -c 'denied')" 1 \
      "the tokenserver user cannot read the event log (compose, ${backend})"
    check "$(compose_sql "${backend}" "${sync_user}" "${sync_password}" "${sync_db}" "INSERT INTO $(env_of ADMIN_DB_NAME).ffs_events (at, kind, detail) VALUES (1, 'admin', 'forged')" 2>&1 | grep -c 'denied')" 1 \
      "the tokenserver user cannot write the event log (compose, ${backend})"
  fi
  podman logs "$(ctr tokenserver_db_init)" 2>&1 | grep -E "Max users|ERROR"
  check "$(compose_healthy 300 docker compose "$@" "${ADMIN_TEST_COMPOSE[@]}")" "all healthy" "every long-running container healthy, the one-shot ones exited 0 (compose, ${backend})"
  [ "${FAILED}" = 0 ] || diagnose "compose-${backend}.log"
  docker compose "$@" "${ADMIN_TEST_COMPOSE[@]}" down -v > /dev/null 2>&1
}
if [ "${SYNC_DB}" = mysql ]; then
  compose_test mysql -f docker-compose.yml -f docker-compose.podman.yml -f docker-compose.sync-mysql.yml
else
  compose_test mariadb -f docker-compose.yml -f docker-compose.podman.yml
fi
compose_test postgres -f docker-compose.sync-postgres.yml

echo "== quadlets with PostgreSQL: docker compose instead"
rm -f .env
setup postgres 1
check "$?" 0 "prepare_environment.sh (postgres, quadlets)"
check "$(grep -c 'Quadlets are only provided for MariaDB' setup-postgres-1.log) $(grep -c 'docker compose -f docker-compose.sync-postgres.yml up -d' setup-postgres-1.log) $(ls "${QUADLET_DIR}" 2> /dev/null | wc -l)" \
  "1 1 0" "quadlets with PostgreSQL fall back to docker compose, no quadlet files"

# the admin UI quadlet gets every setting of the compose ffs-admin service: the keys
# only in compose (allowed: $2, a regex), then those only in the quadlet
compose_env_keys() { docker compose --profile admin "$@" config --format json 2> /dev/null | jq -r '.services["ffs-admin"].environment | keys[]' | LC_ALL=C sort; }
quadlet_env_keys() { sed -nE 's/^Environment="?([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$1" | LC_ALL=C sort -u; }
env_keys_diff() {
  local compose quadlet
  compose=$(compose_env_keys $1) quadlet=$(quadlet_env_keys "${QUADLET_DIR}/firefox-sync-admin.container")
  [ -n "${compose}" ] || { echo "no compose environment"; return; }
  echo "$(LC_ALL=C comm -23 <(echo "${compose}") <(echo "${quadlet}") | grep -vxE "$2" | paste -sd' ')|$(LC_ALL=C comm -13 <(echo "${compose}") <(echo "${quadlet}") | paste -sd' ')"
}

echo "== quadlets (${SYNC_DB})"
export QUADLET_DIR=${HOME}/.config/containers/systemd
if [ -n "${UPGRADE_FROM:-}" ]; then
  echo "== first the quadlets of ${UPGRADE_FROM}, then upgraded as docs/upgrading.md#with-quadlets says"
  [ "${SYNC_DB}" = mariadb ] || { echo "UPGRADE_FROM is for SYNC_DB=mariadb"; exit 2; }
  FROM=${WORK}/from
  cp -r "${UPGRADE_FROM}" "${FROM}" && rm -f "${FROM}/.env" && example "${FROM}" || exit 1
  # that release's admin UI and init image under the names of the units, this tree's aside
  INIT_IMAGE=${REPOSITORY}:syncstorage-rs-mysql-init-${INIT_TAG}
  # (releases before db/: syncstorage-rs-init)
  INIT_DIR=${FROM}/db/mysql/init; [ -d "${INIT_DIR}" ] || INIT_DIR=${FROM}/syncstorage-rs-init
  podman tag "${REPOSITORY}:admin-latest" localhost/ffs-admin:upgrade-to && podman tag "${INIT_IMAGE}" localhost/ffs-init:upgrade-to &&
    podman build -q --format docker -t "${REPOSITORY}:admin-latest" "${FROM}/admin" > build-from.log 2>&1 &&
    podman build -q -t "${INIT_IMAGE}" "${INIT_DIR}" >> build-from.log 2>&1
  check "$?" 0 "the admin UI and init images of ${UPGRADE_FROM}"
  (cd "${FROM}" && setup mariadb 1)
  check "$?" 0 "its prepare_environment.sh (quadlets)"
  timeout 900 systemctl --user start firefox-sync-syncstorage.service
  check "$?" 0 "its units started (quadlets)"
  check "$(hb) $(admin_up /login)" "200 200" "its Sync server and admin UI (quadlets)"
  # (a release from before the SYNC_ names: the old one)
  from_env() {
    local pair v
    v=$(grep "^$1=" "${FROM}/.env" | cut -d= -f2)
    for pair in "${RENAMED_SETTINGS[@]}"; do
      [ -z "${v}" ] && [ "${pair%%=*}" = "$1" ] && v=$(grep "^${pair#*=}=" "${FROM}/.env" | cut -d= -f2)
    done
    echo "${v}"
  }
  from_ts_sql() { podman exec -e MYSQL_PWD="$(from_env SYNC_TOKENSERVER_DB_PASSWORD)" firefox-sync-tokenserver-db \
    mariadb -u"$(from_env SYNC_TOKENSERVER_DB_USER)" "$(from_env SYNC_TOKENSERVER_DB_NAME)" -sN -e "$1"; }
  for _ in $(seq 1 30); do [ "$(from_ts_sql 'SELECT COUNT(*) FROM ffs_events' 2> /dev/null)" -gt 0 ] 2> /dev/null && break; sleep 2; done
  from_ts_sql "INSERT INTO ffs_events (at, kind, detail) VALUES ($(date +%s)000, 'admin', 'ffs-podman: before the Quadlet upgrade by admin (password)')"
  check "$?" 0 "an audit event in the tokenserver database, as before (quadlets)"
  # the upgrade: the units stopped, the one-shot ones too, as docs/upgrading.md#with-quadlets says
  STOP='systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service'
  check "$(grep -cF "\`${STOP}\`" "${CODE}/docs/upgrading.md")" 1 "docs/upgrading.md says \`${STOP}\`"
  timeout 300 ${STOP}
  # (the images of this tree are local: what docs/upgrading.md#with-quadlets pulls is here already)
  podman tag localhost/ffs-admin:upgrade-to "${REPOSITORY}:admin-latest" && podman tag localhost/ffs-init:upgrade-to "${INIT_IMAGE}"
  podman rmi localhost/ffs-admin:upgrade-to localhost/ffs-init:upgrade-to > /dev/null 2>&1
fi
setup "${SYNC_DB}" 1
check "$?" 0 "prepare_environment.sh (quadlets)"
# the healthchecks of compose, those of the Quadlets (as rendered from .env)
sync_compose=(-f docker-compose.yml)
[ "${SYNC_DB}" = mysql ] && sync_compose+=(-f docker-compose.sync-mysql.yml)
check "$(health_parity "${QUADLET_DIR}" docker compose --profile admin --profile backup "${sync_compose[@]}")" same "every long-running service has a healthcheck, the Quadlets compose's (${SYNC_DB})"
check "$(grep -l '%[A-Z_]*%' "${QUADLET_DIR}"/firefox-sync-* | wc -l)" 0 "no unreplaced placeholders in quadlets"
# with the admin UI, SYNC_MAX_USERS=initial:1: the init container and the admin UI both get it
check "$(grep -hcxF 'Environment=MAX_USERS=initial:1' "${QUADLET_DIR}/firefox-sync-tokenserver-db-init.container") $(grep -hcxF 'Environment="MAX_USERS=initial:1"' "${QUADLET_DIR}/firefox-sync-admin.container")" "1 1" \
  "SYNC_MAX_USERS=initial:1 in the init and admin UI quadlets"
# without the accounts: not their settings, nor those of the sign-up gate and of the unconfirmed accounts
# nor the Sync users' passwords: the Quadlets always have ADMIN_DB_PASSWORD, compose only passes them without it
check "$(env_keys_diff "-f docker-compose.yml" 'FXA_.*|ADMIN_SIGNUP_BURST|ADMIN_DELETE_UNCONFIRMED_DAYS|TOKENSERVER_DB_PASSWORD|STORAGE_DB_PASSWORD|FFS_OLD_ENV_NAMES')" "|" "admin quadlet passes every setting of the compose service"
check "$(grep -cE '^Environment="(TOKENSERVER|STORAGE)_DB_PASSWORD=' "${QUADLET_DIR}/firefox-sync-admin.container") $(grep -cE '^Environment="ADMIN_DB_PASSWORD=[A-Za-z0-9]{32}"$' "${QUADLET_DIR}/firefox-sync-admin.container")" \
  "0 1" "the admin UI quadlet has its own database password, none of the Sync users"
# the help of the backups on the overview: their time, how many, the Quadlets' commands
check "$(grep -cxE 'Environment="(BACKUP_TIME=03:00|BACKUP_KEEP=7|ADMIN_DEPLOYMENT=quadlets)"' "${QUADLET_DIR}/firefox-sync-admin.container")" 3 \
  "BACKUP_TIME, BACKUP_KEEP and ADMIN_DEPLOYMENT=quadlets in the admin UI quadlet"
QUADLET=$(ls /usr/libexec/podman/quadlet /usr/lib/podman/quadlet 2> /dev/null | head -1)
"${QUADLET}" -dryrun -user > quadlet-dryrun.log 2>&1
check "$?" 0 "quadlet generator accepts the files"
if [ -n "${UPGRADE_FROM:-}" ]; then
  # docs/upgrading.md#with-quadlets: the database containers (they create the admin UI's users with the new
  # ADMIN_DB_PASSWORD), then the Sync users' new passwords, as the old ones
  timeout 300 systemctl --user start firefox-sync-tokenserver-db.service firefox-sync-syncstorage-db.service
  for db in TOKENSERVER STORAGE; do
    container=firefox-sync-$([ "${db}" = STORAGE ] && echo syncstorage || echo tokenserver)-db
    for _ in $(seq 1 30); do
      podman exec "${container}" mariadb -u"$(from_env "SYNC_${db}_DB_USER")" -p"$(from_env "SYNC_${db}_DB_PASSWORD")" \
        -e "SET PASSWORD = PASSWORD('$(env_of "SYNC_${db}_DB_PASSWORD")')" > /dev/null 2>&1 && ok=0 && break
      ok=1
      sleep 2
    done
    check "${ok}" 0 "the new password of the ${db} user (quadlets upgraded)"
  done
fi
# the journal keeps earlier runs
fast_admin_checks
QUADLET_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
timeout 900 systemctl --user start firefox-sync-syncstorage.service
check "$?" 0 "systemctl --user start firefox-sync-syncstorage.service"
for u in syncstorage-db tokenserver-db syncstorage-migrate tokenserver-db-init syncstorage; do
  printf '  %-22s %s\n' "${u}" "$(systemctl --user is-active "firefox-sync-${u}.service")"
done
check "$(hb)" 200 "/__heartbeat__ (quadlets)"
check "$(podman inspect -f '{{.EffectiveCaps}}' firefox-sync-syncstorage | grep -c NET_RAW) $(grep -hcxF 'DropCapability=NET_RAW' "${QUADLET_DIR}"/firefox-sync-syncstorage{,-migrate}.container | paste -sd' ')" \
  "0 1 1" "the Sync server and its migrations without raw sockets (quadlets)"
journalctl --user -u firefox-sync-syncstorage-migrate.service --no-pager 2> /dev/null | grep -m1 "Migrations completed"
journalctl --user -u firefox-sync-tokenserver-db-init.service --no-pager 2> /dev/null | grep -m1 "Max users"
INIT_END=$(systemctl --user show -p ExecMainExitTimestampMonotonic --value firefox-sync-tokenserver-db-init.service)
APP_START=$(systemctl --user show -p ExecMainStartTimestampMonotonic --value firefox-sync-syncstorage.service)
check "$([ "${APP_START}" -gt "${INIT_END}" ] && echo yes)" yes "syncstorage started after the init (quadlets)"
# started with the Sync server (Wants=), before it
check "$(systemctl --user is-active firefox-sync-admin.service)" active "admin UI started with the Sync server (quadlets)"
check "$(admin_up /login)" 200 "admin UI (quadlets)"
check "$(journalctl --user -u firefox-sync-syncstorage.service --since "${QUADLET_SINCE}" --no-pager 2> /dev/null | grep -c 'Sending metrics to the admin UI')" 1 \
  "Sync server sends metrics to the admin UI (quadlets)"
check "$(admin_sign_in quadlets)" yes "admin UI sign-in over http://localhost (quadlets)"
check "$(metrics_show "${SYNC_UP[@]}" 'ffs_up{component="Storage database"} 1')" all "admin UI reaches the Sync server and its databases (quadlets)"
check "$(podman healthcheck run firefox-sync-admin > /dev/null 2>&1; echo $?)" 0 "admin UI healthcheck (quadlets)"
# a new admin UI container restarts the Sync server, which resolves ffs-admin once
SYNC_PID=$(systemctl --user show -p MainPID --value firefox-sync-syncstorage.service)
timeout 300 systemctl --user restart firefox-sync-admin.service
for _ in $(seq 1 30); do
  pid=$(systemctl --user show -p MainPID --value firefox-sync-syncstorage.service)
  [ "${pid}" != "${SYNC_PID}" ] && [ "${pid}" != 0 ] && break
  sleep 2
done
check "$([ "${pid}" != "${SYNC_PID}" ] && echo yes)" yes "Sync server restarted with the admin UI (quadlets)"
check "$(hb)" 200 "/__heartbeat__ after the admin UI restart (quadlets)"
# backups: the timer installed, off until enabled; a run by hand
# the database container's own client (mariadb, or mysql in the MySQL image)
ts_sql() { podman exec -e MYSQL_PWD="$(grep '^SYNC_TOKENSERVER_DB_PASSWORD=' .env | cut -d= -f2)" firefox-sync-tokenserver-db \
  sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql -u"$(grep '^SYNC_TOKENSERVER_DB_USER=' .env | cut -d= -f2)" "$(grep '^SYNC_TOKENSERVER_DB_NAME=' .env | cut -d= -f2)" -sN -e "$1"; }
# the admin UI's own database (the event log, the backup runs), as its user
admin_db_sql() { podman exec -e MYSQL_PWD="$(env_of ADMIN_DB_PASSWORD)" firefox-sync-tokenserver-db \
  sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql -u"$(env_of ADMIN_DB_USER)" "$(env_of ADMIN_DB_NAME)" -sN -e "$1"; }
check "$([ "$(admin_db_sql "SELECT COUNT(*) FROM ffs_events")" -gt 0 ] && echo yes) $(ts_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 'ffs\\_%'")" \
  "yes 0" "the admin UI records its events in its own database, none in the tokenserver's (quadlets)"
[ -z "${UPGRADE_FROM:-}" ] || check "$(admin_db_sql "SELECT COUNT(*) FROM ffs_events WHERE detail = 'ffs-podman: before the Quadlet upgrade by admin (password)' OR detail LIKE 'Moved the admin UI%'")" 2 \
  "the audit trail of ${UPGRADE_FROM} moved into the admin UI's database (quadlets upgraded)"
check "$(ts_sql "SELECT COUNT(*) FROM $(env_of ADMIN_DB_NAME).ffs_events" 2>&1 | grep -c denied)" 1 "the tokenserver user cannot read the event log (quadlets)"
# the admin UI's reader of the Sync data: the tokenserver database, not the event log
reader_sql() { podman exec -e MYSQL_PWD="$(env_of ADMIN_DB_PASSWORD)" "$1" sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql \
  -u"$(env_of ADMIN_DB_SYNC_USER)" -sN -e "$2"; }
check "$(reader_sql firefox-sync-tokenserver-db "SELECT COUNT(*) > 0 FROM $(env_of SYNC_TOKENSERVER_DB_NAME).nodes") $(reader_sql firefox-sync-tokenserver-db "SELECT COUNT(*) FROM $(env_of ADMIN_DB_NAME).ffs_events" 2>&1 | grep -c denied) $(reader_sql firefox-sync-syncstorage-db "SELECT COUNT(*) >= 0 FROM $(env_of SYNC_STORAGE_DB_NAME).bso")" \
  "1 1 1" "the admin UI's reader reads the Sync databases, not the event log (quadlets)"
check "$(grep -c '^OnCalendar=\*-\*-\* 03:00:00 UTC$' "${SYSTEMD_USER_DIR}/firefox-sync-backup.timer" 2> /dev/null) $(systemctl --user is-enabled firefox-sync-backup.timer 2> /dev/null)" "1 disabled" \
  "backup timer installed, not enabled (quadlets)"
check "$(systemctl --user show -p Triggers --value firefox-sync-backup.timer)" firefox-sync-backup.service "the backup timer starts the backup service"
timeout 300 systemctl --user start firefox-sync-backup.service
check "$?" 0 "systemctl --user start firefox-sync-backup.service (a backup by hand)"
check "$(admin_db_sql "SELECT COUNT(*) FROM ffs_backups WHERE scope = 'sync' AND ok = 1 AND bytes > 0")" 1 "the backup recorded in ffs_backups (quadlets)"
check "$(podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts sh -c 'for f in /backups/sync/*/*.sql.gz; do gzip -t "$f" && basename "$f"; done' | sort | paste -sd' ')" \
  "ffs_admin.sql.gz syncstorage.sql.gz tokenserver.sql.gz" "the dumps in the firefox-sync-backups volume (quadlets)"
[ "${FAILED}" = 0 ] || journalctl --user -u firefox-sync-backup.service --no-pager | tail -20

echo "== a backup restores, the way docs/backups.md#restore-with-quadlets says for the Quadlets"
st_sql() { podman exec -e MYSQL_PWD="$(grep '^SYNC_STORAGE_DB_PASSWORD=' .env | cut -d= -f2)" firefox-sync-syncstorage-db \
  sh -c 'exec "$(command -v mariadb || command -v mysql)" "$@"' sql -u"$(grep '^SYNC_STORAGE_DB_USER=' .env | cut -d= -f2)" "$(grep '^SYNC_STORAGE_DB_NAME=' .env | cut -d= -f2)" -sN -e "$1"; }
# every table of a database with its rows, its triggers and procedures: <sql function>
inventory() {
  local q t
  q="SELECT 'triggers', COUNT(*) FROM information_schema.triggers WHERE trigger_schema = DATABASE()
     UNION ALL SELECT 'routines', COUNT(*) FROM information_schema.routines WHERE routine_schema = DATABASE()"
  for t in $("$1" "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE';"); do
    q="${q} UNION ALL SELECT '${t}', COUNT(*) FROM \`${t}\`"
  done
  "$1" "${q} ORDER BY 1;" | tr '\t' ' '
}
ts_sql "INSERT INTO users (service, email, generation, client_state, created_at, nodeid) SELECT service, 'restore@ffs-e2e.invalid', 1, 'aa', 1, id FROM nodes LIMIT 1;"
# Sync items of that user, as the Sync server writes them (no client here): payloads with
# quotes, a backslash and a line break, which the dump has to carry as they are (Firefox's
# are encrypted JSON, ASCII)
uid=$(ts_sql "SELECT uid FROM users WHERE email = 'restore@ffs-e2e.invalid'")
st_sql "SET @c = (SELECT id FROM collections WHERE name = 'bookmarks'), @m = UNIX_TIMESTAMP() * 1000;
  INSERT INTO user_collections (userid, collection, last_modified) VALUES (${uid}, @c, @m);
  INSERT INTO bso (userid, collection, id, payload, payload_size, modified, ttl) VALUES
    (${uid}, @c, 'restore-1', '{\"ciphertext\":\"it''s \\\\ ok\"}', 30, @m, @m + 86400000),
    (${uid}, @c, 'restore-2', CONCAT('line', CHAR(10), 'break'), 20, @m, @m + 86400000);"
payloads() { st_sql "SELECT MD5(GROUP_CONCAT(id, ':', payload ORDER BY id SEPARATOR '|')) FROM bso"; }
PAYLOADS=$(payloads)
# the units stopped as docs/backups.md#restore-with-quadlets says (nothing writes: the databases hold what the dump holds)
systemctl --user stop firefox-sync-syncstorage.service firefox-sync-admin.service \
  firefox-sync-syncstorage-migrate.service firefox-sync-tokenserver-db-init.service
BEFORE=$(inventory ts_sql | sed 's/^/tokenserver /'; inventory st_sql | sed 's/^/storage /')
check "$(echo "${BEFORE}" | grep -cE '^tokenserver users 1$|^storage collections [1-9]|^storage bso 2$')" 3 "a tokenserver user, the storage's collections and 2 Sync items to back up (quadlets)"
timeout 300 systemctl --user start firefox-sync-backup.service
check "$?" 0 "a backup with the units stopped (quadlets)"
# what the restore has to bring back
EVENTS=$(admin_db_sql "SELECT COUNT(*) FROM ffs_events")
ts_sql "DELETE FROM users;"
admin_db_sql "DELETE FROM ffs_events;"
st_sql "DELETE FROM bso; DELETE FROM user_collections; DELETE FROM collections;"
check "$(ts_sql 'SELECT COUNT(*) FROM users')-$(st_sql 'SELECT COUNT(*) FROM collections')-$(st_sql 'SELECT COUNT(*) FROM bso')" 0-0-0 "rows deleted before the restore (quadlets)"
# the newest run, read out of the volume into each database container, as its own user
run=$(podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts ls /backups/sync | tail -1)
dump() { podman run --rm -v firefox-sync-backups:/backups:ro docker.io/library/mariadb:lts gunzip -c "/backups/$1"; }
# shellcheck disable=SC2016 # (expanded in the database container)
if [ "${SYNC_DB}" = mysql ]; then load='mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"'; else load='mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'; fi
# with set -o pipefail, as docs/backups.md#restore-with-quadlets says: a run that is not there fails, instead of loading nothing
check "$(grep -cxF 'set -o pipefail   # a missing or broken dump fails its line, instead of an empty restore' "${CODE}/docs/backups.md")" 1 "docs/backups.md's Quadlet restore sets pipefail"
missing=$( (set -o pipefail; dump "sync/20000101T000000Z/tokenserver.sql.gz" | podman exec -i firefox-sync-tokenserver-db sh -c "${load}") >> restore.log 2>&1 || echo failed)
check "${missing}" failed "a restore of a run that is not there fails (quadlets)"
for db in tokenserver syncstorage; do
  (set -o pipefail; dump "sync/${run}/${db}.sql.gz" | podman exec -i "firefox-sync-${db}-db" sh -c "${load}") >> restore.log 2>&1
  check "$?" 0 "${db} restored from ${run} as its user (quadlets)"
done
# the admin UI's database, as its user (the line of docs/backups.md#restore-with-quadlets, the client of the image)
# shellcheck disable=SC2016
admin_load='mariadb -u"$ADMIN_DB_USER" -p"$ADMIN_DB_PASSWORD" "$ADMIN_DB_NAME"'
check "$(grep -cF "dump sync/\$run/ffs_admin.sql.gz | podman exec -i firefox-sync-tokenserver-db sh -c '${admin_load}'" "${CODE}/docs/backups.md")" 1 "docs/backups.md's Quadlet restore of the admin UI's database"
[ "${SYNC_DB}" = mysql ] && admin_load=${admin_load/#mariadb/mysql}
(set -o pipefail; dump "sync/${run}/ffs_admin.sql.gz" | podman exec -i firefox-sync-tokenserver-db sh -c "${admin_load}") >> restore.log 2>&1
check "$?" 0 "ffs_admin restored from ${run} as its user (quadlets)"
check "$(admin_db_sql "SELECT COUNT(*) FROM ffs_events")" "${EVENTS}" "the event log as it was (quadlets)"
check "$(inventory ts_sql | sed 's/^/tokenserver /'; inventory st_sql | sed 's/^/storage /')" "${BEFORE}" \
  "the same rows in every table, the same triggers and procedures (quadlets)"
check "$(payloads)" "${PAYLOADS}" "the Sync items' payloads as they were (quadlets)"
[ "${FAILED}" = 0 ] || tail -20 restore.log
timeout 900 systemctl --user start firefox-sync-syncstorage.service
check "$?" 0 "systemctl --user start firefox-sync-syncstorage.service (restored)"
check "$(hb)" 200 "/__heartbeat__ after the restore (quadlets)"
check "$(ts_sql "SELECT COUNT(*) FROM users WHERE email = 'restore@ffs-e2e.invalid'") $(systemctl --user is-active firefox-sync-admin.service)" "1 active" \
  "the restored user kept by the init, the admin UI started again (quadlets)"
check "$(quadlets_healthy 300)" "all healthy" "every long-running unit has a HealthCmd and passes podman healthcheck run (quadlets)"

if [ "${FAILED}" != 0 ]; then
  tail -20 quadlet-dryrun.log
  journalctl --user -u 'firefox-sync-*' --no-pager | tail -60
  diagnose
fi

stop_quadlets() {
  systemctl --user stop $(systemctl --user list-units --all --plain --no-legend 'firefox-sync-*' | awk '{print $1}') 2> /dev/null
  rm -f "${QUADLET_DIR}"/firefox-sync-* "${SYSTEMD_USER_DIR}"/firefox-sync-*.timer
  systemctl --user daemon-reload
  podman volume rm -f $(podman volume ls -q | grep '^firefox-sync-') > /dev/null 2>&1
}
stop_quadlets

echo "== quadlets without the admin UI (mariadb)"
# answers as setup, admin UI: n. The Sync server starts without ffs-admin to resolve
printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 mariadb 1 "" "${TAG}" n | ./prepare_environment.sh > setup-no-admin.log 2>&1
check "$?" 0 "prepare_environment.sh (quadlets, no admin UI)"
check "$(ls "${QUADLET_DIR}"/firefox-sync-admin.* 2> /dev/null | wc -l)" 0 "no admin UI quadlet"
check "$(grep -hcxF 'Environment=MAX_USERS=1' "${QUADLET_DIR}/firefox-sync-tokenserver-db-init.container")" 1 "plain SYNC_MAX_USERS=1 in the init quadlet"
check "$(sed -n 's/^Image=//p' "${QUADLET_DIR}"/firefox-sync-{syncstorage-db,tokenserver-db,backup}.container | paste -sd' ') $(env_of SYNC_MARIADB_IMAGE)" \
  "docker.io/library/mariadb:lts docker.io/library/mariadb:lts docker.io/library/mariadb:lts mariadb:lts" "the Sync MariaDB units on lts for a new install (SYNC_MARIADB_IMAGE)"
"${QUADLET}" -dryrun -user > quadlet-no-admin-dryrun.log 2>&1
check "$?" 0 "quadlet generator accepts the files without the admin UI"
QUADLET_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
timeout 900 systemctl --user start firefox-sync-syncstorage.service
check "$?" 0 "systemctl --user start firefox-sync-syncstorage.service (no admin UI)"
check "$(hb)" 200 "/__heartbeat__ (quadlets, no admin UI)"
check "$(journalctl --user -u firefox-sync-syncstorage.service --since "${QUADLET_SINCE}" --no-pager 2> /dev/null | grep -c 'Sending metrics')" 0 \
  "no metrics host without the admin UI (quadlets)"
if [ "${FAILED}" != 0 ]; then
  tail -20 setup-no-admin.log quadlet-no-admin-dryrun.log
  journalctl --user -u 'firefox-sync-*' --since "${QUADLET_SINCE}" --no-pager | tail -40
fi

echo "== quadlets with the Sync databases on MySQL (SYNC_DB=mysql): only what is installed"
setup mysql 1
check "$?" 0 "prepare_environment.sh (quadlets, MySQL)"
check "$(health_parity "${QUADLET_DIR}" docker compose --profile admin --profile backup -f docker-compose.yml -f docker-compose.sync-mysql.yml)" same "the MySQL Quadlets' healthchecks are compose's"
check "$(grep -c '^SYNC_DB=mysql$' .env) $(grep -c '^COMPOSE_FILE=docker-compose.yml:docker-compose.sync-mysql.yml$' .env)" "1 1" "SYNC_DB=mysql in .env, with the compose overlay"
check "$(sed -n 's/^Image=//p' "${QUADLET_DIR}"/firefox-sync-{syncstorage-db,tokenserver-db,backup}.container | paste -sd' ') $(env_of SYNC_MYSQL_IMAGE)" \
  "docker.io/library/mysql:lts docker.io/library/mysql:lts docker.io/library/mysql:lts mysql:lts" "MySQL lts database and backup units for a new install"
check "$(ls "${QUADLET_DIR}"/firefox-sync-*-db*.volume 2> /dev/null | xargs -n1 basename | LC_ALL=C sort | paste -sd' ')" \
  "firefox-sync-syncstorage-db-mysql.volume firefox-sync-tokenserver-db-mysql.volume" "MySQL's own volumes, not MariaDB's"
check "$(grep -hcxE 'Exec=sh /ffs-db/admin-user\.sh mysqld --disable-log-bin|HealthCmd=mysqladmin ping -h 127\.0\.0\.1 --protocol=tcp -u(syncstorage|tokenserver) -p[A-Za-z0-9]+ --silent' "${QUADLET_DIR}"/firefox-sync-{syncstorage,tokenserver}-db.container | paste -sd' ')" \
  "2 2" "MySQL without binary logging, healthcheck over TCP"
check "$(grep -cxF 'Environment=MARIADB_TLS_VERIFY=false' "${QUADLET_DIR}/firefox-sync-tokenserver-db-init.container")" 1 "init container does not check MySQL's self-signed certificate"
check "$(grep -l '%[A-Z_]*%' "${QUADLET_DIR}"/firefox-sync-* | wc -l)" 0 "no unreplaced placeholders in the MySQL quadlets"
"${QUADLET}" -dryrun -user > quadlet-mysql-dryrun.log 2>&1
check "$?" 0 "quadlet generator accepts the MySQL database units"
stop_quadlets

if [ -n "${EXTERNAL_DB:-}" ]; then
  echo "== quadlets on your own database server (mariadb:lts, binary logging)"
  EXTDB=ffs-podman-extdb
  # answers as above, no accounts, then: your own server? host, port, tokenserver database
  # and user, storage database and user
  printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 mariadb 1 "" "${TAG}" "" n y "${EXTDB}" "" "" "" "" "" \
    | ./prepare_environment.sh > setup-external.log 2>&1
  check "$?" 0 "prepare_environment.sh (quadlets, your own database server)"
  check "$(ls "${QUADLET_DIR}"/firefox-sync-*-db.* 2> /dev/null | wc -l)" 0 "no database quadlets"
  check "$(grep -hE '^(After|Requires)=.*-db\.service' "${QUADLET_DIR}"/firefox-sync-* | wc -l) $(grep -c '^Requires=' "${QUADLET_DIR}/firefox-sync-syncstorage-migrate.container")" "0 0" \
    "no dependencies on database units"
  check "$(grep -c '^Requires=firefox-sync-syncstorage-migrate.service$' "${QUADLET_DIR}/firefox-sync-tokenserver-db-init.container")" 1 "the init still needs the migrations"
  check "$(grep -hcE "^Environment=\"?(SYNC_SYNCSTORAGE__DATABASE_URL=mysql://syncstorage:[A-Za-z0-9]+@${EXTDB}:3306/syncstorage|MARIADB_SERVER=${EXTDB}|MARIADB_TLS_VERIFY=false|STORAGE_DB_HOST=${EXTDB})\"?$" \
    "${QUADLET_DIR}"/firefox-sync-{syncstorage,tokenserver-db-init,admin}.container | paste -sd' ')" "1 2 1" "quadlets connect to your server"
  "${QUADLET}" -dryrun -user > quadlet-external-dryrun.log 2>&1
  check "$?" 0 "quadlet generator accepts the files without database units"
  systemctl --user start firefox-sync-network-network.service
  EXTDB_ROOT=$(tr -dc '[:alnum:]' < /dev/urandom | head -c 24)
  podman rm -f "${EXTDB}" > /dev/null 2>&1
  podman run -d --name "${EXTDB}" --network firefox-sync --tmpfs /var/lib/mysql -e MARIADB_ROOT_PASSWORD="${EXTDB_ROOT}" \
    docker.io/library/mariadb:lts mariadbd --log-bin=mysql-bin --server-id=1 --log-bin-trust-function-creators=1 > /dev/null
  for _ in $(seq 1 60); do
    podman exec -e MYSQL_PWD="${EXTDB_ROOT}" "${EXTDB}" mariadb -uroot -h 127.0.0.1 --protocol=tcp -e 'SELECT 1' > /dev/null 2>&1 && break
    sleep 2
  done
  check "$(stat -c %a database-setup.sql)" 600 "database-setup.sql for this user only"
  podman exec -i -e MYSQL_PWD="${EXTDB_ROOT}" "${EXTDB}" mariadb -uroot < database-setup.sql
  check "$?" 0 "database-setup.sql runs on the server"
  timeout 900 systemctl --user start firefox-sync-syncstorage.service
  check "$?" 0 "systemctl --user start firefox-sync-syncstorage.service (your own server)"
  check "$(hb)" 200 "/__heartbeat__ (quadlets, your own server)"
  check "$(podman exec -e MYSQL_PWD="${EXTDB_ROOT}" "${EXTDB}" mariadb -uroot -sN -e "SELECT @@log_bin; SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_name = 'BeforeInsertUser'" | paste -sd' ')" \
    "1 1" "SYNC_MAX_USERS trigger on your server, with binary logging"
  check "$(metrics_show "${SYNC_UP[@]}" 'ffs_up{component="Storage database"} 1')" all "admin UI reaches your server (quadlets)"
  [ "${FAILED}" = 0 ] || { journalctl --user -u 'firefox-sync-*' --no-pager | tail -40; podman logs --tail 20 "${EXTDB}"; }
  stop_quadlets
  podman rm -f "${EXTDB}" > /dev/null 2>&1
  podman network rm -f firefox-sync > /dev/null 2>&1

  # the accounts on your own MySQL server: only what is installed (no MySQL here)
  # answers: ..., admin host, your own server for Sync? the accounts? host, port, user, policy user
  printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 mariadb 1 "" "${TAG}" "" y fxa.invalid mail.invalid 587 test pw "" "" "" \
    n y fxa-mysql.invalid "" "" "" | ./prepare_environment.sh > setup-fxa-external.log 2>&1
  check "$?" 0 "prepare_environment.sh (quadlets, accounts on your own server)"
  check "$(ls "${QUADLET_DIR}"/firefox-sync-fxa-* 2> /dev/null | wc -l)" 11 "accounts quadlet files without the database"
  check "$(grep -hoE '^Environment="(((AUTH|OAUTH|PROFILE|PUSHBOX)_)?MYSQL|FXA_DB)_HOST=[^"]*"' "${QUADLET_DIR}"/firefox-sync-{fxa-*,admin}.container | sed 's/.*=//' | sort | uniq -c | sed 's/^ *//')" \
    '10 fxa-mysql.invalid"' "the accounts connect to your server"
  check "$(grep -hcE '^Environment="(FXA_DB_ROOT_USER=ffs_policy|FXA_MYSQL_USER=fxa)"$' "${QUADLET_DIR}/firefox-sync-fxa-policy.container")" 2 "sign-up policy installed by ffs_policy"
  check "$(grep -c '^Requires=' "${QUADLET_DIR}/firefox-sync-fxa-migrations.container")" 0 "accounts migrations without the database unit"
  "${QUADLET}" -dryrun -user > quadlet-fxa-external-dryrun.log 2>&1
  check "$?" 0 "quadlet generator accepts the accounts files without the database"
  stop_quadlets
fi

FXA_DB=${FXA_DB:-mysql}
fxa_db_image() { sed -n 's/^Image=//p' "${QUADLET_DIR}/firefox-sync-fxa-db.container" 2> /dev/null; }
if [ -z "${SKIP_FXA:-}" ] && [ "${FXA_DB}" != mariadb ]; then
  echo "== quadlets with the accounts on MariaDB: only what is installed"
  # answers: as below, then your own server for Sync? the accounts? the accounts database
  printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 mariadb 1 "" "${TAG}" "" y fxa.invalid mail.invalid 587 test pw "" "" "" \
    n n mariadb | ./prepare_environment.sh > setup-fxa-mariadb.log 2>&1
  check "$?" 0 "prepare_environment.sh (quadlets, accounts on MariaDB)"
  check "$(health_parity "${QUADLET_DIR}" docker compose --profile admin --profile backup --profile pairing -f docker-compose.yml -f docker-compose.fxa.yml -f docker-compose.fxa-mariadb.yml)" same \
    "the Quadlets' healthchecks with the accounts on MariaDB are compose's"
  check "$(fxa_db_image) $(ls "${QUADLET_DIR}"/firefox-sync-fxa-db* 2> /dev/null | xargs -n1 basename | LC_ALL=C sort | paste -sd' ')" \
    "docker.io/library/mariadb:lts firefox-sync-fxa-db-mariadb.volume firefox-sync-fxa-db.container" "MariaDB lts unit and its own volume, not MySQL's"
  check "$(sed -n 's/^Image=//p' "${QUADLET_DIR}/firefox-sync-backup-fxa.container")" docker.io/library/mariadb:lts "the backups of the accounts with the same MariaDB"
  "${QUADLET}" -dryrun -user > quadlet-fxa-mariadb-dryrun.log 2>&1
  check "$?" 0 "quadlet generator accepts the MariaDB accounts database"
  stop_quadlets
fi

if [ -z "${SKIP_FXA:-}" ]; then
  echo "== quadlets with self-hosted Mozilla accounts (${FXA_DB})"
  # answers: ..., image tag, admin UI, FxA, FxA domain, SMTP host, port, user, password, sender, allowlist,
  # admin emails, admin host, [your own server for Sync? the accounts? the accounts database]
  fxa_db_answers=()
  [ "${FXA_DB}" = mariadb ] && fxa_db_answers=(n n mariadb)
  # one pull up front, otherwise every unit pulls the 5 GB image at the same time; before
  # prepare_environment.sh, which reads its label (mozilla/fxa#21554: MySQL lts)
  case "$(uname -m)" in aarch64|arm64) fxa_arch=arm64 ;; *) fxa_arch=amd64 ;; esac
  fxa_image=$(grep '^IMAGE_REPOSITORY=' .env-example | cut -d= -f2):$(grep '^FXA_VERSION=' .env-example | cut -d= -f2)
  if [ -n "${FXA_TEST_IMAGE:-}" ]; then
    # the candidate, under the name the quadlets use
    # (a local build is used as it is)
    { podman image exists "${FXA_TEST_IMAGE}" || podman pull -q --arch "${fxa_arch}" "${FXA_TEST_IMAGE}" > /dev/null; } && podman tag "${FXA_TEST_IMAGE}" "${fxa_image}"
  else
    podman pull -q --arch "${fxa_arch}" "${fxa_image}" > /dev/null
  fi
  fxa_pulled=$?
  fxa_image_id=$(podman image inspect -f '{{.Id}}' "${fxa_image}" 2> /dev/null)
  printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 mariadb 1 "" "${TAG}" "" y fxa.invalid mail.invalid 587 test 'p%ss|w&rd' "" "@fxa.invalid" \
    "me@fxa.invalid" "" "${fxa_db_answers[@]}" \
    | ./prepare_environment.sh > setup-fxa-quadlets.log 2>&1
  check "$?" 0 "prepare_environment.sh (quadlets with accounts)"
  fxa_compose=(-f docker-compose.yml -f docker-compose.fxa.yml)
  [ "${FXA_DB}" = mariadb ] && fxa_compose+=(-f docker-compose.fxa-mariadb.yml)
  check "$(health_parity "${QUADLET_DIR}" docker compose --profile admin --profile backup --profile pairing "${fxa_compose[@]}")" same \
    "every long-running service has a healthcheck, the Quadlets with the accounts compose's (${FXA_DB})"
  check "$(ls "${QUADLET_DIR}"/firefox-sync-fxa-* 2> /dev/null | wc -l)" 13 "accounts quadlet files installed"
  # MySQL: lts when the accounts image of .env has mozilla/fxa#21554, else 8 with mysql_native_password
  if [ "${FXA_DB}" = mariadb ]; then
    expected_image=docker.io/library/mariadb:lts expected_exec=mariadbd
  elif [ "$(env_of FXA_MYSQL_IMAGE)" = mysql:lts ]; then
    expected_image=docker.io/library/mysql:lts expected_exec="mysqld --event-scheduler=ON "
    check "[$(env_of FXA_MYSQL_ARGS)] $(grep -c 'does not have mozilla/fxa#21554' setup-fxa-quadlets.log)" "[] 0" "the accounts on MySQL lts: no mysql_native_password"
  else
    expected_image=docker.io/library/mysql:8 expected_exec="mysqld --event-scheduler=ON --mysql-native-password=ON --authentication-policy=mysql_native_password"
    check "$(env_of FXA_MYSQL_IMAGE) $(grep -cE 'does not have mozilla/fxa#21554|could not read the labels of' setup-fxa-quadlets.log)" "mysql:8 1" \
      "the accounts on MySQL 8 with mysql_native_password, for an accounts image without mozilla/fxa#21554 (said)"
  fi
  check "$(fxa_db_image) $(sed -n 's/^Image=//p' "${QUADLET_DIR}/firefox-sync-backup-fxa.container")" "${expected_image} ${expected_image}" "accounts database ${FXA_DB} and its backups"
  [ "${FXA_DB}" = mariadb ] || check "$(sed -n 's/^Exec=//p' "${QUADLET_DIR}/firefox-sync-fxa-db.container")" "${expected_exec}" "fxa-db's options (FXA_MYSQL_ARGS)"
  check "$(grep -c 'FXA_DB_HOST=fxa-db' "${QUADLET_DIR}/firefox-sync-admin.container")" 1 "admin UI quadlet for the accounts"
  # no pairing server in the quadlets
  check "$(env_keys_diff "-f docker-compose.yml -f docker-compose.fxa.yml" 'FXA_PAIRING_URL|TOKENSERVER_DB_PASSWORD|STORAGE_DB_PASSWORD|FFS_OLD_ENV_NAMES')" "|" "admin quadlet with the accounts passes every setting of the compose service"
  # max accounts: not asked here (the last question), unlimited and managed in the admin UI
  check "$(cat "${QUADLET_DIR}/firefox-sync-fxa-policy.container" "${QUADLET_DIR}/firefox-sync-admin.container" | grep -cxF 'Environment="FXA_MAX_ACCOUNTS=initial:unlimited"')" 2 \
    "FXA_MAX_ACCOUNTS=initial:unlimited in the sign-up policy and admin UI quadlets"
  # the security history: not asked here either (EOF), off in the auth server and the admin UI;
  # never the sign-in code skipped for a known IP address
  check "$(cat "${QUADLET_DIR}/firefox-sync-fxa-auth.container" "${QUADLET_DIR}/firefox-sync-admin.container" | grep -cxE 'Environment="(ACCOUNT_EVENTS_ENABLED|FXA_ACCOUNT_EVENTS)=false"|Environment="IP_PROFILING_RECENCY=0"')" 3 \
    "no security history by default in the accounts and admin UI quadlets"
  check "$(grep -lE '%[A-Z][A-Z0-9_]*%' "${QUADLET_DIR}"/firefox-sync-* | wc -l)" 0 "no unreplaced placeholders"
  check "$(grep -c 'SMTP_PASS=p%%ss|w&rd"' "${QUADLET_DIR}/firefox-sync-fxa-auth.container")" 1 "values escaped for systemd"
  # the admin UI signs in with these accounts: its OAuth client always asks the sign-in code
  admin_client=$(grep '^ADMIN_FXA_CLIENT_ID=' .env | cut -d= -f2)
  check "$(echo "${admin_client}" | grep -cE '^[0-9a-f]{16}$')" 1 "admin UI OAuth client id (quadlets)"
  check "$(grep -c "SERVICES_WITH_EMAIL_VERIFICATION=.*,${admin_client}\"" "${QUADLET_DIR}/firefox-sync-fxa-auth.container")" 1 \
    "accounts ask the sign-in code for the admin UI (quadlets)"
  # no defaults in Quadlets: without TRUST_UNVERIFIED_EMAIL every sign-in with the accounts fails
  check "$(grep -cE "^Environment=\"(ADMIN_OIDC_ISSUER=https://accounts.fxa.invalid|ADMIN_OIDC_CLIENT_ID=${admin_client}|ADMIN_ALLOWED_USERS=me@fxa.invalid|ADMIN_OIDC_REDIRECT_URL=https://admin.fxa.invalid/auth/callback|ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true|ADMIN_OIDC_NAME=Mozilla account)\"$" \
    "${QUADLET_DIR}/firefox-sync-admin.container")" 6 "admin UI signs in with the accounts (quadlets)"
  "${QUADLET}" -dryrun -user > quadlet-fxa-dryrun.log 2>&1
  check "$?" 0 "quadlet generator accepts the accounts files"
  fast_admin_checks
  check "${fxa_pulled}" 0 "pull mozilla/fxa-mono ${FXA_TEST_IMAGE:-${fxa_image}}"
  check "$(grep '^FXA_IMAGE=' .env | cut -d= -f2):$(grep '^FXA_VERSION=' .env | cut -d= -f2) $(grep '^FXA_ARCH=' .env | cut -d= -f2)" "${fxa_image} ${fxa_arch}" \
    "the accounts image pulled is the one of .env"
  # (all of them, as at boot: WantedBy=default.target)
  timeout 1200 systemctl --user start firefox-sync-syncstorage.service firefox-sync-fxa-content.service firefox-sync-fxa-profile.service \
    firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service firefox-sync-admin.service
  check "$?" 0 "systemctl --user start (syncstorage and accounts)"
  # the image the accounts' units run is the one whose label chose fxa-db's MySQL: lts only with
  # mozilla/fxa#21554 in it, and the units did not pull another one over it (podman 4 does with
  # --arch, which the units have only for another architecture)
  run_id=$(podman image inspect -f '{{.Id}}' "${fxa_image}" 2> /dev/null)
  run_label=$(podman image inspect -f '{{index .Labels "org.firefox-sync.upstream-patches"}}' "${fxa_image}" 2> /dev/null)
  check "$(sed -n 's/^Image=//p' "${QUADLET_DIR}"/firefox-sync-fxa-{migrations,auth}.container | sort -u) [$(grep -h '^PodmanArgs=--arch' "${QUADLET_DIR}"/firefox-sync-fxa-{migrations,auth}.container | sort -u)] $(grep -hc '^PodmanArgs=--network-alias=fxa-' "${QUADLET_DIR}"/firefox-sync-fxa-{migrations,auth}.container | awk '{ s += $1 } END { print s }') ${run_id}" \
    "${fxa_image} [$([ "${fxa_arch}" = "$(case "$(uname -m)" in aarch64|arm64) echo arm64 ;; *) echo amd64 ;; esac)" ] || echo "PodmanArgs=--arch=${fxa_arch}")] 2 ${fxa_image_id}" \
    "the accounts' units run ${fxa_image}, the image prepare_environment.sh read (not pulled over: no --arch on this host's architecture)"
  if [ "${FXA_DB}" != mariadb ]; then
    [[ " ${run_label} " == *" mozilla/fxa#21554@"* ]] && want_db=docker.io/library/mysql:lts || want_db=docker.io/library/mysql:8
    check "$(fxa_db_image)" "${want_db}" "fxa-db's MySQL agrees with the label of the image the units run ($([ "${want_db##*:}" = lts ] && echo with || echo without) mozilla/fxa#21554)"
  fi
  ok=""
  for _ in $(seq 1 225); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${CONTENT_PORT}/__heartbeat__)" = 200 ] && ok=yes && break
    sleep 2
  done
  check "${ok}" yes "accounts web pages answer (quadlets)"
  ok=""
  for _ in $(seq 1 225); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${AUTH_PORT}/__heartbeat__)" = 200 ] && ok=yes && break
    sleep 2
  done
  check "${ok}" yes "accounts API answers (quadlets)"
  check "$(curl -s http://127.0.0.1:${CONTENT_PORT}/.well-known/fxa-client-configuration | grep -o '"auth_server_base_url":"[^"]*"')" '"auth_server_base_url":"https://api.fxa.invalid"' "client configuration (quadlets)"
  journalctl --user -u firefox-sync-fxa-policy.service --no-pager 2> /dev/null | grep -m1 "sign-ups:"
  check "$(journalctl --user -u firefox-sync-fxa-policy.service --no-pager 2> /dev/null | grep -q 'max accounts: unlimited (FXA_MAX_ACCOUNTS=initial:unlimited' && echo yes)" yes \
    "fxa-policy set max accounts (quadlets)"
  check "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"email":"someone@example.org","authPW":"00"}' http://127.0.0.1:${GATE_PORT}/v1/account/create)" 400 "sign-up gate refuses an email not on the allowlist (quadlets)"
  # the gate reaches the accounts API by its network alias: give it the same time as the checks above
  gate=""
  for _ in $(seq 1 30); do
    gate=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${GATE_PORT}/__heartbeat__)
    [ "${gate}" = 200 ] && break
    sleep 2
  done
  check "${gate}" 200 "sign-up gate forwards to the accounts API (quadlets)"
  [ "${gate}" = 200 ] || journalctl --user -u firefox-sync-admin.service --no-pager | tail -15
  # the admin UI with the accounts: grants, Redis, the internal URLs of the health checks
  check "$(metrics_show "${SYNC_UP[@]}" 'ffs_up{component="Storage database"} 1' 'ffs_up{component="Accounts API"} 1' \
    'ffs_up{component="Accounts pages"} 1' 'ffs_up{component="Profile server"} 1' 'ffs_up{component="Accounts database"} 1' \
    'ffs_up{component="Accounts Redis"} 1' 'ffs_accounts 0')" all "admin UI reaches the accounts services (quadlets)"
  check "$(podman healthcheck run firefox-sync-admin > /dev/null 2>&1; echo $?)" 0 "admin UI healthcheck (quadlets with accounts)"
  check "$(curl -s http://127.0.0.1:${ADMIN_PORT}/login | grep -c '>Sign in with Mozilla account</a>')" 1 "admin UI offers the accounts' sign-in (quadlets)"
  # the backup of the accounts runs with that of Sync, before it (WantedBy=, Before=)
  timeout 600 systemctl --user start firefox-sync-backup.service
  check "$?" 0 "systemctl --user start firefox-sync-backup.service (quadlets with accounts)"
  check "$(admin_db_sql "SELECT DISTINCT scope FROM ffs_backups WHERE ok = 1 ORDER BY scope" | paste -sd' ')" "accounts sync" "the backups of the accounts and of Sync recorded (quadlets)"
  [ "${FAILED}" = 0 ] || journalctl --user -u 'firefox-sync-backup*' --no-pager | tail -20
  check "$(quadlets_healthy 600)" "all healthy" "every long-running unit has a HealthCmd and passes podman healthcheck run (quadlets with accounts)"
  if [ "${FAILED}" != 0 ]; then
    journalctl --user -u 'firefox-sync-fxa-*' --no-pager | tail -40
  fi
  stop_quadlets
fi

echo "== cleanup"
rm -rf "${WORK}"

[ ${FAILED} = 0 ] && echo "RESULT podman: all checks passed" || echo "RESULT podman: some checks FAILED"
exit ${FAILED}
