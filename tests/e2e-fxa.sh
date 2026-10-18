#!/bin/bash
# End-to-end test of the stack with self-hosted Mozilla accounts (docker-compose.fxa.yml):
# sign-up, email verification, OAuth and sync through HTTPS, without any Mozilla service,
# and the admin UI (sign-up policy, accounts, max users), by default built from admin/.
#
# Usage: tests/e2e-fxa.sh
# Environment:
#   REPOSITORY, TAG  syncstorage images to test (default: ghcr.io/porelli/firefox-sync, latest)
#   FXA_IMAGE        accounts image (default: REPOSITORY, i.e. our builds)
#   FXA_VERSION      accounts image tag (default: fxa-mono-latest)
#   FXA_ARCH         amd64 or arm64 (default: this machine)
#   FXA_PAIRING_IMAGE pairing server image (default: REPOSITORY:fxa-channelserver-latest)
#   ADMIN_IMAGE      admin UI and sign-up policy image, used as is (default: built from admin/)
#   KEEP             set to 1 to leave the stack running (its settings: KEPT_ENV)
#   RERUN            set to 1 to run only the Python tests again, against the stack left
#                    by KEEP=1 (seconds instead of minutes, while working on a test)
#   ONLY             with RERUN: flow,admin,browser (default: all three)
#   PYTEST_ARGS      with RERUN: passed to pytest, e.g. "-k sign_out"
#   SKIP_BROWSER     set to 1 to skip the real Firefox test
#   FXA_ACCOUNT_EVENTS true (default here, off for users) records the security history of the
#                    accounts: every test then also runs with it on, test_fxa_admin.py checks it
#   SKIP_PULL        set to 1 to use the local images (e.g. an init image built from this tree)
#   FXA_DB           mysql (default, MySQL 8) or mariadb (FXA_MARIADB_IMAGE, docker-compose.fxa-mariadb.yml)
#                    for the accounts database
#   FXA_MARIADB_IMAGE with FXA_DB=mariadb (default: mariadb:lts, MariaDB 12 today, when the accounts image
#                    has mozilla/fxa#21494 in its label org.firefox-sync.upstream-patches (upstream-patches.yml);
#                    else mariadb:11, as for the installs from before, e.g. with Mozilla's images)
#   EXTERNAL_DB      set to 1 for one server outside the stack for Sync and the accounts, MySQL 8
#                    (FXA_MARIADB_IMAGE with FXA_DB=mariadb) (SYNC_DB_CONTAINERS=0, FXA_DB_CONTAINERS=0,
#                    DATABASES.md), container EXTDB, created with only the grants of
#                    db/mysql/; kept with KEEP, reused by RERUN. fxa: only the accounts
#                    there, with one user for the accounts and the sign-up policy
#   SLOT             runs next to each other on one host (tests/slot.sh): 0 (default) project
#                    ffs-e2e-fxa, port 28653 and the other ports of .env-example; 1, 2...: -s<SLOT>
#                    after the project, 1000 * SLOT added to 28653, the others at 28700-28706 + 1000 * SLOT
#   INIT_TAG         tag suffix of the init image (default: TAG), e.g. one built from this tree
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
# shellcheck source=tests/slot.sh
source "${TESTS}/slot.sh"
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
INIT_TAG=${INIT_TAG:-${TAG}}
PROJECT=ffs-e2e-fxa${SLOT_SUFFIX}
WORK=$(mktemp -d)
ENV_FILE=${WORK}/fxa.env
KEPT_ENV=${KEPT_ENV:-${HOME}/.cache/${PROJECT}.env}
ONLY=${ONLY:-flow,admin,browser}
PYTEST_ARGS=${PYTEST_ARGS:-}
runs() { [ -z "${RERUN:-}" ] || [[ ",${ONLY}," == *",$1,"* ]]; }

rnd() { tr -dc '[:alnum:]' < /dev/urandom 2> /dev/null | head -c 32; }
# the admin UI signs in with these accounts too (@example.com): its OAuth client, public
# (PKCE, no secret: the accounts service refuses PKCE from a client with a secret)
ADMIN_FXA_CLIENT_ID=ad41a7e5f0c0ffee
sed -e "s|<REPLACE_WITH_SOMETHING_SECURE>|RANDOM|" "${CODE}/.env-example" | while IFS= read -r line; do
  case "${line}" in *=RANDOM) echo "${line%RANDOM}$(rnd)" ;; *) echo "${line}" ;; esac
done | sed -e "s|^SYNC_PUBLIC_URL=.*|SYNC_PUBLIC_URL=https://sync.fxa.test|" \
    -e "s|^SYNC_EXPORT_PORT=.*|SYNC_EXPORT_PORT=127.0.0.1:$((28653 + SLOT_PORTS))|" \
    -e "s|^SYNC_MAX_USERS=.*|SYNC_MAX_USERS=initial:10|" \
    -e "s|^IMAGE_REPOSITORY=.*|IMAGE_REPOSITORY=${REPOSITORY}|" \
    -e "s|^SYNC_IMAGE_TAG=.*|SYNC_IMAGE_TAG=${TAG}|" \
    -e "s|^SYNC_INIT_IMAGE_TAG=.*|SYNC_INIT_IMAGE_TAG=${INIT_TAG}|" \
    -e "s|^FXA_EMAIL_DOMAIN=.*|FXA_EMAIL_DOMAIN=api.fxa.test|" \
    -e "s|^FXA_OAUTH_SERVER_URL=.*|FXA_OAUTH_SERVER_URL=http://fxa-auth:9000/v1|" \
    -e "s|^FXA_CONTENT_URL=.*|FXA_CONTENT_URL=https://accounts.fxa.test|" \
    -e "s|^FXA_AUTH_URL=.*|FXA_AUTH_URL=https://api.fxa.test|" \
    -e "s|^FXA_PROFILE_URL=.*|FXA_PROFILE_URL=https://profile.fxa.test|" \
    -e "s|^FXA_SMTP_HOST=.*|FXA_SMTP_HOST=mailpit|" \
    -e "s|^FXA_SMTP_PORT=.*|FXA_SMTP_PORT=1025|" \
    -e "s|^FXA_SMTP_USER=.*|FXA_SMTP_USER=test|" \
    -e "s|^FXA_SMTP_PASS=.*|FXA_SMTP_PASS=test|" \
    -e "s|^FXA_SMTP_SENDER=.*|FXA_SMTP_SENDER=\"Mozilla accounts <no-reply@fxa.test>\"|" \
    -e "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=pairing,admin,backup|" \
    -e "s|^BACKUP_KEEP=.*|BACKUP_KEEP=1|" \
    -e "s|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=$(rnd)|" \
    -e "s|^FXA_SIGNUPS=.*|FXA_SIGNUPS=allowlist|" \
    -e "s|^FXA_SIGNUP_ALLOWLIST=.*|FXA_SIGNUP_ALLOWLIST=@example.com,invited@example.net|" \
    -e "s|^# FXA_PAIRING_URL=.*|FXA_PAIRING_URL=wss://pairing.fxa.test|" \
    -e "s|^ADMIN_FXA_CLIENT_ID=.*|ADMIN_FXA_CLIENT_ID=${ADMIN_FXA_CLIENT_ID}|" \
    -e "s|^ADMIN_OIDC_REDIRECT_URL=.*|ADMIN_OIDC_REDIRECT_URL=https://admin.fxa.test/auth/callback|" \
    -e "s|^ADMIN_ALLOWED_USERS=.*|ADMIN_ALLOWED_USERS=@example.com|" \
    -e "s|^ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=.*|ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true|" \
    -e "s|^FXA_ACCOUNT_EVENTS=.*|FXA_ACCOUNT_EVENTS=${FXA_ACCOUNT_EVENTS:-true}|" \
    -e "/^COMPOSE_FILE=/d" > "${ENV_FILE}"
slot_fxa_ports "${ENV_FILE}"
# by default the accounts images of the registry under test, for this machine
case "$(uname -m)" in aarch64|arm64) default_arch=arm64 ;; *) default_arch=amd64 ;; esac
sed -i -e "s|^FXA_IMAGE=.*|FXA_IMAGE=${REPOSITORY}|" -e "s|^FXA_ARCH=.*|FXA_ARCH=${default_arch}|" \
    -e "s|^FXA_PAIRING_IMAGE=.*|FXA_PAIRING_IMAGE=${REPOSITORY}:fxa-channelserver-latest|" "${ENV_FILE}"
[ -n "${FXA_VERSION:-}" ] && sed -i "s|^FXA_VERSION=.*|FXA_VERSION=${FXA_VERSION}|" "${ENV_FILE}"
[ -n "${FXA_IMAGE:-}" ] && sed -i "s|^FXA_IMAGE=.*|FXA_IMAGE=${FXA_IMAGE}|" "${ENV_FILE}"
[ -n "${FXA_ARCH:-}" ] && sed -i "s|^FXA_ARCH=.*|FXA_ARCH=${FXA_ARCH}|" "${ENV_FILE}"
[ -n "${FXA_PAIRING_IMAGE:-}" ] && sed -i "s|^FXA_PAIRING_IMAGE=.*|FXA_PAIRING_IMAGE=${FXA_PAIRING_IMAGE}|" "${ENV_FILE}"
case "${FXA_DB:-mysql}" in mysql|mariadb) sed -i "s|^FXA_DB=.*|FXA_DB=${FXA_DB:-mysql}|" "${ENV_FILE}" ;; *) echo "FXA_DB: mysql or mariadb"; exit 2 ;; esac
# MariaDB lts (12) needs mozilla/fxa#21494 in the accounts image (upstream-patches.yml, the
# label our builds set; not in Mozilla's images nor in ours built before): MariaDB 11 without
# it, what prepare_environment.sh warns about
if [ "${FXA_DB:-mysql}" = mariadb ] && [ -z "${FXA_MARIADB_IMAGE:-}" ] && [ -z "${RERUN:-}" ]; then
  fxa_tested=$(sed -n 's/^FXA_IMAGE=//p' "${ENV_FILE}"):$(sed -n 's/^FXA_VERSION=//p' "${ENV_FILE}")
  docker image inspect "${fxa_tested}" > /dev/null 2>&1 || [ -n "${SKIP_PULL:-}" ] ||
    docker pull -q --platform "linux/$(sed -n 's/^FXA_ARCH=//p' "${ENV_FILE}")" "${fxa_tested}" > /dev/null
  fxa_patches=$(docker image inspect -f '{{index .Config.Labels "org.firefox-sync.upstream-patches"}}' "${fxa_tested}" 2> /dev/null)
  if [[ " ${fxa_patches} " == *" mozilla/fxa#21494@"* ]]; then
    FXA_MARIADB_IMAGE=mariadb:lts
  else
    FXA_MARIADB_IMAGE=mariadb:11
    echo "== ${fxa_tested} without mozilla/fxa#21494 (label org.firefox-sync.upstream-patches): the accounts on ${FXA_MARIADB_IMAGE}"
  fi
