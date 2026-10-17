#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${REPO_ROOT}/charts/firefox-sync"

check() {
  echo "✓ $1"
}

fail() {
  echo "✗ $1"
  exit 1
}

lint() {
  echo "=== Running Helm lint checks ==="

  # Check that chart directory exists
  if [[ ! -d "${CHART_DIR}" ]]; then
    fail "Chart directory not found: ${CHART_DIR}"
  fi

  # Lint with each CI values file
  for values_file in "${CHART_DIR}"/ci/*.yaml; do
    if [[ ! -f "${values_file}" ]]; then
      continue
    fi
    echo "Linting with $(basename "${values_file}")..."
    if ! helm lint "${CHART_DIR}" -f "${values_file}"; then
      fail "Helm lint failed with $(basename "${values_file}")"
    fi
    check "Helm lint passed with $(basename "${values_file}")"
  done

  # Test maxUsers value propagation
  echo "Testing maxUsers value propagation..."
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set-string maxUsers=5)
  count=$(echo "${output}" | grep -c 'value: "5"' || true)
  if [[ ${count} -lt 1 ]]; then
    fail "maxUsers=5 not found in template output (expected at least 1 occurrence, found ${count})"
  fi
  check "maxUsers value propagation works (found ${count} occurrences)"

  # Test schema validation - invalid backend should fail
  echo "Testing schema validation with invalid backend..."
  if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend=sqlite >/dev/null 2>&1; then
    fail "Schema validation did not reject invalid database.backend (sqlite)"
  fi
  check "Schema validation correctly rejects invalid database.backend"

  # The database URLs of the syncstorage containers read the right password variables
  echo "Testing the database URLs' password variables..."
  for backend in postgres mysql mariadb; do
    output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}")
    urls=$(echo "${output}" | grep -A1 -E 'name: SYNC_(TOKENSERVER|SYNCSTORAGE)__DATABASE_URL$' | grep 'value:')
    [[ $(echo "${urls}" | wc -l) -eq 4 ]] || fail "${backend}: expected 4 database URLs (migrate and syncstorage), got: ${urls}"
    if [[ ${backend} == postgres ]]; then
      bad=$(echo "${urls}" | grep -v '$(POSTGRES_PASSWORD)@' || true)
    else
      bad=$(echo "${output}" | grep -A1 -E 'name: SYNC_TOKENSERVER__DATABASE_URL$' | grep 'value:' | grep -v '$(TOKENSERVER_DB_PASSWORD)@' || true)
      bad+=$(echo "${output}" | grep -A1 -E 'name: SYNC_SYNCSTORAGE__DATABASE_URL$' | grep 'value:' | grep -v '$(STORAGE_DB_PASSWORD)@' || true)
    fi
    [[ -z "${bad}" ]] || fail "${backend}: database URLs with the wrong password variable: ${bad}"
    check "${backend}: database URLs use the backend's password variables"
  done

  # existingSecret: no Secret rendered, every secretKeyRef reads that one
  echo "Testing existingSecret..."
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set existingSecret=my-secret)
  if echo "${output}" | grep -q '^kind: Secret'; then
    fail "existingSecret set, but the chart still renders a Secret"
  fi
  refs=$(echo "${output}" | grep -A1 'secretKeyRef:' | grep 'name:' | sort -u)
  [[ "${refs}" =~ ^[[:space:]]*name:\ my-secret$ ]] || fail "secretKeyRefs not all to my-secret: ${refs}"
  check "existingSecret: no Secret rendered, all secretKeyRefs read it"

  echo ""
  echo "=== All lint checks passed ==="
}

# e2e <mariadb|mysql|postgres>: the chart on a throwaway kind cluster, with upstream's mock
# FxA, what a Firefox client does (tests/test_client_flow.py), fail closed, and upgrades
e2e() {
  local backend=${1:-}
  local flavor password_key init_dir
  case "${backend}" in
    mariadb|mysql) flavor=mysql; password_key=TOKENSERVER_DB_PASSWORD; init_dir=syncstorage-rs-init ;;
    postgres) flavor=postgres; password_key=POSTGRES_PASSWORD; init_dir=syncstorage-rs-init-postgres ;;
    *) echo "Usage: $0 e2e <mariadb|mysql|postgres>"; exit 1 ;;
  esac
  # as tests/e2e.sh: REPOSITORY and TAG of the images; the init image is built from this
  # tree (the published one may be older than the chart), unless SKIP_BUILD=1
  local repository=${REPOSITORY:-ghcr.io/porelli/firefox-sync} tag=${TAG:-latest} init_tag=${TAG:-latest}
  BACKEND=${backend}
  CLUSTER="ffs-helm-${backend}"
  REL=t
  FULL="${REL}-firefox-sync"
  SYNC_IMAGE="${repository}:syncstorage-rs-${flavor}-${tag}"
  SYNCSTORAGE_DOMAIN=https://sync.example.test
  POD_SELECTOR="app.kubernetes.io/instance=${REL},app.kubernetes.io/component=syncstorage"

  echo "=== e2e on kind (${backend}) ==="
  kind delete cluster --name "${CLUSTER}" > /dev/null 2>&1 || true
  trap 'diagnostics; kind delete cluster --name "${CLUSTER}"' EXIT
  kind create cluster --name "${CLUSTER}" --wait 120s
  kubectl config use-context "kind-${CLUSTER}" > /dev/null
  if [[ -z "${SKIP_BUILD:-}" ]]; then
    init_tag=helm-e2e
    docker build -q -t "${repository}:syncstorage-rs-${flavor}-init-${init_tag}" "${REPO_ROOT}/${init_dir}" \
      || fail "init image not built"
    kind load docker-image --name "${CLUSTER}" "${repository}:syncstorage-rs-${flavor}-init-${init_tag}"
    check "init image built from ${init_dir}"
  fi

  sed "s|ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-latest|${SYNC_IMAGE}|" \
    "${SCRIPT_DIR}/helm/mock-fxa.yaml" | kubectl apply -f -
  kubectl rollout status deploy/mock-fxa --timeout=5m
  check "mock FxA is up"

  helm install "${REL}" "${CHART_DIR}" \
    --set syncDomain="${SYNCSTORAGE_DOMAIN}" --set-string maxUsers=1 \
    --set fxa.oauthServerUrl=http://mock-fxa:6000 \
    --set fxa.emailDomain=api-accounts.stage.mozaws.net \
    --set database.backend="${backend}" --set image.repository="${repository}" \
    --set image.syncstorageTag="${tag}" --set image.initTag="${init_tag}" --wait --timeout 10m \
    || fail "helm install did not get Ready"
  check "helm install (${backend}) Ready"

  kubectl create configmap ffs-tests --from-file="${SCRIPT_DIR}/test_client_flow.py"
  client_flow flow-1 || fail "client flow failed"
  check "client flow passed"

  # fail closed: an invalid MAX_USERS never reaches the cluster
  if out=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set maxUsers=bogus --no-hooks 2>&1); then
    fail "helm upgrade accepted maxUsers=bogus"
  fi
  echo "${out}" | grep -q maxUsers || fail "maxUsers=bogus refused, but not by the schema: ${out}"
  check "maxUsers=bogus refused by the schema"

  # fail closed: a wrong database password keeps the pod in its init containers, out of the Service
  good=$(kubectl get secret "${FULL}" -o jsonpath="{.data.${password_key}}")
  kubectl patch secret "${FULL}" --type merge -p "{\"data\":{\"${password_key}\":\"$(printf wrong | base64)\"}}"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true
  wait_pod_status 'Init:Error|Init:CrashLoopBackOff' 420 || fail "pod did not stop in its init containers"
  check "wrong ${password_key}: pod is in ${MATCHED_STATUS}"
  addresses=$(kubectl get endpoints "${FULL}-syncstorage" -o jsonpath='{.subsets[*].addresses[*].ip}')
  [[ -z "${addresses}" ]] || fail "the Service has endpoints while the init fails: ${addresses}"
  check "the syncstorage Service has no endpoints"
  kubectl patch secret "${FULL}" --type merge -p "{\"data\":{\"${password_key}\":\"${good}\"}}"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true
  kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout=10m || fail "pod not Ready after restoring the password"
  check "password restored: Ready again"

  # upgrades keep every secret
  before=$(kubectl get secret "${FULL}" -o json | jq -S .data)
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values \
    --set syncstorage.resources.requests.cpu=50m --wait --timeout 10m || fail "helm upgrade failed"
  after=$(kubectl get secret "${FULL}" -o json | jq -S .data)
  [[ "${before}" == "${after}" ]] || fail "helm upgrade changed the Secret"
  for key in SYNC_MASTER_SECRET METRICS_HASH_SECRET ADMIN_PASSWORD; do
    [[ "$(echo "${after}" | jq -r ".${key} // empty")" != "" ]] || fail "Secret has no ${key}"
  done
  check "helm upgrade kept the Secret data"
  # as tests/e2e.sh: the first run changed alice's keys, a first sign-in needs no users
  sql "DELETE FROM users;" || fail "could not empty the users table"
  client_flow flow-2 "-k first_sign_in" || fail "client flow after the upgrade failed"
  check "client flow after the upgrade passed"

  echo ""
  echo "=== e2e (${backend}) passed ==="
}

# sql <statement>: on the tokenserver database, as the stack's user, in the database pod
sql() {
  case "${BACKEND}" in
    mariadb) kubectl exec "${FULL}-tokenserver-db-0" -- sh -c 'mariadb -u"${MARIADB_USER}" -p"${MARIADB_PASSWORD}" "${MARIADB_DATABASE}" -e "$1"' sh "$1" ;;
    mysql) kubectl exec "${FULL}-tokenserver-db-0" -- sh -c 'mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${MYSQL_DATABASE}" -e "$1"' sh "$1" ;;
    postgres) kubectl exec "${FULL}-postgres-0" -- sh -c 'psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "$1"' sh "$1" ;;
  esac
}

pod_status() {
  kubectl get pods -l "${POD_SELECTOR}" --no-headers 2>/dev/null | awk '{print $3}' | paste -sd, -
}

# wait_pod_status <regex> <seconds>: the only syncstorage pod has a STATUS matching regex
wait_pod_status() {
  local deadline=$(( $(date +%s) + $2 )) status
  while [[ $(date +%s) -lt ${deadline} ]]; do
    status=$(pod_status)
    if [[ "${status}" != *,* ]] && [[ "${status}" =~ ^($1)$ ]]; then
      MATCHED_STATUS=${status}
      return 0
    fi
    sleep 5
  done
  echo "pod status: ${status}"
  return 1
}

# client_flow <job name> [pytest args]: tests/test_client_flow.py in the syncstorage image,
# with the syncstorage container's own env (database URLs and their passwords from the Secret)
client_flow() {
  local name=$1 args=${2:-}
  local env
  env=$(kubectl get deploy "${FULL}-syncstorage" -o json | jq '.spec.template.spec.containers[]
    | select(.name == "syncstorage") | .env
    | map(select(.name != "SYNC_SERVER_URL" and .name != "MAX_USERS"))
    + [{name: "SYNC_SERVER_URL", value: "http://'"${FULL}"'-syncstorage:8000"},
       {name: "SYNCSTORAGE_DOMAIN", value: "'"${SYNCSTORAGE_DOMAIN}"'"},
       {name: "MAX_USERS", value: "1"},
       {name: "PYTHONPATH", value: "/app:/app/tools"},
       {name: "PYTHONDONTWRITEBYTECODE", value: "1"}]') || return 1
  jq -n --arg name "${name}" --arg image "${SYNC_IMAGE}" --arg args "${args}" --argjson env "${env}" '{
    apiVersion: "batch/v1", kind: "Job", metadata: {name: $name},
    spec: {backoffLimit: 0, template: {spec: {restartPolicy: "Never",
      securityContext: {runAsUser: 0},
      containers: [{name: "pytest", image: $image, workingDir: "/app",
        command: ["/bin/sh", "-c", ("python3 -m pytest -q -p no:cacheprovider /tests/test_client_flow.py " + $args)],
        env: $env, volumeMounts: [{name: "tests", mountPath: "/tests", readOnly: true}]}],
      volumes: [{name: "tests", configMap: {name: "ffs-tests"}}]}}}}' | kubectl apply -f - || return 1
  local deadline=$(( $(date +%s) + 600 )) succeeded failed
  while [[ $(date +%s) -lt ${deadline} ]]; do
    succeeded=$(kubectl get job "${name}" -o jsonpath='{.status.succeeded}')
    failed=$(kubectl get job "${name}" -o jsonpath='{.status.failed}')
    if [[ "${succeeded}" == 1 || -n "${failed}" ]]; then
      break
    fi
    sleep 5
  done
  kubectl logs "job/${name}" --tail=40 || true
  [[ "${succeeded}" == 1 ]]
}

# on the way out, what the pods did (only useful when something failed)
diagnostics() {
  kubectl get pods -o wide 2>/dev/null || return 0
  for pod in $(kubectl get pods -l "${POD_SELECTOR}" -o name 2>/dev/null); do
    for c in wait-db migrate db-init syncstorage; do
      echo "--- ${pod} ${c}"
      kubectl logs "${pod}" -c "${c}" --tail=15 2>/dev/null || true
    done
  done
}

case "${1:-}" in
  lint)
    lint
    ;;
  e2e)
    e2e "${2:-}"
    ;;
  *)
    echo "Usage: $0 {lint|e2e <mariadb|mysql|postgres>}"
    echo "  lint                              - helm lint and template checks"
    echo "  e2e <mariadb|mysql|postgres>      - install on a kind cluster and run the client flow"
    exit 1
    ;;
esac
