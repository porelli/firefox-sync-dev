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
#   SKIP_PULL        set to 1 to use the local images (e.g. an init image built from this tree)
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
PROJECT=ffs-e2e-fxa
WORK=$(mktemp -d)
ENV_FILE=${WORK}/fxa.env
KEPT_ENV=${KEPT_ENV:-${HOME}/.cache/ffs-e2e-fxa.env}
ONLY=${ONLY:-flow,admin,browser}
PYTEST_ARGS=${PYTEST_ARGS:-}
runs() { [ -z "${RERUN:-}" ] || [[ ",${ONLY}," == *",$1,"* ]]; }

rnd() { tr -dc '[:alnum:]' < /dev/urandom 2> /dev/null | head -c 32; }
# the admin UI signs in with these accounts too (@example.com): its OAuth client, public
# (PKCE, no secret: the accounts service refuses PKCE from a client with a secret)
ADMIN_FXA_CLIENT_ID=ad41a7e5f0c0ffee
sed -e "s|<REPLACE_WITH_SOMETHING_SECURE>|RANDOM|" "${CODE}/.env-example" | while IFS= read -r line; do
  case "${line}" in *=RANDOM) echo "${line%RANDOM}$(rnd)" ;; *) echo "${line}" ;; esac
done | sed -e "s|^SYNCSTORAGE_DOMAIN=.*|SYNCSTORAGE_DOMAIN=https://sync.fxa.test|" \
    -e "s|^CONTAINER_EXPORT_PORT=.*|CONTAINER_EXPORT_PORT=127.0.0.1:28653|" \
    -e "s|^MAX_USERS=.*|MAX_USERS=initial:10|" \
    -e "s|^REPOSITORY=.*|REPOSITORY=${REPOSITORY}|" \
    -e "s|^SYNCSTORAGE_IMAGE_TAG=.*|SYNCSTORAGE_IMAGE_TAG=${TAG}|" \
    -e "s|^SYNCSTORAGE_INIT_IMAGE_TAG=.*|SYNCSTORAGE_INIT_IMAGE_TAG=${TAG}|" \
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
    -e "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=pairing,admin|" \
    -e "s|^FXA_SIGNUPS=.*|FXA_SIGNUPS=allowlist|" \
    -e "s|^FXA_SIGNUP_ALLOWLIST=.*|FXA_SIGNUP_ALLOWLIST=@example.com,invited@example.net|" \
    -e "s|^# FXA_PAIRING_URL=.*|FXA_PAIRING_URL=wss://pairing.fxa.test|" \
    -e "s|^ADMIN_FXA_CLIENT_ID=.*|ADMIN_FXA_CLIENT_ID=${ADMIN_FXA_CLIENT_ID}|" \
    -e "s|^ADMIN_OIDC_REDIRECT_URL=.*|ADMIN_OIDC_REDIRECT_URL=https://admin.fxa.test/auth/callback|" \
    -e "s|^ADMIN_ALLOWED_USERS=.*|ADMIN_ALLOWED_USERS=@example.com|" \
    -e "s|^ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=.*|ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true|" \
    -e "/^COMPOSE_FILE=/d" > "${ENV_FILE}"
# by default the accounts images of the registry under test, for this machine
case "$(uname -m)" in aarch64|arm64) default_arch=arm64 ;; *) default_arch=amd64 ;; esac
sed -i -e "s|^FXA_IMAGE=.*|FXA_IMAGE=${REPOSITORY}|" -e "s|^FXA_ARCH=.*|FXA_ARCH=${default_arch}|" \
    -e "s|^FXA_PAIRING_IMAGE=.*|FXA_PAIRING_IMAGE=${REPOSITORY}:fxa-channelserver-latest|" "${ENV_FILE}"
