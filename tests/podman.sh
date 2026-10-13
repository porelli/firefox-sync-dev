#!/bin/bash
# Rootless podman test: docker compose on the Podman socket (MariaDB and PostgreSQL) and
# quadlets (MariaDB), set up with prepare_environment.sh exactly like a user would.
# Needs rootless podman, docker compose (v2, no Docker daemon) and a systemd user session.
#
# Usage: tests/podman.sh
# Environment:
#   REPOSITORY  image repository (default: ghcr.io/porelli/firefox-sync)
#   TAG         tag suffix of both the app and init images (default: latest)
#   PORT        host port (default: 28660)
#   SKIP_FXA    set to 1 to skip the quadlets with self-hosted accounts
#   ADMIN_IMAGE     admin UI image to test, pulled and used as is (default: built from admin/)
#   FXA_TEST_IMAGE  accounts image to test with the quadlets, e.g.
#                   ghcr.io/porelli/firefox-sync:fxa-mono-v1.347.1-linux-arm64 (default: REPOSITORY:fxa-mono-latest)
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
PORT=${PORT:-28660}
WORK=$(mktemp -d)
export QUADLET_DIR=${WORK}/quadlets-unused  # replaced below for the quadlet phase
FAILED=0

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
sed -i -e "s|^REPOSITORY=.*|REPOSITORY=${REPOSITORY}|" \
       -e "s|^SYNCSTORAGE_INIT_IMAGE_TAG=.*|SYNCSTORAGE_INIT_IMAGE_TAG=${TAG}|" \
       -e "s|^ADMIN_EXPORT_PORT=.*|ADMIN_EXPORT_PORT=127.0.0.1:28690|" \
       -e "s|^ADMIN_GATE_EXPORT_PORT=.*|ADMIN_GATE_EXPORT_PORT=127.0.0.1:28691|" \
       -e "s|^ADMIN_METRICS_TOKEN=.*|ADMIN_METRICS_TOKEN=ffs-test-metrics-token|" \
       -e "s|^ADMIN_UPDATE_CHECK=.*|ADMIN_UPDATE_CHECK=false|" \
       -e "s|^FXA_CONTENT_EXPORT_PORT=.*|FXA_CONTENT_EXPORT_PORT=127.0.0.1:28630|" \
       -e "s|^FXA_AUTH_EXPORT_PORT=.*|FXA_AUTH_EXPORT_PORT=127.0.0.1:28600|" \
       -e "s|^FXA_PROFILE_EXPORT_PORT=.*|FXA_PROFILE_EXPORT_PORT=127.0.0.1:28611|" \
       -e "s|^FXA_PROFILE_STATIC_EXPORT_PORT=.*|FXA_PROFILE_STATIC_EXPORT_PORT=127.0.0.1:28612|" \
       -e "s|^FXA_PAIRING_EXPORT_PORT=.*|FXA_PAIRING_EXPORT_PORT=127.0.0.1:28658|" .env-example
# the admin UI under test, where compose and the quadlets look for it
if [ -n "${ADMIN_IMAGE:-}" ]; then
  podman pull -q "${ADMIN_IMAGE}" > build-admin.log 2>&1 && podman tag "${ADMIN_IMAGE}" "${REPOSITORY}:admin-latest" >> build-admin.log 2>&1
else
  podman build -q --format docker -t "${REPOSITORY}:admin-latest" admin > build-admin.log 2>&1
