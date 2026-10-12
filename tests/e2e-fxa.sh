#!/bin/bash
# End-to-end test of the stack with self-hosted Mozilla accounts (docker-compose.fxa.yml):
# sign-up, email verification, OAuth and sync through HTTPS, without any Mozilla service.
#
# Usage: tests/e2e-fxa.sh
# Environment:
#   REPOSITORY, TAG  syncstorage images to test (default: ghcr.io/porelli/firefox-sync, latest)
#   FXA_IMAGE        accounts image (default: REPOSITORY, i.e. our builds)
#   FXA_VERSION      accounts image tag (default: fxa-mono-latest)
#   FXA_ARCH         amd64 or arm64 (default: this machine)
#   FXA_PAIRING_IMAGE pairing server image (default: REPOSITORY:fxa-channelserver-latest)
#   KEEP             set to 1 to leave the stack running
#   SKIP_BROWSER     set to 1 to skip the real Firefox test
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
REPOSITORY=${REPOSITORY:-ghcr.io/porelli/firefox-sync}
TAG=${TAG:-latest}
PROJECT=ffs-e2e-fxa
WORK=$(mktemp -d)
ENV_FILE=${WORK}/fxa.env

rnd() { tr -dc '[:alnum:]' < /dev/urandom 2> /dev/null | head -c 32; }
sed -e "s|<REPLACE_WITH_SOMETHING_SECURE>|RANDOM|" "${CODE}/.env-example" | while IFS= read -r line; do
  case "${line}" in *=RANDOM) echo "${line%RANDOM}$(rnd)" ;; *) echo "${line}" ;; esac
done | sed -e "s|^SYNCSTORAGE_DOMAIN=.*|SYNCSTORAGE_DOMAIN=https://sync.fxa.test|" \
    -e "s|^CONTAINER_EXPORT_PORT=.*|CONTAINER_EXPORT_PORT=127.0.0.1:28653|" \
    -e "s|^MAX_USERS=.*|MAX_USERS=10|" \
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
    -e "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=pairing|" \
    -e "s|^# FXA_PAIRING_URL=.*|FXA_PAIRING_URL=wss://pairing.fxa.test|" \
    -e "/^COMPOSE_FILE=/d" > "${ENV_FILE}"
# by default the accounts images of the registry under test, for this machine
case "$(uname -m)" in aarch64|arm64) default_arch=arm64 ;; *) default_arch=amd64 ;; esac
sed -i -e "s|^FXA_IMAGE=.*|FXA_IMAGE=${REPOSITORY}|" -e "s|^FXA_ARCH=.*|FXA_ARCH=${default_arch}|" \
    -e "s|^FXA_PAIRING_IMAGE=.*|FXA_PAIRING_IMAGE=${REPOSITORY}:fxa-channelserver-latest|" "${ENV_FILE}"
[ -n "${FXA_VERSION:-}" ] && sed -i "s|^FXA_VERSION=.*|FXA_VERSION=${FXA_VERSION}|" "${ENV_FILE}"
[ -n "${FXA_IMAGE:-}" ] && sed -i "s|^FXA_IMAGE=.*|FXA_IMAGE=${FXA_IMAGE}|" "${ENV_FILE}"
[ -n "${FXA_ARCH:-}" ] && sed -i "s|^FXA_ARCH=.*|FXA_ARCH=${FXA_ARCH}|" "${ENV_FILE}"
[ -n "${FXA_PAIRING_IMAGE:-}" ] && sed -i "s|^FXA_PAIRING_IMAGE=.*|FXA_PAIRING_IMAGE=${FXA_PAIRING_IMAGE}|" "${ENV_FILE}"
set -a; source "${ENV_FILE}"; set +a

dc() {
  docker compose -p "${PROJECT}" --env-file "${ENV_FILE}" --project-directory "${CODE}" \
    -f "${CODE}/docker-compose.yml" -f "${CODE}/docker-compose.fxa.yml" -f "${TESTS}/docker-compose.fxa-test.yml" "$@"
}
FAILED=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; fi; }
state() { docker inspect -f "{{.State.$2}}" "$(dc ps -a -q "$1")" 2> /dev/null; }

teardown() {
  [ -n "${KEEP:-}" ] && { echo "keeping stack ${PROJECT} (env: ${ENV_FILE})"; return; }
  echo "== teardown"
  dc down -v --remove-orphans > /dev/null 2>&1
  rm -rf "${WORK}"
}
trap teardown EXIT

