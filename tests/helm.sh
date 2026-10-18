#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${REPO_ROOT}/charts/firefox-sync"

check() {
  echo "✓ $1"
}

# rendered manifests (stdin) as a JSON array, for jq
manifests() {
  python3 -c 'import json, sys, yaml; print(json.dumps([d for d in yaml.safe_load_all(sys.stdin) if d]))'
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

  # every long-running container has its readiness and liveness probes (not the init
  # containers, not the pods of Jobs and CronJobs), with every values set of ci/
  for values_file in "${CHART_DIR}"/ci/*.yaml; do
    missing=$(helm template test-release "${CHART_DIR}" -f "${values_file}" | manifests | jq -r '.[]
      | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "ReplicaSet")
      | .metadata.name as $w | .spec.template.spec.containers[]
      | select(.readinessProbe == null or .livenessProbe == null) | "\($w)/\(.name)"')
    [[ -z "${missing}" ]] || fail "$(basename "${values_file}"): containers without a readinessProbe or livenessProbe: ${missing}"
  done
  check "every container of the Deployments and StatefulSets has a readinessProbe and a livenessProbe (ci/*.yaml)"

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
  # a changed admin-user.sh rolls the databases out again (their ConfigMap is read at the start)
  for backend in mariadb mysql; do
    sums=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" | manifests \
      | jq -r '.[] | select(.kind == "StatefulSet") | .spec.template.metadata.annotations["checksum/db-scripts"] // "none"' | sort -u)
    [[ "${sums}" == "$(sha256sum < "${CHART_DIR}/files/admin-user.sh" | cut -d' ' -f1)" ]] \
      || fail "${backend}: checksum/db-scripts of the databases is not the sha256 of files/admin-user.sh: ${sums}"
  done
  check "checksum/db-scripts on both MariaDB/MySQL databases: a changed admin-user.sh restarts them"

  # the backups, compose's backup service (COMPOSE_PROFILES=backup): config/backup/backup.sh
  # identical, off by default, then a CronJob with compose's image and variables
  echo "Testing the backups..."
  cmp -s "${CHART_DIR}/files/backup.sh" "${REPO_ROOT}/config/backup/backup.sh" \
    || fail "charts/firefox-sync/files/backup.sh differs from config/backup/backup.sh"
  if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" | manifests \
    | jq -e '.[] | select(.kind == "CronJob" or (.metadata.name | test("backup")))' > /dev/null; then
    fail "backup.enabled=false: a CronJob or a backup object rendered"
  fi
  check "backup.sh identical to config/backup/backup.sh; no backups by default"
  names=""
  for backend in mariadb mysql postgres; do
    compose=docker-compose.yml image=mariadb:lts
    [[ ${backend} == mysql ]] && image=mysql:8.4
    [[ ${backend} == postgres ]] && compose=docker-compose.sync-postgres.yml image=postgres:18
    docs=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" \
      --set backup.enabled=true | manifests)
    cron=$(echo "${docs}" | jq '.[] | select(.kind == "CronJob" and .metadata.name == "test-release-firefox-sync-backup")')
    [[ -n "${cron}" ]] || fail "${backend}: no CronJob test-release-firefox-sync-backup"
    # BACKUP_TIME is UTC: the schedule too, whatever the cluster's time zone
    [[ "$(echo "${cron}" | jq -c '[.spec.schedule, .spec.timeZone, .spec.concurrencyPolicy, .spec.jobTemplate.spec.template.spec.restartPolicy]')" \
      == '["0 3 * * *","Etc/UTC","Forbid","Never"]' ]] || fail "${backend}: the CronJob's schedule, timeZone, concurrencyPolicy, restartPolicy: ${cron}"
    pod=$(echo "${cron}" | jq '.spec.jobTemplate.spec.template.spec')
    [[ "$(echo "${pod}" | jq -c '.containers | map([.image, .command, .args])')" == "[[\"${image}\",[\"sh\",\"/ffs-backup/backup.sh\"],[\"now\"]]]" ]] \
      || fail "${backend}: the backup container is not ${image} running backup.sh now: $(echo "${pod}" | jq -c .containers)"
    # backup.sh from its ConfigMap at /ffs-backup (read-only), the PVC at /backups
    [[ "$(echo "${pod}" | jq -c '.volumes as $v | [.containers[0].volumeMounts[] | .name as $n
      | [.mountPath, (.readOnly // false), ($v[] | select(.name == $n) | (.configMap.name // .persistentVolumeClaim.claimName))]] | sort')" \
      == '[["/backups",false,"test-release-firefox-sync-backups"],["/ffs-backup",true,"test-release-firefox-sync-backup"]]' ]] \
      || fail "${backend}: the backup's mounts: $(echo "${pod}" | jq -c '[.containers[0].volumeMounts, .volumes]')"
    cm=$(echo "${docs}" | jq -r '.[] | select(.kind == "ConfigMap" and .metadata.name == "test-release-firefox-sync-backup") | .data["backup.sh"]')
    [[ "${cm}" == "$(cat "${CHART_DIR}/files/backup.sh")" ]] || fail "${backend}: the backup ConfigMap's backup.sh is not files/backup.sh"
    # the backups PVC, kept on helm uninstall like the databases' volumes
    [[ "$(echo "${docs}" | jq -c '.[] | select(.kind == "PersistentVolumeClaim" and .metadata.name == "test-release-firefox-sync-backups")
      | [.spec.accessModes, .spec.resources.requests.storage, .metadata.annotations["helm.sh/resource-policy"]]')" == '[["ReadWriteOnce"],"10Gi","keep"]' ]] \
      || fail "${backend}: no PVC test-release-firefox-sync-backups of 10Gi, kept on uninstall"
    # a Job of the release binds it at once: with a WaitForFirstConsumer storage class (kind,
    # most clouds) it stays Pending until a pod uses it, which helm install --wait waits for.
    # Named after its pod template (a Job's is immutable: a new one when it changes)
    bind=$(echo "${docs}" | jq '[.[] | select(.kind == "Job" and (.metadata.name | startswith("test-release-firefox-sync-backup-volume-")))]')
    [[ "$(echo "${bind}" | jq -c 'map(.spec.template.spec | [(.volumes[] | .persistentVolumeClaim.claimName // empty), .containers[0].image, .restartPolicy])')" \
      == "[[\"test-release-firefox-sync-backups\",\"${image}\",\"Never\"]]" ]] || fail "${backend}: no Job binding the backups PVC: ${bind}"
    names+=" $(echo "${bind}" | jq -r '.[0].metadata.name | ltrimstr("test-release-firefox-sync-backup-volume-")')"
    # compose's variables of the backup service, the secrets from the Secret
    env=$(echo "${pod}" | jq '.containers[0].env')
    want=$(sed -n '/^  backup:$/,/^  [a-z_-]*:$/p' "${REPO_ROOT}/${compose}" | sed -n '/^    environment:$/,/^    [a-z_]*:$/p' \
      | grep -oE '^      [A-Z][A-Z0-9_]*' | tr -d ' ' | sort)
    got=$(echo "${env}" | jq -r '.[].name' | sort)
    [[ -n "${want}" && "${want}" == "${got}" ]] || fail "${backend}: the backup's variables differ from ${compose}'s backup: $(diff <(echo "${want}") <(echo "${got}") | grep '^[<>]' | paste -sd' ' -)"
    vals=$(echo "${env}" | jq -cS 'map({(.name): (.value // ("secret:" + .valueFrom.secretKeyRef.key))}) | add')
    case ${backend} in
      # as the Sync server's own role (the owner of its tables, ADMIN.md#restoring loads it as
      # that role too), never the superuser: no POSTGRES_PASSWORD
      postgres) expected='{"ADMIN_DB_NAME":"ffs_admin","ADMIN_DB_PASSWORD":"secret:ADMIN_DB_PASSWORD","ADMIN_DB_USER":"ffs_admin_ui","BACKUP_KEEP":"7","BACKUP_SCOPE":"sync","BACKUP_TIME":"03:00","TOKENSERVER_DB_HOST":"test-release-firefox-sync-postgres","TOKENSERVER_DB_NAME":"syncserver","TOKENSERVER_DB_PASSWORD":"secret:POSTGRES_SYNC_PASSWORD","TOKENSERVER_DB_PORT":"5432","TOKENSERVER_DB_TYPE":"postgres","TOKENSERVER_DB_USER":"syncserver_app"}' ;;
      *) expected='{"ADMIN_DB_NAME":"ffs_admin","ADMIN_DB_PASSWORD":"secret:ADMIN_DB_PASSWORD","ADMIN_DB_USER":"ffs_admin_ui","BACKUP_KEEP":"7","BACKUP_SCOPE":"sync","BACKUP_TIME":"03:00","MARIADB_TLS_VERIFY":"'"$([[ ${backend} == mysql ]] && echo false || echo true)"'","STORAGE_DB_HOST":"test-release-firefox-sync-storage-db","STORAGE_DB_NAME":"syncstorage","STORAGE_DB_PASSWORD":"secret:STORAGE_DB_PASSWORD","STORAGE_DB_PORT":"3306","STORAGE_DB_USER":"syncstorage","TOKENSERVER_DB_HOST":"test-release-firefox-sync-tokenserver-db","TOKENSERVER_DB_NAME":"tokenserver","TOKENSERVER_DB_PASSWORD":"secret:TOKENSERVER_DB_PASSWORD","TOKENSERVER_DB_PORT":"3306","TOKENSERVER_DB_TYPE":"mysql","TOKENSERVER_DB_USER":"tokenserver"}' ;;
    esac
    [[ "${vals}" == "${expected}" ]] || fail "${backend}: the backup's variables: ${vals}"
    check "${backend}: CronJob ${image} backup.sh now at 0 3 * * * UTC (Forbid), the PVC at /backups (bound by a Job), compose's variables, secrets from the Secret"
  done
  # (one per image: a hash of the pod template)
  [[ "${names}" =~ ^\ [0-9a-f]{8}\ [0-9a-f]{8}\ [0-9a-f]{8}$ && $(tr ' ' '\n' <<< "${names}" | sort -u | wc -l) -eq 4 ]] \
    || fail "the binding Jobs not named after their pod templates: ${names}"
  # a hung dump ends within a day: under Forbid it would block every later run
  deadline() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set backup.enabled=true "$@" | manifests \
      | jq -r '.[] | select(.kind == "CronJob") | .spec.jobTemplate.spec.activeDeadlineSeconds'
  }
  [[ "$(deadline)" == 82800 && "$(deadline --set backup.activeDeadlineSeconds=3600)" == 3600 ]] \
    || fail "the backup Job's activeDeadlineSeconds: $(deadline), with 3600: $(deadline --set backup.activeDeadlineSeconds=3600)"
  check "the backup Job ends after backup.activeDeadlineSeconds (82800 by default)"
  # the backup and binding pods: root (the dumps are root's, 0600) without capabilities
  for backend in mariadb mysql postgres; do
    sec=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" --set backup.enabled=true \
      | manifests | jq -c '[.[] | select(.kind == "CronJob" or (.kind == "Job" and (.metadata.name | contains("backup")))) | (.spec.jobTemplate.spec // .spec).template.spec
      | [.securityContext.seccompProfile.type, (.containers[] | .securityContext | [.allowPrivilegeEscalation, .capabilities.drop])]] | unique')
    [[ "${sec}" == '[["RuntimeDefault",[false,["ALL"]]]]' ]] || fail "${backend}: the backup pods' securityContext: ${sec}"
  done
  check "backup and binding pods: seccomp RuntimeDefault, no privilege escalation, every capability dropped"
  # the binding Job's name (and its job-name label) within 63 characters, with a long fullname
  # too (the CronJob keeps <fullname>-backup, the name the admin UI shows)
  # (45: the longest a CronJob allows)
  long=$(printf 'f%.0s' $(seq 1 45))
  names=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set backup.enabled=true --set fullnameOverride="${long}" \
    --set database.bundled=false --set database.external.host=db.example.test \
    | manifests | jq -r '.[] | select(.kind == "Job") | .metadata.name')
  [[ -n "${names}" ]] && ! awk 'length($0) > 63 {bad = 1} END {exit !bad}' <<< "${names}" || fail "Job names over 63 characters: ${names}"
  grep -q -- "-backup-volume-[0-9a-f]\{8\}$" <<< "${names}" || fail "the binding Job lost its hash: ${names}"
  check "the binding Job's name within 63 characters (fullnameOverride of 45), with its hash"
  # names within Kubernetes' limits, refused at render time otherwise (none truncated: the
  # admin UI builds them from ADMIN_K8S_FULLNAME): the CronJob 52 (its Jobs get 11 more), the
  # StatefulSets 52 (their pods' controller-revision-hash label, <name>-<hash of 10>), the
  # Services 63
  of() { printf "f%.0s" $(seq 1 "$1"); }
  renders() { helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "$@" 2>&1; }
  external=(--set database.bundled=false --set database.external.host=db.example.test)
  out=$(renders "${external[@]}" --set backup.enabled=true --set fullnameOverride="$(of 46)") \
    && fail "a fullname of 46 with the backups renders"
  grep -q "fullnameOverride or a shorter release name: the backup CronJob name $(of 46)-backup is 53 characters, at most 52" <<< "${out}" \
    || fail "a fullname of 46 with the backups: not the message on the CronJob's name: ${out}"
  renders "${external[@]}" --set backup.enabled=true --set fullnameOverride="$(of 45)" > /dev/null || fail "a fullname of 45 with the backups does not render"
  # (component: the longest fullname that renders, its name)
  for limit in "mariadb 37 tokenserver-db StatefulSet" "mysql 37 tokenserver-db StatefulSet" "postgres 43 postgres StatefulSet" \
    "external 51 syncstorage Service" "admin 51 syncstorage Service"; do
    read -r what max name kind <<< "${limit}"
    case ${what} in
      external) args=("${external[@]}") ;;
      admin) args=("${external[@]}" --set admin.enabled=true) ;;
      *) args=(--set database.backend="${what}") ;;
    esac
    renders "${args[@]}" --set fullnameOverride="$(of "${max}")" > /dev/null || fail "${what}: a fullname of ${max} does not render: $(renders "${args[@]}" --set fullnameOverride="$(of "${max}")" | tail -1)"
    out=$(renders "${args[@]}" --set fullnameOverride="$(of $((max + 1)))") && fail "${what}: a fullname of $((max + 1)) renders"
    grep -q "the ${name} ${kind} name $(of $((max + 1)))-${name} is" <<< "${out}" || fail "${what}: a fullname of $((max + 1)): not the message on the ${name} ${kind}: ${out}"
  done
  check "names over Kubernetes' limits refused at render time (CronJob 52, StatefulSets 52, Services 63): backups 45, mariadb/mysql 37, postgres 43, Sync 51"
  # helm install --dry-run renders NOTES: a backup now, under a new name each time
  grep -qF 'create job --from=cronjob/{{ include "firefox-sync.fullname" . }}-backup backup-now-$(date +%s)' "${CHART_DIR}/templates/NOTES.txt" \
    || fail "NOTES.txt: the backup-now command is not one for every run"
  [[ "$(sed -n 's/^kubeVersion: //p' "${CHART_DIR}/Chart.yaml")" == '">=1.27.0-0"' ]] || fail "Chart.yaml: kubeVersion not >=1.27.0-0 (CronJob timeZone)"
  check "NOTES: backup-now-\$(date +%s); kubeVersion >=1.27.0-0 (CronJob timeZone)"
  # BACKUP_TIME (the admin UI's help, backup.sh) from a daily schedule only, BACKUP_KEEP from
  # backup.keep: the same in the CronJob and the admin UI
  # (the admin UI's first: admin.yaml renders before backup.yaml)
  backup_env() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" --set backup.enabled=true "$@" | manifests | jq -r '[.[]
      | (select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec), (select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin") | .spec.template.spec)
      | .containers[0].env | map(select(.name == "BACKUP_TIME" or .name == "BACKUP_KEEP")) | map(.name + "=" + .value) | join(",")] | join(" ")'
  }
  [[ "$(backup_env)" == "BACKUP_TIME=03:00,BACKUP_KEEP=7 BACKUP_KEEP=7,BACKUP_TIME=03:00" ]] || fail "default BACKUP_TIME, BACKUP_KEEP: $(backup_env)"
  [[ "$(backup_env --set backup.schedule='5 23 * * *' --set backup.keep=3)" == "BACKUP_TIME=23:05,BACKUP_KEEP=3 BACKUP_KEEP=3,BACKUP_TIME=23:05" ]] \
    || fail "backup.schedule='5 23 * * *', keep 3: $(backup_env --set backup.schedule='5 23 * * *' --set backup.keep=3)"
  for schedule in '0 */6 * * *' '0 3 * * 1' '@daily' '0 3\,15 * * *'; do
    [[ "$(backup_env --set backup.schedule="${schedule}")" == "BACKUP_KEEP=7 BACKUP_KEEP=7" ]] \
      || fail "backup.schedule='${schedule}' is not daily at one time, yet: $(backup_env --set backup.schedule="${schedule}")"
  done
  [[ "$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" | manifests | jq -r '.[]
    | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin") | .spec.template.spec.containers[0].env[]
    | select(.name | startswith("BACKUP_")) | .name + "=" + .value' | paste -sd, -)" == "BACKUP_TIME=03:00,BACKUP_KEEP=7" ]] \
    || fail "the admin UI without the backups: no BACKUP_TIME, BACKUP_KEEP (compose passes them always)"
  check "BACKUP_TIME from a daily backup.schedule (else unset), BACKUP_KEEP from backup.keep, in the CronJob and the admin UI"
  for bad in 'backup.keep=0' 'backup.schedule='; do
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set backup.enabled=true --set "${bad}" > /dev/null 2>&1; then
      fail "${bad} not refused by the schema"
    fi
  done
  check "backup.keep=0 and an empty backup.schedule refused by the schema"

  # existingSecret: no Secret rendered, every secretKeyRef reads that one
  echo "Testing existingSecret..."
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set existingSecret=my-secret)
  if echo "${output}" | grep -q '^kind: Secret'; then
    fail "existingSecret set, but the chart still renders a Secret"
  fi
  refs=$(echo "${output}" | grep -A1 'secretKeyRef:' | grep 'name:' | sort -u)
  [[ "${refs}" =~ ^[[:space:]]*name:\ my-secret$ ]] || fail "secretKeyRefs not all to my-secret: ${refs}"
  check "existingSecret: no Secret rendered, all secretKeyRefs read it"

  # the admin UI: off by default, then a Service (http, statsd) and the Sync server's statsd
  # host only while it is on; compose's variables, its secrets from the Secret
  echo "Testing the admin UI..."
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml")
  if echo "${output}" | grep -qE 'name: test-release-firefox-sync-admin$|SYNC_STATSD_(HOST|PORT)'; then
    fail "admin.enabled=false: an admin UI or SYNC_STATSD_* rendered"
  fi
  check "admin UI off by default, no SYNC_STATSD_* on the Sync server"
  for backend in mariadb mysql postgres; do
    compose=docker-compose.yml
    [[ ${backend} == postgres ]] && compose=docker-compose.sync-postgres.yml
    output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" \
      --set database.backend="${backend}" --set admin.enabled=true)
    docs=$(echo "${output}" | manifests)
    svc=$(echo "${docs}" | jq '.[] | select(.kind == "Service" and .metadata.name == "test-release-firefox-sync-admin")')
    [[ "$(echo "${svc}" | jq -c '[.spec.ports[] | [.name, .port, .protocol]] | sort')" == '[["http",8080,"TCP"],["statsd",8125,"UDP"]]' ]] \
      || fail "${backend}: the admin Service's ports: ${svc}"
    sync=$(echo "${docs}" | jq '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-syncstorage")
      | .spec.template.spec.containers[] | select(.name == "syncstorage") | .env')
    [[ "$(echo "${sync}" | jq -c 'map(select(.name | startswith("SYNC_STATSD_"))) | map({(.name): .value}) | add')" \
      == '{"SYNC_STATSD_HOST":"test-release-firefox-sync-admin","SYNC_STATSD_PORT":"8125"}' ]] || fail "${backend}: SYNC_STATSD_* of the Sync server"
    admin=$(echo "${docs}" | jq '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin")
      | .spec.template.spec.containers[] | select(.name == "admin") | .env')
    [[ "$(echo "${admin}" | jq -r 'map(select(.name == "ADMIN_DEPLOYMENT" or .name == "ADMIN_K8S_RELEASE"))[].value' | paste -sd' ' -)" == "kubernetes test-release" ]] \
      || fail "${backend}: ADMIN_DEPLOYMENT, ADMIN_K8S_RELEASE"
    # no secret as a plain value
    # (ADMIN_K8S_SECRET: the name of the Secret)
    plain=$(echo "${admin}" | jq -r '.[] | select(.value != null) | .name' | grep -E '(^|_)(PASS|PASSWORD|SECRET|TOKEN)$' | grep -vx ADMIN_K8S_SECRET || true)
    [[ -z "${plain}" ]] || fail "${backend}: secrets of the admin UI as plain values: ${plain}"
    # compose's ffs-admin variables, but ADMIN_EXPORT_PORT (a port of the host: the Service
    # here); and the chart's own
    want=$(sed -n '/^  ffs-admin:$/,/^  [a-z_-]*:$/p' "${REPO_ROOT}/${compose}" | sed -n '/^    environment:$/,/^    [a-z_]*:$/p' \
      | grep -oE '^      [A-Z][A-Z0-9_]*' | tr -d ' ' | grep -vx ADMIN_EXPORT_PORT | sort)
    got=$(echo "${admin}" | jq -r '.[].name' | grep -vxE 'ADMIN_K8S_(RELEASE|NAMESPACE|FULLNAME|SECRET)' | sort)
    [[ "${want}" == "${got}" ]] || fail "${backend}: the admin UI's variables differ from ${compose}'s ffs-admin: $(diff <(echo "${want}") <(echo "${got}") | grep '^[<>]' | paste -sd' ' -)"
    check "${backend}: admin Service http 8080/TCP + statsd 8125/UDP, SYNC_STATSD_HOST, compose's variables, secrets from the Secret"
  done
  # its optional secrets: from the values into the Secret, optional in an existingSecret
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set admin.enabled=true \
    --set admin.metricsToken=tok --set admin.smtp.password=pw --set admin.password=adm)
  data=$(echo "${output}" | manifests | jq '.[] | select(.kind == "Secret") | .data')
  [[ "$(echo "${data}" | jq -r '[.ADMIN_METRICS_TOKEN, .FXA_SMTP_PASS, .ADMIN_PASSWORD, .ADMIN_OIDC_CLIENT_SECRET] | map(@base64d) | join(" ")')" == "tok pw adm " ]] \
    || fail "admin secrets in the Secret: ${data}"
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set admin.enabled=true --set existingSecret=my-secret)
  optional=$(echo "${output}" | manifests | jq -r '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin")
    | .spec.template.spec.containers[0].env[] | select(.valueFrom.secretKeyRef.optional == true) | .valueFrom.secretKeyRef.key' | sort | paste -sd' ' -)
  [[ "${optional}" == "ADMIN_METRICS_TOKEN ADMIN_NOTIFY ADMIN_OIDC_CLIENT_SECRET ADMIN_PASSWORD FXA_SMTP_PASS" ]] || fail "optional keys of an existingSecret: ${optional}"
  refs=$(echo "${output}" | grep -A1 'secretKeyRef:' | grep 'name:' | sort -u)
  [[ "${refs}" =~ ^[[:space:]]*name:\ my-secret$ ]] || fail "admin UI on, secretKeyRefs not all to my-secret: ${refs}"
  check "admin secrets: values into the Secret; FXA_SMTP_PASS, ADMIN_OIDC_CLIENT_SECRET, ADMIN_METRICS_TOKEN, ADMIN_PASSWORD optional in an existingSecret"
  # the three optional ones are the values' alone: an empty value an empty key, never what a
  # lookup of the Secret found (helm template has no cluster: the template must not read them)
  data=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" --set admin.metricsToken= \
    --set admin.smtp.password= --set admin.oidc.clientSecret= --set admin.notify= | manifests | jq -c '.[] | select(.kind == "Secret") | .data
    | [.ADMIN_METRICS_TOKEN, .FXA_SMTP_PASS, .ADMIN_OIDC_CLIENT_SECRET, .ADMIN_NOTIFY]')
  [[ "${data}" == '["","","",""]' ]] || fail "empty admin secrets of the values not empty in the Secret: ${data}"
  for key in FXA_SMTP_PASS ADMIN_OIDC_CLIENT_SECRET ADMIN_METRICS_TOKEN ADMIN_NOTIFY; do
    grep -qE '^\{\{- \$_ := set \$data "'"${key}"'" \((\.Values\.admin\.|include "firefox-sync\.adminNotify")' "${CHART_DIR}/templates/_helpers.tpl" \
      || fail "${key} not set from the values alone in firefox-sync.secretData"
  done
  check "FXA_SMTP_PASS, ADMIN_OIDC_CLIENT_SECRET, ADMIN_METRICS_TOKEN, ADMIN_NOTIFY from the values alone (empty: empty)"
  # admin.notify: a list joined by commas, or a string as it is
  notify() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" "$@" | manifests \
      | jq -r '.[] | select(.kind == "Secret") | .data.ADMIN_NOTIFY | @base64d'
  }
  [[ "$(notify)" == "ntfy://ntfy.sh/ci-topic,webhook://hooks.example.test/ci" ]] || fail "admin.notify as a list: $(notify)"
  [[ "$(notify --set-string admin.notify='ntfy://a.test/x\,slack://b.test/y')" == "ntfy://a.test/x,slack://b.test/y" ]] || fail "admin.notify as a string"
  check "admin.notify: a list joined by commas, or a string, into ADMIN_NOTIFY"
  # a new admin pod when the chart's Secret changes: the checksum is over all of its data,
  # the generated secrets with it (helm template generates new ones on every render), not
  # over the secrets of the values alone, which the pod spec would give away
  render() { helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" "$@" | manifests; }
  checksum() {
    jq -r '.[] | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin")
      | .spec.template.metadata.annotations["checksum/admin-secrets"] // empty'
  }
  docs=$(render --set admin.password=one)
  sum=$(echo "${docs}" | checksum)
  data_sum=$(echo "${docs}" | jq -cS '.[] | select(.kind == "Secret") | .data' | tr -d '\n' | sha256sum | cut -d' ' -f1)
  [[ -n "${sum}" && "${sum}" == "${data_sum}" ]] || fail "checksum/admin-secrets is not the sha256 of the Secret's data: ${sum} ${data_sum}"
  for plain in '[null,"one","ci-smtp","ci-oidc","ci-token"]' '["","one","ci-smtp","ci-oidc","ci-token"]' '["one","ci-smtp","ci-oidc","ci-token"]'; do
    [[ "${sum}" != "$(printf '%s' "${plain}" | sha256sum | cut -d' ' -f1)" ]] || fail "checksum/admin-secrets is the sha256 of the values' secrets alone"
  done
  [[ "$(render --set admin.password=two | checksum)" != "${sum}" ]] || fail "checksum/admin-secrets does not change with admin.password"
  [[ -z "$(render --set admin.password=one --set existingSecret=mine | checksum)" ]] || fail "existingSecret: a checksum of secrets in the pod spec"
  check "checksum/admin-secrets: sha256 of the Secret's whole data (not of the values' secrets alone), none with existingSecret"
  # the names the admin UI shows, as the chart has them
  env_of() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" "$@" | manifests | jq -cS '[.[]
      | select(.kind == "Deployment") | .spec.template.spec.containers[] | .env[]?
      | select(.name | test("^(ADMIN_K8S_|SYNC_STATSD_HOST)")) | {(.name): .value}] | add'
  }
  [[ "$(env_of --set fullnameOverride=x --set existingSecret=mine)" == \
    '{"ADMIN_K8S_FULLNAME":"x","ADMIN_K8S_NAMESPACE":"default","ADMIN_K8S_RELEASE":"test-release","ADMIN_K8S_SECRET":"mine","SYNC_STATSD_HOST":"x-admin"}' ]] \
    || fail "names with fullnameOverride and existingSecret: $(env_of --set fullnameOverride=x --set existingSecret=mine)"
  [[ "$(env_of | jq -r '.ADMIN_K8S_FULLNAME + " " + .ADMIN_K8S_SECRET')" == "test-release-firefox-sync test-release-firefox-sync" ]] \
    || fail "default names: $(env_of)"
  check "ADMIN_K8S_FULLNAME, ADMIN_K8S_SECRET as the chart names them (fullnameOverride, existingSecret)"
  # numbers of a values file (float64 there) as integers, never 2e+06
  values=$(mktemp)
  printf 'admin:\n  dbGrowthMb: 2000000\n  retentionDays: 1000000\n  smtp:\n    port: 465\n' > "${values}"
  numbers=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" -f "${values}" | manifests | jq -r '.[]
    | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin") | .spec.template.spec.containers[0].env[]
    | select(.name == "ADMIN_DB_GROWTH_MB" or .name == "ADMIN_RETENTION_DAYS" or .name == "SMTP_PORT") | .value' | paste -sd' ' -)
  rm -f "${values}"
  [[ "${numbers}" == "465 1000000 2000000" ]] || fail "numbers of a values file: ${numbers}"
  check "numbers of a values file as integers (dbGrowthMb 2000000, retentionDays 1000000, smtp.port 465)"

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
  # the admin UI too (ADMIN_DEPLOYMENT=kubernetes is in this tree)
  ADMIN_TAG=${TAG:-latest}
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
    ADMIN_TAG=helm-e2e
    # with BuildKit (the Dockerfile's BUILDPLATFORM), as tests/e2e.sh builds it
    ADMIN_IMAGE="${repository}:admin-${ADMIN_TAG}" COMPOSE_BAKE=false docker compose -p ffs-helm-admin-build \
      -f "${SCRIPT_DIR}/docker-compose.admin-build.yml" build -q || fail "admin image not built"
    kind load docker-image --name "${CLUSTER}" "${repository}:admin-${ADMIN_TAG}"
    check "admin image built from admin/"
  fi

  # a syncstorage image of the host's docker (of a private repository, or built there): into
  # the cluster, which would pull it otherwise
  # (not kind load: it imports --all-platforms, which a pulled image's export lacks)
  if docker image inspect "${SYNC_IMAGE}" > /dev/null 2>&1; then
    docker save "${SYNC_IMAGE}" | docker exec -i "${CLUSTER}-control-plane" \
      ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs - > /dev/null || fail "${SYNC_IMAGE} not loaded"
    check "${SYNC_IMAGE} loaded from the host's docker"
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
    --set image.syncstorageTag="${tag}" --set image.initTag="${init_tag}" --set backup.enabled=true --wait --timeout 10m \
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

  admin_toggle

  echo ""
  echo "=== e2e (${backend}) passed ==="
}

