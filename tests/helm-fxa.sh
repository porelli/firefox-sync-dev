#!/bin/bash
# The chart's self-hosted Mozilla accounts (fxa.enabled), FXA.md under Kubernetes.
#
#   fxa_lint    the template checks of the accounts, run by `tests/helm.sh lint`, which sources
#               this file (it uses check, fail and manifests of tests/helm/lib.sh, and CHART_DIR)
#   tests/helm-fxa.sh e2e <mysql|mariadb>
#               the chart with the accounts on a throwaway kind cluster (fxa_e2e)
#
# PARITY_BASE_CHART=<dir>: chart 0.1.0 already extracted there (charts/firefox-sync of
# PARITY_BASE, default e917067), for a checkout without that commit (a copy without .git,
# a shallow clone): `git archive e917067 charts/firefox-sync | tar -x -C <dir>`

# the commit of chart 0.1.0 (part 1): with fxa.enabled=false the chart renders what it did
PARITY_BASE=${PARITY_BASE:-e917067}

fxa_lint() {
  echo "=== The self-hosted accounts (fxa.*) ==="
  local fxa="${CHART_DIR}/ci/fxa-values.yaml" out values
  fxa_render() { helm template test-release "${CHART_DIR}" "$@" 2>&1; }

  # the ci values of the accounts render, and are valid Kubernetes objects
  for values in fxa-values fxa-mariadb-values fxa-external-values; do
    out=$(fxa_render -f "${CHART_DIR}/ci/${values}.yaml") || fail "ci/${values}.yaml does not render: ${out}"
    helm lint "${CHART_DIR}" -f "${CHART_DIR}/ci/${values}.yaml" > /dev/null || fail "helm lint fails with ci/${values}.yaml"
    if command -v kubeconform > /dev/null; then
      fxa_render -f "${CHART_DIR}/ci/${values}.yaml" | kubeconform -strict -summary -kubernetes-version 1.27.0 > /dev/null \
        || fail "kubeconform -strict: invalid objects with ci/${values}.yaml"
    fi
  done
  command -v kubeconform > /dev/null || echo "(kubeconform not installed: the objects of ci/fxa-*.yaml not validated)"
  check "ci/fxa-values.yaml, fxa-mariadb-values.yaml, fxa-external-values.yaml: helm lint, kubeconform -strict"

  # what the values must have, or the render fails saying so
  fxa_refused() {
    local want=$1
    shift
    out=$(fxa_render "$@") && fail "$*: renders"
    grep -qF -- "${want}" <<< "${out}" || fail "$*: not the message '${want}': ${out}"
  }
  local default_values=(-f "${CHART_DIR}/ci/default-values.yaml")
  fxa_refused "fxa.enabled needs fxa.contentUrl, fxa.authUrl and fxa.profileUrl" "${default_values[@]}" --set fxa.enabled=true
  fxa_refused "fxa.enabled needs fxa.contentUrl, fxa.authUrl and fxa.profileUrl" -f "${fxa}" --set fxa.profileUrl=
  fxa_refused "fxa.database.bundled=false needs existingSecret" -f "${fxa}" --set fxa.database.bundled=false --set fxa.database.external.host=fxadb.example.test
  fxa_refused "fxa.database.bundled=false needs fxa.database.external.host" -f "${fxa}" --set fxa.database.bundled=false --set existingSecret=mine
  fxa_refused "fxa.database.external.port 70000 is no port" -f "${fxa}" --set fxa.database.bundled=false --set existingSecret=mine \
    --set fxa.database.external.host=fxadb.example.test --set-string fxa.database.external.port=70000
  fxa_refused "fxa.pairing.enabled needs fxa.pairing.url" -f "${fxa}" --set fxa.pairing.url=
  # (your own server: chart 0.1.0's checks first, then the accounts')
  check "fxa.enabled without its URLs, your own accounts server without its host or existingSecret (or a bad port), pairing without its URL: refused, saying so"

  # the schema: closed objects, the formats of the accounts
  for bad in fxa.database.backend=postgres fxa.maxAccounts=lots fxa.maxAccounts=initial: fxa.signups=invite fxa.contentUrl=accounts.example.test \
    fxa.authUrl=ftp://api.example.test fxa.pairing.url=https://pairing.example.test fxa.adminClientId=0123456789ABCDEF fxa.adminClientId=0123 \
    fxa.adminClientSecret=abc fxa.enable=true fxa.database.bakend=mysql fxa.database.external.hots=x fxa.ingress.tls.secretName=x \
    fxa.ingress.tls.secretNames.api=x fxa.resources.worker.requests.memory=1Mi fxa.keys.secret=x fxa.redis.tag=x fxa.pairing.urls=x \
    admin.smtp.host=b smtp.hots=b fxa.database.image.mysql= fxa.clientAddressDepth=-1; do
    out=$(fxa_render -f "${fxa}" --set "${bad}") && fail "${bad}: not refused by the schema"
    grep -qi 'schema' <<< "${out}" || fail "${bad}: refused, but not by the schema: ${out}"
  done
  out=$(fxa_render -f "${fxa}" --set admin.smtp.host=b) || true
  grep -q "smtp" <<< "${out}" || fail "admin.smtp.host: the schema's message does not name smtp: ${out}"
  for good in fxa.maxAccounts=5 fxa.maxAccounts=initial:5 fxa.maxAccounts=fixed:unlimited fxa.maxAccounts=unlimited fxa.signups=closed \
    fxa.signupAllowlist=you@example.test fxa.adminClientId=0123456789abcdef fxa.adminClientSecret="$(printf 'a%.0s' $(seq 1 64))" \
    fxa.pairing.url=ws://pairing.example.test fxa.clientAddressDepth=3 fxa.resources.auth.limits.memory=2Gi fxa.ingress.annotations.a=b \
    fxa.database.resources.limits.memory=1Gi fxa.extraCaCerts.configMap=ca smtp.port=465 smtp.secure=true; do
    fxa_render -f "${fxa}" --set "${good}" > /dev/null || fail "${good}: refused: $(fxa_render -f "${fxa}" --set "${good}" | tail -3)"
  done
  check "the schema: postgres, maxAccounts lots, signups invite, URLs without http(s):// (pairing ws(s)://), client id/secret not hex 16/64, admin.smtp and unknown keys refused"

  # names within Kubernetes' limits with the accounts too: <fullname>-fxa-db (StatefulSet, 52)
  # (your own Sync database: its StatefulSets would fail first)
  local sync_external=(--set database.bundled=false --set database.external.host=db.example.test --set existingSecret=mine)
  fxa_refused "the fxa-db StatefulSet name $(printf 'f%.0s' $(seq 1 46))-fxa-db is 53 characters, at most 52" \
    -f "${fxa}" "${sync_external[@]}" --set fullnameOverride="$(printf 'f%.0s' $(seq 1 46))"
  fxa_render -f "${fxa}" "${sync_external[@]}" --set fullnameOverride="$(printf 'f%.0s' $(seq 1 45))" > /dev/null \
    || fail "a fullname of 45 with the accounts does not render"
  # (your own accounts server: no fxa-db, the Sync server's Service and fxa-profile, 63)
  fxa_render -f "${CHART_DIR}/ci/fxa-external-values.yaml" "${sync_external[@]}" --set fullnameOverride="$(printf 'f%.0s' $(seq 1 51))" > /dev/null \
    || fail "a fullname of 51 with your own accounts server does not render"
  fxa_refused "name $(printf 'f%.0s' $(seq 1 52))-" -f "${CHART_DIR}/ci/fxa-external-values.yaml" "${sync_external[@]}" \
    --set fullnameOverride="$(printf 'f%.0s' $(seq 1 52))"
  if ! grep -qF '(list "fxa-db" "StatefulSet" 52)' "${CHART_DIR}/templates/_helpers.tpl" \
    || ! grep -qF '(list "fxa-profile" "Service" 63)' "${CHART_DIR}/templates/_helpers.tpl"; then
    fail "checkNames: no fxa-db StatefulSet 52, fxa-profile Service 63"
  fi
  check "names: fxa-db (StatefulSet 52) refuses a fullname of 46, fxa-profile (Service 63) checked"

  # every public host of its own: the four Ingresses (and the Sync server's, the admin UI's)
  # cannot share one. Case-insensitive, a trailing dot the same host, the port ignored
  fxa_refused "fxa.authUrl has the host accounts.example.test of fxa.contentUrl" -f "${fxa}" \
    --set fxa.contentUrl=https://accounts.example.test --set fxa.authUrl=https://Accounts.example.test.
  fxa_refused "fxa.profileUrl has the host api.example.test of fxa.authUrl" -f "${fxa}" --set fxa.profileUrl=https://API.example.test:8443
  fxa_refused "fxa.contentUrl has the host sync.example.test of syncDomain" -f "${fxa}" --set fxa.contentUrl=https://sync.example.test
  fxa_refused "fxa.pairing.url has the host profile.example.test of fxa.profileUrl" -f "${fxa}" --set fxa.pairing.url=wss://profile.example.test
  fxa_refused "admin.ingress.host has the host pairing.example.test of fxa.pairing.url" -f "${fxa}" --set admin.ingress.enabled=true \
    --set admin.ingress.host=pairing.example.test.
  fxa_refused "fxa.authUrl has the host sync.example.test of ingress.host" -f "${fxa}" --set syncDomain=https://ffs.example.test \
    --set ingress.enabled=true --set ingress.host=sync.example.test --set fxa.authUrl=https://sync.example.test
  # (pairing off: its URL not used, not checked; the Sync server's Ingress on syncDomain's host)
  fxa_render -f "${fxa}" --set fxa.pairing.enabled=false --set fxa.pairing.url=wss://accounts.example.test --set ingress.enabled=true \
    --set ingress.host=sync.example.test --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test > /dev/null \
    || fail "distinct hosts refused: $(fxa_render -f "${fxa}" --set fxa.pairing.enabled=false --set fxa.pairing.url=wss://accounts.example.test | tail -2)"
  check "the hosts of contentUrl, authUrl, profileUrl, pairing.url, syncDomain (ingress.host) and admin.ingress.host pairwise distinct (case, trailing dot, port)"

  # the Secret: with the accounts, their eight generated secrets (as prepare_environment.sh,
  # 32 letters and digits) and ADMIN_FXA_CLIENT_SECRET of the values; none without them (the
  # generated ones kept by the lookup, ADMIN_FXA_CLIENT_SECRET removed: no old copy)
  local generated="FXA_ADMIN_DB_PASSWORD FXA_AUTH_SECRET FXA_CONTENT_SESSION_SECRET FXA_FLOW_ID_KEY FXA_MYSQL_PASSWORD FXA_OAUTH_SECRET FXA_PROFILE_SECRET FXA_SESSION_TOKEN_HANDLE_KEY"
  local prepared
  prepared=$(sed -n 's/^ *for name in \(FXA_MYSQL_PASSWORD .*\); do$/\1/p' "${REPO_ROOT}/prepare_environment.sh" | tr ' ' '\n' | LC_ALL=C sort | paste -sd' ' -)
  [[ "${prepared}" == "${generated}" ]] || fail "prepare_environment.sh generates ${prepared}, the chart ${generated}"
  secret_data() { helm template test-release "${CHART_DIR}" "$@" --show-only templates/secret.yaml | manifests | jq -c '.[0].data'; }
  local on off added
  on=$(secret_data -f "${fxa}" --set fxa.adminClientSecret="$(printf 'b%.0s' $(seq 1 64))")
  off=$(secret_data -f "${fxa}" --set fxa.enabled=false)
  added=$(jq -r --argjson off "${off}" 'keys - ($off | keys) | join(" ")' <<< "${on}")
  [[ "${added}" == "ADMIN_FXA_CLIENT_SECRET ${generated}" ]] || fail "fxa.enabled adds to the Secret: ${added}"
  jq -e 'has("ADMIN_FXA_CLIENT_SECRET") | not' <<< "$(secret_data -f "${fxa}" --set fxa.enabled=false --set fxa.adminClientSecret="$(printf 'b%.0s' $(seq 1 64))")" > /dev/null \
    || fail "accounts off: ADMIN_FXA_CLIENT_SECRET in the Secret"
  grep -qF '{{- $_ := unset $data "ADMIN_FXA_CLIENT_SECRET" }}' "${CHART_DIR}/templates/_helpers.tpl" \
    || fail "secretData does not remove ADMIN_FXA_CLIENT_SECRET with the accounts off (a lookup would keep an old copy)"
  jq -e --arg g "${generated}" '. as $d | [$g | split(" ")[] | $d[.] | @base64d | test("^[A-Za-z0-9]{32}$")] | all' <<< "${on}" > /dev/null \
    || fail "the generated secrets of the accounts are not 32 letters and digits: ${on}"
  [[ "$(jq -r '.ADMIN_FXA_CLIENT_SECRET | @base64d' <<< "${on}")" == "$(printf 'b%.0s' $(seq 1 64))" ]] || fail "ADMIN_FXA_CLIENT_SECRET is not fxa.adminClientSecret"
  [[ "$(secret_data -f "${fxa}" | jq -r '.ADMIN_FXA_CLIENT_SECRET')" == "" ]] || fail "an empty fxa.adminClientSecret is not an empty ADMIN_FXA_CLIENT_SECRET"
  for values in "${CHART_DIR}"/ci/{default,admin,backup,mysql,postgres}-values.yaml; do
    [[ "$(secret_data -f "${values}" | jq -r 'keys[] | select(test("^(FXA_|ADMIN_FXA_)") and . != "FXA_SMTP_PASS")')" == "" ]] \
      || fail "$(basename "${values}"): keys of the accounts in the Secret without them"
  done
  [[ "$(secret_data -f "${fxa}" --set smtp.password=pw | jq -r '.FXA_SMTP_PASS | @base64d')" == pw ]] || fail "FXA_SMTP_PASS is not smtp.password"
  check "Secret: fxa.enabled adds the eight generated secrets of prepare_environment.sh (32 characters) and ADMIN_FXA_CLIENT_SECRET (fxa.adminClientSecret); none without (ADMIN_FXA_CLIENT_SECRET removed); FXA_SMTP_PASS of smtp.password"

  # an existingSecret without the accounts' keys: the render fails naming them (lookup, so
  # tested here on the data it would return: helm template has no cluster)
  existing_check() {
    local d data=$1
    shift
    d=$(mktemp -d)
    cp -r "${CHART_DIR}" "${d}/chart"
    printf '%s\n' '{{- include "firefox-sync.checkSecretKeys" (dict "root" . "name" .Values.existingSecret "data" (fromJson (.Files.Get "files/data.json"))) }}' \
      'apiVersion: v1' 'kind: ConfigMap' 'metadata: {name: checked}' > "${d}/chart/templates/zz-check.yaml"
    printf '%s' "${data}" > "${d}/chart/files/data.json"
    helm template test-release "${d}/chart" "$@" --show-only templates/zz-check.yaml 2>&1
    local rc=$?
    rm -rf "${d}"
    return "${rc}"
  }
  local full='{"FXA_MYSQL_PASSWORD":"eA==","FXA_ADMIN_DB_PASSWORD":"eA==","FXA_AUTH_SECRET":"eA==","FXA_OAUTH_SECRET":"eA==","FXA_PROFILE_SECRET":"eA==","FXA_FLOW_ID_KEY":"eA==","FXA_SESSION_TOKEN_HANDLE_KEY":"eA==","FXA_CONTENT_SESSION_SECRET":"eA=="}'
  out=$(existing_check '{"SYNC_MASTER_SECRET":"eA==","FXA_MYSQL_PASSWORD":"eA==","FXA_ADMIN_DB_PASSWORD":"eA==","FXA_OAUTH_SECRET":"","FXA_PROFILE_SECRET":"eA=="}' \
    -f "${fxa}" --set existingSecret=ffs-own) && fail "an existingSecret without the accounts' keys passes"
  grep -qF "existingSecret ffs-own lacks FXA_AUTH_SECRET, FXA_CONTENT_SESSION_SECRET, FXA_FLOW_ID_KEY, FXA_OAUTH_SECRET, FXA_SESSION_TOKEN_HANDLE_KEY" <<< "${out}" \
    || fail "an existingSecret without the accounts' keys: not the message: ${out}"
  existing_check "${full}" -f "${fxa}" --set existingSecret=ffs-own > /dev/null || fail "an existingSecret with the accounts' keys refused"
  existing_check '{}' -f "${fxa}" --set fxa.enabled=false --set existingSecret=ffs-own > /dev/null || fail "accounts off: their keys required"
  # your own accounts server: its policy user's password too (none without a policy user)
  out=$(existing_check "${full}" -f "${CHART_DIR}/ci/fxa-external-values.yaml") && fail "your own accounts server: FXA_MYSQL_POLICY_PASSWORD not required"
  grep -qF "lacks FXA_MYSQL_POLICY_PASSWORD" <<< "${out}" || fail "your own accounts server without FXA_MYSQL_POLICY_PASSWORD: not the message: ${out}"
  existing_check "${full}" -f "${CHART_DIR}/ci/fxa-external-values.yaml" --set fxa.database.external.policyUser= > /dev/null \
    || fail "your own accounts server without a policy user: FXA_MYSQL_POLICY_PASSWORD required"
  grep -qE '^\{\{- \$existing := lookup "v1" "Secret" \.Release\.Namespace \.Values\.existingSecret \}\}$' "${CHART_DIR}/templates/_fxa.tpl" \
    || fail "checkExistingSecret does not look the existingSecret up"
  check "existingSecret without FXA_* keys (or with them empty): the render fails naming them; FXA_MYSQL_POLICY_PASSWORD with your own server's policy user"

  # smtp.*: the server of the accounts and the admin UI (no admin.smtp)
  smtp_env() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" "$@" | manifests | jq -c '[.[]
      | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin") | .spec.template.spec.containers[0].env[]
      | select(.name | startswith("SMTP_")) | {(.name): (.value // .valueFrom.secretKeyRef.key)}] | add'
  }
  [[ "$(smtp_env --set smtp.host=x)" == '{"SMTP_HOST":"x","SMTP_PORT":"587","SMTP_USER":"","SMTP_PASS":"FXA_SMTP_PASS","SMTP_SECURE":"false","SMTP_SENDER":""}' ]] \
    || fail "smtp.host=x: the admin UI's SMTP_*: $(smtp_env --set smtp.host=x)"
  [[ "$(smtp_env --set smtp.port=465 --set smtp.secure=true --set smtp.user=u --set-string smtp.sender='S <s@example.test>')" \
    == '{"SMTP_HOST":"smtp.example.test","SMTP_PORT":"465","SMTP_USER":"u","SMTP_PASS":"FXA_SMTP_PASS","SMTP_SECURE":"true","SMTP_SENDER":"S <s@example.test>"}' ]] \
    || fail "smtp.*: the admin UI's SMTP_*: $(smtp_env --set smtp.port=465 --set smtp.secure=true --set smtp.user=u)"
  ! grep -rn 'admin\.smtp' "${CHART_DIR}" "${REPO_ROOT}"/{HELM,ADMIN}.md "${REPO_ROOT}/tests/helm.sh" "${REPO_ROOT}/tests/helm_parity.py" "${REPO_ROOT}/admin/templates" \
    || fail "admin.smtp still named (now smtp)"
  check "smtp.* (host x) is the admin UI's SMTP_*; admin.smtp named nowhere"

  # the helpers of the accounts (for the templates of the next steps)
  helpers() {
    local d
    d=$(mktemp -d)
    cp -r "${CHART_DIR}" "${d}/chart"
    printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata: {name: helpers}' 'data:' \
      '  fxa: {{ include "firefox-sync.fxaImage" (dict "root" . "name" "fxa") | quote }}' \
      '  pairing: {{ include "firefox-sync.fxaImage" (dict "root" . "name" "pairing") | quote }}' \
      '  db: {{ printf "%s %s %s %s" (include "firefox-sync.fxaDbHost" .) (include "firefox-sync.fxaDbPort" .) (include "firefox-sync.fxaDbUser" .) (include "firefox-sync.fxaDbImage" .) | quote }}' \
      '  host: {{ include "firefox-sync.fxaHost" (dict "root" . "url" .Values.fxa.authUrl) | quote }}' \
      '  oauth: {{ include "firefox-sync.fxaOauthServerUrl" . | quote }}' \
      '  email: {{ include "firefox-sync.fxaEmailDomain" . | quote }}' \
      '  allowlist: {{ include "firefox-sync.fxaAllowlist" . | quote }}' \
      '  mysql: {{ include "firefox-sync.fxaMysqlEnv" (dict "root" . "prefix" "AUTH_") | fromYamlArray | toJson | quote }}' \
      '  smtp: {{ include "firefox-sync.smtp" . | quote }}' \
      '  sec: {{ include "firefox-sync.fxaSecurityContext" . | fromYaml | toJson | quote }}' \
      '  pod: {{ include "firefox-sync.fxaPodSecurityContext" . | fromYaml | toJson | quote }}' \
      > "${d}/chart/templates/zz-helpers.yaml"
    helm template test-release "${d}/chart" "$@" --show-only templates/zz-helpers.yaml | manifests | jq -c '.[0].data'
    rm -rf "${d}"
  }
  out=$(helpers -f "${fxa}")
  [[ "$(jq -r '[.fxa, .pairing, .db, .host, .oauth, .email, .allowlist] | join("|")' <<< "${out}")" == \
    "ghcr.io/porelli/firefox-sync:fxa-mono-latest|ghcr.io/porelli/firefox-sync:fxa-channelserver-latest|test-release-firefox-sync-fxa-db 3306 root docker.io/library/mysql:8|api.example.test|http://test-release-firefox-sync-fxa-auth:9000/v1|api.example.test|@example.test,you@example.org" ]] \
    || fail "the helpers of the accounts: ${out}"
  [[ "$(jq -r '.mysql' <<< "${out}")" == '[{"name":"AUTH_MYSQL_HOST","value":"test-release-firefox-sync-fxa-db"},{"name":"AUTH_MYSQL_PORT","value":"3306"},{"name":"AUTH_MYSQL_USERNAME","value":"root"},{"name":"AUTH_MYSQL_PASSWORD","valueFrom":{"secretKeyRef":{"key":"FXA_MYSQL_PASSWORD","name":"test-release-firefox-sync"}}}]' ]] \
    || fail "fxaMysqlEnv AUTH_: $(jq -r '.mysql' <<< "${out}")"
  [[ "$(jq -r '.sec' <<< "${out}")" == '{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}' ]] \
    || fail "fxaSecurityContext: $(jq -r '.sec' <<< "${out}")"
  [[ "$(jq -r '.pod' <<< "${out}")" == '{"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}' ]] \
    || fail "fxaPodSecurityContext (volumeOwnerInit: the init containers chown, no fsGroup): $(jq -r '.pod' <<< "${out}")"
  [[ "$(helpers -f "${fxa}" --set fxa.volumeOwnerInit=false | jq -r '.pod')" == \
    '{"fsGroup":10001,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}' ]] \
    || fail "fxaPodSecurityContext with volumeOwnerInit=false: $(helpers -f "${fxa}" --set fxa.volumeOwnerInit=false | jq -r '.pod')"
  out=$(helpers -f "${CHART_DIR}/ci/fxa-external-values.yaml" --set fxa.image.repository=docker.io/mozilla/fxa-mono --set fxa.image.tag=v1.347.1 \
    --set fxa.pairing.image=docker.io/mozilla/channelserver:v0.9 --set fxa.database.external.port=3307 --set-string fxa.signupAllowlist='a@x.test\,@y.test')
  [[ "$(jq -r '[.fxa, .pairing, .db, .allowlist] | join("|")' <<< "${out}")" == \
    "docker.io/mozilla/fxa-mono:v1.347.1|docker.io/mozilla/channelserver:v0.9|fxadb.example.test 3307 fxa docker.io/library/mariadb:lts|a@x.test,@y.test" ]] \
    || fail "the helpers with your own accounts server: ${out}"
  out=$(helpers -f "${CHART_DIR}/ci/default-values.yaml")
  [[ "$(jq -r '[.oauth, .email] | join("|")' <<< "${out}")" == "https://oauth.accounts.firefox.com/v1|api.accounts.firefox.com" ]] \
    || fail "accounts off: fxaOauthServerUrl, fxaEmailDomain not fxa.oauthServerUrl, fxa.emailDomain: ${out}"
  [[ "$(jq -r '.smtp' <<< "${out}")" == '{"host":"","port":"587","secure":"false","sender":"","user":""}' ]] || fail "firefox-sync.smtp: $(jq -r '.smtp' <<< "${out}")"
  check "helpers: fxaImage, fxaDb*, fxaHost, fxaOauthServerUrl, fxaEmailDomain (derived with the accounts), fxaAllowlist, fxaMysqlEnv, smtp, security contexts"

  fxa_objects_lint

  # chart 0.1.0's render, with the accounts off: the same objects for every ci/*.yaml it had,
  # but the chart label, ADMIN_K8S_CHART_VERSION and the generated secrets
  fxa_base_parity
}

# the accounts' objects: the database, Redis, the keys, the auth pod and its init containers,
# the Sync server pointed to them
fxa_objects_lint() {
  local fxa="${CHART_DIR}/ci/fxa-values.yaml" out objs
  fxa_objs() { helm template test-release "${CHART_DIR}" -f "${fxa}" "$@" | manifests; }
  # auth_pod <helm args>: the auth Deployment's pod spec
  auth_pod() { fxa_objs "$@" | jq -c '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-fxa-auth") | .spec.template'; }
  inits() { jq -r '[.spec.initContainers[].name] | join(" ")' <<< "$1"; }

  # compose's order: the keys' owner (or the keys of fxa.keys.existingSecret), the database,
  # the migrations, the policy, Redis; the keys on their PVC (kept) or that Secret's copy
  out=$(auth_pod)
  [[ "$(inits "${out}")" == "keys-owner wait-db migrations policy wait-redis" ]] || fail "auth's init containers: $(inits "${out}")"
  [[ "$(auth_pod --set fxa.volumeOwnerInit=false | jq -r '[.spec.initContainers[].name] | join(" ")')" == "wait-db migrations policy wait-redis" ]] \
    || fail "fxa.volumeOwnerInit=false: auth's init containers: $(auth_pod --set fxa.volumeOwnerInit=false | jq -r '[.spec.initContainers[].name] | join(" ")')"
  out=$(auth_pod --set fxa.keys.existingSecret=my-keys)
  [[ "$(inits "${out}")" == "keys-copy wait-db migrations policy wait-redis" ]] || fail "fxa.keys.existingSecret: auth's init containers: $(inits "${out}")"
  jq -e '[.spec.volumes[] | select(.name == "fxa-keys" or .name == "fxa-keys-secret")] == [{name: "fxa-keys", emptyDir: {}}, {name: "fxa-keys-secret", secret: {secretName: "my-keys"}}]
    and (.spec.initContainers[0].securityContext.runAsUser == 10001)' <<< "${out}" > /dev/null || fail "fxa.keys.existingSecret: the keys' volumes: ${out}"
  grep -q 'for f in secret-key.json public-key.json vapid-keys.json openid-key.json; do' <<< "$(jq -r '.spec.initContainers[0].args[2]' <<< "${out}")" \
    || fail "keys-copy does not check the four keys"
  objs=$(fxa_objs)
  jq -e '[.[] | select(.kind == "PersistentVolumeClaim" and .metadata.name == "test-release-firefox-sync-fxa-keys")
    | [.metadata.annotations["helm.sh/resource-policy"], .spec.accessModes[0], .spec.resources.requests.storage]] == [["keep", "ReadWriteOnce", "1Gi"]]' <<< "${objs}" > /dev/null \
    || fail "no PVC test-release-firefox-sync-fxa-keys (keep, RWO, 1Gi)"
  [[ "$(fxa_objs --set fxa.keys.existingSecret=my-keys | jq '[.[] | select(.kind == "PersistentVolumeClaim" and (.metadata.name | endswith("-fxa-keys")))] | length')" == 0 ]] \
    || fail "fxa.keys.existingSecret: the PVC of the keys still rendered"
  check "auth's init containers keys-owner (keys-copy with fxa.keys.existingSecret, none with volumeOwnerInit=false), wait-db, migrations, policy, wait-redis; the keys' PVC kept"

  # wait-db logs in to nothing, as the Sync server's
  out=$(auth_pod)
  if jq -r '.spec.initContainers[] | select(.name == "wait-db") | tostring' <<< "${out}" | grep -qE 'secretKeyRef|PASSWORD'; then
    fail "auth's wait-db uses a password"
  fi
  jq -e '(.spec.containers[0] | .workingDir == "/fxa/packages/fxa-auth-server/dist/packages/fxa-auth-server" and .startupProbe.httpGet.path == "/__heartbeat__")
    and (.spec.initContainers[] | select(.name == "migrations") | .workingDir == "/fxa/packages/db-migrations")
    and (.spec.initContainers[] | select(.name == "policy") | .args == ["fxa-init"] and .image == "ghcr.io/porelli/firefox-sync:admin-latest")
    and (.metadata.annotations | (.["checksum/fxa-config"] | test("^[0-9a-f]{64}$")) and (.["checksum/secrets"] | test("^[0-9a-f]{64}$")))' <<< "${out}" > /dev/null \
    || fail "auth: working dirs, probe, policy or checksums: ${out}"
  [[ "$(auth_pod --set existingSecret=mine | jq -r '.metadata.annotations | has("checksum/secrets")')" == false ]] || fail "existingSecret: checksum/secrets of a Secret the chart does not have"
  # the policy: your own server's policy user and its password, else FxA's user's pair
  policy_env() { jq -c '[.spec.initContainers[] | select(.name == "policy") | .env[] | select(.name | test("^FXA_(DB_ROOT|SIGNUP|MAX)"))
    | {(.name): (.value // .valueFrom.secretKeyRef.key)}] | add' <<< "$1"; }
  [[ "$(policy_env "${out}")" == '{"FXA_DB_ROOT_USER":"","FXA_DB_ROOT_PASSWORD":"","FXA_SIGNUPS":"allowlist","FXA_SIGNUP_ALLOWLIST":"@example.test,you@example.org","FXA_MAX_ACCOUNTS":"initial:unlimited"}' ]] \
    || fail "the policy's env: $(policy_env "${out}")"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/fxa-external-values.yaml" --set-string fxa.maxAccounts=5 | manifests \
    | jq -c '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-fxa-auth") | .spec.template')
  [[ "$(policy_env "${out}")" == '{"FXA_DB_ROOT_USER":"ffs_policy","FXA_DB_ROOT_PASSWORD":"FXA_MYSQL_POLICY_PASSWORD","FXA_SIGNUPS":"open","FXA_SIGNUP_ALLOWLIST":"","FXA_MAX_ACCOUNTS":"5"}' ]] \
    || fail "your own accounts server: the policy's env: $(policy_env "${out}")"
  jq -e '.spec.initContainers[] | select(.name == "wait-db") | .image == "docker.io/library/mariadb:lts" and (.args[0] | contains("mariadb-admin --connect-timeout=5 -h \"fxadb.example.test\" -P \"3306\" ping"))' <<< "${out}" > /dev/null \
    || fail "your own MariaDB server: wait-db"
  check "auth: wait-db without credentials; working dirs, heartbeat, checksums (checksum/secrets not with existingSecret); the policy's user (your own server's policyUser), signups, allowlist, max accounts"

  # the accounts database: compose's fxa-db for each backend, only bundled
  db_spec() { fxa_objs "$@" | jq -cS '.[] | select(.kind == "StatefulSet" and .metadata.name == "test-release-firefox-sync-fxa-db") | .spec.template.spec.containers[0]
    | {image, args, env: [.env[] | {(.name): (.value // .valueFrom.secretKeyRef.key)}] | add, probe: .startupProbe.exec.command, mount: .volumeMounts[0]}'; }
  # shellcheck disable=SC2016 # (compose's $$, literally)
  [[ "$(db_spec)" == '{"args":["mysqld","--mysql-native-password=ON","--authentication-policy=mysql_native_password","--event-scheduler=ON"],"env":{"MYSQL_ROOT_PASSWORD":"FXA_MYSQL_PASSWORD"},"image":"docker.io/library/mysql:8","mount":{"mountPath":"/var/lib/mysql","name":"data","subPath":"data"},"probe":["sh","-c","mysqladmin ping -h 127.0.0.1 --protocol=tcp -uroot -p$${MYSQL_ROOT_PASSWORD} --silent"]}' ]] \
    || fail "fxa-db (mysql): $(db_spec)"
  [[ "$(db_spec --set fxa.database.backend=mariadb)" == '{"args":["mariadbd","--event-scheduler=ON"],"env":{"MARIADB_AUTO_UPGRADE":"true","MYSQL_ROOT_PASSWORD":"FXA_MYSQL_PASSWORD"},"image":"docker.io/library/mariadb:lts","mount":{"mountPath":"/var/lib/mysql","name":"data","subPath":"data"},"probe":["healthcheck.sh","--connect","--innodb_initialized"]}' ]] \
    || fail "fxa-db (mariadb): $(db_spec --set fxa.database.backend=mariadb)"
  [[ "$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/fxa-external-values.yaml" | manifests | jq '[.[] | select(.metadata.name | test("-fxa-db$"))] | length')" == 0 ]] \
    || fail "your own accounts server: fxa-db rendered"
  check "fxa-db: compose's command, env and healthcheck (mysql, mariadb), data in subPath data; none with your own server"

  # Redis: the image's user, its data in memory
  jq -e '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-fxa-redis") | .spec | .strategy.type == "Recreate"
    and (.template.spec | .securityContext.runAsUser == 999 and .securityContext.runAsGroup == 1000 and .securityContext.fsGroup == 1000
    and .volumes == [{name: "data", emptyDir: {}}] and .containers[0].readinessProbe.exec.command == ["redis-cli", "ping"])' <<< "${objs}" > /dev/null \
    || fail "fxa-redis: not Recreate, uid 999/1000 with /data in an emptyDir and redis-cli ping"
  check "fxa-redis: Recreate, the image's redis (999, 1000), /data an emptyDir, redis-cli ping"

  # the scripts of config/fxa, byte for byte, in the ConfigMap
  local file
  for file in content-server.js oauth-clients.js; do
    cmp -s "${CHART_DIR}/files/fxa/${file}" "${REPO_ROOT}/config/fxa/${file}" || fail "files/fxa/${file} is not config/fxa/${file}"
    jq -j --arg f "${file}" '.[] | select(.kind == "ConfigMap" and .metadata.name == "test-release-firefox-sync-fxa-config") | .data[$f]' <<< "${objs}" \
      | cmp -s - "${REPO_ROOT}/config/fxa/${file}" || fail "the ConfigMap's ${file} is not config/fxa/${file}"
  done
  check "ConfigMap fxa-config: config/fxa/content-server.js and oauth-clients.js as they are"

  # the Sync server and the admin UI on these accounts
  [[ "$(jq -r '[.[] | select(.kind == "Deployment") | .spec.template.spec | (.initContainers // [])[], .containers[] | .env[]?
    | select(.name | test("FXA_(OAUTH_SERVER_URL|EMAIL_DOMAIN)$")) | "\(.name)=\(.value)"] | unique | join(" ")' <<< "${objs}")" == \
    "FXA_EMAIL_DOMAIN=api.example.test FXA_OAUTH_SERVER_URL=http://test-release-firefox-sync-fxa-auth:9000/v1 SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN=api.example.test SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL=http://test-release-firefox-sync-fxa-auth:9000/v1" ]] \
    || fail "the Sync server and the admin UI not on the accounts' auth server"
  check "the Sync server (migrate, syncstorage) and the admin UI: FXA_OAUTH_SERVER_URL the chart's auth, FXA_EMAIL_DOMAIN the host of fxa.authUrl"

  # fxa.extraCaCerts (chart-only): the ConfigMap at /ffs-ca, NODE_EXTRA_CA_CERTS
  out=$(auth_pod --set fxa.extraCaCerts.configMap=my-ca --set fxa.extraCaCerts.key=root.pem)
  jq -e '(.spec.containers[0] | (.env[] | select(.name == "NODE_EXTRA_CA_CERTS") | .value == "/ffs-ca/root.pem")
    and ([.volumeMounts[] | select(.name == "ffs-ca")] == [{name: "ffs-ca", mountPath: "/ffs-ca", readOnly: true}]))
    and ([.spec.volumes[] | select(.name == "ffs-ca")] == [{name: "ffs-ca", configMap: {name: "my-ca"}}])' <<< "${out}" > /dev/null \
    || fail "fxa.extraCaCerts: auth without /ffs-ca or NODE_EXTRA_CA_CERTS"
  [[ "$(auth_pod | jq '[.. | objects | select(.name? == "ffs-ca" or .name? == "NODE_EXTRA_CA_CERTS")] | length')" == 0 ]] || fail "no fxa.extraCaCerts: /ffs-ca rendered"
  check "fxa.extraCaCerts: auth's NODE_EXTRA_CA_CERTS=/ffs-ca/<key>, the ConfigMap at /ffs-ca; nothing without it"
}

fxa_base_parity() {
  local base base_dir mask values name diffs old new
  base=$(mktemp -d)
  if [[ -n "${PARITY_BASE_CHART:-}" ]]; then
    base_dir=$(cd "${PARITY_BASE_CHART}" && pwd) || fail "PARITY_BASE_CHART ${PARITY_BASE_CHART}: no such directory"
  elif git -C "${REPO_ROOT}" archive "${PARITY_BASE}" charts/firefox-sync 2> /dev/null | tar -x -C "${base}"; then
    base_dir="${base}/charts/firefox-sync"
  else
    rm -rf "${base}"
    fail "chart 0.1.0 (${PARITY_BASE}) not in this checkout: set PARITY_BASE_CHART to it extracted (git archive ${PARITY_BASE} charts/firefox-sync | tar -x -C <dir>)"
  fi
  [[ "$(sed -n 's/^version: //p' "${base_dir}/Chart.yaml")" == 0.1.0 ]] || fail "${base_dir}: not chart 0.1.0"
  # (the Secret's data masked: its generated values differ on every render, and so does the
  # admin UI's checksum/admin-secrets, the sha256 of that data; its keys are compared)
  mask='walk(if type == "object" then
      (if has("helm.sh/chart") then .["helm.sh/chart"] = "masked" else . end)
      | (if has("checksum/admin-secrets") then .["checksum/admin-secrets"] = "masked" else . end)
      | (if .name? == "ADMIN_K8S_CHART_VERSION" and has("value") then .value = "masked" else . end)
      | (if .kind? == "Secret" and has("data") then .data = (.data | map_values("masked")) else . end)
    else . end)'
  diffs=""
  for values in "${base_dir}"/ci/*.yaml; do
    name=$(basename "${values}")
    [[ -f "${CHART_DIR}/ci/${name}" ]] || fail "ci/${name} of chart 0.1.0 is gone"
    old=$(helm template test-release "${base_dir}" -f "${values}" 2>&1) || fail "chart 0.1.0 failed to render with ci/${name}: ${old}"
    new=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/${name}" 2>&1) || fail "the chart failed to render with ci/${name}: ${new}"
    if ! diff <(manifests <<< "${old}" | jq -S "${mask}") <(manifests <<< "${new}" | jq -S "${mask}") > "${base}/${name}.diff"; then
      diffs+=" ${name}"
      cut -c1-200 "${base}/${name}.diff" | head -40
    fi
  done
  rm -rf "${base}"
  [[ -z "${diffs}" ]] || fail "with the accounts off, not what chart 0.1.0 renders:${diffs}"
  check "accounts off: the same objects as chart 0.1.0 (${PARITY_BASE}) for every ci/*.yaml it had (but helm.sh/chart, ADMIN_K8S_CHART_VERSION, the Secret's values and their checksum)"
}

# e2e <mysql|mariadb>: the chart with the accounts (their database on that backend, the Sync
# server's too) on a throwaway kind cluster: the auth pod's init containers in compose's
# order, its keys, its heartbeat, the sign-up policy, and fail closed on a wrong password.
# REPOSITORY, TAG: the Sync server's images, as tests/helm.sh; FXA_IMAGE (default REPOSITORY),
# FXA_VERSION (default fxa-mono-latest): the accounts'; FXA_MARIADB_IMAGE: their MariaDB (as
# tests/e2e-fxa.sh: the chart's lts when the accounts image has mozilla/fxa#21494, else mariadb:11)
fxa_e2e() {
  local backend=${1:-}
  case "${backend}" in
    mysql|mariadb) ;;
    *) echo "Usage: $0 e2e <mysql|mariadb>"; exit 1 ;;
  esac
  local repository=${REPOSITORY:-ghcr.io/porelli/firefox-sync} tag=${TAG:-latest} init_tag=${TAG:-latest}
  local fxa_image=${FXA_IMAGE:-${repository}}:${FXA_VERSION:-fxa-mono-latest}
  local db_image redis_image=docker.io/library/redis:7-alpine
  db_image=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["fxa"]["database"]["image"][sys.argv[2]])' \
    "${CHART_DIR}/values.yaml" "${backend}") || fail "no fxa.database.image.${backend} in values.yaml"
  # MariaDB lts (12) needs mozilla/fxa#21494 in the accounts image (the label of our builds,
  # upstream-patches.yml): MariaDB 11 without it, as tests/e2e-fxa.sh
  local db_args=()
  if [[ ${backend} == mariadb ]]; then
    if [[ -n "${FXA_MARIADB_IMAGE:-}" ]]; then
      db_image=${FXA_MARIADB_IMAGE}
    else
      docker image inspect "${fxa_image}" > /dev/null 2>&1 || docker pull -q "${fxa_image}" > /dev/null || fail "${fxa_image} not pulled"
      if [[ " $(docker image inspect -f '{{index .Config.Labels "org.firefox-sync.upstream-patches"}}' "${fxa_image}") " != *" mozilla/fxa#21494@"* ]]; then
        db_image=docker.io/library/mariadb:11
        echo "== ${fxa_image} without mozilla/fxa#21494 (label org.firefox-sync.upstream-patches): the accounts on ${db_image}"
      fi
    fi
    db_args=(--set fxa.database.image.mariadb="${db_image}")
  fi
  ADMIN_TAG=${TAG:-latest}
  CLUSTER="ffs-helm-fxa-${backend}"
  REL=t
  FULL="${REL}-firefox-sync"
  SECRET=${FULL}
  SYNC_IMAGE="${repository}:syncstorage-rs-mysql-${tag}"
  POD_SELECTOR="app.kubernetes.io/instance=${REL},app.kubernetes.io/component=fxa-auth"

  # the accounts image is about 5 GB in the node, on top of the Sync server's images
  local free
  free=$(df -BG --output=avail "$(docker info -f '{{.DockerRootDir}}')" | tail -1 | tr -dc 0-9)
  [[ "${free}" -ge 15 ]] || fail "${free} GB free for docker, the accounts' kind cluster needs 15 GB (vm.sh prune, docker system prune)"
  [[ ${backend} != mysql ]] || mysqld_apparmor_check

  echo "=== e2e of the accounts on kind (${backend}) ==="
  kind delete cluster --name "${CLUSTER}" > /dev/null 2>&1 || true
  trap 'rc=$?; if ((rc)); then diagnostics; fi; kind delete cluster --name "${CLUSTER}"' EXIT
  kind create cluster --name "${CLUSTER}" --wait 120s
  kubectl config use-context "kind-${CLUSTER}" > /dev/null
  # PodSecurity baseline, enforced, as tests/helm.sh
  kubectl label ns default pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=latest > /dev/null
  load_images "${repository}" mysql db/mysql/init
  # the images of the host's docker (pulled there first when missing) into the node, as
  # tests/helm.sh loads the Sync server's: the node's platform alone (a pulled image's export
  # lacks the others), the import's layers dropped once unpacked (disk)
  local image platform
  platform=$(docker version -f 'linux/{{.Server.Arch}}')
  local sync_db_image
  sync_db_image=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["database"]["image"][sys.argv[2]])' \
    "${CHART_DIR}/values.yaml" "${backend}") || fail "no database.image.${backend} in values.yaml"
  for image in "${SYNC_IMAGE}" "${fxa_image}" "${db_image}" "${redis_image}" $([[ ${sync_db_image} == "${db_image}" ]] || echo "${sync_db_image}"); do
    docker image inspect "${image}" > /dev/null 2>&1 || docker pull -q "${image}" > /dev/null || fail "${image} not pulled"
    docker save --platform "${platform}" "${image}" | docker exec -i "${CLUSTER}-control-plane" ctr --namespace=k8s.io images import --digests \
      --snapshotter=overlayfs --local --discard-unpacked-layers - > /dev/null || fail "${image} not loaded"
  done
  check "loaded from the host's docker: ${SYNC_IMAGE} ${fxa_image} ${db_image} ${redis_image}$([[ ${sync_db_image} == "${db_image}" ]] || echo " ${sync_db_image}")"
  # the user of fxa-redis' pod: the image's redis
  [[ "$(docker run --rm "${redis_image}" id redis)" == "uid=999(redis) gid=1000(redis)"* ]] \
    || fail "${redis_image}: redis is $(docker run --rm "${redis_image}" id redis), not uid 999, gid 1000"
  check "${redis_image}: redis is uid 999, gid 1000"

  helm install "${REL}" "${CHART_DIR}" -f "${SCRIPT_DIR}/helm/fxa-values.yaml" --set fxa.enabled=true \
    --set database.backend="${backend}" --set fxa.database.backend="${backend}" \
    --set image.repository="${repository}" --set image.syncstorageTag="${tag}" --set image.initTag="${init_tag}" \
    --set image.adminTag="${ADMIN_TAG}" --set fxa.image.repository="${fxa_image%:*}" --set fxa.image.tag="${fxa_image##*:}" "${db_args[@]}" \
    --wait --timeout 20m || fail "helm install with the accounts did not get Ready"
  check "helm install with the accounts (${backend}) Ready, in a namespace enforcing PodSecurity baseline"

  # the auth server only after its init containers, in compose's order, all succeeded
  local inits
  inits=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r '.items[0].status.initContainerStatuses[]
    | "\(.name)=\(.state.terminated.exitCode // "none")"' | paste -sd' ' -) || true
  [[ "${inits}" == "keys-owner=0 wait-db=0 migrations=0 policy=0 wait-redis=0" ]] || fail "the auth pod's init containers: ${inits}"
  check "auth's init containers: ${inits}"
  local auth="deploy/${FULL}-fxa-auth"
  # (oauth_gen_keys.js also writes openid-oldKey.json, FXA_OPENID_OLDKEYFILE)
  [[ "$(kubectl exec "${auth}" -c auth -- ls /fxa-keys | paste -sd' ' -)" == "oauth-clients.json openid-key.json openid-oldKey.json public-key.json secret-key.json vapid-keys.json" ]] \
    || fail "/fxa-keys has $(kubectl exec "${auth}" -c auth -- ls -l /fxa-keys)"
  [[ "$(kubectl exec "${auth}" -c auth -- sh -c 'stat -c %u /fxa-keys /fxa-keys/*' | sort -u)" == 10001 ]] \
    || fail "/fxa-keys not 10001's: $(kubectl exec "${auth}" -c auth -- ls -ln /fxa-keys)"
  check "/fxa-keys: oauth-clients.json, openid-key.json, openid-oldKey.json, public-key.json, secret-key.json, vapid-keys.json, uid 10001's"
  kubectl exec "${auth}" -c auth -- node -e "fetch('http://localhost:9000/__heartbeat__').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))" \
    || fail "auth's /__heartbeat__ does not answer 200"
  check "auth's /__heartbeat__ answers"
  kubectl logs "${auth}" -c policy | grep -q 'max accounts: unlimited' || fail "the policy's log: $(kubectl logs "${auth}" -c policy | tail -5)"
  check "the sign-up policy installed: max accounts: unlimited"

  # fail closed: a wrong password of the accounts' database stops auth at the migrations
  # (wait-db has no credentials), never Ready, out of its Service
  local good ready
  good=$(kubectl get secret "${SECRET}" -o jsonpath='{.data.FXA_MYSQL_PASSWORD}')
  kubectl patch secret "${SECRET}" --type merge -p "{\"data\":{\"FXA_MYSQL_PASSWORD\":\"$(printf wrong | base64)\"}}"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true
  # (the first failure, after the migrations' 60 tries, is rerun at once: Init:Error lasts a
  # moment, then Init:2/5 again, Init:CrashLoopBackOff from the second one on)
  wait_init_failed migrations 600 || fail "the auth pod's migrations did not fail"
  [[ "$(pod_status)" =~ ^Init: ]] || fail "the auth pod is $(pod_status), not in its init containers"
  MATCHED_STATUS=$(pod_status)
  inits=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r '.items[0].status.initContainerStatuses[]
    | "\(.name)=\(.state.terminated.exitCode // .lastState.terminated.exitCode // "none")"' | paste -sd' ' -) || true
  [[ "${inits}" =~ wait-db=0\ migrations=[1-9] ]] || fail "expected wait-db to pass and the migrations to fail: ${inits}"
  ready=$(kubectl get endpointslices -l "kubernetes.io/service-name=${FULL}-fxa-auth" -o json \
    | jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length')
  [[ "${ready}" == 0 ]] || fail "${FULL}-fxa-auth has ${ready} ready endpoints while the migrations fail"
  check "wrong FXA_MYSQL_PASSWORD: auth in ${MATCHED_STATUS} (${inits}), no ready endpoint"
  kubectl patch secret "${SECRET}" --type merge -p "{\"data\":{\"FXA_MYSQL_PASSWORD\":\"${good}\"}}"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true
  kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout=15m || fail "auth not Ready after restoring the password"
  check "password restored: auth Ready again"

  echo ""
  echo "=== e2e of the accounts (${backend}) passed ==="
}

# wait_init_failed <init container> <seconds>: in the only pod of POD_SELECTOR, that init
# container exited with an error (now or in its previous run)
wait_init_failed() {
  local deadline=$(( $(date +%s) + $2 )) code
  while [[ $(date +%s) -lt ${deadline} ]]; do
    code=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r --arg c "$1" '[.items[].status.initContainerStatuses[]? | select(.name == $c)
      | .state.terminated.exitCode // .lastState.terminated.exitCode // 0] | if length == 1 then .[0] else 0 end') || code=0
    [[ "${code}" -gt 0 ]] && return 0
    sleep 5
  done
  echo "pod status: $(pod_status)"
  return 1
}

# run, not sourced by tests/helm.sh: the e2e
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  CHART_DIR="${REPO_ROOT}/charts/firefox-sync"
  # shellcheck source=tests/helm/lib.sh
  source "${SCRIPT_DIR}/helm/lib.sh"
  case "${1:-}" in
    e2e) fxa_e2e "${2:-}" ;;
    *)
      echo "Usage: $0 e2e <mysql|mariadb>   (the template checks: tests/helm.sh lint)"
      exit 1
      ;;
  esac
fi