[ -n "${FXA_VERSION:-}" ] && sed -i "s|^FXA_VERSION=.*|FXA_VERSION=${FXA_VERSION}|" "${ENV_FILE}"
[ -n "${FXA_IMAGE:-}" ] && sed -i "s|^FXA_IMAGE=.*|FXA_IMAGE=${FXA_IMAGE}|" "${ENV_FILE}"
[ -n "${FXA_ARCH:-}" ] && sed -i "s|^FXA_ARCH=.*|FXA_ARCH=${FXA_ARCH}|" "${ENV_FILE}"
[ -n "${FXA_PAIRING_IMAGE:-}" ] && sed -i "s|^FXA_PAIRING_IMAGE=.*|FXA_PAIRING_IMAGE=${FXA_PAIRING_IMAGE}|" "${ENV_FILE}"
if [ -n "${RERUN:-}" ]; then
  [ -f "${KEPT_ENV}" ] || { echo "RERUN: no ${KEPT_ENV}, run with KEEP=1 first"; exit 2; }
  cp "${KEPT_ENV}" "${ENV_FILE}"
  KEEP=1
fi
set -a; source "${ENV_FILE}"; set +a
# the admin UI under test: ADMIN_IMAGE as is (pulled when missing), or built from admin/
ADMIN_GIVEN=${ADMIN_IMAGE:-}
export ADMIN_IMAGE=${ADMIN_IMAGE:-ffs-admin:test}

dc() {
  docker compose -p "${PROJECT}" --env-file "${ENV_FILE}" --project-directory "${CODE}" \
    -f "${CODE}/docker-compose.yml" -f "${CODE}/docker-compose.fxa.yml" -f "${TESTS}/docker-compose.fxa-test.yml" "$@"
}
FAILED=0
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
  rm -f "${KEPT_ENV}"
  rm -rf "${WORK}"
}
trap teardown EXIT