# the admin UI on (signed in with the Secret's ADMIN_PASSWORD, the overview shows the Sync
# server and alice of the client flow), then off: the Sync server Ready both ways, with
# SYNC_STATSD_HOST only while the admin UI's Service exists
admin_toggle() {
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set admin.enabled=true --set admin.metricsToken=e2e-token \
    --set image.adminTag="${ADMIN_TAG}" --wait --timeout 10m || fail "helm upgrade with the admin UI did not get Ready"
  check "admin UI on: Ready"
  sync_ready "${FULL}-admin"
  check "syncstorage Ready with SYNC_STATSD_HOST=${FULL}-admin"

  kubectl port-forward "svc/${FULL}-admin" 18090:8080 > /dev/null 2>&1 &
  local pf=$! jar page deadline
  jar=$(mktemp)
  deadline=$(( $(date +%s) + 60 ))
  until curl -sf -o /dev/null http://localhost:18090/healthz; do
    [[ $(date +%s) -lt ${deadline} ]] || { kill "${pf}"; fail "port-forward to the admin UI does not answer"; }
    sleep 2
  done
  # a session cookie (Secure: curl keeps it for http://localhost), as test_admin_sync.py signs in
  page=$(curl -s -L -c "${jar}" -b "${jar}" --data-urlencode "password=$(secret ADMIN_PASSWORD)" http://localhost:18090/login)
  if ! grep -q 'Sign out' <<< "${page}"; then
    kill "${pf}"; fail "sign-in with the Secret's ADMIN_PASSWORD refused: $(head -c 500 <<< "${page}")"
  fi
  check "signed in to the admin UI with the Secret's ADMIN_PASSWORD"
  # a backup now, the command of the overview's help; restored as ADMIN.md#restoring says
  backup_restore
  # the first health check runs at the start, the version once the Sync server answered
  deadline=$(( $(date +%s) + 180 ))
  while :; do
    page=$(curl -s -b "${jar}" http://localhost:18090/)
    if grep -qE '<td>Sync server</td><td><span class="ok">up</span>.*?</td><td>[0-9]+\.[0-9]+\.[0-9]+' <<< "${page}" \
      && grep -q 'href="/users/alice"' <<< "${page}" && grep -q 'id="sync-users">1<' <<< "${page}"; then
      break
    fi
    if [[ $(date +%s) -ge ${deadline} ]]; then
      kill "${pf}"
      # (the published images before APP_BUILD_REVISION 2 say TBD: REPOSITORY=ghcr.io/porelli/firefox-sync-dev)
      fail "overview without the Sync server's version or alice: $(grep -oE '<td>Sync server</td>.{0,200}' <<< "${page}")"
    fi
    sleep 5
  done
  check "overview: the Sync server up with its version, alice's account"
  # the commands of the Helm chart there
  # (a new Job name for each run; + is &#43; in the page)
  grep -qF "create job --from=cronjob/${FULL}-backup backup-now-\$(date &#43;%s)" <<< "${page}" || { kill "${pf}"; fail "overview: no kubectl backup command"; }
  ! grep -q 'docker compose' <<< "${page}" || { kill "${pf}"; fail "overview: docker compose commands"; }
  check "overview: kubectl commands, no docker compose"
  # the run of backup-now on the Backups card (the admin UI reads ffs_backups, backup.sh
  # writes it), within a minute
  deadline=$(( $(date +%s) + 120 ))
  until grep -qE '<p class="hint" data-scope="sync">Last backup of the Sync databases: [^<]+, [0-9.]+ [KMG]?B, <span class="ok">ok</span>' <<< "${page}"; do
    if [[ $(date +%s) -ge ${deadline} ]]; then
      kill "${pf}"; fail "the Backups card does not show the run: $(grep -oE 'id="backups">.{0,300}' <<< "${page}")"
    fi
    sleep 5
    page=$(curl -s -b "${jar}" http://localhost:18090/)
  done
  grep -q 'id="backup-what">Every night at 03:00 UTC' <<< "${page}" || { kill "${pf}"; fail "the Backups card without BACKUP_TIME 03:00"; }
  check "overview: the Backups card shows the run of backup-now, every night at 03:00 UTC"
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer e2e-token' http://localhost:18090/metrics)" == 200 ]] \
    || { kill "${pf}"; fail "/metrics refuses admin.metricsToken"; }
  check "/metrics with admin.metricsToken"
  kill "${pf}" 2> /dev/null || true
  rm -f "${jar}"

  # an upgrade that changes nothing keeps the admin pod (the Secret read back, the same checksum)
  local before
  before=$(kubectl get pods -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=admin" -o jsonpath='{.items[0].metadata.name}')
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --wait --timeout 10m || fail "helm upgrade without changes failed"
  [[ "$(kubectl get pods -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=admin" -o jsonpath='{.items[*].metadata.name}')" == "${before}" ]] \
    || fail "an upgrade without changes replaced the admin pod"
  check "an upgrade without changes keeps the admin pod"
  # the token taken out of the values: out of the Secret (no lookup keeps it), a new admin pod
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set admin.metricsToken= --wait --timeout 10m \
    || fail "helm upgrade without admin.metricsToken did not get Ready"
  [[ -z "$(secret ADMIN_METRICS_TOKEN)" ]] || fail "admin.metricsToken emptied, still in the Secret"
  kubectl wait --for=delete "pod/${before}" --timeout=2m > /dev/null 2>&1 || fail "the admin pod ${before} kept running with the old secret"
  check "admin.metricsToken emptied: empty in the Secret, a new admin pod"

  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set admin.enabled=false --wait --timeout 10m \
    || fail "helm upgrade without the admin UI did not get Ready"
  ! kubectl get svc "${FULL}-admin" > /dev/null 2>&1 || fail "the admin Service is still there"
  sync_ready ""
  check "admin UI off: syncstorage Ready again, no SYNC_STATSD_HOST"
}

# backup_restore: a run of the backup CronJob now (kubectl create job --from=cronjob/...,
# as the admin UI says), then its dumps restored the way ADMIN.md#restoring says on a new
# host: into empty database servers like the chart's (pods of the StatefulSets' spec, with
# empty volumes), by pods of the backup's own spec (its variables, its volume: compose's
# `docker compose run --rm --no-deps --entrypoint sh backup -c '...'`), as the stack's users,
# with ADMIN.md's commands. The same users and Sync items there as in the chart's databases
backup_restore() {
  kubectl create job --from="cronjob/${FULL}-backup" backup-now > /dev/null || fail "kubectl create job --from=cronjob/${FULL}-backup failed"
  wait_job backup-now 300 || fail "the backup-now Job did not complete"
  kubectl logs job/backup-now | grep -q "^backup sync: ok: /backups/sync/" || fail "backup-now: no 'ok' in its log"
  check "kubectl create job --from=cronjob/${FULL}-backup backup-now: complete"

  # 2. the run
  local run
  run=$(backup_pod restore-ls '["ls", "/backups/sync"]' | tail -1)
  [[ "${run}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || fail "no run in the backups volume: ${run}"
  check "a run in the backups volume: ${run}"

  # 1. empty database servers, as on a new host (the chart's spec, empty volumes)
  local servers ts st ts_ip st_ip
  if [[ "${BACKEND}" == postgres ]]; then
    servers="${FULL}-postgres"
  else
    servers="${FULL}-tokenserver-db ${FULL}-storage-db"
  fi
  for s in ${servers}; do
    kubectl get sts "${s}" -o json | jq --arg n "scratch-${s#"${FULL}-"}" '.spec.template.spec as $s | {apiVersion: "v1", kind: "Pod",
      metadata: {name: $n, labels: {"ffs-e2e": "scratch"}}, spec: ($s + {volumes: (($s.volumes // []) + [{name: "data", emptyDir: {}}])})}' \
      | kubectl apply -f - > /dev/null || fail "scratch server of ${s} not created"
  done
  kubectl wait --for=condition=Ready pod -l ffs-e2e=scratch --timeout=5m > /dev/null || fail "the scratch database servers not Ready"
  if [[ "${BACKEND}" == postgres ]]; then
    ts=scratch-postgres st=scratch-postgres
  else
    ts=scratch-tokenserver-db st=scratch-storage-db
  fi
  ts_ip=$(kubectl get pod "${ts}" -o jsonpath='{.status.podIP}')
  st_ip=$(kubectl get pod "${st}" -o jsonpath='{.status.podIP}')
  check "empty database servers like the chart's: ${ts} ${st}"

  # 4. the tokenserver (PostgreSQL: the one database), with ADMIN.md's commands
  local restore
  restore=$(admin_md_restore "$([[ "${BACKEND}" == postgres ]] && echo 2 || echo 1)")
  [[ -n "${restore}" ]] || fail "no restore command of step 4 in ADMIN.md#restoring"
  [[ "${BACKEND}" == mysql ]] && restore=$(sed 's/^\( *\)mariadb /\1mysql /' <<< "${restore}")
  if [[ "${BACKEND}" == postgres ]]; then
    # into the empty database as the Sync server's role, which sync_role_init creates first:
    # here the sync-role init container of the Sync server's pod, on the new server
    one_shot restore-sync-role "$(kubectl get deploy "${FULL}-syncstorage" -o json | jq --arg ip "${ts_ip}" '{containers: [.spec.template.spec.initContainers[]
      | select(.name == "sync-role") | .env |= map(if .name == "POSTGRES_SERVER" then .value = $ip else . end)]}')" > /dev/null \
      || fail "sync-role on the new server failed"
    check "the Sync server's role on the new server (sync-role)"
  fi
  # a run that is not there (pruned, mistyped) fails, and loads nothing
  if backup_pod restore-missing "$(jq -nc --arg c "${restore//20261013T030000Z/20000101T000000Z}" '["sh", "-c", $c]')" \
    "TOKENSERVER_DB_HOST=${ts_ip}" > /dev/null; then
    fail "the restore of a run that is not there succeeded"
  fi
  ! count "${ts}" users > /dev/null 2>&1 || fail "the restore of a run that is not there loaded a users table"
  check "the restore of a run that is not there fails, loads nothing"
  backup_pod restore-tokenserver "$(jq -nc --arg c "${restore//20261013T030000Z/${run}}" '["sh", "-c", $c]')" "TOKENSERVER_DB_HOST=${ts_ip}" \
    || fail "the restore of the tokenserver (step 4) failed"
  check "the tokenserver restored as its user (ADMIN.md#restoring step 4)"
  # 6. the storage, "as in step 4 with $STORAGE_DB_NAME..." (PostgreSQL: in the one dump)
  if [[ "${BACKEND}" != postgres ]]; then
    backup_pod restore-storage "$(jq -nc --arg c "$(sed 's/TOKENSERVER_DB_/STORAGE_DB_/g' <<< "${restore//20261013T030000Z/${run}}")" '["sh", "-c", $c]')" \
      "STORAGE_DB_HOST=${st_ip}" || fail "the restore of the storage (step 6) failed"
    check "the storage restored as its user (ADMIN.md#restoring step 6)"
  fi

  local bso=bso users_now items_now
  [[ "${BACKEND}" == postgres ]] && bso=bsos
  if [[ "${BACKEND}" == postgres ]]; then
    users_now=$(count "${FULL}-postgres-0" users) items_now=$(count "${FULL}-postgres-0" "${bso}")
  else
    users_now=$(count "${FULL}-tokenserver-db-0" users) items_now=$(count "${FULL}-storage-db-0" "${bso}")
  fi
  [[ "${users_now}" =~ ^[1-9][0-9]*$ && "${items_now}" =~ ^[1-9][0-9]*$ ]] || fail "no users or Sync items to back up: ${users_now} ${items_now}"
  [[ "$(count "${ts}" users)" == "${users_now}" ]] || fail "users: $(count "${ts}" users) restored, ${users_now} in the chart's database"
  [[ "$(count "${st}" "${bso}")" == "${items_now}" ]] || fail "${bso}: $(count "${st}" "${bso}") restored, ${items_now} in the chart's database"
  check "the same rows of users (${users_now}) and ${bso} (${items_now}) restored"
  kubectl delete pod -l ffs-e2e --wait=false > /dev/null
}

# admin_md_restore <n>: the n-th command of ADMIN.md#restoring run in the backup container that
# restores $TOKENSERVER_DB_NAME (1: MariaDB, 2: PostgreSQL), as it is there
admin_md_restore() {
  awk -v n="$1" '
    /--entrypoint sh backup -c '"'"'$/ { on = 1; b = ""; next }
    on {
      line = $0; last = (line ~ /'"'"'$/)
      if (last) sub(/'"'"'$/, "", line)
      b = b line "\n"
      if (last) { on = 0; if (b ~ /\$TOKENSERVER_DB_NAME\.sql\.gz/ && ++i == n) printf "%s", b }
    }' "${REPO_ROOT}/ADMIN.md"
}

# backup_pod <name> <command, JSON> [VAR=value...]: a pod of the backup CronJob's spec (its
# variables from the Secret, its volume) running the command, with these variables changed;
# its output, and whether it succeeded
backup_pod() {
  local name=$1 command=$2 spec
  shift 2
  spec=$(kubectl get cronjob "${FULL}-backup" -o json | jq --argjson c "${command}" --args '.spec.jobTemplate.spec.template.spec
    | .containers[0] |= (.command = $c | del(.args)
      | reduce ($ARGS.positional[] | capture("^(?<k>[^=]+)=(?<v>.*)$")) as $e (.; .env |= map(if .name == $e.k then .value = $e.v else . end)))' "$@") || return 1
  one_shot "${name}" "${spec}"
}

# one_shot <name> <pod spec, JSON>: a pod run once; its logs, and whether it succeeded
one_shot() {
  jq --arg n "$1" '{apiVersion: "v1", kind: "Pod", metadata: {name: $n, labels: {"ffs-e2e": "one-shot"}}, spec: (. + {restartPolicy: "Never"})}' <<< "$2" \
    | kubectl apply -f - > /dev/null || return 1
  local deadline=$(( $(date +%s) + 300 )) phase=
  while [[ $(date +%s) -lt ${deadline} ]]; do
    phase=$(kubectl get pod "$1" -o jsonpath='{.status.phase}')
    [[ "${phase}" == Succeeded || "${phase}" == Failed ]] && break
    sleep 2
  done
  kubectl logs "$1" 2> /dev/null
  [[ "${phase}" == Succeeded ]]
}

# count <pod> <table>: its rows, in the pod's database server, as the stack's user
count() {
  case "${BACKEND}" in
    mariadb) kubectl exec "$1" -c db -- sh -c 'mariadb -N -u"${MARIADB_USER}" -p"${MARIADB_PASSWORD}" "${MARIADB_DATABASE}" -e "SELECT COUNT(*) FROM $1"' sh "$2" ;;
    mysql) kubectl exec "$1" -c db -- sh -c 'mysql -N -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${MYSQL_DATABASE}" -e "SELECT COUNT(*) FROM $1" 2> /dev/null' sh "$2" ;;
    postgres) kubectl exec "$1" -c db -- env PGPASSWORD="$(secret POSTGRES_SYNC_PASSWORD)" \
      psql -X -tA -v ON_ERROR_STOP=1 -h 127.0.0.1 -U syncserver_app -d syncserver -c "SELECT COUNT(*) FROM $2" ;;
  esac
}

# wait_job <name> <seconds>: the Job succeeded (its logs on the way)
wait_job() {
  local deadline=$(( $(date +%s) + $2 )) succeeded failed
  while [[ $(date +%s) -lt ${deadline} ]]; do
    succeeded=$(kubectl get job "$1" -o jsonpath='{.status.succeeded}')
    failed=$(kubectl get job "$1" -o jsonpath='{.status.failed}')
    if [[ "${succeeded}" == 1 || -n "${failed}" ]]; then
      break
    fi
    sleep 5
  done
  kubectl logs "job/$1" --tail=40 || true
  [[ "${succeeded}" == 1 ]]
}

# sync_ready <statsd host, "" for none>: the one syncstorage pod Ready, SYNC_STATSD_HOST as given
sync_ready() {
  kubectl rollout status "deploy/${FULL}-syncstorage" --timeout=10m || fail "syncstorage not rolled out"
  wait_pod_status Running 300 || fail "syncstorage not a single Running pod"
  kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout=5m || fail "syncstorage not Ready"
  local host
  host=$(kubectl get pods -l "${POD_SELECTOR}" -o json | jq -r '.items[0].spec.containers[]
    | select(.name == "syncstorage") | .env[] | select(.name == "SYNC_STATSD_HOST") | .value')
  [[ "${host}" == "$1" ]] || fail "syncstorage's SYNC_STATSD_HOST is '${host}', expected '$1'"
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
  wait_job "${name}" 600
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
  # the backup and the restore check
  for pod in $(kubectl get pods -l "ffs-e2e" -o name 2>/dev/null) $(kubectl get pods -l "job-name=backup-now" -o name 2>/dev/null); do
    echo "--- ${pod}"
    kubectl logs "${pod}" --tail=15 2>/dev/null || true
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