fi
rc=$?; check "${rc}" 0 "admin UI image"; [ "${rc}" = 0 ] || tail -5 build-admin.log
# answers: domain, compose dir, port, max users, backend, deploy method, user, image tag, admin UI
setup() { printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 "$1" "$2" "" "${TAG}" "" | ./prepare_environment.sh > "setup-$1-$2.log" 2>&1; }
admin_up() {
  local c
  for _ in $(seq 1 30); do
    c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:28690$1")
    [ "${c}" = 200 ] && break
    sleep 2
  done
  echo "${c}"
}
# Prometheus metrics of the admin UI, retried until they have every line given (it
# checks the components every HEALTH_CHECK_SECONDS, 60, and its first check of the
# Quadlets runs before the Sync server is up; a check can take 10 s more on a timeout):
# "all", or the first missing
metrics_show() {
  local m line missing
  for _ in $(seq 1 75); do
    m=$(curl -s -H 'Authorization: Bearer ffs-test-metrics-token' http://127.0.0.1:28690/metrics)
    missing=""
    for line in "$@"; do grep -qxF "${line}" <<< "${m}" || { missing=${line}; break; }; done
    [ -z "${missing}" ] && break
    sleep 2
  done
  echo "${missing:-all}"
}
SYNC_UP=('ffs_up{component="Sync server"} 1' 'ffs_up{component="Tokenserver database"} 1')
# signed in with the default Secure cookie over plain http: curl, like browsers, keeps
# it for localhost
admin_sign_in() {
  local jar=${WORK}/cookies-$1
  curl -s -o /dev/null -c "${jar}" --data-urlencode "password=$(grep '^ADMIN_PASSWORD=' .env | cut -d= -f2)" http://localhost:28690/login
  curl -s -b "${jar}" http://localhost:28690/ | grep -q 'Sign out' && echo yes
}

compose_test() {
  local backend=$1; shift
  echo "== docker compose on the Podman socket (${backend})"
  setup "${backend}" 2
  check "$?" 0 "prepare_environment.sh (${backend}, compose)"
  check "$(grep -c "docker compose $* up -d" "setup-${backend}-2.log")" 1 "prepare_environment.sh prints the compose command (${backend})"
  timeout 600 docker compose "$@" up -d > "compose-${backend}.log" 2>&1
  check "$?" 0 "docker compose up (${backend})"
  check "$(hb)" 200 "/__heartbeat__ (compose, ${backend})"
  check "$(podman inspect -f '{{.State.ExitCode}}' "$(ctr syncstorage_migrate)")" 0 "migrate container exit code (${backend})"
  check "$(podman inspect -f '{{.State.ExitCode}}' "$(ctr tokenserver_db_init)")" 0 "init container exit code (${backend})"
  check "$([ "$(started "$(ctr syncstorage)" StartedAt)" -gt "$(started "$(ctr tokenserver_db_init)" FinishedAt)" ] && echo yes)" yes \
    "syncstorage started after the init (compose, ${backend})"
  check "$(admin_up /login)" 200 "admin UI (compose, ${backend})"
  check "$(admin_sign_in "${backend}")" yes "admin UI sign-in over http://localhost (compose, ${backend})"
  if [ "${backend}" = mariadb ]; then
    check "$(metrics_show "${SYNC_UP[@]}" 'ffs_up{component="Storage database"} 1')" all "admin UI reaches the Sync server and its databases (compose, ${backend})"
  else
    check "$(metrics_show "${SYNC_UP[@]}")" all "admin UI reaches the Sync server and its database (compose, ${backend})"
  fi
  check "$(podman logs "$(ctr syncstorage)" 2>&1 | grep -c 'Sending metrics to the admin UI')" 1 "Sync server sends metrics to the admin UI (compose, ${backend})"
  podman logs "$(ctr tokenserver_db_init)" 2>&1 | grep -E "Max users|ERROR"
  [ "${FAILED}" = 0 ] || diagnose "compose-${backend}.log"
  docker compose "$@" down -v > /dev/null 2>&1
}
compose_test mariadb -f docker-compose.yml -f docker-compose.podman.yml
compose_test postgres -f docker-compose.postgres.yml

echo "== quadlets (mariadb)"
export QUADLET_DIR=${HOME}/.config/containers/systemd
setup mariadb 1
check "$?" 0 "prepare_environment.sh (quadlets)"
check "$(grep -l '%[A-Z_]*%' "${QUADLET_DIR}"/firefox-sync-* | wc -l)" 0 "no unreplaced placeholders in quadlets"
# with the admin UI, MAX_USERS=initial:1: the init container and the admin UI both get it
check "$(grep -hcxF 'Environment=MAX_USERS=initial:1' "${QUADLET_DIR}/firefox-sync-tokenserver-db-init.container") $(grep -hcxF 'Environment="MAX_USERS=initial:1"' "${QUADLET_DIR}/firefox-sync-admin.container")" "1 1" \
  "MAX_USERS=initial:1 in the init and admin UI quadlets"
QUADLET=$(ls /usr/libexec/podman/quadlet /usr/lib/podman/quadlet 2> /dev/null | head -1)
"${QUADLET}" -dryrun -user > quadlet-dryrun.log 2>&1
check "$?" 0 "quadlet generator accepts the files"
# the journal keeps earlier runs
QUADLET_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
timeout 900 systemctl --user start firefox-sync-syncstorage.service
check "$?" 0 "systemctl --user start firefox-sync-syncstorage.service"
for u in syncstorage-db tokenserver-db syncstorage-migrate tokenserver-db-init syncstorage; do
  printf '  %-22s %s\n' "${u}" "$(systemctl --user is-active "firefox-sync-${u}.service")"
done
check "$(hb)" 200 "/__heartbeat__ (quadlets)"
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
if [ "${FAILED}" != 0 ]; then
  tail -20 quadlet-dryrun.log
  journalctl --user -u 'firefox-sync-*' --no-pager | tail -60
  diagnose
fi

stop_quadlets() {
  systemctl --user stop $(systemctl --user list-units --all --plain --no-legend 'firefox-sync-*' | awk '{print $1}') 2> /dev/null
  rm -f "${QUADLET_DIR}"/firefox-sync-*
  systemctl --user daemon-reload
  podman volume rm -f $(podman volume ls -q | grep '^firefox-sync-') > /dev/null 2>&1
}
stop_quadlets

if [ -z "${SKIP_FXA:-}" ]; then
  echo "== quadlets with self-hosted Mozilla accounts"
  # answers: ..., image tag, admin UI, FxA, FxA domain, SMTP host, port, user, password, sender, allowlist,
  # admin emails, admin host
  printf '%s\n' ffs-e2e.invalid "" "${PORT}" 1 mariadb 1 "" "${TAG}" "" y fxa.invalid mail.invalid 587 test 'p%ss|w&rd' "" "@fxa.invalid" \
    "me@fxa.invalid" "" \
    | ./prepare_environment.sh > setup-fxa-quadlets.log 2>&1
  check "$?" 0 "prepare_environment.sh (quadlets with accounts)"
  check "$(ls "${QUADLET_DIR}"/firefox-sync-fxa-* 2> /dev/null | wc -l)" 13 "accounts quadlet files installed"
  check "$(grep -c 'FXA_DB_HOST=fxa-db' "${QUADLET_DIR}/firefox-sync-admin.container")" 1 "admin UI quadlet for the accounts"
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
  # one pull up front, otherwise every unit pulls the 5 GB image at the same time
  fxa_arch=$(grep '^FXA_ARCH=' .env | cut -d= -f2)
  fxa_image=$(grep '^FXA_IMAGE=' .env | cut -d= -f2):$(grep '^FXA_VERSION=' .env | cut -d= -f2)
  if [ -n "${FXA_TEST_IMAGE:-}" ]; then
    # the candidate, under the name the quadlets use
    podman pull -q --arch "${fxa_arch}" "${FXA_TEST_IMAGE}" > /dev/null && podman tag "${FXA_TEST_IMAGE}" "${fxa_image}"
  else
    podman pull -q --arch "${fxa_arch}" "${fxa_image}" > /dev/null
  fi
  check "$?" 0 "pull mozilla/fxa-mono ${FXA_TEST_IMAGE:-${fxa_image}}"
  timeout 1200 systemctl --user start firefox-sync-syncstorage.service firefox-sync-fxa-content.service firefox-sync-fxa-profile.service firefox-sync-admin.service
  check "$?" 0 "systemctl --user start (syncstorage and accounts)"
  ok=""
  for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:28630/__heartbeat__)" = 200 ] && ok=yes && break
    sleep 5
  done
  check "${ok}" yes "accounts web pages answer (quadlets)"
  ok=""
  for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:28600/__heartbeat__)" = 200 ] && ok=yes && break
    sleep 5
  done
  check "${ok}" yes "accounts API answers (quadlets)"
  check "$(curl -s http://127.0.0.1:28630/.well-known/fxa-client-configuration | grep -o '"auth_server_base_url":"[^"]*"')" '"auth_server_base_url":"https://api.fxa.invalid"' "client configuration (quadlets)"
  journalctl --user -u firefox-sync-fxa-policy.service --no-pager 2> /dev/null | grep -m1 "sign-ups:"
  check "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"email":"someone@example.org","authPW":"00"}' http://127.0.0.1:28691/v1/account/create)" 400 "sign-up gate refuses an email not on the allowlist (quadlets)"
  # the gate reaches the accounts API by its network alias: give it the same time as the checks above
  gate=""
  for _ in $(seq 1 30); do
    gate=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:28691/__heartbeat__)
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
  check "$(curl -s http://127.0.0.1:28690/login | grep -c '>Sign in with Mozilla account</a>')" 1 "admin UI offers the accounts' sign-in (quadlets)"
  if [ "${FAILED}" != 0 ]; then
    journalctl --user -u 'firefox-sync-fxa-*' --no-pager | tail -40
  fi
  stop_quadlets
fi

echo "== cleanup"
rm -rf "${WORK}"

[ ${FAILED} = 0 ] && echo "RESULT podman: all checks passed" || echo "RESULT podman: some checks FAILED"
exit ${FAILED}