if [ -z "${RERUN:-}" ]; then
echo "== prepare_environment.sh with self-hosted accounts"
SETUP=${WORK}/setup && mkdir -p "${SETUP}" && cp -r "${CODE}/." "${SETUP}/" && rm -f "${SETUP}/.env"
# answers: domain, compose dir, port, max users, backend, [deploy method], user, image tag, admin UI,
# FxA, FxA domain, SMTP host, port, user, password, sender, sign-up allowlist, admin emails, admin host
answers=(sync.example.org "${SETUP}" 5000 2 mariadb)
command -v podman > /dev/null && answers+=(2)
admin_answer=$((${#answers[@]} + 2))
answers+=("" latest "" y "" smtp.example.org 587 mailer 'p@ss|w&rd\#1 $x' "" "alice@example.org, @example.net" "admin@example.org" "")
printf '%s\n' "${answers[@]}" | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup.log" 2>&1
check "$?" 0 "prepare_environment.sh with self-hosted accounts"
password='p@ss|w&rd\#1 $x'
check "$(grep -cxF "FXA_SMTP_PASS='${password}'" "${SETUP}/.env")" 1 "SMTP password written as typed"
check "$(sed -n '/SELF-HOSTED MOZILLA ACCOUNTS/,$p' "${SETUP}/.env" | grep -v '^#' | grep -c REPLACE)" 0 "no placeholders left for the accounts"
check "$(cd "${SETUP}" && docker compose config --services 2> /dev/null | grep -c '^fxa-')" 11 "compose stack with the accounts services (and the optional pairing server)"
check "$(grep -c '^COMPOSE_PROFILES=admin$' "${SETUP}/.env")" 1 "admin UI enabled"
check "$(grep -c '^MAX_USERS=initial:2$' "${SETUP}/.env")" 1 "max users managed in the admin UI (MAX_USERS=initial:2)"
check "$(grep -c '^FXA_SIGNUPS=allowlist$' "${SETUP}/.env") $(grep -c '^FXA_SIGNUP_ALLOWLIST=alice@example.org,@example.net$' "${SETUP}/.env")" "1 1" "sign-up allowlist"
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
check "$(grep -c '^COMPOSE_FILE=docker-compose.postgres.yml:docker-compose.fxa.yml$' "${SETUP}/.env")" 1 "PostgreSQL compose file with the accounts"
check "$(setup_compose config --services | grep -cxE 'postgres_db|fxa-auth|fxa-policy|ffs-admin')" 4 "compose stack with PostgreSQL, the accounts and the admin UI"
check "$(setup_compose config | sed -n '/^  ffs-admin:/,/^  [a-z]/p' | grep -cE '^ +(TOKENSERVER_DB_TYPE: postgres|FXA_DB_HOST: fxa-db|MAX_USERS: "?initial:2"?)$')" 3 "admin UI for PostgreSQL and the accounts, with MAX_USERS"
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
check "$(grep -c '^MAX_USERS=2$' "${SETUP}/.env")" 1 "plain MAX_USERS=2 without the admin UI"
check "$(setup_compose config --services | grep -cxE 'fxa-policy|ffs-admin')" 1 "sign-up policy without the admin UI"
check "$(setup_compose config --services | grep -cx ffs-admin)" 0 "no admin UI service"

echo "== ${PROJECT}: syncstorage ${REPOSITORY} ${TAG}, mozilla/fxa-mono ${FXA_VERSION}"
if [ -z "${ADMIN_GIVEN}" ]; then
  COMPOSE_BAKE=false docker compose -p ffs-admin-build -f "${TESTS}/docker-compose.admin-build.yml" build -q || { echo "FAIL: admin UI image built from admin/"; exit 1; }
fi
[ -n "${SKIP_PULL:-}" ] || dc pull -q || exit 1
dc up -d > "${WORK}/up.log" 2>&1 || { echo "FAIL: compose up"; grep -iE "error|fail" "${WORK}/up.log" | tail -10; }
echo "== waiting for FxA (slow under emulation)"
for _ in $(seq 1 120); do
  [ "$(state fxa-content Health.Status)" = healthy ] && [ "$(state syncstorage Health.Status)" = healthy ] && break
  [ "$(state fxa-migrations ExitCode)" != "" ] && [ "$(state fxa-migrations ExitCode)" != 0 ] && break
  crashing=""
  for s in fxa-auth fxa-content fxa-profile; do [ "$(state "${s}" RestartCount || echo 0)" -ge 3 ] 2> /dev/null && crashing="${s}"; done
  [ -n "${crashing}" ] && { echo "${crashing} keeps restarting"; break; }
  sleep 10
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
  -e FXA_CONTENT_URL -e FXA_AUTH_URL -e FXA_PROFILE_URL -e FXA_PAIRING_URL -e SYNCSTORAGE_DOMAIN -e MAILPIT_URL=http://mailpit:8025 \
  -e PYTHONPATH=/app:/app/tools -e PYTHONDONTWRITEBYTECODE=1 \
  --entrypoint /bin/sh syncstorage \
  -c "cd /app && python3 -m pytest -q -p no:cacheprovider /tests/test_fxa_flow.py ${PYTEST_ARGS} > /tmp/pytest.log 2>&1; rc=\$?; tail -40 /tmp/pytest.log; exit \$rc" < /dev/null
check "$?" 0 "self-hosted FxA flow tests"
fi

if runs admin; then
echo "== sign-up policy, admin UI, rate limits"
dc run --rm -T --no-deps --user root \
  -v "${TESTS}:/tests:ro" -v "${PROJECT}_caddy-ca:/caddy-ca:ro" \
  -e REQUESTS_CA_BUNDLE=/caddy-ca/root.crt \
  -e FXA_CONTENT_URL -e FXA_AUTH_URL -e FXA_PROFILE_URL -e SYNCSTORAGE_DOMAIN -e MAILPIT_URL=http://mailpit:8025 \
  -e ADMIN_URL=https://admin.fxa.test -e ADMIN_PASSWORD -e FXA_DIRECT_URL=http://fxa-auth:9000 -e ADMIN_FXA_CLIENT_ID \
  -e PYTHONPATH=/app:/app/tools:/tests -e PYTHONDONTWRITEBYTECODE=1 \
  --entrypoint /bin/sh syncstorage \
  -c "cd /app && python3 -m pytest -q -p no:cacheprovider /tests/test_fxa_admin.py ${PYTEST_ARGS} > /tmp/pytest.log 2>&1; rc=\$?; tail -40 /tmp/pytest.log; exit \$rc" < /dev/null
check "$?" 0 "sign-up policy and admin UI tests"
fi

if [ -z "${RERUN:-}" ]; then
echo "== settings from the admin UI survive a restart, .env changes replace them (MAX_USERS: a plain number)"
fxa_sql() { dc exec -T fxa-db mysql -uroot -p"${FXA_MYSQL_PASSWORD}" -sN -e "$1" 2> /dev/null; }
ts_sql() { dc exec -T tokenserver_db mariadb -u"${MARIADB_TOKENSERVER_USER}" -p"${MARIADB_TOKENSERVER_PASSWORD}" "${MARIADB_TOKENSERVER_DATABASE}" -sN -e "$1" 2> /dev/null; }
dc run --rm --no-deps fxa-policy > /dev/null 2>&1
check "$?" 0 "sign-up policy restarted"
check "$(fxa_sql "SELECT COUNT(*) FROM ffs.signup_allowlist WHERE entry = 'kept@example.net'")" 1 "allowlist set in the admin UI kept"
dc run --rm --no-deps tokenserver_db_init > /dev/null 2>&1
check "$(ts_sql "SELECT config_value FROM config WHERE config_key = 'max_users'")" 7 "max users set in the admin UI kept (MAX_USERS=initial:10)"
set_env FXA_SIGNUP_ALLOWLIST @example.com
dc run --rm --no-deps fxa-policy > /dev/null 2>&1
check "$(fxa_sql "SELECT GROUP_CONCAT(entry) FROM ffs.signup_allowlist")" "@example.com" "allowlist changed in .env applied"
set_env MAX_USERS 11
dc run --rm --no-deps tokenserver_db_init > /dev/null 2>&1
check "$(ts_sql "SELECT config_value FROM config WHERE config_key = 'max_users'")" 11 "plain MAX_USERS=11 in .env applied over the admin UI"
set_env MAX_USERS initial:12
dc run --rm --no-deps tokenserver_db_init > /dev/null 2>&1
check "$(ts_sql "SELECT config_value FROM config WHERE config_key = 'max_users'")" 11 "MAX_USERS=initial:12 keeps the value in the database"
fi

if [ -z "${SKIP_BROWSER:-}" ] && runs browser; then
  echo "== real Firefox: sign-up on one profile, sync to a second one"
  docker build -q -t ffs-fxa-browser "${TESTS}/browser" > /dev/null || check build failed "Firefox test image"
  docker run --rm --network "${PROJECT}_default" --shm-size 1g \
    -v "${TESTS}:/tests:ro" -v "${PROJECT}_caddy-ca:/caddy-ca:ro" \
    -e FXA_CONTENT_URL -e MAILPIT_URL=http://mailpit:8025 -e PYTHONDONTWRITEBYTECODE=1 \
    -e FXA_PAIRING_URL -e ADMIN_PASSWORD -e ADMIN_URL=https://admin.fxa.test -e ADMIN_FXA_CLIENT_ID \
    ffs-fxa-browser sh -c "python3 -m pytest -q -p no:cacheprovider /tests/test_fxa_browser.py /tests/test_fxa_pairing.py ${PYTEST_ARGS} > /tmp/pytest.log 2>&1; rc=\$?; tail -30 /tmp/pytest.log; [ \$rc = 0 ] || grep -h FirefoxAccounts /tmp/ffs-firefox-*.log | grep -E 'ERROR|WARN' | tail -10; exit \$rc" < /dev/null
  check "$?" 0 "real Firefox sign-up and sync, pairing server"
fi
echo "== admin UI"
for _ in $(seq 1 60); do [ "$(state ffs-admin Health.Status)" = healthy ] && break; sleep 1; done
check "$(state ffs-admin Health.Status)" healthy "admin UI container healthcheck"
admin_errors() { dc logs ffs-admin 2>&1 | grep -E '(pruning|metrics|event log|database size|rendering [^:]*): '; }
check "$(admin_errors | wc -l)" 0 "no background errors in the admin UI logs"
admin_errors | tail -5
[ "${FAILED}" = 0 ] || for s in fxa-auth syncstorage; do echo "---- ${s}"; dc logs --tail 30 "${s}" 2>&1; done

[ ${FAILED} = 0 ] && echo "RESULT fxa: all checks passed" || echo "RESULT fxa: some checks FAILED"
exit ${FAILED}
