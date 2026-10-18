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

  # maxUsers: a string, or a number rendered as a string, in the db-init container's MAX_USERS
  echo "Testing maxUsers..."
  max_users() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "$@" \
      --show-only templates/syncstorage.yaml | grep -A1 'name: MAX_USERS$' | grep 'value:' | sed 's/^ *//'
  }
  [[ "$(max_users --set maxUsers=5)" == 'value: "5"' ]] || fail "--set maxUsers=5: $(max_users --set maxUsers=5)"
  [[ "$(max_users --set-string maxUsers=initial:5)" == 'value: "initial:5"' ]] || fail "maxUsers=initial:5 not rendered as is"
  values=$(mktemp)
  printf 'maxUsers: 5\n' > "${values}"
  [[ "$(max_users -f "${values}")" == 'value: "5"' ]] || fail "unquoted maxUsers: 5 in a values file: $(max_users -f "${values}")"
  printf 'maxUsers: 1000000\n' > "${values}"
  [[ "$(max_users -f "${values}")" == 'value: "1000000"' ]] || fail "maxUsers: 1000000: $(max_users -f "${values}")"
  rm -f "${values}"
  check "maxUsers 5 (--set and unquoted in a values file), initial:5 and 1000000 render as strings"
  for bad in bogus -1 fixed:-1 initial:; do
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set maxUsers="${bad}" > /dev/null 2>&1; then
      fail "maxUsers=${bad} not refused by the schema"
    fi
  done
  check "maxUsers bogus, -1, fixed:-1, initial: refused by the schema"

  # wait-db logs in to nothing: no password in that init container
  for backend in mariadb mysql postgres; do
    waitdb=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" \
      --show-only templates/syncstorage.yaml | sed -En '/- name: wait-db$/,/- name: (sync-role|migrate)$/p')
    [[ -n "${waitdb}" ]] || fail "${backend}: no wait-db init container"
    if echo "${waitdb}" | grep -qiE 'secretKeyRef|PASSWORD|-p"'; then
      fail "${backend}: wait-db uses a password: ${waitdb}"
    fi
  done
  check "wait-db has no credentials (mariadb, mysql, postgres)"

  # MariaDB and MySQL data in a subdirectory of the volume (lost+found)
  for backend in mariadb mysql; do
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" \
      --show-only templates/databases.yaml | grep -A1 'mountPath: /var/lib/mysql$' | grep -q 'subPath: data$' \
      || fail "${backend}: /var/lib/mysql not mounted with subPath: data"
  done
  check "MariaDB and MySQL data mounted with subPath: data"

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
      # the Sync server's own role, never POSTGRES_USER (the superuser)
      bad=$(echo "${urls}" | grep -v 'postgres://syncserver_app:$(POSTGRES_SYNC_PASSWORD)@' || true)
    else
      bad=$(echo "${output}" | grep -A1 -E 'name: SYNC_TOKENSERVER__DATABASE_URL$' | grep 'value:' | grep -v '$(TOKENSERVER_DB_PASSWORD)@' || true)
      bad+=$(echo "${output}" | grep -A1 -E 'name: SYNC_SYNCSTORAGE__DATABASE_URL$' | grep 'value:' | grep -v '$(STORAGE_DB_PASSWORD)@' || true)
    fi
    [[ -z "${bad}" ]] || fail "${backend}: database URLs with the wrong password variable: ${bad}"
    check "${backend}: database URLs use the backend's password variables"
  done

  # the Sync server and its migrations: never POSTGRES_PASSWORD (the superuser's), no NET_RAW
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/postgres-values.yaml" --show-only templates/syncstorage.yaml)
  for c in migrate syncstorage; do
    block=$(echo "${output}" | awk -v c="${c}" '$0 ~ "^        - name: "c"$" {on=1; print; next} on && /^        - name: / {on=0} on')
    [[ -n "${block}" ]] || fail "postgres: no ${c} container"
    if echo "${block}" | grep -qE 'name: POSTGRES_PASSWORD$|key: POSTGRES_PASSWORD$'; then
      fail "postgres: ${c} gets POSTGRES_PASSWORD"
    fi
    echo "${block}" | grep -A2 'capabilities:' | grep -q 'drop: \["NET_RAW"\]' || fail "postgres: ${c} keeps NET_RAW"
  done
  echo "${output}" | grep -q '^        - name: sync-role$' || fail "postgres: no sync-role init container"
  [[ "$(echo "${output}" | grep -E '^        - name: (wait-db|sync-role|migrate|db-init)$' | awk '{print $3}' | paste -sd' ' -)" == "wait-db sync-role migrate db-init" ]] \
    || fail "postgres: init containers not in compose's order"
  check "postgres: sync-role before migrate; migrate and syncstorage without POSTGRES_PASSWORD and NET_RAW"
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --show-only templates/syncstorage.yaml)
  [[ $(echo "${output}" | grep -c 'drop: \["NET_RAW"\]') -eq 2 ]] || fail "mariadb: NET_RAW not dropped on migrate and syncstorage"
  check "mariadb: migrate and syncstorage without NET_RAW"

  # db/mysql/admin-user.sh: the chart's copy identical, run by the MariaDB and MySQL containers
  cmp -s "${CHART_DIR}/files/admin-user.sh" "${REPO_ROOT}/db/mysql/admin-user.sh" \
    || fail "charts/firefox-sync/files/admin-user.sh differs from db/mysql/admin-user.sh"
  for backend in mariadb mysql; do
    output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" --show-only templates/databases.yaml)
    [[ $(echo "${output}" | grep -c 'args: \[sh, /ffs-db/admin-user.sh, ') -eq 2 ]] || fail "${backend}: admin-user.sh not the command of both databases"
    [[ $(echo "${output}" | grep -c 'name: ADMIN_DB_ROLE$') -eq 2 ]] || fail "${backend}: ADMIN_DB_ROLE missing"
  done
  check "admin-user.sh identical to db/mysql/admin-user.sh, run by both MariaDB/MySQL databases"

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
    mariadb|mysql) failing_init='wait-db=0 migrate=[1-9]'; flavor=mysql; password_key=TOKENSERVER_DB_PASSWORD; init_dir=db/mysql/init ;;
    postgres) failing_init='wait-db=0 sync-role=[1-9]'; flavor=postgres; password_key=POSTGRES_PASSWORD; init_dir=db/postgres/init ;;
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
    --set syncDomain="${SYNCSTORAGE_DOMAIN}" --set maxUsers=1 \
    --set fxa.oauthServerUrl=http://mock-fxa:6000 \
    --set fxa.emailDomain=api-accounts.stage.mozaws.net \
    --set database.backend="${backend}" --set image.repository="${repository}" \
    --set image.syncstorageTag="${tag}" --set image.initTag="${init_tag}" --wait --timeout 10m \
    || fail "helm install did not get Ready"
  check "helm install (${backend}) Ready"

  kubectl create configmap ffs-tests --from-file="${SCRIPT_DIR}/test_client_flow.py"
  client_flow flow-1 || fail "client flow failed"
  check "client flow passed"
  database_users

  # fail closed: an invalid MAX_USERS never reaches the cluster
  if out=$(helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set maxUsers=bogus --no-hooks 2>&1); then
    fail "helm upgrade accepted maxUsers=bogus"
  fi
  echo "${out}" | grep -q maxUsers || fail "maxUsers=bogus refused, but not by the schema: ${out}"
  check "maxUsers=bogus refused by the schema"

  # fail closed: a wrong database password stops the pod at migrate (wait-db has no
  # credentials), never Ready, out of the Service
  good=$(kubectl get secret "${FULL}" -o jsonpath="{.data.${password_key}}")
  kubectl patch secret "${FULL}" --type merge -p "{\"data\":{\"${password_key}\":\"$(printf wrong | base64)\"}}"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true
  wait_pod_status 'Init:Error|Init:CrashLoopBackOff' 420 || fail "pod did not stop in its init containers"
  check "wrong ${password_key}: pod is in ${MATCHED_STATUS}"
  inits=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r '.items[0].status.initContainerStatuses[]
    | "\(.name)=\(.state.terminated.exitCode // .lastState.terminated.exitCode // "none")"' | paste -sd' ' -)
  # (PostgreSQL: the superuser's password, the first login is sync-role's; the Sync role's
  # own password is set again by sync-role at every start)
  [[ "${inits}" =~ ${failing_init} ]] || fail "expected wait-db to pass and the next init to fail: ${inits}"
  check "wait-db passed, the next init failed (${inits})"
  ready=$(kubectl get endpointslices -l "kubernetes.io/service-name=${FULL}-syncstorage" -o json \
    | jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length')
  [[ "${ready}" == 0 ]] || fail "the Service has ${ready} ready endpoints while the init fails"
  [[ "$(kubectl get pods -l "${POD_SELECTOR}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')" != True ]] \
    || fail "the syncstorage pod is Ready while the init fails"
  check "the syncstorage Service has no ready endpoints, the pod is not Ready"
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
    # as the Sync server's own role: no superuser session on the tables it owns
    postgres) kubectl exec "${FULL}-postgres-0" -- env PGPASSWORD="$(secret POSTGRES_SYNC_PASSWORD)" \
      psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U syncserver_app -d syncserver -c "$1" "${@:2}" ;;
  esac
}

secret() { kubectl get secret "${FULL}" -o jsonpath="{.data.$1}" | base64 -d; }

# who the Sync server is on its databases, and the admin UI's users that the databases and
# the init container create (db/mysql/admin-user.sh, db/postgres/init)
database_users() {
  local pod_ip env
  pod_ip=$(kubectl get pods -l "${POD_SELECTOR}" -o jsonpath='{.items[0].status.podIP}')
  env=$(kubectl get deploy "${FULL}-syncstorage" -o json)
  if [[ "${BACKEND}" == postgres ]]; then
    for c in migrate syncstorage; do
      names=$(echo "${env}" | jq -r --arg c "${c}" '[.spec.template.spec.initContainers[], .spec.template.spec.containers[]]
        | map(select(.name == $c))[0].env[] | .name, (.valueFrom.secretKeyRef.key // empty)')
      ! echo "${names}" | grep -qx POSTGRES_PASSWORD || fail "${c} gets POSTGRES_PASSWORD"
      urls=$(echo "${env}" | jq -r --arg c "${c}" '[.spec.template.spec.initContainers[], .spec.template.spec.containers[]]
        | map(select(.name == $c))[0].env[] | select(.name | endswith("__DATABASE_URL")) | .value')
      ! echo "${urls}" | grep -qv '^postgres://syncserver_app:' || fail "${c} does not connect as syncserver_app: ${urls}"
    done
    check "migrate and syncstorage: no POSTGRES_PASSWORD, URLs as syncserver_app"
    users=$(kubectl exec "${FULL}-postgres-0" -- sh -c 'psql -X -tA -U "${POSTGRES_USER}" -d postgres -c "$1"' sh \
      "SELECT string_agg(DISTINCT usename, ',') FROM pg_stat_activity WHERE client_addr = '${pod_ip}'")
    [[ "${users}" == syncserver_app ]] || fail "the Sync server connects as '${users}', not syncserver_app"
    super=$(kubectl exec "${FULL}-postgres-0" -- sh -c 'psql -X -tA -U "${POSTGRES_USER}" -d postgres -c "$1"' sh \
      "SELECT rolsuper FROM pg_roles WHERE rolname = 'syncserver_app'")
    [[ "${super}" == f ]] || fail "syncserver_app is a superuser (${super})"
    owners=$(sql "SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname = 'public'" -tA)
    [[ "${owners}" == syncserver_app ]] || fail "the Sync tables are owned by '${owners}'"
    check "the Sync server connects as syncserver_app (no superuser), which owns the Sync tables"
    kubectl exec "${FULL}-postgres-0" -- env PGPASSWORD="$(secret ADMIN_DB_PASSWORD)" \
      psql -X -tA -h 127.0.0.1 -U ffs_admin_ui -d ffs_admin -c 'SELECT 1' > /dev/null || fail "ffs_admin_ui cannot reach ffs_admin"
    check "the admin UI's user ffs_admin_ui reaches ffs_admin"
  else
    local client=mariadb
    [[ "${BACKEND}" == mysql ]] && client=mysql
    for db in tokenserver storage; do
      kubectl exec "${FULL}-${db}-db-0" -- "${client}" -h 127.0.0.1 -u ffs_admin_sync -p"$(secret ADMIN_DB_PASSWORD)" \
        -e 'SELECT 1' > /dev/null || fail "ffs_admin_sync cannot log in to ${db}-db"
    done
    kubectl exec "${FULL}-tokenserver-db-0" -- "${client}" -h 127.0.0.1 -u ffs_admin_ui -p"$(secret ADMIN_DB_PASSWORD)" \
      ffs_admin -e 'SELECT 1' > /dev/null || fail "ffs_admin_ui cannot reach ffs_admin"
    check "admin-user.sh created ffs_admin_ui (ffs_admin) and ffs_admin_sync (both databases)"
  fi
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