fi
# written out, as prepare_environment.sh does for a new install (unset it is lts too)
[ "${FXA_DB:-mysql}" = mariadb ] && sed -i "s|^# FXA_MARIADB_IMAGE=.*|FXA_MARIADB_IMAGE=${FXA_MARIADB_IMAGE:-mariadb:lts}|" "${ENV_FILE}"
# EXTERNAL_DB=1: a server elsewhere, its own container and network, reached by name
EXTDB=${PROJECT}-extdb
if [ -n "${EXTERNAL_DB:-}" ]; then
  sed -i -e "s|^FXA_DB_CONTAINERS=.*|FXA_DB_CONTAINERS=0|" -e "s|^FXA_MYSQL_HOST=.*|FXA_MYSQL_HOST=${EXTDB}|" \
      -e "s|^FXA_MYSQL_USER=.*|FXA_MYSQL_USER=fxa|" "${ENV_FILE}"
  # the backup service is for the database containers
  sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=pairing,admin|" "${ENV_FILE}"
  if [ "${EXTERNAL_DB}" = fxa ]; then
    # one user for both (DATABASES.md): a policy password left in .env must not be used
    sed -i "s|^FXA_MYSQL_POLICY_PASSWORD=.*|FXA_MYSQL_POLICY_PASSWORD=unused|" "${ENV_FILE}"
  else
    sed -i -e "s|^SYNC_DB_CONTAINERS=.*|SYNC_DB_CONTAINERS=0|" -e "s|^SYNC_DB_TLS_VERIFY=.*|SYNC_DB_TLS_VERIFY=false|" \
        -e "s|^SYNC_TOKENSERVER_DB_HOST=.*|SYNC_TOKENSERVER_DB_HOST=${EXTDB}|" \
        -e "s|^SYNC_STORAGE_DB_HOST=.*|SYNC_STORAGE_DB_HOST=${EXTDB}|" \
        -e "s|^FXA_MYSQL_POLICY_USER=.*|FXA_MYSQL_POLICY_USER=ffs_policy|" \
        -e "s|^FXA_MYSQL_POLICY_PASSWORD=.*|FXA_MYSQL_POLICY_PASSWORD=$(rnd)|" "${ENV_FILE}"
  fi
  # the server's administrator, for the checks below
  echo "EXTDB_ROOT=$(rnd)" >> "${ENV_FILE}"
fi
if [ -n "${RERUN:-}" ]; then
  [ -f "${KEPT_ENV}" ] || { echo "RERUN: no ${KEPT_ENV}, run with KEEP=1 first"; exit 2; }
  cp "${KEPT_ENV}" "${ENV_FILE}"
  KEEP=1
fi
set -a; source "${ENV_FILE}"; set +a
FXA_DB=${FXA_DB:-mysql}
# (RERUN: as the kept stack was started)
COMPOSE_EXTRA=()
[ "${FXA_DB}" = mariadb ] && COMPOSE_EXTRA=(-f "${CODE}/docker-compose.fxa-mariadb.yml")
if [ "${FXA_DB_CONTAINERS:-1}" = 0 ]; then
  export EXTDB_NETWORK=${EXTDB}
  COMPOSE_EXTRA+=(-f "${TESTS}/docker-compose.external-db-fxa-test.yml")
  [ "${SYNC_DB_CONTAINERS:-1}" = 0 ] && COMPOSE_EXTRA+=(-f "${TESTS}/docker-compose.external-db-test.yml")
fi
# the server's name and version as the admin UI shows them, its client
if [ "${FXA_DB}" = mariadb ]; then
  # a major (mariadb:11): MariaDB 11.x, a series (11.8): 11.8.x; lts or another name: any version
  FXA_MARIADB_IMAGE=${FXA_MARIADB_IMAGE:-mariadb:lts}
  case "${FXA_MARIADB_IMAGE##*:}" in
    [0-9]*.[0-9]*) FXA_DB_SERVER="MariaDB ${FXA_MARIADB_IMAGE##*:}" FXA_DB_SERVER=${FXA_DB_SERVER//./\\.} ;;
    [0-9]*) FXA_DB_SERVER="MariaDB ${FXA_MARIADB_IMAGE##*:}\\." ;;
    *) FXA_DB_SERVER='MariaDB [0-9]+\.[0-9]+' ;;
  esac
  DB_CLIENT=mariadb EXTDB_IMAGE=${FXA_MARIADB_IMAGE}
  # binary logging is off by default on MariaDB: on, as DATABASES.md expects it may be
  EXTDB_ARGS=(--log-bin --log-bin-trust-function-creators=ON)
else
  FXA_DB_SERVER='MySQL 8' DB_CLIENT=mysql EXTDB_IMAGE=mysql:8
  EXTDB_ARGS=(--mysql-native-password=ON --log-bin-trust-function-creators=ON)
fi
# the admin UI under test: ADMIN_IMAGE as is (pulled when missing), or built from admin/
ADMIN_GIVEN=${ADMIN_IMAGE:-}
export ADMIN_IMAGE=${ADMIN_IMAGE:-ffs-admin:test}

dc() {
  docker compose -p "${PROJECT}" --env-file "${ENV_FILE}" --project-directory "${CODE}" \
    -f "${CODE}/docker-compose.yml" -f "${CODE}/docker-compose.fxa.yml" -f "${TESTS}/docker-compose.fxa-test.yml" "${COMPOSE_EXTRA[@]}" "$@"
}
FAILED=0
# compose_healthy, the healthchecks of the stack
# shellcheck source=tests/healthy.sh
source "${TESTS}/healthy.sh"
# compose prefers the environment to --env-file: change both
set_env() { sed -i "s|^$1=.*|$1=$2|" "${ENV_FILE}"; export "$1=$2"; }
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; fi; }
state() { docker inspect -f "{{.State.$2}}" "$(dc ps -a -q "$1")" 2> /dev/null; }

teardown() {
  if [ -n "${KEEP:-}" ]; then
    # the stack's secrets: for this user only
    [ -n "${RERUN:-}" ] || (umask 077; mkdir -p "$(dirname "${KEPT_ENV}")"; install -m 600 "${ENV_FILE}" "${KEPT_ENV}")
    echo "keeping stack ${PROJECT} (env: ${KEPT_ENV}, run the tests again with RERUN=1)"
    return
  fi
  echo "== teardown"
  dc down -v --remove-orphans > /dev/null 2>&1
  docker rm -f "${EXTDB}" > /dev/null 2>&1
  docker network rm "${EXTDB}" > /dev/null 2>&1
  rm -f "${KEPT_ENV}"
  rm -rf "${WORK}"
}
trap teardown EXIT

