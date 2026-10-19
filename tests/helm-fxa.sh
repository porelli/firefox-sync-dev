#!/bin/bash
# The chart's self-hosted Mozilla accounts (fxa.enabled), FXA.md under Kubernetes.
#
#   fxa_lint    the template checks of the accounts, run by `tests/helm.sh lint`, which sources
#               this file (it uses helm.sh's check, fail, manifests and CHART_DIR)
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
  # 32 letters and digits) and ADMIN_FXA_CLIENT_SECRET of the values; none without them
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
  jq -e --arg g "${generated}" '. as $d | [$g | split(" ")[] | $d[.] | @base64d | test("^[A-Za-z0-9]{32}$")] | all' <<< "${on}" > /dev/null \
    || fail "the generated secrets of the accounts are not 32 letters and digits: ${on}"
  [[ "$(jq -r '.ADMIN_FXA_CLIENT_SECRET | @base64d' <<< "${on}")" == "$(printf 'b%.0s' $(seq 1 64))" ]] || fail "ADMIN_FXA_CLIENT_SECRET is not fxa.adminClientSecret"
  [[ "$(secret_data -f "${fxa}" | jq -r '.ADMIN_FXA_CLIENT_SECRET')" == "" ]] || fail "an empty fxa.adminClientSecret is not an empty ADMIN_FXA_CLIENT_SECRET"
  for values in "${CHART_DIR}"/ci/{default,admin,backup,mysql,postgres}-values.yaml; do
    [[ "$(secret_data -f "${values}" | jq -r 'keys[] | select(test("^(FXA_|ADMIN_FXA_)") and . != "FXA_SMTP_PASS")')" == "" ]] \
      || fail "$(basename "${values}"): keys of the accounts in the Secret without them"
  done
  [[ "$(secret_data -f "${fxa}" --set smtp.password=pw | jq -r '.FXA_SMTP_PASS | @base64d')" == pw ]] || fail "FXA_SMTP_PASS is not smtp.password"
  check "Secret: fxa.enabled adds the eight generated secrets of prepare_environment.sh (32 characters) and ADMIN_FXA_CLIENT_SECRET (fxa.adminClientSecret); none without; FXA_SMTP_PASS of smtp.password"

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
  jq -e '.pod | fromjson | .runAsUser == 10001 and .runAsGroup == 10001 and .runAsNonRoot and .fsGroup == 10001 and .seccompProfile.type == "RuntimeDefault"' <<< "${out}" > /dev/null \
    || fail "fxaPodSecurityContext: $(jq -r '.pod' <<< "${out}")"
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

  # chart 0.1.0's render, with the accounts off: the same objects for every ci/*.yaml it had,
  # but the chart label, ADMIN_K8S_CHART_VERSION and the generated secrets
  fxa_base_parity
}

fxa_base_parity() {
  local base base_dir mask values name diffs
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
  # admin UI's checksum/admin-secrets, the sha256 of that data)
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
    if ! diff <(helm template test-release "${base_dir}" -f "${values}" | manifests | jq -S "${mask}") \
      <(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/${name}" | manifests | jq -S "${mask}") > "${base}/${name}.diff"; then
      diffs+=" ${name}"
      cut -c1-200 "${base}/${name}.diff" | head -40
    fi
  done
  rm -rf "${base}"
  [[ -z "${diffs}" ]] || fail "with the accounts off, not what chart 0.1.0 renders:${diffs}"
  check "accounts off: the same objects as chart 0.1.0 (${PARITY_BASE}) for every ci/*.yaml it had (but helm.sh/chart, ADMIN_K8S_CHART_VERSION, the Secret's values and their checksum)"
}