echo "== prepare_environment.sh with self-hosted accounts"
SETUP=${WORK}/setup && mkdir -p "${SETUP}" && cp -r "${CODE}/." "${SETUP}/" && rm -f "${SETUP}/.env"
# answers: domain, compose dir, port, max users, backend, [deploy method], user, image tag, FxA, FxA domain, SMTP host, port, user, password, sender
answers=(sync.example.org "${SETUP}" 5000 2 mariadb)
command -v podman > /dev/null && answers+=(2)
answers+=("" latest y "" smtp.example.org 587 mailer 'p@ss|w&rd\#1 $x' "")
printf '%s\n' "${answers[@]}" | (cd "${SETUP}" && ./prepare_environment.sh) > "${WORK}/setup.log" 2>&1
check "$?" 0 "prepare_environment.sh with self-hosted accounts"
password='p@ss|w&rd\#1 $x'
check "$(grep -cxF "FXA_SMTP_PASS='${password}'" "${SETUP}/.env")" 1 "SMTP password written as typed"
check "$(sed -n '/SELF-HOSTED MOZILLA ACCOUNTS/,$p' "${SETUP}/.env" | grep -v '^#' | grep -c REPLACE)" 0 "no placeholders left for the accounts"
check "$(cd "${SETUP}" && docker compose config --services 2> /dev/null | grep -c '^fxa-')" 10 "compose stack with the accounts services (and the optional pairing server)"
check "$(grep -c 'server_name accounts.example.org;' "${SETUP}/config/nginx/fxa.conf")" 1 "nginx example for the accounts"

echo "== ${PROJECT}: syncstorage ${REPOSITORY} ${TAG}, mozilla/fxa-mono ${FXA_VERSION}"
dc pull -q || exit 1
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

echo "== sign-up, OAuth and sync through self-hosted FxA"
dc run --rm -T --no-deps --user root \
  -v "${TESTS}:/tests:ro" -v "${PROJECT}_caddy-ca:/caddy-ca:ro" \
  -e REQUESTS_CA_BUNDLE=/caddy-ca/root.crt \
  -e FXA_CONTENT_URL -e FXA_AUTH_URL -e FXA_PROFILE_URL -e FXA_PAIRING_URL -e SYNCSTORAGE_DOMAIN -e MAILPIT_URL=http://mailpit:8025 \
  -e PYTHONPATH=/app:/app/tools -e PYTHONDONTWRITEBYTECODE=1 \
  --entrypoint /bin/sh syncstorage \
  -c "cd /app && python3 -m pytest -q -p no:cacheprovider /tests/test_fxa_flow.py > /tmp/pytest.log 2>&1; rc=\$?; tail -40 /tmp/pytest.log; exit \$rc" < /dev/null
check "$?" 0 "self-hosted FxA flow tests"

if [ -z "${SKIP_BROWSER:-}" ]; then
  echo "== real Firefox: sign-up on one profile, sync to a second one"
  docker build -q -t ffs-fxa-browser "${TESTS}/browser" > /dev/null || check build failed "Firefox test image"
  docker run --rm --network "${PROJECT}_default" --shm-size 1g \
    -v "${TESTS}:/tests:ro" -v "${PROJECT}_caddy-ca:/caddy-ca:ro" \
    -e FXA_CONTENT_URL -e MAILPIT_URL=http://mailpit:8025 -e PYTHONDONTWRITEBYTECODE=1 \
    -e FXA_PAIRING_URL \
    ffs-fxa-browser sh -c "python3 -m pytest -q -p no:cacheprovider /tests/test_fxa_browser.py /tests/test_fxa_pairing.py > /tmp/pytest.log 2>&1; rc=\$?; tail -30 /tmp/pytest.log; [ \$rc = 0 ] || grep -h FirefoxAccounts /tmp/ffs-firefox-*.log | grep -E 'ERROR|WARN' | tail -10; exit \$rc" < /dev/null
  check "$?" 0 "real Firefox sign-up and sync, pairing server"
fi
[ "${FAILED}" = 0 ] || for s in fxa-auth syncstorage; do echo "---- ${s}"; dc logs --tail 30 "${s}" 2>&1; done

[ ${FAILED} = 0 ] && echo "RESULT fxa: all checks passed" || echo "RESULT fxa: some checks FAILED"
exit ${FAILED}