if [ -z "${RERUN:-}" ]; then
echo "== prepare_environment.sh with self-hosted accounts"
SETUP=${WORK}/setup${SLOT_SUFFIX} && mkdir -p "${SETUP}" && cp -r "${CODE}/." "${SETUP}/" && rm -f "${SETUP}/.env"
# answers: domain, compose dir, port, max users, backend, [deploy method], user, image tag, admin UI,
# FxA, FxA domain, SMTP host, port, user, password, sender, sign-up allowlist, admin emails, admin host
answers=(sync.example.org "${SETUP}" 5000 2 mariadb)
command -v podman > /dev/null && answers+=(2)
admin_answer=$((${#answers[@]} + 2))
answers+=("" latest "" y "" smtp.example.org 587 mailer 'p@ss|w&rd\#1 $x' "" "alice@example.org, @example.net" "admin@example.org" "")
# the last questions: your own database servers for Sync and the accounts (no, no), the accounts database (mysql), max accounts
printf '%s\n' "${answers[@]}" "" "" "" 5 | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup.log" 2>&1
check "$?" 0 "prepare_environment.sh with self-hosted accounts"
password='p@ss|w&rd\#1 $x'
check "$(grep -cxF "FXA_SMTP_PASS='${password}'" "${SETUP}/.env")" 1 "SMTP password written as typed"
check "$(sed -n '/SELF-HOSTED MOZILLA ACCOUNTS/,$p' "${SETUP}/.env" | grep -v '^#' | grep -c REPLACE)" 0 "no placeholders left for the accounts"
check "$(cd "${SETUP}" && docker compose config --services 2> /dev/null | grep -c '^fxa-')" 11 "compose stack with the accounts services (and the optional pairing server)"
check "$(grep -c '^COMPOSE_PROFILES=admin$' "${SETUP}/.env")" 1 "admin UI enabled"
check "$(grep -c '^SYNC_MAX_USERS=initial:2$' "${SETUP}/.env")" 1 "max users managed in the admin UI (SYNC_MAX_USERS=initial:2)"
check "$(grep -c '^FXA_SIGNUPS=allowlist$' "${SETUP}/.env") $(grep -c '^FXA_SIGNUP_ALLOWLIST=alice@example.org,@example.net$' "${SETUP}/.env")" "1 1" "sign-up allowlist"
check "$(grep -c '^FXA_MAX_ACCOUNTS=initial:5$' "${SETUP}/.env")" 1 "max accounts managed in the admin UI (FXA_MAX_ACCOUNTS=initial:5)"
# the security history, the last question: not answered, off
check "$(grep -c '^FXA_ACCOUNT_EVENTS=false$' "${SETUP}/.env") $(grep -c 'kept with its IP address' "${WORK}/setup.log")" "1 1" "no security history by default, the question says why"
check "$(cd "${SETUP}" && env -i PATH="${PATH}" HOME="${HOME}" ${DOCKER_HOST:+DOCKER_HOST="${DOCKER_HOST}"} docker compose config 2> /dev/null | sed -n '/^  fxa-policy:/,/^  [a-z]/p' | grep -cE '^ +FXA_MAX_ACCOUNTS: "?initial:5"?$')" 1 \
  "fxa-policy gets FXA_MAX_ACCOUNTS"
# not a number: refused before anything is written
rm -f "${SETUP}/.env"
printf '%s\n' "${answers[@]}" "" "" "" lots | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-bad-max.log" 2>&1
check "$? $(grep -c "max accounts must be a number or unlimited, got 'lots'" "${WORK}/setup-bad-max.log")" "1 1" "prepare_environment.sh refuses max accounts lots"
# and the last question, a destination of the alerts: written as given, said without its token
# (separated by a space; Slack's https:// URL as pasted, turned into slack://)
printf '%s\n' "${answers[@]}" "" "" "" 5 y 'ntfy://tk_ffsSECRET@ntfy.example.org/ffs-topic https://hooks.slack.com/services/T0/B0/ffsSECRET2' | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup.log" 2>&1
check "$(grep -c '^FXA_ACCOUNT_EVENTS=true$' "${SETUP}/.env")" 1 "security history turned on (y)"
check "$(grep -cxF "ADMIN_NOTIFY='ntfy://tk_ffsSECRET@ntfy.example.org/ffs-topic,slack://hooks.slack.com/services/T0/B0/ffsSECRET2'" "${SETUP}/.env") $(grep -c 'tk_ffsSECRET\|ffsSECRET2\|ffs-topic' "${WORK}/setup.log") $(grep -c '^Alerts also to ntfy://ntfy.example.org, slack://hooks.slack.com ' "${WORK}/setup.log")" \
  "1 0 1" "ADMIN_NOTIFY written as pasted, shown as scheme://host only"
check "$(cd "${SETUP}" && env -u ADMIN_NOTIFY docker compose config 2> /dev/null | sed -n '/^  ffs-admin:/,/^  [a-z]/p' | grep -cE 'ADMIN_NOTIFY: "?ntfy://tk_ffsSECRET@ntfy.example.org/ffs-topic,slack://')" 1 \
  "the admin UI gets ADMIN_NOTIFY"
# a user or password with / ? # in it: refused, nothing after the scheme said (the .env
# of the run above kept for the checks below)
cp "${SETUP}/.env" "${WORK}/setup.env"
for notify in 'webhook://bot:ffs1234#abcd@example.com/x' 'webhook://alice:ffss3cr/et@example.com/hook' 'ntfy://user:ffspa?ss@host.example.org/topic'; do
  rm -f "${SETUP}/.env"
  printf '%s\n' "${answers[@]}" "" "" "" 5 y "${notify}" | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-notify.log" 2>&1
  check "$? $(grep -c '://…: an @ after the host, percent-encode / ? # in the user or password' "${WORK}/setup-notify.log") $(grep -c 'ffs1234\|ffss3cr\|ffspa\|abcd' "${WORK}/setup-notify.log")" "1 1 0" \
    "prepare_environment.sh refuses ${notify%%:*}:// with an @ after the host, without naming it"
done
cp "${WORK}/setup.env" "${SETUP}/.env"
check "$(cd "${SETUP}" && env -u FXA_ACCOUNT_EVENTS docker compose config 2> /dev/null | sed -n '/^  fxa-auth:/,/^  [a-z]/p' | grep -cE '^ +(ACCOUNT_EVENTS_ENABLED: "?true"?|IP_PROFILING_RECENCY: "?0"?)$') $(cd "${SETUP}" && env -u FXA_ACCOUNT_EVENTS docker compose config 2> /dev/null | sed -n '/^  ffs-admin:/,/^  [a-z]/p' | grep -cE '^ +FXA_ACCOUNT_EVENTS: "?true"?$')" \
  "2 1" "the accounts record the security history, never skip the sign-in code for a known IP address, the admin UI shows it"
check "$(grep -c 'server_name accounts.example.org;' "${SETUP}/config/nginx/fxa.conf")" 1 "nginx example for the accounts"
check "$(grep -c 'proxy_pass http://127.0.0.1:8091;' "${SETUP}/config/nginx/fxa.conf")" 1 "nginx sends sign-ups to the gate"
env_value() { grep "^$1=" "${SETUP}/.env" | cut -d= -f2-; }
check "$(env_value ADMIN_FXA_CLIENT_ID | grep -cE '^[0-9a-f]{16}$') [$(env_value ADMIN_FXA_CLIENT_SECRET)]" "1 []" "admin UI OAuth client: an id, public (no secret)"
check "$(env_value ADMIN_ALLOWED_USERS) $(env_value ADMIN_OIDC_REDIRECT_URL) $(env_value ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL)" \
  "admin@example.org https://admin.example.org/auth/callback true" "admin UI signs in with the accounts"
check "$(env_value ADMIN_OIDC_ISSUER) $(env_value ADMIN_OIDC_CLIENT_ID)" "https://accounts.example.org $(env_value ADMIN_FXA_CLIENT_ID)" "admin UI's OpenID Connect provider"
# the ID tokens' iss is the accounts' content URL, which the issuer must be exactly
check "$(env_value ADMIN_OIDC_ISSUER)" "$(env_value FXA_CONTENT_URL)" "admin UI's issuer is the accounts' issuer"
check "$(grep -c 'server_name admin.example.org;' "${SETUP}/config/nginx/fxa.conf") $(grep -c 'proxy_pass http://127.0.0.1:8090;' "${SETUP}/config/nginx/fxa.conf")" "1 1" \
  "nginx example for the admin UI host"
# (this shell has the stack's ADMIN_FXA_CLIENT_ID, which compose would prefer)
check "$(cd "${SETUP}" && env -u ADMIN_FXA_CLIENT_ID docker compose config 2> /dev/null | sed -n '/^  fxa-auth:/,/^  [a-z]/p' | grep -cE "^ +SERVICES_WITH_EMAIL_VERIFICATION: .*,$(env_value ADMIN_FXA_CLIENT_ID)$")" 1 \
  "the accounts always ask the sign-in code for the admin UI"
# the same with PostgreSQL, then without the admin UI (the answers after the backend
# are the same); compose as configured by .env, not by this shell's COMPOSE_PROFILES
# only what prepare_environment.sh wrote: not this shell's stack settings (compose
# prefers the environment to .env)
setup_compose() { (cd "${SETUP}" && env -i PATH="${PATH}" HOME="${HOME}" ${DOCKER_HOST:+DOCKER_HOST="${DOCKER_HOST}"} docker compose "$@" 2> /dev/null); }
prepare_again() {
  rm -f "${SETUP}/.env"
  answers[4]=$1; answers[admin_answer]=$2; answers[admin_answer+9]=${3-admin@example.org}
  printf '%s\n' "${answers[@]}" | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-$1-$2.log" 2>&1
}
prepare_again postgres ""
check "$?" 0 "prepare_environment.sh with PostgreSQL and self-hosted accounts"
check "$(grep -c '^COMPOSE_FILE=docker-compose.sync-postgres.yml:docker-compose.fxa.yml$' "${SETUP}/.env")" 1 "PostgreSQL compose file with the accounts"
check "$(setup_compose config --services | grep -cxE 'postgres_db|fxa-auth|fxa-policy|ffs-admin')" 4 "compose stack with PostgreSQL, the accounts and the admin UI"
check "$(setup_compose config | sed -n '/^  ffs-admin:/,/^  [a-z]/p' | grep -cE '^ +(TOKENSERVER_DB_TYPE: postgres|FXA_DB_HOST: fxa-db|MAX_USERS: "?initial:2"?)$')" 3 "admin UI for PostgreSQL and the accounts, with SYNC_MAX_USERS"
# Sync on MySQL 8 containers (SYNC_DB=mysql), the same mysql images
prepare_again mysql ""
check "$?" 0 "prepare_environment.sh with MySQL for Sync and self-hosted accounts"
check "$(env_value SYNC_DB) $(env_value SYNC_DB_TLS_VERIFY) $(grep -c '^COMPOSE_FILE=docker-compose.yml:docker-compose.sync-mysql.yml:docker-compose.fxa.yml$' "${SETUP}/.env")" \
  "mysql false 1" "Sync on MySQL 8 in .env, with the accounts"
check "$(setup_compose config | sed -n '/^  tokenserver_db:/,/^  [a-z]/p' | grep -cE '^ +(image: mysql:8|source: tokenserver-db-mysql|- --disable-log-bin)$')" 3 \
  "tokenserver_db on MySQL 8 without binary logging, in its own volume"
check "$(setup_compose config | sed -n '/^  tokenserver_db_init:/,/^  [a-z]/p' | grep -cE '^ +MARIADB_TLS_VERIFY: "?false"?$')" 1 "init container does not check MySQL's self-signed certificate"
prepare_again mariadb "" ""
check "$?" 0 "prepare_environment.sh with the admin UI, no admin emails (password only)"
check "$(grep -cE 'server_name admin\.|<ADMIN_' "${SETUP}/config/nginx/fxa.conf")" 0 "no admin UI host in the nginx example, password only"
check "[$(env_value ADMIN_FXA_CLIENT_ID)] [$(env_value ADMIN_OIDC_ISSUER)] [$(env_value ADMIN_OIDC_REDIRECT_URL)]" "[] [] []" "no admin UI sign-in with the accounts, password only"
# (without the stack's values of this shell)
setup_config=$(cd "${SETUP}" && env -u COMPOSE_PROFILES -u ADMIN_FXA_CLIENT_ID -u ADMIN_FXA_CLIENT_SECRET -u ADMIN_OIDC_REDIRECT_URL docker compose config 2> /dev/null)
check "$(echo "${setup_config}" | sed -n '/^  ffs-admin:/,/^  [a-z]/p' | grep -cE '^ +ADMIN_OIDC_(ISSUER|CLIENT_ID|NAME): ""$')" 3 "admin UI without OpenID Connect, password only"
check "$(echo "${setup_config}" | sed -n '/^  fxa-auth:/,/^  [a-z]/p' | grep -cE '^ +SERVICES_WITH_EMAIL_VERIFICATION: .*,$')" 1 "no admin UI client for the accounts, password only"
prepare_again mariadb n
check "$?" 0 "prepare_environment.sh with self-hosted accounts, without the admin UI"
check "$(grep -cE 'ADMIN_GATE_EXPORT_PORT|8091' "${SETUP}/config/nginx/fxa.conf")" 0 "no sign-up gate in the nginx example without the admin UI"
check "$(grep -cE 'server_name admin\.|<ADMIN_' "${SETUP}/config/nginx/fxa.conf") [$(env_value ADMIN_FXA_CLIENT_ID)]" "0 []" "no admin UI sign-in without the admin UI"
check "$(grep -c '^COMPOSE_PROFILES=' "${SETUP}/.env")" 0 "no compose profile without the admin UI"
check "$(grep -c '^SYNC_MAX_USERS=2$' "${SETUP}/.env")" 1 "plain SYNC_MAX_USERS=2 without the admin UI"
check "$(grep -c '^FXA_MAX_ACCOUNTS=unlimited$' "${SETUP}/.env")" 1 "max accounts unlimited by default, plain without the admin UI"
check "$(setup_compose config --services | grep -cxE 'fxa-policy|ffs-admin')" 1 "sign-up policy without the admin UI"
check "$(setup_compose config --services | grep -cx ffs-admin)" 0 "no admin UI service"
# your own servers for Sync and the accounts: the questions after all the others
# (database server? host, port, tokenserver database and user, storage database and user;
# the accounts? host, port, user, policy user)
answers[4]=mariadb; answers[admin_answer]=""; answers[admin_answer+9]=admin@example.org
external_answers=("${answers[@]}" y db.example.org "" "" "" sync_storage "" y "" 3307 "" "")
rm -f "${SETUP}/.env"
printf '%s\n' "${external_answers[@]}" | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-external.log" 2>&1
check "$?" 0 "prepare_environment.sh with your own database servers"
check "$(env_value SYNC_DB_CONTAINERS) $(env_value SYNC_DB_TLS_VERIFY) $(env_value SYNC_TOKENSERVER_DB_HOST):$(env_value SYNC_TOKENSERVER_DB_PORT) $(env_value SYNC_STORAGE_DB_HOST) $(env_value SYNC_STORAGE_DB_NAME)" \
  "0 false db.example.org:3306 db.example.org sync_storage" "Sync on your own server in .env"
check "$(env_value FXA_DB_CONTAINERS) $(env_value FXA_MYSQL_HOST):$(env_value FXA_MYSQL_PORT) $(env_value FXA_MYSQL_USER) $(env_value FXA_MYSQL_POLICY_USER) $(env_value FXA_MYSQL_POLICY_PASSWORD | grep -cE '^[A-Za-z0-9]{32}$')" \
  "0 db.example.org:3307 fxa ffs_policy 1" "the accounts on your own server in .env"
for f in database-setup.sql database-setup-fxa.sql; do
  check "$(stat -c %a "${SETUP}/${f}" 2> /dev/null) $(grep -c '@[A-Z_]*@' "${SETUP}/${f}")" "600 0" "${f}: for this user only, filled in"
done
check "$(grep -c "'tokenserver'@'%' IDENTIFIED BY '$(env_value SYNC_TOKENSERVER_DB_PASSWORD)'" "${SETUP}/database-setup.sql") $(grep -c 'ON `sync_storage`.\* TO' "${SETUP}/database-setup.sql")" \
  "2 3" "database-setup.sql with the generated password (created, set again) and the names given"
# the admin UI's own users and database, out of the Sync users' reach (the storage: the names
# given; with the storage on another server, the commented statements for it)
check "$(grep -c "'ffs_admin_\(ui\|sync\)'@'%' IDENTIFIED BY '$(env_value ADMIN_DB_PASSWORD)'" "${SETUP}/database-setup.sql") $(grep -cE "^GRANT (SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, LOCK TABLES ON \`ffs_admin\`\.\* TO 'ffs_admin_ui'|SELECT, EXECUTE ON \`tokenserver\`\.\* TO 'ffs_admin_sync'|SELECT, DELETE ON \`sync_storage\`\.\* TO 'ffs_admin_sync')@'%';$" "${SETUP}/database-setup.sql")" \
  "6 3" "database-setup.sql with the admin UI's users (its database; the Sync data) and its database"
check "$(grep -c "'fxa'@'%' IDENTIFIED WITH mysql_native_password BY '$(env_value FXA_MYSQL_PASSWORD)'" "${SETUP}/database-setup-fxa.sql") $(grep -c "'ffs_policy'@'%' IDENTIFIED BY '$(env_value FXA_MYSQL_POLICY_PASSWORD)'" "${SETUP}/database-setup-fxa.sql")" \
  "2 2" "database-setup-fxa.sql with the generated passwords"
check "$(grep -c "'ffs_admin'@'%' IDENTIFIED BY '$(env_value FXA_ADMIN_DB_PASSWORD)'" "${SETUP}/database-setup-fxa.sql") $(grep -c 'CREATE USER ON' "${SETUP}/database-setup-fxa.sql")" \
  "2 0" "database-setup-fxa.sql creates ffs_admin, no CREATE USER for the policy user"
check "$(grep -cE '(mysql|mariadb) -h db.example.org -P 3306 -u root -p < database-setup.sql' "${WORK}/setup-external.log")" 2 "prepare_environment.sh says how to run the SQL (MySQL, MariaDB)"
external_config=$(setup_compose config)
check "$(echo "${external_config}" | grep -cE '^ +replicas: 0$')" 3 "no database containers (replicas: 0)"
check "$(echo "${external_config}" | sed -n '/^  fxa-policy:/,/^  [a-z]/p' | grep -cE '^ +(FXA_DB_HOST: db.example.org|FXA_DB_PORT: "?3307"?|FXA_DB_ROOT_USER: ffs_policy)$')" 3 "sign-up policy installed by ffs_policy on your server"
check "$(echo "${external_config}" | sed -n '/^  fxa-auth:/,/^  [a-z]/p' | grep -cE '^ +(AUTH_|PUSHBOX_)?MYSQL_USERNAME: fxa$')" 3 "the accounts connect as fxa"
check "$(echo "${external_config}" | sed -n '/^  syncstorage:/,/^  [a-z]/p' | grep -cE '^ +SYNC_(SYNCSTORAGE|TOKENSERVER)__DATABASE_URL: mysql://[a-z]+:[A-Za-z0-9]+@db\.example\.org:3306/')" 2 "the Sync server connects to your server"
check "$(env_value FXA_DB) $(grep -c '^COMPOSE_FILE=docker-compose.yml:docker-compose.fxa.yml$' "${SETUP}/.env")" "mysql 1" "the accounts on MySQL by default"
# localhost is the container itself: refused
external_answers[admin_answer+12]=localhost
rm -f "${SETUP}/.env"
printf '%s\n' "${external_answers[@]}" | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-localhost.log" 2>&1
check "$? $(grep -c "would be the container itself" "${WORK}/setup-localhost.log")" "1 1" "prepare_environment.sh refuses localhost as the database host"
# unbracketed in the database URLs: refused
external_answers[admin_answer+12]=fd00::10
rm -f "${SETUP}/.env"
printf '%s\n' "${external_answers[@]}" | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-ipv6.log" 2>&1
check "$? $(grep -c "no IPv6 address" "${WORK}/setup-ipv6.log")" "1 1" "prepare_environment.sh refuses an IPv6 address as the database host"
# answers that would break the quoting of .env or add lines to it: refused, no .env
refused() {
  local at=$1 value=$2 message=$3 log="${WORK}/setup-refused-$1.log" bad=("${answers[@]}")
  bad[at]=${value}
  rm -f "${SETUP}/.env"
  printf '%s\n' "${bad[@]}" | (cd "${SETUP}" && ./prepare_environment.sh) > "${log}" 2>&1
  check "$? $(grep -c "${message}" "${log}") [$(ls "${SETUP}/.env" 2> /dev/null)]" "1 1 []" "prepare_environment.sh refuses ${value} (${message})"
}
refused $((admin_answer + 6)) "it's" "cannot contain a single quote"
refused $((admin_answer + 8)) "alice@example.org;rm" "not a list of emails and domains"
refused $((admin_answer + 9)) 'admin@example.org$(id)' "not a list of emails and domains"
refused $((admin_answer + 10)) "admin.example.org/x" "not a host name"
refused 3 ten "max users must be a number"
refused 4 sqlite "unknown database backend"
# answers about your own server that end up unquoted in database-setup.sql (run as
# root) and in the database URLs: refused, no .env, no SQL
external_answers[admin_answer+12]=db.example.org
external_at=$((admin_answer + 12))
refused_external() {
  local at=$1 value=$2 message=$3 log="${WORK}/setup-refused-external-$1.log" bad=("${external_answers[@]}")
  bad[at]=${value}
  rm -f "${SETUP}/.env" "${SETUP}"/database-setup*.sql
  printf '%s
' "${bad[@]}" | (cd "${SETUP}" && ./prepare_environment.sh) > "${log}" 2>&1
  check "$? $(grep -c "${message}" "${log}") [$(ls "${SETUP}/.env" "${SETUP}"/database-setup*.sql 2> /dev/null)]" "1 1 []" "prepare_environment.sh refuses '${value}' (${message})"
}
refused_external $((external_at + 2)) "tokenserver;drop" "not a valid database or user name"
refused_external $((external_at + 5)) "Sync-User" "not a valid database or user name"
refused_external $((external_at + 4)) "tokenserver" "need two databases"
refused_external $((external_at + 1)) "33o6" "not a port"
refused_external "${external_at}" "" "database host is required"
# the accounts on MariaDB: the last question (EOF above: mysql)
external_answers[admin_answer+12]=db.example.org
rm -f "${SETUP}/.env"
printf '%s\n' "${external_answers[@]}" mariadb | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-external-mariadb.log" 2>&1
check "$?" 0 "prepare_environment.sh with your own MariaDB server for the accounts"
check "$(grep -c "'fxa'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('$(env_value FXA_MYSQL_PASSWORD)')" "${SETUP}/database-setup-fxa.sql") $(grep -c 'mariadb -h db.example.org -P 3307 -u root -p < database-setup-fxa.sql' "${WORK}/setup-external-mariadb.log")" \
  "2 1" "database-setup-fxa.sql for MariaDB"
# Sync on your own PostgreSQL server (host, port, database, user), the accounts built in
answers[4]=postgres
rm -f "${SETUP}/.env" "${SETUP}"/database-setup*.sql
printf '%s\n' "${answers[@]}" y db.example.org "" "" "" n | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-external-postgres.log" 2>&1
check "$?" 0 "prepare_environment.sh with your own PostgreSQL server"
check "$(env_value SYNC_DB_CONTAINERS) $(env_value SYNC_POSTGRES_HOST):$(env_value SYNC_POSTGRES_PORT) $(env_value SYNC_POSTGRES_NAME) $(env_value SYNC_POSTGRES_USER) $(env_value FXA_DB_CONTAINERS)" \
  "0 db.example.org:5432 syncserver syncserver 1" "Sync on your own PostgreSQL server in .env"
check "$(stat -c %a "${SETUP}/database-setup.sql" 2> /dev/null) $(grep -c '@[A-Z_]*@' "${SETUP}/database-setup.sql") $(grep -c "ROLE syncserver .*PASSWORD '$(env_value SYNC_POSTGRES_PASSWORD)'" "${SETUP}/database-setup.sql") [$(ls "${SETUP}/database-setup-fxa.sql" 2> /dev/null)]" \
  "600 0 2 []" "database-setup.sql for PostgreSQL with the generated password, none for the built-in accounts"
check "$(grep -c "ROLE ffs_admin_\(ui\|sync\) .*PASSWORD '$(env_value ADMIN_DB_PASSWORD)'" "${SETUP}/database-setup.sql") $(grep -cxE '(CREATE DATABASE ffs_admin OWNER ffs_admin_ui TEMPLATE template0 ALLOW_CONNECTIONS false|REVOKE ALL ON DATABASE ffs_admin FROM PUBLIC|ALTER DATABASE ffs_admin ALLOW_CONNECTIONS true|REVOKE CREATE ON SCHEMA public FROM PUBLIC);' "${SETUP}/database-setup.sql")" \
  "4 4" "database-setup.sql for PostgreSQL with the admin UI's roles and its own database, from template0"
check "$(grep -c 'psql -h db.example.org -p 5432 -U postgres -f database-setup.sql' "${WORK}/setup-external-postgres.log")" 1 "prepare_environment.sh says how to run the SQL (PostgreSQL)"
check "$(setup_compose config | sed -n '/^  postgres_db:/,/^  [a-z]/p' | grep -cE '^ +replicas: 0$') $(setup_compose config | sed -n '/^  syncstorage:/,/^  [a-z]/p' | grep -cE '^ +SYNC_(SYNCSTORAGE|TOKENSERVER)__DATABASE_URL: postgres(ql)?://syncserver:[A-Za-z0-9]+@db\.example\.org:5432/syncserver$')" \
  "1 2" "no postgres_db container, the Sync server connects to your server"
answers[4]=mariadb
rm -f "${SETUP}/.env" "${SETUP}"/database-setup*.sql
printf '%s\n' "${answers[@]}" n n mariadb | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-mariadb.log" 2>&1
check "$?" 0 "prepare_environment.sh with the accounts on MariaDB"
check "$(env_value FXA_DB) $(grep -c '^COMPOSE_FILE=docker-compose.yml:docker-compose.fxa.yml:docker-compose.fxa-mariadb.yml$' "${SETUP}/.env")" "mariadb 1" "MariaDB for the accounts in .env"
check "$(env_value FXA_MARIADB_IMAGE) $(setup_compose config | sed -n '/^  fxa-db:/,/^  [a-z]/p' | grep -cE '^ +(image: mariadb:lts|source: fxa-db-mariadb|- mariadbd)$')" "mariadb:lts 3" "fxa-db on MariaDB lts for a new install, in its own volume"
check "$(setup_compose --profile backup config | sed -n '/^  backup-fxa:/,/^  [a-z]/p' | grep -cE '^ +image: mariadb:lts$')" 1 "the backups of the accounts with the same MariaDB"
# an install from before FXA_MARIADB_IMAGE (MariaDB 11): the new files alone move it to lts
# (MIGRATING.md says so), run again it is pinned to 11 and stays there
sed -i '/^FXA_MARIADB_IMAGE=/d' "${SETUP}/.env"
check "$(setup_compose --profile backup config | awk '/^  [a-z]/ { on = ($1 == "fxa-db:" || $1 == "backup-fxa:") } on' | grep -cE '^ +image: mariadb:lts$')" 2 "without FXA_MARIADB_IMAGE: fxa-db and its backups on MariaDB lts"
printf '%s\n' "${answers[@]}" n n mariadb | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-mariadb-again.log" 2>&1
check "$? $(env_value FXA_MARIADB_IMAGE) $(grep -c 'stays on MariaDB 11\.' "${WORK}/setup-mariadb-again.log")" "0 mariadb:11 1" "prepare_environment.sh again on an install on MariaDB 11 keeps it there"
check "$(setup_compose config | sed -n '/^  fxa-db:/,/^  [a-z]/p' | grep -cE '^ +image: mariadb:11$')" 1 "fxa-db on MariaDB 11 after running it again"
printf '%s\n' "${answers[@]}" n n mariadb | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-mariadb-again2.log" 2>&1
check "$? $(env_value FXA_MARIADB_IMAGE) $(grep -c 'stays on MariaDB 11\.' "${WORK}/setup-mariadb-again2.log")" "0 mariadb:11 0" "and again: FXA_MARIADB_IMAGE kept, nothing to say"
# --upgrade of an install from before
sed -i '/^FXA_MARIADB_IMAGE=/d' "${SETUP}/.env"
(cd "${SETUP}" && ./prepare_environment.sh --upgrade) > "${WORK}/setup-mariadb-upgrade.log" 2>&1
check "$? $(env_value FXA_MARIADB_IMAGE) $(grep -c 'stays on MariaDB 11\.' "${WORK}/setup-mariadb-upgrade.log")" "0 mariadb:11 1" "prepare_environment.sh --upgrade pins MariaDB 11"
# MariaDB lts (12) with Mozilla's images (no mozilla/fxa#21494): a warning; with 11 none
sed -i -e 's|^FXA_IMAGE=.*|FXA_IMAGE=docker.io/mozilla/fxa-mono|' -e 's|^FXA_VERSION=.*|FXA_VERSION=v1.347.3|' "${SETUP}/.env"
(cd "${SETUP}" && ./prepare_environment.sh --upgrade) > "${WORK}/setup-mariadb-mozilla-11.log" 2>&1
check "$? $(grep -c 'mozilla/fxa#21494' "${WORK}/setup-mariadb-mozilla-11.log")" "0 0" "Mozilla's images on MariaDB 11: no warning"
sed -i 's|^FXA_MARIADB_IMAGE=.*|FXA_MARIADB_IMAGE=mariadb:lts|' "${SETUP}/.env"
(cd "${SETUP}" && ./prepare_environment.sh --upgrade) > "${WORK}/setup-mariadb-mozilla-lts.log" 2>&1
check "$? $(grep -c 'WARNING: the accounts on MariaDB lts (FXA_MARIADB_IMAGE=mariadb:lts) need an image with mozilla/fxa#21494' "${WORK}/setup-mariadb-mozilla-lts.log")" "0 1" "Mozilla's images on MariaDB lts: a warning"
rm -f "${SETUP}/.env" "${SETUP}"/.env.before-upgrade
# a new setup over the MariaDB volume of an earlier install (its .env gone): kept on 11
volume="$(basename "${SETUP}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')_fxa-db-mariadb"
docker volume create "${volume}" > /dev/null
printf '%s\n' "${answers[@]}" n n mariadb | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-mariadb-volume.log" 2>&1
check "$? $(env_value FXA_MARIADB_IMAGE) $(grep -c "found the accounts database of an earlier install (docker volume ${volume})" "${WORK}/setup-mariadb-volume.log")" "0 mariadb:11 1" \
  "prepare_environment.sh keeps MariaDB 11 for the volume of an earlier install"
docker volume rm "${volume}" > /dev/null
rm -f "${SETUP}/.env"
printf '%s\n' "${answers[@]}" n n postgres | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup-fxa-db-wrong.log" 2>&1
check "$? $(grep -c "ERROR: mysql or mariadb" "${WORK}/setup-fxa-db-wrong.log")" "1 1" "prepare_environment.sh refuses another accounts database"

echo "== ${PROJECT}: syncstorage ${REPOSITORY} ${TAG}, mozilla/fxa-mono ${FXA_VERSION}, accounts on ${FXA_DB}"
if [ -z "${ADMIN_GIVEN}" ]; then
  # (one build of the tag at a time: the other tests build it too)
  COMPOSE_BAKE=false one_at_a_time admin-build docker compose -p ffs-admin-build -f "${TESTS}/docker-compose.admin-build.yml" build -q || { echo "FAIL: admin UI image built from admin/"; exit 1; }
fi
[ -n "${SKIP_PULL:-}" ] || dc pull -q || exit 1
# left by an earlier run with KEEP=1: a fresh stack, not its volumes or database server
dc down -v --remove-orphans > /dev/null 2>&1
docker rm -f "${EXTDB}" > /dev/null 2>&1
docker network rm "${EXTDB}" > /dev/null 2>&1
if [ "${FXA_DB_CONTAINERS:-1}" = 0 ]; then
  echo "== external database server ${EXTDB} (${EXTDB_IMAGE}) for $([ "${SYNC_DB_CONTAINERS:-1}" = 0 ] && echo "Sync and ")the accounts"
  docker network create "${EXTDB}" > /dev/null
  # as DATABASES.md says: native passwords for the accounts' driver, binary logging
  # with the trigger and function of the sign-up policy and of SYNC_MAX_USERS
  docker run -d --rm --name "${EXTDB}" --network "${EXTDB}" --tmpfs /var/lib/mysql -e MYSQL_ROOT_PASSWORD="${EXTDB_ROOT}" \
    "${EXTDB_IMAGE}" "${EXTDB_ARGS[@]}" > /dev/null
  extdb_admin() { docker exec -i -e MYSQL_PWD="${EXTDB_ROOT}" "${EXTDB}" "${DB_CLIENT}" -uroot -h 127.0.0.1 --protocol=tcp -sN "$@"; }
  for _ in $(seq 1 90); do extdb_admin -e 'SELECT 1' < /dev/null > /dev/null 2>&1 && break; sleep 2; done
  # one user for both: as DATABASES.md says, without the policy user's own lines
  if [ -z "${FXA_MYSQL_POLICY_USER}" ]; then
    fxa_template() { grep -v "^[A-Z ]* USER [A-Z ]*'@FXA_POLICY_USER@'" "$1" | sed "s|@FXA_POLICY_USER@|@FXA_USER@|g"; }
  else
    fxa_template() { cat "$1"; }
  fi
  { [ "${SYNC_DB_CONTAINERS:-1}" = 0 ] && sed -e "s|@SYNC_TOKENSERVER_DATABASE@|${SYNC_TOKENSERVER_DB_NAME}|g" -e "s|@SYNC_TOKENSERVER_USER@|${SYNC_TOKENSERVER_DB_USER}|g" \
        -e "s|@SYNC_TOKENSERVER_PASSWORD@|${SYNC_TOKENSERVER_DB_PASSWORD}|g" -e "s|@SYNC_STORAGE_DATABASE@|${SYNC_STORAGE_DB_NAME}|g" \
        -e "s|@SYNC_STORAGE_USER@|${SYNC_STORAGE_DB_USER}|g" -e "s|@SYNC_STORAGE_PASSWORD@|${SYNC_STORAGE_DB_PASSWORD}|g" \
        -e "s|@ADMIN_DATABASE@|${ADMIN_DB_NAME}|g" -e "s|@ADMIN_USER@|${ADMIN_DB_USER}|g" -e "s|@ADMIN_SYNC_USER@|${ADMIN_DB_SYNC_USER}|g" -e "s|@ADMIN_PASSWORD@|${ADMIN_DB_PASSWORD}|g" \
        "${CODE}/db/mysql/sync.sql"
    fxa_template "${CODE}/db/mysql/fxa-${FXA_DB}.sql" | sed -e "s|@FXA_USER@|${FXA_MYSQL_USER}|g" -e "s|@FXA_PASSWORD@|${FXA_MYSQL_PASSWORD}|g" \
        -e "s|@FXA_POLICY_USER@|${FXA_MYSQL_POLICY_USER}|g" -e "s|@FXA_POLICY_PASSWORD@|${FXA_MYSQL_POLICY_PASSWORD}|g" \
        -e "s|@FXA_ADMIN_PASSWORD@|${FXA_ADMIN_DB_PASSWORD}|g"; } > "${WORK}/database-setup.sql"
  check "$(grep -c '@[A-Z_]*@' "${WORK}/database-setup.sql")" 0 "external database: SQL templates filled in"
  extdb_admin < "${WORK}/database-setup.sql"
  check "$?" 0 "external database server with the users of db/mysql/"
fi
dc up -d > "${WORK}/up.log" 2>&1 || { echo "FAIL: compose up"; grep -iE "error|fail" "${WORK}/up.log" | tail -10; }
echo "== waiting for FxA (slow under emulation)"
for _ in $(seq 1 600); do
  [ "$(state fxa-content Health.Status)" = healthy ] && [ "$(state syncstorage Health.Status)" = healthy ] && break
  [ "$(state fxa-migrations ExitCode)" != "" ] && [ "$(state fxa-migrations ExitCode)" != 0 ] && break
  crashing=""
  for s in fxa-auth fxa-content fxa-profile; do [ "$(state "${s}" RestartCount || echo 0)" -ge 3 ] 2> /dev/null && crashing="${s}"; done
  [ -n "${crashing}" ] && { echo "${crashing} keeps restarting"; break; }
  sleep 2
done
check "$(state fxa-migrations ExitCode)" 0 "FxA database migrations"
check "$(state fxa-auth Health.Status)" healthy "FxA auth server healthy"
check "$(state fxa-content Health.Status)" healthy "FxA content server healthy"
check "$(state syncstorage Health.Status)" healthy "syncstorage healthy"
if [ "${FAILED}" != 0 ]; then
  tail -20 "${WORK}/up.log"
  for s in fxa-migrations fxa-auth fxa-content fxa-profile syncstorage; do echo "---- ${s}"; dc logs --tail 25 "${s}" 2>&1; done
  exit 1
fi
else
  echo "== RERUN against the kept stack ${PROJECT} (${ONLY}) ${PYTEST_ARGS}"
fi

if runs flow; then
echo "== sign-up, OAuth and sync through self-hosted FxA"
dc run --rm -T --no-deps --user root \
  -v "${TESTS}:/tests:ro" -v "${PROJECT}_caddy-ca:/caddy-ca:ro" \
  -e REQUESTS_CA_BUNDLE=/caddy-ca/root.crt \
  -e FXA_CONTENT_URL -e FXA_AUTH_URL -e FXA_PROFILE_URL -e FXA_PAIRING_URL -e SYNC_PUBLIC_URL -e MAILPIT_URL=http://mailpit:8025 \
  -e ADMIN_URL=https://admin.fxa.test -e ADMIN_PASSWORD \
  -e PYTHONPATH=/app:/app/tools -e PYTHONDONTWRITEBYTECODE=1 \
  --entrypoint /bin/sh syncstorage \
  -c "cd /app && python3 -m pytest -q -p no:cacheprovider /tests/test_fxa_flow.py ${PYTEST_ARGS} > /tmp/pytest.log 2>&1; rc=\$?; tail -40 /tmp/pytest.log; exit \$rc" < /dev/null
check "$?" 0 "self-hosted FxA flow tests"
fi

# test_fxa_admin.py, with the arguments of pytest
admin_tests() {
dc run --rm -T --no-deps --user root \
  -v "${TESTS}:/tests:ro" -v "${PROJECT}_caddy-ca:/caddy-ca:ro" \
  -e REQUESTS_CA_BUNDLE=/caddy-ca/root.crt \
  -e FXA_CONTENT_URL -e FXA_AUTH_URL -e FXA_PROFILE_URL -e SYNC_PUBLIC_URL -e MAILPIT_URL=http://mailpit:8025 \
  -e ADMIN_URL=https://admin.fxa.test -e ADMIN_PASSWORD -e FXA_DIRECT_URL=http://fxa-auth:9000 -e ADMIN_FXA_CLIENT_ID \
  -e FXA_DB_SERVER="${FXA_DB_SERVER}" -e FXA_ACCOUNT_EVENTS -e PYTHONPATH=/app:/app/tools:/tests -e PYTHONDONTWRITEBYTECODE=1 \
  -e FXA_TEST_DB_URL="mysql://${FXA_MYSQL_USER}:${FXA_MYSQL_PASSWORD}@${FXA_MYSQL_HOST}:${FXA_MYSQL_PORT}/fxa" \
  -e ADMIN_DB_URL="mysql://${ADMIN_DB_USER}:${ADMIN_DB_PASSWORD}@${SYNC_TOKENSERVER_DB_HOST}:${SYNC_TOKENSERVER_DB_PORT}/${ADMIN_DB_NAME}" \
  --entrypoint /bin/sh syncstorage \
  -c "cd /app && python3 -m pytest -q -p no:cacheprovider /tests/test_fxa_admin.py $1 > /tmp/pytest.log 2>&1; rc=\$?; tail -40 /tmp/pytest.log; exit \$rc" < /dev/null
}
if runs admin; then
echo "== sign-up policy, admin UI, rate limits"
admin_tests "${PYTEST_ARGS}"
check "$?" 0 "sign-up policy and admin UI tests"
fi

if [ -z "${RERUN:-}" ]; then
echo "== settings from the admin UI survive a restart, .env changes replace them (SYNC_MAX_USERS: a plain number)"
if [ "${FXA_DB_CONTAINERS:-1}" = 0 ]; then
  fxa_sql() { docker exec -i -e MYSQL_PWD="${EXTDB_ROOT}" "${EXTDB}" "${DB_CLIENT}" -uroot -sN -e "$1" < /dev/null 2> /dev/null; }
  echo "== external database server: nothing more than the documented grants"
  sync_external=$([ "${SYNC_DB_CONTAINERS:-1}" = 0 ] && echo 1 || echo 0)
  check "$(dc ps -a --format '{{.Service}}' | grep -cxE 'syncstorage_db|tokenserver_db') $(dc ps -a --format '{{.Service}}' | grep -cx fxa-db)" \
    "$([ "${sync_external}" = 1 ] && echo 0 || echo 2) 0" "no database container in the project for what is on your server"
  check "$(fxa_sql "SELECT COUNT(*) FROM mysql.user WHERE (Super_priv = 'Y' OR Create_user_priv = 'Y') AND user IN ('fxa', 'ffs_policy', 'ffs_admin', '${SYNC_TOKENSERVER_DB_USER}', '${SYNC_STORAGE_DB_USER}')")" 0 "no SUPER or CREATE USER for the stack's users"
  check "$(fxa_sql "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_name IN ('BeforeInsertUser', 'ffs_signup_policy')")" $((sync_external + 1)) "sign-up (and SYNC_MAX_USERS) triggers on your server"
  check "$(fxa_sql "SELECT DEFINER FROM information_schema.triggers WHERE trigger_name = 'ffs_signup_policy'")" "${FXA_MYSQL_POLICY_USER:-${FXA_MYSQL_USER}}@%" "sign-up policy installed by ${FXA_MYSQL_POLICY_USER:-${FXA_MYSQL_USER}}"
  # the view runs as the policy user: all 5 databases only with its SELECT on them
  check "$(fxa_sql "SELECT COUNT(*) FROM ffs.database_sizes")" 5 "the admin UI sees the sizes of all the accounts databases"
else
  fxa_sql() { dc exec -T fxa-db "${DB_CLIENT}" -uroot -p"${FXA_MYSQL_PASSWORD}" -sN -e "$1" 2> /dev/null; }
fi
if [ "${SYNC_DB_CONTAINERS:-1}" = 0 ]; then
  ts_sql() { docker exec -i -e MYSQL_PWD="${SYNC_TOKENSERVER_DB_PASSWORD}" "${EXTDB}" "${DB_CLIENT}" -u"${SYNC_TOKENSERVER_DB_USER}" "${SYNC_TOKENSERVER_DB_NAME}" -sN -e "$1" < /dev/null 2> /dev/null; }
  admin_sql() { docker exec -i -e MYSQL_PWD="${ADMIN_DB_PASSWORD}" "${EXTDB}" "${DB_CLIENT}" -u"${ADMIN_DB_USER}" "${ADMIN_DB_NAME}" -sN -e "$1" < /dev/null 2> /dev/null; }
else
  ts_sql() { dc exec -T tokenserver_db mariadb -u"${SYNC_TOKENSERVER_DB_USER}" -p"${SYNC_TOKENSERVER_DB_PASSWORD}" "${SYNC_TOKENSERVER_DB_NAME}" -sN -e "$1" 2> /dev/null; }
  # the admin UI's own database (the event log, the backup runs), as its user
  admin_sql() { dc exec -T tokenserver_db mariadb -u"${ADMIN_DB_USER}" -p"${ADMIN_DB_PASSWORD}" "${ADMIN_DB_NAME}" -sN -e "$1" 2> /dev/null; }
fi
echo "== the admin UI's user changes the accounts only through the procedures of fxa-policy"
# (the errors too; not the warning of the MariaDB client about MYSQL_PWD)
if [ "${FXA_DB_CONTAINERS:-1}" = 0 ]; then
  as_ffs_admin() { docker exec -i -e MYSQL_PWD="${FXA_ADMIN_DB_PASSWORD}" "${EXTDB}" "${DB_CLIENT}" -uffs_admin -h 127.0.0.1 --protocol=tcp -sN -e "$1" < /dev/null 2>&1 | grep -v '^WARNING: '; }
else
  as_ffs_admin() { dc exec -T -e MYSQL_PWD="${FXA_ADMIN_DB_PASSWORD}" fxa-db "${DB_CLIENT}" -uffs_admin -h 127.0.0.1 --protocol=tcp -sN -e "$1" < /dev/null 2>&1 | grep -v '^WARNING: '; }
fi
check "$(as_ffs_admin 'SELECT COUNT(uid) > 0 FROM fxa.accounts')" 1 "ffs_admin reads the accounts"
check "$(as_ffs_admin 'DELETE FROM fxa.sessionTokens WHERE uid IS NULL' | grep -c 'command denied')" 1 "ffs_admin cannot delete FxA's sessions itself"
check "$(as_ffs_admin 'UPDATE fxa.accounts SET disabledAt = NULL WHERE uid IS NULL' | grep -c 'command denied')" 1 "ffs_admin cannot change fxa.accounts itself"
check "$(as_ffs_admin 'SHOW GRANTS' | grep -cE 'GRANT .*(UPDATE|DELETE|INSERT).* ON `?fxa(_oauth)?`?\.')" 0 "no grant to change FxA's tables for ffs_admin"
check "$(as_ffs_admin 'SHOW GRANTS' | grep -cE 'GRANT EXECUTE ON PROCEDURE `?ffs`?\.`?(disable_account|enable_account|sign_out_all|delete_account|delete_unconfirmed|prune)`?')" 6 "ffs_admin runs the procedures to disable, enable, sign out, delete and prune"
check "$(fxa_sql "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = 'ffs' AND ROUTINE_NAME IN ('disable_account', 'enable_account', 'sign_out_all', 'remove_totp', 'remove_recovery_key', 'confirm_email', 'delete_account', 'delete_unconfirmed', 'prune')")" 9 "fxa-policy installed the account procedures"
# what they run on is Mozilla's: no stand-in refusing (a procedure of FxA missing, or no EXECUTE on fxa.*)
check "$(fxa_sql "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = 'ffs' AND ROUTINE_DEFINITION LIKE '%missing from the accounts database%'")" 0 "no account procedure replaced by a stand-in"
# the procedures take the database's time, whatever ffs_admin passes: no fresh account
# deleted, no recent security event pruned, with a time far in the future
newest=$(fxa_sql "SELECT HEX(uid) FROM fxa.accounts ORDER BY createdAt DESC LIMIT 1")
check "$(as_ffs_admin "CALL ffs.delete_unconfirmed(UNHEX('${newest}'), 9000000000000000)" | grep -c 'not an account unconfirmed since before the cutoff')" 1 "ffs.delete_unconfirmed refuses an account created today"
recent_events() { fxa_sql "SELECT COUNT(*) FROM fxa.securityEvents WHERE createdAt > UNIX_TIMESTAMP() * 1000 - 43200000"; }
events_before=$(recent_events)
as_ffs_admin "CALL ffs.prune(9000000000000000, 9000000000000000)" > /dev/null
check "$(recent_events) $(fxa_sql "SELECT CAST(value AS SIGNED) <= UNIX_TIMESTAMP() * 1000 FROM fxa.dbMetadata WHERE name = 'prune-last-ran'")" "${events_before} 1" "ffs.prune keeps the security events of the last day and records the database's time"
# how accounts sign in, through the views: never the secrets behind them
check "$(as_ffs_admin 'SELECT COUNT(*) > 0 FROM ffs.account_security') $(as_ffs_admin 'SELECT COUNT(*) > 0 FROM ffs.emails')" "1 1" "ffs_admin reads the sign-in security and the emails through the views"
# the security history: through the view, not the table (its JSON can hold a phone number)
if [ "${FXA_ACCOUNT_EVENTS}" = true ]; then
  check "$(as_ffs_admin "SELECT COUNT(*) > 0 FROM ffs.security_events WHERE name = 'account.login' AND ipAddr <> ''")" 1 "ffs_admin reads the security history through the view"
else
  check "$(fxa_sql "SELECT COUNT(*) FROM fxa.securityEvents")" 0 "no security history with FXA_ACCOUNT_EVENTS=false"
fi
check "$(as_ffs_admin 'SELECT additionalInfo FROM fxa.securityEvents LIMIT 1' | grep -c 'command denied')" 1 "ffs_admin cannot read fxa.securityEvents itself"
for secret in 'sharedSecret FROM fxa.totp' 'codeHash FROM fxa.recoveryCodes' 'recoveryData FROM fxa.recoveryKeys' 'phoneNumber FROM fxa.recoveryPhones' 'emailCode FROM fxa.accounts'; do
  check "$(as_ffs_admin "SELECT ${secret} LIMIT 1" | grep -cE 'command denied|denied for column')" 1 "ffs_admin cannot read ${secret}"
done
check "$(as_ffs_admin "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = 'ffs' AND column_name IN ('sharedSecret', 'codeHash', 'recoveryData', 'phoneNumber', 'emailCode', 'tokenId')")" 0 "no secret column in the views of ffs_admin"
dc run --rm --no-deps fxa-policy > /dev/null 2>&1
check "$?" 0 "sign-up policy restarted"
check "$(fxa_sql "SELECT COUNT(*) FROM ffs.signup_allowlist WHERE entry = 'kept@example.net'")" 1 "allowlist set in the admin UI kept"
dc run --rm --no-deps tokenserver_db_init > /dev/null 2>&1
check "$(ts_sql "SELECT config_value FROM config WHERE config_key = 'max_users'")" 7 "max users set in the admin UI kept (SYNC_MAX_USERS=initial:10)"
set_env FXA_SIGNUP_ALLOWLIST @example.com
dc run --rm --no-deps fxa-policy > /dev/null 2>&1
check "$(fxa_sql "SELECT GROUP_CONCAT(entry) FROM ffs.signup_allowlist")" "@example.com" "allowlist changed in .env applied"
set_env SYNC_MAX_USERS 11
dc run --rm --no-deps tokenserver_db_init > /dev/null 2>&1
check "$(ts_sql "SELECT config_value FROM config WHERE config_key = 'max_users'")" 11 "plain SYNC_MAX_USERS=11 in .env applied over the admin UI"
set_env SYNC_MAX_USERS initial:12
dc run --rm --no-deps tokenserver_db_init > /dev/null 2>&1
check "$(ts_sql "SELECT config_value FROM config WHERE config_key = 'max_users'")" 11 "SYNC_MAX_USERS=initial:12 keeps the value in the database"
# FXA_MAX_ACCOUNTS the same way (not set here: initial:unlimited); test_fxa_admin.py set it to unlimited on the page
fxa_max() { fxa_sql "SELECT value FROM ffs.settings WHERE name = 'max_accounts'"; }
check "$(fxa_max)" unlimited "max accounts set in the admin UI kept (FXA_MAX_ACCOUNTS not set)"
set_env FXA_MAX_ACCOUNTS 500
dc run --rm --no-deps fxa-policy > /dev/null 2>&1
check "$(fxa_max)" 500 "plain FXA_MAX_ACCOUNTS=500 in .env applied over the admin UI"
set_env FXA_MAX_ACCOUNTS initial:9
dc run --rm --no-deps fxa-policy > /dev/null 2>&1
check "$(fxa_max)" 500 "FXA_MAX_ACCOUNTS=initial:9 keeps the value in the database"
set_env FXA_MAX_ACCOUNTS lots
dc run --rm --no-deps fxa-policy > "${WORK}/fxa-policy-bad.log" 2>&1
check "$? $(grep -c 'FXA_MAX_ACCOUNTS="lots" is not valid' "${WORK}/fxa-policy-bad.log")" "1 1" "fxa-policy refuses FXA_MAX_ACCOUNTS=lots, and says why"
check "$(fxa_max)" 500 "max accounts unchanged by a FXA_MAX_ACCOUNTS not valid"
# the trigger on its own: full refuses an insert that skips the gate and the auth server
set_env FXA_MAX_ACCOUNTS initial:unlimited
fxa_sql "UPDATE ffs.settings SET value = '0' WHERE name = 'max_accounts'" > /dev/null
check "$(fxa_sql "SELECT ffs.signup_refusal('nobody@example.com'), ffs.signup_allowed('nobody@example.com')" | tr '\t' ' ')" "full 0" "max accounts 0: ffs.signup_refusal says full"
fxa_sql "UPDATE ffs.settings SET value = 'unlimited' WHERE name = 'max_accounts'" > /dev/null
check "$(fxa_sql "SELECT COALESCE(ffs.signup_refusal('nobody@example.com'), 'allowed')")" allowed "max accounts unlimited: allowed (@example.com on the list)"
if [ "${FXA_ACCOUNT_EVENTS}" = true ]; then
  echo "== the security history turned off again (the default): nothing more recorded"
  set_env FXA_ACCOUNT_EVENTS false
  dc up -d --no-deps fxa-auth ffs-admin > "${WORK}/events-off.log" 2>&1
  for _ in $(seq 1 60); do [ "$(state fxa-auth Health.Status)" = healthy ] && [ "$(state ffs-admin Health.Status)" = healthy ] && break; sleep 5; done
  check "$(state fxa-auth Health.Status) $(state ffs-admin Health.Status)" "healthy healthy" "accounts service and admin UI restarted with FXA_ACCOUNT_EVENTS=false"
  off_since=$(fxa_sql "SELECT UNIX_TIMESTAMP() * 1000")
  # a sign-up and a sign-in, and the account page says how to turn it on
  admin_tests "-k test_security_history_off"
  check "$?" 0 "the account page without the security history"
  check "$(fxa_sql "SELECT COUNT(*) FROM fxa.securityEvents WHERE createdAt >= ${off_since%.*}") $(fxa_sql "SELECT COUNT(*) > 0 FROM fxa.securityEvents")" "0 1" \
    "no security event recorded with FXA_ACCOUNT_EVENTS=false, those of before kept"
fi
fi

if [ -z "${RERUN:-}" ] && [ "${FXA_DB_CONTAINERS:-1}" = 1 ] && [ "${SYNC_DB_CONTAINERS:-1}" = 1 ]; then
  echo "== backups of the accounts and of Sync, the accounts restored into a scratch database"
  dc exec -T backup-fxa sh /ffs-backup/backup.sh now > "${WORK}/backup.log" 2>&1
  check "$?" 0 "a backup of the accounts databases"
  # the sync scope records the accounts' run too (the accounts image has no client for PostgreSQL)
  dc exec -T backup sh /ffs-backup/backup.sh now >> "${WORK}/backup.log" 2>&1
  check "$?" 0 "a backup of the Sync databases"
  [ "${FAILED}" = 0 ] || tail -5 "${WORK}/backup.log"
  check "$(admin_sql "SELECT scope FROM ffs_backups WHERE ok = 1 AND bytes > 0 ORDER BY scope" | sort -u | paste -sd' ')" "accounts sync" "both runs in ffs_backups"
  run_dir=$(dc exec -T backup-fxa sh -c 'ls -1 /backups/accounts | tail -1' | tr -d '\r')
  check "$(dc exec -T backup-fxa sh -c "cd /backups/accounts/${run_dir} && for f in *.sql.gz; do gzip -t \$f && echo \$f; done" | LC_ALL=C sort | paste -sd' ')" \
    "ffs.sql.gz fxa.sql.gz fxa_oauth.sql.gz fxa_profile.sql.gz pushbox.sql.gz" "the five accounts databases, each passing gzip -t"
  # a restore as ADMIN.md says (the same definer user, root here), into a scratch database
  accounts=$(fxa_sql "SELECT COUNT(*) FROM fxa.accounts")
  dc exec -T -e MYSQL_PWD="${FXA_MYSQL_PASSWORD}" backup-fxa sh -c "${DB_CLIENT} -h fxa-db -uroot -e 'CREATE DATABASE ffs_restore_test' &&
    gunzip -c /backups/accounts/${run_dir}/fxa.sql.gz | ${DB_CLIENT} -h fxa-db -uroot ffs_restore_test" > "${WORK}/restore.log" 2>&1
  check "$?" 0 "the dump of fxa restores"
  [ "${FAILED}" = 0 ] || tail -5 "${WORK}/restore.log"
  check "$(fxa_sql "SELECT COUNT(*) FROM ffs_restore_test.accounts")" "${accounts}" "the restored copy has every account (${accounts})"
  routines() { fxa_sql "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '$1'"; }
  check "$(routines ffs_restore_test)" "$(routines fxa)" "and its procedures"
  fxa_sql "DROP DATABASE ffs_restore_test" > /dev/null
  check "$(fxa_sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'ffs_restore_test'")" 0 "scratch database dropped"
  # a password with the option file's escapes (\\ \n \s \"), on a scratch database and directory
  pw='b\\k\n\s"q\'
  fxa_sql "SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'; CREATE DATABASE ffs_pw_test; CREATE TABLE ffs_pw_test.t (i INT);
    CREATE USER 'ffs_pw_test'@'%' IDENTIFIED BY '${pw}'; GRANT ALL ON ffs_pw_test.* TO 'ffs_pw_test'@'%'" > /dev/null
  bk_pw() { dc exec -T -e FXA_DB_USER=ffs_pw_test -e FXA_DB_PASSWORD="$1" -e FXA_DATABASES=ffs_pw_test -e BACKUP_DIR=/tmp/ffs-pw-test \
    backup-fxa sh /ffs-backup/backup.sh now >> "${WORK}/backup.log" 2>&1; }
  bk_pw "${pw}"
  check "$?" 0 "a backup with backslashes in the password"
  bk_pw "${pw}
x"
  check "$?" 1 "a password with a line break refused"
  check "$(grep -c 'ffs_pw_test has a line break' "${WORK}/backup.log")" 1 "with a clear error"
  dc exec -T backup-fxa rm -rf /tmp/ffs-pw-test
  fxa_sql "DROP USER 'ffs_pw_test'@'%'; DROP DATABASE ffs_pw_test" > /dev/null
  # the admin UI sees both, within HEALTH_CHECK_SECONDS (5)
  for _ in $(seq 1 30); do
    shown=$(dc exec -T syncstorage curl -s -H 'Authorization: Bearer ffs-test-metrics-token' http://ffs-admin:8080/metrics | grep -c '^ffs_backup_last_ok{scope="[a-z]*"} 1$')
    [ "${shown}" = 2 ] && break
    sleep 1
  done
  check "${shown}" 2 "the admin UI sees both backups (ffs_backup_last_ok)"
fi

if [ -z "${SKIP_BROWSER:-}" ] && runs browser; then
  echo "== real Firefox: sign-up on one profile, sync to a second one"
  # tagged by its files: built once, the same for runs next to each other
  BROWSER_IMAGE=ffs-fxa-browser:src-$(src_hash "${TESTS}/browser")
  docker image inspect "${BROWSER_IMAGE}" > /dev/null 2>&1 || one_at_a_time browser-build docker build -q -t "${BROWSER_IMAGE}" "${TESTS}/browser" > /dev/null ||
    check build failed "Firefox test image"
  docker run --rm --network "${PROJECT}_default" --shm-size 1g \
    -v "${TESTS}:/tests:ro" -v "${PROJECT}_caddy-ca:/caddy-ca:ro" \
    -e FXA_CONTENT_URL -e MAILPIT_URL=http://mailpit:8025 -e PYTHONDONTWRITEBYTECODE=1 \
    -e FXA_PAIRING_URL -e ADMIN_PASSWORD -e ADMIN_URL=https://admin.fxa.test -e ADMIN_FXA_CLIENT_ID \
    "${BROWSER_IMAGE}" sh -c "python3 -m pytest -q -p no:cacheprovider /tests/test_fxa_browser.py /tests/test_fxa_pairing.py ${PYTEST_ARGS} > /tmp/pytest.log 2>&1; rc=\$?; tail -30 /tmp/pytest.log; [ \$rc = 0 ] || grep -h FirefoxAccounts /tmp/ffs-firefox-*.log | grep -E 'ERROR|WARN' | tail -10; exit \$rc" < /dev/null
  check "$?" 0 "real Firefox sign-up and sync, pairing server"
fi
echo "== admin UI"
for _ in $(seq 1 60); do [ "$(state ffs-admin Health.Status)" = healthy ] && break; sleep 1; done
check "$(state ffs-admin Health.Status)" healthy "admin UI container healthcheck"
admin_errors() { dc logs ffs-admin 2>&1 | grep -E '(pruning|metrics|event log|database size|rendering [^:]*): '; }
check "$(admin_errors | wc -l)" 0 "no background errors in the admin UI logs"
admin_errors | tail -5
echo "== every container that keeps running healthy, the one-shot ones exited 0"
check "$(compose_healthy 300 dc)" "all healthy" "every long-running container healthy (docker compose ps), the one-shot ones exited 0"
[ "${FAILED}" = 0 ] || for s in fxa-auth syncstorage; do echo "---- ${s}"; dc logs --tail 30 "${s}" 2>&1; done

[ ${FAILED} = 0 ] && echo "RESULT fxa: all checks passed" || echo "RESULT fxa: some checks FAILED"
exit ${FAILED}
