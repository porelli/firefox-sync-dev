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
  # database.image.<backend>: the database server, wait-db, the backups and the PVC's binding
  # Job (compose's POSTGRES_IMAGE: postgres_db and backup), postgres:18 by default
  for backend in mariadb mysql postgres; do
    images() {
      helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" --set backup.enabled=true "$@" \
        | manifests | jq -r '[.[] | select(.kind == "StatefulSet" or .kind == "Job" or .kind == "CronJob" or .kind == "Deployment")
          | (.spec.jobTemplate.spec // .spec).template.spec | (.initContainers // [])[], .containers[]
          | select(.name == "db" or .name == "wait-db" or .name == "backup" or .name == "bind") | .image] | unique | join(" ")'
    }
    default=$(sed -n "s/^    ${backend}: //p" "${CHART_DIR}/values.yaml")
    [[ "$(images)" == "${default}" ]] || fail "${backend}: the database images are not ${default}: $(images)"
    [[ "$(images --set database.image."${backend}"=registry.example.test/db:9)" == "registry.example.test/db:9" ]] \
      || fail "${backend}: database.image.${backend} not used everywhere: $(images --set database.image."${backend}"=registry.example.test/db:9)"
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.image."${backend}"= > /dev/null 2>&1; then
      fail "an empty database.image.${backend} not refused by the schema"
    fi
  done
  [[ "$(sed -n 's/^    postgres: //p' "${CHART_DIR}/values.yaml")" == postgres:18 ]] || fail "database.image.postgres is not postgres:18 by default"
  check "database.image.<backend> for the server, wait-db, the backups and the binding Job (mariadb:lts, mysql:8.4, postgres:18), empty refused"

  # db/mysql/admin-user.sh (the chart's copy identical: parity), run by the MariaDB and MySQL containers
  for backend in mariadb mysql; do
    output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" --show-only templates/databases.yaml)
    [[ $(echo "${output}" | grep -c 'args: \[sh, /ffs-db/admin-user.sh, ') -eq 2 ]] || fail "${backend}: admin-user.sh not the command of both databases"
    [[ $(echo "${output}" | grep -c 'name: ADMIN_DB_ROLE$') -eq 2 ]] || fail "${backend}: ADMIN_DB_ROLE missing"
  done
  check "admin-user.sh run by both MariaDB/MySQL databases"
  # a changed admin-user.sh rolls the databases out again (their ConfigMap is read at the start)
  for backend in mariadb mysql; do
    sums=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" | manifests \
      | jq -r '.[] | select(.kind == "StatefulSet") | .spec.template.metadata.annotations["checksum/db-scripts"] // "none"' | sort -u)
    [[ "${sums}" == "$(sha256sum < "${CHART_DIR}/files/admin-user.sh" | cut -d' ' -f1)" ]] \
      || fail "${backend}: checksum/db-scripts of the databases is not the sha256 of files/admin-user.sh: ${sums}"
  done
  check "checksum/db-scripts on both MariaDB/MySQL databases: a changed admin-user.sh restarts them"

  # the backups, compose's backup service (COMPOSE_PROFILES=backup): off by default, then a
  # CronJob with compose's image (its variables, backup.sh identical: parity)
  echo "Testing the backups..."
  if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" | manifests \
    | jq -e '.[] | select(.kind == "CronJob" or (.metadata.name | test("backup")))' > /dev/null; then
    fail "backup.enabled=false: a CronJob or a backup object rendered"
  fi
  check "no backups by default"
  names=""
  for backend in mariadb mysql postgres; do
    image=mariadb:lts
    [[ ${backend} == mysql ]] && image=mysql:8.4
    [[ ${backend} == postgres ]] && image=postgres:18
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
    check "${backend}: CronJob ${image} backup.sh now at 0 3 * * * UTC (Forbid), the PVC at /backups (bound by a Job)"
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
    --set database.bundled=false --set database.external.host=db.example.test --set existingSecret=mine \
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
  external=(--set database.bundled=false --set database.external.host=db.example.test --set existingSecret=mine)
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
    check "${backend}: admin Service http 8080/TCP + statsd 8125/UDP, SYNC_STATSD_HOST, secrets from the Secret"
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
    '{"ADMIN_K8S_CHART":"oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync","ADMIN_K8S_FULLNAME":"x","ADMIN_K8S_NAMESPACE":"default","ADMIN_K8S_RELEASE":"test-release","ADMIN_K8S_SECRET":"mine","SYNC_STATSD_HOST":"x-admin"}' ]] \
    || fail "names with fullnameOverride and existingSecret: $(env_of --set fullnameOverride=x --set existingSecret=mine)"
  [[ "$(env_of | jq -r '.ADMIN_K8S_FULLNAME + " " + .ADMIN_K8S_SECRET')" == "test-release-firefox-sync test-release-firefox-sync" ]] \
    || fail "default names: $(env_of)"
  check "ADMIN_K8S_FULLNAME, ADMIN_K8S_SECRET as the chart names them (fullnameOverride, existingSecret)"
  # where the chart was published (the annotation the publish job sets), for helm upgrade
  [[ "$(sed -n 's|^  org.firefox-sync/chart: ||p' "${CHART_DIR}/Chart.yaml")" == oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync ]] \
    || fail "Chart.yaml: the annotation org.firefox-sync/chart is not the public repository's chart"
  check "ADMIN_K8S_CHART: the annotation org.firefox-sync/chart of Chart.yaml (the public repository's chart)"
  # numbers of a values file (float64 there) as integers, never 2e+06
  values=$(mktemp)
  printf 'admin:\n  dbGrowthMb: 2000000\n  retentionDays: 1000000\n  smtp:\n    port: 465\n' > "${values}"
  numbers=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/admin-values.yaml" -f "${values}" | manifests | jq -r '.[]
    | select(.kind == "Deployment" and .metadata.name == "test-release-firefox-sync-admin") | .spec.template.spec.containers[0].env[]
    | select(.name == "ADMIN_DB_GROWTH_MB" or .name == "ADMIN_RETENTION_DAYS" or .name == "SMTP_PORT") | .value' | paste -sd' ' -)
  rm -f "${values}"
  [[ "${numbers}" == "465 1000000 2000000" ]] || fail "numbers of a values file: ${numbers}"
  check "numbers of a values file as integers (dbGrowthMb 2000000, retentionDays 1000000, smtp.port 465)"

  external_lint
  ingress_lint
  publish_lint
  # compose's variables, commands, probes and scripts
  parity

  echo ""
  echo "=== All lint checks passed ==="
}

# the publish job's tag check (.github/scripts/chart-version.sh): the tag is chart-v<the
# version of Chart.yaml>, a semver; a stable one (no -<pre-release>, +<build> is stable) only
# from a commit of the default branch
publish_lint() {
  echo "Testing the tag check of the publishing..."
  local script="${REPO_ROOT}/.github/scripts/chart-version.sh" d out
  d=$(mktemp -d)
  # a repository: main with a chart, a branch with one more commit
  git -C "${d}" init -q -b main && mkdir -p "${d}/chart"
  publish_at() { printf 'apiVersion: v2\nname: firefox-sync\nversion: %s\n' "$1" > "${d}/chart/Chart.yaml"; git -C "${d}" add -A
    git -C "${d}" -c user.name=t -c user.email=t@example.test commit -qm "$1"; }
  publish_at 1.0.0
  [[ "$(cd "${d}" && "${script}" chart)" == $'version=1.0.0\nprerelease=false' ]] || fail "chart-version.sh without a tag: $(cd "${d}" && "${script}" chart)"
  [[ "$(cd "${d}" && "${script}" chart chart-v1.0.0 main)" == $'version=1.0.0\nprerelease=false' ]] || fail "chart-v1.0.0 on main refused"
  out=$(cd "${d}" && "${script}" chart chart-v1.0.1 main 2>&1) && fail "chart-v1.0.1 for 1.0.0 accepted"
  grep -q 'is not chart-v1.0.0' <<< "${out}" || fail "a tag of another version: not the message: ${out}"
  git -C "${d}" switch -q -c topic
  for v in 1.0.1 1.0.1+build-1; do
    publish_at "${v}"
    out=$(cd "${d}" && "${script}" chart "chart-v${v}" main 2>&1) && fail "stable ${v} accepted off the default branch"
    grep -q 'a commit of main' <<< "${out}" || fail "stable ${v} off main: not the message: ${out}"
  done
  publish_at 1.0.1-dev.1+build-2
  [[ "$(cd "${d}" && "${script}" chart chart-v1.0.1-dev.1+build-2 main)" == $'version=1.0.1-dev.1+build-2\nprerelease=true' ]] \
    || fail "pre-release 1.0.1-dev.1+build-2 refused off the default branch"
  for v in 1.0 v1.0.0 01.0.0 1.0.0-; do
    publish_at "${v}"
    out=$(cd "${d}" && "${script}" chart 2>&1) && fail "version ${v} accepted"
    grep -q 'not a semantic version' <<< "${out}" || fail "version ${v}: not the message: ${out}"
  done
  printf 'apiVersion: v2\nname: firefox-sync\nversion: "2.0.0"\n' > "${d}/chart/Chart.yaml"
  [[ "$(cd "${d}" && "${script}" chart)" == $'version=2.0.0\nprerelease=false' ]] || fail "a quoted version: $(cd "${d}" && "${script}" chart)"
  rm -rf "${d}"
  [[ "$("${script}" "${CHART_DIR}" | head -1)" == "version=$(helm show chart "${CHART_DIR}" | sed -n 's/^version: //p')" ]] \
    || fail "chart-version.sh: not the version helm reads"
  check "the tag check: chart-v<version>, semver, stable (+build too) from the default branch only, pre-releases from anywhere"
}

# the chart against compose (docker compose config, no daemon): tests/helm_parity.py
parity() {
  echo "=== Comparing the chart with compose ==="
  python3 -I -c 'import yaml' 2> /dev/null || fail "parity needs PyYAML for python3 (apt install python3-yaml, pip install pyyaml)"
  docker compose version > /dev/null 2>&1 || fail "parity needs docker compose (config only, no daemon)"
  command -v helm > /dev/null || fail "parity needs helm"
  python3 -I "${SCRIPT_DIR}/helm_parity.py" "$@" || fail "the chart differs from compose"
}

# every env entry of every container (init containers too) of the rendered manifests (a JSON
# array on stdin): {c: container, n: name, v: value, or "secret:<key>"}
ENVS='[.[] | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "CronJob" or .kind == "Job")
  | (.spec.jobTemplate.spec // .spec).template.spec | ((.initContainers // []) + .containers)[] | .name as $c
  | (.env // [])[] | {c: $c, n: .name, v: (.value // ("secret:" + .valueFrom.secretKeyRef.key))}]'

# the values of an env variable over all containers, sorted, unique: env_values <name> <helm args>...
env_values() {
  local name=$1
  shift
  helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "$@" | manifests \
    | jq -r --arg n "${name}" "${ENVS} | map(select(.n == \$n) | .v) | unique | join(\" \")"
}

# notes <helm args>...: NOTES.txt as helm install shows it (helm template does not render it, and
# install --dry-run needs a cluster): rendered with tpl in a copy of the chart
notes() {
  local d out
  d=$(mktemp -d)
  cp -r "${CHART_DIR}" "${d}/chart" && cp "${CHART_DIR}/templates/NOTES.txt" "${d}/chart/files/notes.txt"
  printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata: {name: notes}' 'data:' '  notes: {{ tpl (.Files.Get "files/notes.txt") . | toJson }}' \
    > "${d}/chart/templates/zz-notes.yaml"
  out=$(helm template test-release "${d}/chart" -f "${CHART_DIR}/ci/default-values.yaml" "$@" --show-only templates/zz-notes.yaml 2>&1 | manifests | jq -r '.[0].data.notes') || true
  rm -rf "${d}"
  echo "${out}"
}

# the names of the roles and databases (compose's POSTGRES_SYNC_USER, ADMIN_DB_NAME,
# ADMIN_DB_USER, ADMIN_DB_SYNC_USER) and your own database server (database.bundled=false)
external_lint() {
  echo "Testing the names of the roles and databases..."
  local names=(--set database.postgresSyncUser=sync_owner --set database.admin.name=adm_db --set database.admin.user=adm_ui
    --set database.admin.syncUser=adm_sync --set admin.enabled=true --set backup.enabled=true)
  local backend out
  for backend in mariadb mysql postgres; do
    # (but in the scripts of the ConfigMaps, admin-user.sh and backup.sh, compose's defaults)
    out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" "${names[@]}" \
      | manifests | jq -c '.[] | select(.kind != "ConfigMap")')
    ! grep -qE 'ffs_admin|syncserver_app' <<< "${out}" || fail "${backend}: the default names rendered: $(grep -oE '.{60}(ffs_admin|syncserver_app).{20}' <<< "${out}" | sort -u | head -5)"
    for pair in ADMIN_DB_NAME=adm_db ADMIN_DB_USER=adm_ui ADMIN_DB_SYNC_USER=adm_sync; do
      [[ "$(env_values "${pair%%=*}" --set database.backend="${backend}" "${names[@]}")" == "${pair#*=}" ]] \
        || fail "${backend}: ${pair%%=*}: $(env_values "${pair%%=*}" --set database.backend="${backend}" "${names[@]}")"
    done
  done
  [[ "$(env_values POSTGRES_SYNC_USER --set database.backend=postgres "${names[@]}")" == sync_owner ]] || fail "POSTGRES_SYNC_USER not database.postgresSyncUser"
  # the Sync server, its migrations, the backups and the admin UI's reader as that role
  out=$(env_values SYNC_TOKENSERVER__DATABASE_URL --set database.backend=postgres "${names[@]}")
  [[ "${out}" == 'postgres://sync_owner:$(POSTGRES_SYNC_PASSWORD)@test-release-firefox-sync-postgres:5432/syncserver' ]] || fail "the Sync server's URL: ${out}"
  [[ "$(env_values TOKENSERVER_DB_USER --set database.backend=postgres "${names[@]}")" == sync_owner ]] || fail "the backups and the admin UI not as database.postgresSyncUser"
  for bad in database.postgresSyncUser=Bad-Name database.admin.name= database.admin.user='x;drop' database.admin.syncUser=1abc \
    database.admin.name="$(printf 'a%.0s' $(seq 1 33))" database.external.postgresUser="$(printf 'a%.0s' $(seq 1 33))"; do
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set "${bad}" > /dev/null 2>&1; then
      fail "${bad} not refused by the schema"
    fi
  done
  helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.admin.user="$(printf 'a%.0s' $(seq 1 32))" > /dev/null \
    || fail "a name of 32 characters refused"
  check "database.postgresSyncUser, database.admin.name/user/syncUser everywhere (no default name left), names a-z 0-9 _ only, at most 32"

  echo "Testing your own database server..."
  local ext=(--set database.bundled=false --set database.external.host=db.example.test --set existingSecret=mine)
  for backend in mariadb mysql postgres; do
    out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" "${ext[@]}" | manifests)
    [[ "$(jq -r '[.[] | select(.kind == "StatefulSet" or .kind == "PersistentVolumeClaim" or .kind == "Secret" or .kind == "ConfigMap") | .kind + "/" + .metadata.name] | join(" ")' <<< "${out}")" == "" ]] \
      || fail "${backend}, bundled=false: a database server, volume, Secret or db-scripts rendered: $(jq -c '[.[] | .kind + "/" + .metadata.name]' <<< "${out}")"
    [[ "$(jq -r '[.[] | select(.kind == "Service") | .metadata.name] | join(" ")' <<< "${out}")" == "test-release-firefox-sync-syncstorage" ]] \
      || fail "${backend}, bundled=false: Services other than the Sync server's"
  done
  check "bundled=false: no database server, volume, db-scripts ConfigMap or Secret (mariadb, mysql, postgres)"
  # MariaDB/MySQL: compose's MARIADB_TOKENSERVER_* and MARIADB_SYNCSTORAGE_*, the storage
  # on another server too; the init container's TLS check from tlsVerify
  out=$(env_values SYNC_SYNCSTORAGE__DATABASE_URL --set database.backend=mysql "${ext[@]}")
  [[ "${out}" == 'mysql://syncstorage:$(STORAGE_DB_PASSWORD)@db.example.test:3306/syncstorage' ]] || fail "mysql, bundled=false: the storage URL: ${out}"
  local other=(--set database.backend=mysql "${ext[@]}" --set database.external.storageHost=st.example.test --set database.external.storagePort=3307
    --set database.external.port=3308 --set database.external.tokenserverDatabase=ts_db --set database.external.tokenserverUser=ts_user
    --set database.external.storageDatabase=st_db --set database.external.storageUser=st_user --set database.external.tlsVerify=false
    --set admin.enabled=true --set backup.enabled=true)
  [[ "$(env_values SYNC_TOKENSERVER__DATABASE_URL "${other[@]}")" == 'mysql://ts_user:$(TOKENSERVER_DB_PASSWORD)@db.example.test:3308/ts_db' ]] \
    || fail "mysql: the tokenserver URL: $(env_values SYNC_TOKENSERVER__DATABASE_URL "${other[@]}")"
  [[ "$(env_values SYNC_SYNCSTORAGE__DATABASE_URL "${other[@]}")" == 'mysql://st_user:$(STORAGE_DB_PASSWORD)@st.example.test:3307/st_db' ]] \
    || fail "mysql: the storage URL: $(env_values SYNC_SYNCSTORAGE__DATABASE_URL "${other[@]}")"
  for pair in "STORAGE_DB_HOST=st.example.test" "STORAGE_DB_PORT=3307" "STORAGE_DB_USER=st_user" "STORAGE_DB_NAME=st_db" \
    "TOKENSERVER_DB_HOST=db.example.test" "TOKENSERVER_DB_PORT=3308" "TOKENSERVER_DB_USER=ts_user" "TOKENSERVER_DB_NAME=ts_db" \
    "MARIADB_SERVER=db.example.test" "MARIADB_SERVER_PORT=3308" "MARIADB_DATABASE=ts_db" "MARIADB_USER=ts_user" "MARIADB_TLS_VERIFY=false"; do
    [[ "$(env_values "${pair%%=*}" "${other[@]}")" == "${pair#*=}" ]] || fail "mysql, your own servers: ${pair%%=*} is '$(env_values "${pair%%=*}" "${other[@]}")', not ${pair#*=}"
  done
  waits=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "${other[@]}" --show-only templates/syncstorage.yaml \
    | grep -E '^ *wait_db "' | sed 's/^ *//' | paste -sd' ' -)
  [[ "${waits}" == 'wait_db "db.example.test" "3308" wait_db "st.example.test" "3307"' ]] || fail "wait-db does not wait for both servers: ${waits}"
  check "mysql, your own servers: host/port/database/user of each, the storage on another server, tlsVerify, wait-db for both"
  # MARIADB_TLS_VERIFY: false for your own server unless tlsVerify (prepare_environment.sh's),
  # the bundled ones unchanged (MariaDB checked, MySQL's self-signed not)
  for backend in mariadb mysql; do
    [[ "$(env_values MARIADB_TLS_VERIFY --set database.backend="${backend}" "${ext[@]}" --set backup.enabled=true)" == false ]] \
      || fail "${backend}, your own server: MARIADB_TLS_VERIFY not false by default"
    [[ "$(env_values MARIADB_TLS_VERIFY --set database.backend="${backend}" "${ext[@]}" --set backup.enabled=true --set database.external.tlsVerify=true)" == true ]] \
      || fail "${backend}, your own server: tlsVerify=true not MARIADB_TLS_VERIFY=true"
  done
  [[ "$(env_values MARIADB_TLS_VERIFY --set backup.enabled=true) $(env_values MARIADB_TLS_VERIFY --set database.backend=mysql --set backup.enabled=true)" == "true false" ]] \
    || fail "the bundled servers' MARIADB_TLS_VERIFY changed"
  notes --set database.backend=mysql "${ext[@]}" | grep -q 'do not check the server.s certificate (tlsVerify false' || fail "NOTES: nothing on tlsVerify false"
  notes --set database.backend=mysql "${ext[@]}" --set database.external.tlsVerify=true | grep -q 'from a CA the images trust' || fail "NOTES: nothing on tlsVerify true"
  check "your own MariaDB/MySQL: MARIADB_TLS_VERIFY false unless tlsVerify (NOTES says which), the bundled ones unchanged"
  # PostgreSQL: compose's POSTGRES_* of your own server, POSTGRES_USER the owner (no Sync role)
  out=$(env_values SYNC_TOKENSERVER__DATABASE_URL --set database.backend=postgres "${ext[@]}")
  [[ "${out}" == 'postgres://syncserver:$(POSTGRES_PASSWORD)@db.example.test:5432/syncserver' ]] || fail "postgres, bundled=false: the URL: ${out}"
  local pg=(--set database.backend=postgres "${ext[@]}" --set database.external.port=6432 --set database.external.postgresDatabase=pg_db
    --set database.external.postgresUser=pg_owner --set admin.enabled=true --set backup.enabled=true)
  [[ "$(env_values SYNC_SYNCSTORAGE__DATABASE_URL "${pg[@]}")" == 'postgres://pg_owner:$(POSTGRES_PASSWORD)@db.example.test:6432/pg_db' ]] \
    || fail "postgres: the URL: $(env_values SYNC_SYNCSTORAGE__DATABASE_URL "${pg[@]}")"
  for pair in "POSTGRES_SERVER=db.example.test" "POSTGRES_SERVER_PORT=6432" "POSTGRES_DATABASE=pg_db" "POSTGRES_USER=pg_owner" \
    "POSTGRES_SYNC_USER=" "POSTGRES_SYNC_PASSWORD=" "TOKENSERVER_DB_USER=pg_owner" "TOKENSERVER_DB_PORT=6432" "TOKENSERVER_DB_PASSWORD=secret:ADMIN_DB_PASSWORD secret:POSTGRES_PASSWORD"; do
    [[ "$(env_values "${pair%%=*}" "${pg[@]}")" == "${pair#*=}" ]] || fail "postgres, your own server: ${pair%%=*} is '$(env_values "${pair%%=*}" "${pg[@]}")', not '${pair#*=}'"
  done
  ! helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "${pg[@]}" | grep -q "key: POSTGRES_SYNC_PASSWORD$" \
    || fail "postgres, your own server: POSTGRES_SYNC_PASSWORD read from the Secret"
  check "postgres, your own server: host/port/database/owner, no Sync role (POSTGRES_SYNC_USER empty), the backups and the admin UI's reader as the owner"
  # fail closed: no server to reach, or generated passwords your server cannot know
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.bundled=false --set existingSecret=mine 2>&1) \
    && fail "bundled=false without database.external.host renders"
  grep -q 'database.external.host' <<< "${out}" || fail "bundled=false without a host: not the message: ${out}"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.bundled=false --set database.external.host=db.example.test 2>&1) \
    && fail "bundled=false without existingSecret renders"
  grep -q 'existingSecret' <<< "${out}" || fail "bundled=false without existingSecret: not the message: ${out}"
  [[ "$(env_values SYNC_TOKENSERVER__DATABASE_URL --set database.backend=postgres "${ext[@]}" --set-string database.external.port=6432)" == *@db.example.test:6432/* ]] \
    || fail "a quoted database.external.port not taken"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "${ext[@]}" --set-string database.external.port=70000 2>&1) \
    && fail "a quoted database.external.port 70000 renders"
  grep -q 'database.external.port 70000 is no port' <<< "${out}" || fail "a quoted port 70000: not the message: ${out}"
  for bad in database.external.port=-1 database.external.port=70000 database.external.port=abc database.external.storagePort=0; do
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "${ext[@]}" --set "${bad}" > /dev/null 2>&1; then
      fail "${bad} not refused by the schema"
    fi
  done
  check "bundled=false refused without database.external.host or existingSecret; ports 1-65535 only (quoted too, with a message)"
}

# the Ingress of the Sync server (ingress.*) and, apart, of the admin UI (admin.ingress.*):
# never the admin UI by accident
ingress_lint() {
  echo "Testing the Ingresses..."
  ingresses() {
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" "$@" | manifests | jq -c '[.[] | select(.kind == "Ingress")
      | {name: .metadata.name, class: .spec.ingressClassName, annotations: .metadata.annotations, tls: .spec.tls,
         rules: [.spec.rules[] | {host, paths: [.http.paths[] | [.path, .pathType, .backend.service.name, .backend.service.port.number]]}]}]'
  }
  [[ "$(ingresses --set admin.enabled=true --set admin.ingress.host=admin.example.test)" == '[]' ]] || fail "an Ingress by default"
  [[ "$(ingresses --set ingress.enabled=true --set ingress.host=sync.example.test)" == \
    '[{"name":"test-release-firefox-sync-syncstorage","class":null,"annotations":null,"tls":null,"rules":[{"host":"sync.example.test","paths":[["/","Prefix","test-release-firefox-sync-syncstorage",8000]]}]}]' ]] \
    || fail "ingress.enabled: $(ingresses --set ingress.enabled=true --set ingress.host=sync.example.test)"
  # the host of syncDomain when ingress.host is empty; class, TLS, annotations
  [[ "$(ingresses --set ingress.enabled=true --set syncDomain=https://ffs.example.test/ --set ingress.className=nginx --set ingress.tls.enabled=true \
    --set ingress.tls.secretName=ffs-tls --set ingress.annotations.a=b --set syncstorage.service.port=8001)" == \
    '[{"name":"test-release-firefox-sync-syncstorage","class":"nginx","annotations":{"a":"b"},"tls":[{"hosts":["ffs.example.test"],"secretName":"ffs-tls"}],"rules":[{"host":"ffs.example.test","paths":[["/","Prefix","test-release-firefox-sync-syncstorage",8001]]}]}]' ]] \
    || fail "ingress with the host of syncDomain, class, TLS, annotations: $(ingresses --set ingress.enabled=true --set syncDomain=https://ffs.example.test/ \
      --set ingress.className=nginx --set ingress.tls.enabled=true --set ingress.tls.secretName=ffs-tls --set ingress.annotations.a=b --set syncstorage.service.port=8001)"
  check "ingress: off by default; <fullname>-syncstorage at / of ingress.host (else syncDomain's), class, TLS, annotations"
  # the admin UI's: only with admin.enabled and admin.ingress.enabled, on a host of its own
  [[ "$(ingresses --set ingress.enabled=true --set admin.enabled=true | jq -r 'map(.name) | join(" ")')" == test-release-firefox-sync-syncstorage ]] \
    || fail "ingress.enabled with the admin UI: an admin Ingress"
  [[ "$(ingresses --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test)" == '[]' ]] || fail "admin.ingress.enabled without admin.enabled: an Ingress"
  [[ "$(ingresses --set admin.enabled=true --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test --set admin.ingress.className=internal \
    --set admin.ingress.tls.enabled=true --set admin.ingress.annotations.c=d)" == \
    '[{"name":"test-release-firefox-sync-admin","class":"internal","annotations":{"c":"d"},"tls":[{"hosts":["admin.example.test"]}],"rules":[{"host":"admin.example.test","paths":[["/","Prefix","test-release-firefox-sync-admin",8080]]}]}]' ]] \
    || fail "admin.ingress: $(ingresses --set admin.enabled=true --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test \
      --set admin.ingress.className=internal --set admin.ingress.tls.enabled=true --set admin.ingress.annotations.c=d)"
  local out
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set admin.enabled=true --set admin.ingress.enabled=true 2>&1) \
    && fail "admin.ingress without a host renders"
  grep -q 'admin.ingress.host' <<< "${out}" || fail "admin.ingress without a host: not the message: ${out}"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set ingress.enabled=true --set admin.enabled=true \
    --set admin.ingress.enabled=true --set admin.ingress.host=sync.example.test 2>&1) && fail "the admin UI's Ingress on the Sync server's host renders"
  grep -q 'admin.ingress.host' <<< "${out}" || fail "the admin UI's Ingress on the Sync host: not the message: ${out}"
  # (syncDomain's host also without the Sync server's Ingress: your own in front of it)
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set admin.enabled=true \
    --set admin.ingress.enabled=true --set admin.ingress.host=sync.example.test 2>&1) && fail "the admin UI's Ingress on syncDomain's host renders"
  grep -q 'is the Sync server.s host' <<< "${out}" || fail "the admin UI's Ingress on syncDomain's host: not the message: ${out}"
  local admin_on=(--set admin.enabled=true --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test)
  notes "${admin_on[@]}" | grep -q '^WARNING: admin.ingress.tls.enabled is false' || fail "NOTES: no warning on the admin Ingress without TLS"
  ! notes "${admin_on[@]}" --set admin.ingress.tls.enabled=true | grep -q WARNING || fail "NOTES: a warning on the admin Ingress with TLS"
  out=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set ingress.enabled=true --set syncDomain=https:// 2>&1) \
    && fail "ingress without a host (none in syncDomain either) renders"
  check "admin.ingress: <fullname>-admin:8080 only with admin.enabled and admin.ingress.enabled, a host of its own (required, not the Sync server's nor syncDomain's), NOTES warns without TLS"
  # valid Kubernetes objects, everything on (kubeconform -strict)
  if command -v kubeconform > /dev/null; then
    helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/backup-values.yaml" --set ingress.enabled=true --set ingress.host=sync.example.test \
      --set ingress.tls.enabled=true --set ingress.tls.secretName=ffs-tls --set admin.ingress.enabled=true --set admin.ingress.host=admin.example.test \
      | kubeconform -strict -summary -kubernetes-version 1.27.0 || fail "kubeconform -strict: invalid objects"
    for backend in mysql postgres; do
      helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend="${backend}" \
        --set database.bundled=false --set database.external.host=db.example.test --set existingSecret=mine --set ingress.enabled=true \
        | kubeconform -strict -summary -kubernetes-version 1.27.0 || fail "kubeconform -strict (${backend}, your own server): invalid objects"
    done
    check "kubeconform -strict: the chart with the Ingresses, admin UI and backups; with your own server (mysql, postgres)"
  else
    echo "(kubeconform not installed: the objects not validated)"
  fi
}

# e2e <mariadb|mysql|postgres>: the chart on a throwaway kind cluster, with upstream's mock
# FxA, what a Firefox client does (tests/test_client_flow.py), fail closed, and upgrades.
# EXTERNAL_DB=1 (mysql, postgres): on a database server of its own in the cluster, which the
# chart does not manage (database.bundled=false), as tests/e2e.sh's EXTERNAL_DB=1
e2e() {
  local backend=${1:-}
  local flavor password_key init_dir
  EXTERNAL=${EXTERNAL_DB:-}
  case "${backend}" in
    mariadb|mysql) failing_init='wait-db=0 migrate=[1-9]'; flavor=mysql; password_key=TOKENSERVER_DB_PASSWORD; init_dir=db/mysql/init ;;
    postgres) failing_init='wait-db=0 sync-role=[1-9]'; flavor=postgres; password_key=POSTGRES_PASSWORD; init_dir=db/postgres/init ;;
    *) echo "Usage: $0 e2e <mariadb|mysql|postgres>"; exit 1 ;;
  esac
  if [[ -n "${EXTERNAL}" ]]; then
    [[ ${backend} != mariadb ]] || { echo "EXTERNAL_DB=1: mysql (MySQL 8.4 with binary logging) or postgres (PostgreSQL 18), as tests/e2e.sh"; exit 1; }
    # (PostgreSQL: POSTGRES_USER is the owner, no Sync role: sync-role does nothing, the
    # migrations are the first to log in)
    [[ ${backend} == postgres ]] && failing_init='wait-db=0 sync-role=0 migrate=[1-9]'
  fi
  # A host with Ubuntu's mysql-server (the GitHub runners) has an AppArmor profile for
  # /usr/sbin/mysqld, and kind's pods run unconfined: the profile then takes the mysqld of the
  # mysql:8.4 image too (docker's containers, in docker-default, are not). It denies /etc/my.cnf,
  # /usr/share/mysql-8.4 and the init file of admin-user.sh (/run/ffs-admin, errno 13): the
  # first start aborts half-way and every next one finds no mysql.user (CrashLoopBackOff)
  if [[ ${backend} == mysql && -e /etc/apparmor.d/usr.sbin.mysqld && ! -e /etc/apparmor.d/disable/usr.sbin.mysqld \
    && "$(cat /sys/module/apparmor/parameters/enabled 2> /dev/null)" == Y ]]; then
    fail "the host's AppArmor profile /usr/sbin/mysqld would confine MySQL in kind; disable it first:
  sudo ln -s /etc/apparmor.d/usr.sbin.mysqld /etc/apparmor.d/disable/ && sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.mysqld"
  fi
  # as tests/e2e.sh: REPOSITORY and TAG of the images; the init image is built from this
  # tree (the published one may be older than the chart), unless SKIP_BUILD=1
  local repository=${REPOSITORY:-ghcr.io/porelli/firefox-sync} tag=${TAG:-latest} init_tag=${TAG:-latest}
  # the admin UI too (ADMIN_DEPLOYMENT=kubernetes is in this tree)
  ADMIN_TAG=${TAG:-latest}
  BACKEND=${backend}
  CLUSTER="ffs-helm-${backend}${EXTERNAL:+-ext}"
  REL=t
  FULL="${REL}-firefox-sync"
  # the Secret the chart reads: its own, or that of existingSecret
  SECRET=${FULL}
  SYNC_IMAGE="${repository}:syncstorage-rs-${flavor}-${tag}"
  SYNCSTORAGE_DOMAIN=https://sync.example.test
  POD_SELECTOR="app.kubernetes.io/instance=${REL},app.kubernetes.io/component=syncstorage"

  echo "=== e2e on kind (${backend}${EXTERNAL:+, your own database server}) ==="
  kind delete cluster --name "${CLUSTER}" > /dev/null 2>&1 || true
  trap 'rc=$?; if ((rc)); then diagnostics; fi; kind delete cluster --name "${CLUSTER}"' EXIT
  kind create cluster --name "${CLUSTER}" --wait 120s
  kubectl config use-context "kind-${CLUSTER}" > /dev/null
  if [[ -z "${SKIP_BUILD:-}" ]]; then
    init_tag=helm-e2e
    ADMIN_TAG=helm-e2e
    # in the test VM its helper (vm.sh: ~/.ffs/lib.sh), which builds a folder once per content
    # and serializes the builds of the slots; elsewhere docker
    if ! declare -F ffs_image > /dev/null && [[ -f "${HOME}/.ffs/lib.sh" ]]; then
      # shellcheck source=/dev/null
      source "${HOME}/.ffs/lib.sh"
    fi
    if declare -F ffs_image > /dev/null; then
      (cd "${REPO_ROOT}" && ffs_image "${init_dir}" "${repository}:syncstorage-rs-${flavor}-init-${init_tag}" > /dev/null) \
        || fail "init image not built"
      (cd "${REPO_ROOT}" && ffs_image admin "${repository}:admin-${ADMIN_TAG}" > /dev/null) || fail "admin image not built"
    else
      docker build -q -t "${repository}:syncstorage-rs-${flavor}-init-${init_tag}" "${REPO_ROOT}/${init_dir}" > /dev/null \
        || fail "init image not built"
      # with BuildKit (the Dockerfile's BUILDPLATFORM), as tests/e2e.sh builds it
      ADMIN_IMAGE="${repository}:admin-${ADMIN_TAG}" COMPOSE_BAKE=false docker compose -p ffs-helm-admin-build \
        -f "${SCRIPT_DIR}/docker-compose.admin-build.yml" build -q || fail "admin image not built"
    fi
    kind load docker-image --name "${CLUSTER}" "${repository}:syncstorage-rs-${flavor}-init-${init_tag}"
    check "init image built from ${init_dir}"
    kind load docker-image --name "${CLUSTER}" "${repository}:admin-${ADMIN_TAG}"
    check "admin image built from admin/"
  fi

  # a syncstorage image of the host's docker (of a private repository, or built there): into
  # the cluster, which would pull it otherwise
  # (not kind load: it imports --all-platforms, which a pulled image's export lacks); pulled
  # with the host's credentials first when it is not there (a private repository)
  docker image inspect "${SYNC_IMAGE}" > /dev/null 2>&1 || docker pull -q "${SYNC_IMAGE}" > /dev/null 2>&1 || true
  if docker image inspect "${SYNC_IMAGE}" > /dev/null 2>&1; then
    docker save "${SYNC_IMAGE}" | docker exec -i "${CLUSTER}-control-plane" \
      ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs - > /dev/null || fail "${SYNC_IMAGE} not loaded"
    check "${SYNC_IMAGE} loaded from the host's docker"
  fi
  sed "s|ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-latest|${SYNC_IMAGE}|" \
    "${SCRIPT_DIR}/helm/mock-fxa.yaml" | kubectl apply -f -
  kubectl rollout status deploy/mock-fxa --timeout=5m
  check "mock FxA is up"

  local db_args=(--set backup.enabled=true)
  if [[ -n "${EXTERNAL}" ]]; then
    start_extdb
    # your own server: its names (not the defaults), the passwords in your Secret, the
    # backups; the Ingress on, of a class no controller serves
    SECRET=ffs-own
    db_args=(--set database.bundled=false --set database.external.host=extdb --set existingSecret="${SECRET}"
      --set database.admin.name="${EXT_ADMIN_DB}" --set database.admin.user="${EXT_ADMIN_USER}" --set database.admin.syncUser="${EXT_ADMIN_SYNC}"
      --set ingress.enabled=true --set ingress.className=none --set backup.enabled=true)
    if [[ ${backend} == mysql ]]; then
      # (MySQL's own certificate is self-signed: database.external.tlsVerify false, its default)
      db_args+=(--set database.external.tokenserverDatabase="${EXT_TS_DB}"
        --set database.external.tokenserverUser="${EXT_TS_USER}" --set database.external.storageDatabase="${EXT_ST_DB}"
        --set database.external.storageUser="${EXT_ST_USER}")
    else
      db_args+=(--set database.external.postgresDatabase="${EXT_PG_DB}" --set database.external.postgresUser="${EXT_PG_USER}")
    fi
  fi
  helm install "${REL}" "${CHART_DIR}" \
    --set syncDomain="${SYNCSTORAGE_DOMAIN}" --set maxUsers=1 \
    --set fxa.oauthServerUrl=http://mock-fxa:6000 \
    --set fxa.emailDomain=api-accounts.stage.mozaws.net \
    --set database.backend="${backend}" --set image.repository="${repository}" \
    --set image.syncstorageTag="${tag}" --set image.initTag="${init_tag}" "${db_args[@]}" --wait --timeout 10m \
    || fail "helm install did not get Ready"
  check "helm install (${backend}${EXTERNAL:+, your own server}) Ready"
  if [[ -n "${EXTERNAL}" ]]; then
    # (the backups' PVC only)
    [[ "$(kubectl get sts,pvc,secret -l "app.kubernetes.io/instance=${REL}" -o name | paste -sd' ' -)" == "persistentvolumeclaim/${FULL}-backups" ]] \
      || fail "bundled=false: the chart made $(kubectl get sts,pvc,secret -l "app.kubernetes.io/instance=${REL}" -o name | paste -sd' ' -)"
    check "no database server, database volume or Secret of the chart (the backups' PVC)"
    ingress_is "${FULL}-syncstorage" none sync.example.test "${FULL}-syncstorage" 8000
    check "Ingress ${FULL}-syncstorage (class none): sync.example.test/ to ${FULL}-syncstorage:8000"
  fi

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
  good=$(kubectl get secret "${SECRET}" -o jsonpath="{.data.${password_key}}")
  kubectl patch secret "${SECRET}" --type merge -p "{\"data\":{\"${password_key}\":\"$(printf wrong | base64)\"}}"
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
  kubectl patch secret "${SECRET}" --type merge -p "{\"data\":{\"${password_key}\":\"${good}\"}}"
  kubectl delete pod -l "${POD_SELECTOR}" --wait=true
  kubectl wait --for=condition=Ready pod -l "${POD_SELECTOR}" --timeout=10m || fail "pod not Ready after restoring the password"
  check "password restored: Ready again"

  # upgrades keep every secret
  before=$(kubectl get secret "${SECRET}" -o json | jq -S .data)
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values \
    --set syncstorage.resources.requests.cpu=50m --wait --timeout 10m || fail "helm upgrade failed"
  after=$(kubectl get secret "${SECRET}" -o json | jq -S .data)
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
  # (your own server: ADMIN_METRICS_TOKEN is in your Secret; the admin UI's Ingress too)
  local admin_args=()
  [[ -z "${EXTERNAL}" ]] || admin_args=(--set admin.ingress.enabled=true --set admin.ingress.className=none --set admin.ingress.host=admin.example.test)
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set admin.enabled=true --set admin.metricsToken=e2e-token \
    --set image.adminTag="${ADMIN_TAG}" "${admin_args[@]}" --wait --timeout 10m || fail "helm upgrade with the admin UI did not get Ready"
  check "admin UI on: Ready"
  if [[ -n "${EXTERNAL}" ]]; then
    ingress_is "${FULL}-admin" none admin.example.test "${FULL}-admin" 8080
    check "Ingress ${FULL}-admin (class none): admin.example.test/ to ${FULL}-admin:8080"
    # its tables in database.admin.name, as database.admin.user
    local events
    if [[ "${BACKEND}" == mysql ]]; then
      events=$(kubectl exec extdb-0 -- env MYSQL_PWD="$(secret ADMIN_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -N -u "${EXT_ADMIN_USER}" "${EXT_ADMIN_DB}" \
        -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${EXT_ADMIN_DB}' AND table_name = 'ffs_events'") || true
    else
      events=$(kubectl exec extdb-0 -- env PGPASSWORD="$(secret ADMIN_DB_PASSWORD)" psql -X -tA -h 127.0.0.1 -U "${EXT_ADMIN_USER}" -d "${EXT_ADMIN_DB}" \
        -c "SELECT COUNT(*) FROM pg_tables WHERE tablename = 'ffs_events' AND tableowner = '${EXT_ADMIN_USER}'") || true
    fi
    [[ "${events}" == 1 ]] || fail "no ffs_events of ${EXT_ADMIN_USER} in ${EXT_ADMIN_DB}: ${events}"
    check "the admin UI keeps its tables in ${EXT_ADMIN_DB} as ${EXT_ADMIN_USER}"
  fi
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
  # (existingSecret: the values' are not read)
  [[ -n "${EXTERNAL}" ]] || admin_token_off
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set admin.enabled=false --wait --timeout 10m \
    || fail "helm upgrade without the admin UI did not get Ready"
  ! kubectl get svc "${FULL}-admin" > /dev/null 2>&1 || fail "the admin Service is still there"
  if [[ -n "${EXTERNAL}" ]]; then
    ! kubectl get ingress "${FULL}-admin" > /dev/null 2>&1 || fail "the admin UI's Ingress is still there"
    ingress_is "${FULL}-syncstorage" none sync.example.test "${FULL}-syncstorage" 8000
  fi
  sync_ready ""
  check "admin UI off: syncstorage Ready again, no SYNC_STATSD_HOST${EXTERNAL:+, no admin Ingress}"
}

admin_token_off() {
  helm upgrade "${REL}" "${CHART_DIR}" --reuse-values --set admin.metricsToken= --wait --timeout 10m \
    || fail "helm upgrade without admin.metricsToken did not get Ready"
  [[ -z "$(secret ADMIN_METRICS_TOKEN)" ]] || fail "admin.metricsToken emptied, still in the Secret"
  kubectl wait --for=delete "pod/${before}" --timeout=2m > /dev/null 2>&1 || fail "the admin pod ${before} kept running with the old secret"
  check "admin.metricsToken emptied: empty in the Secret, a new admin pod"
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

  # 1. empty database servers, as on a new host (the chart's spec, empty volumes; your own:
  # one more like it, with DATABASES.md's SQL)
  local servers ts st ts_ip st_ip
  if [[ -n "${EXTERNAL}" ]]; then
    servers=
    extdb_server scratchdb
    if [[ "${BACKEND}" == mysql ]]; then
      # the dumps of MySQL lock each table while they load it (LOCK TABLES), which
      # db/mysql/sync.sql does not grant the Sync users (the stack's MySQL containers grant
      # them everything on their databases): given here, as the administrator of the new server
      EXTDB_POD=scratchdb-0 extdb_admin -e "GRANT LOCK TABLES ON \`${EXT_TS_DB}\`.* TO '${EXT_TS_USER}'@'%';
        GRANT LOCK TABLES ON \`${EXT_ST_DB}\`.* TO '${EXT_ST_USER}'@'%';" < /dev/null || fail "LOCK TABLES not granted on scratchdb"
    fi
  elif [[ "${BACKEND}" == postgres ]]; then
    servers="${FULL}-postgres"
  else
    servers="${FULL}-tokenserver-db ${FULL}-storage-db"
  fi
  for s in ${servers}; do
    kubectl get sts "${s}" -o json | jq --arg n "scratch-${s#"${FULL}-"}" '.spec.template.spec as $s | {apiVersion: "v1", kind: "Pod",
      metadata: {name: $n, labels: {"ffs-e2e": "scratch"}}, spec: ($s + {volumes: (($s.volumes // []) + [{name: "data", emptyDir: {}}])})}' \
      | kubectl apply -f - > /dev/null || fail "scratch server of ${s} not created"
  done
  [[ -z "${servers}" ]] || kubectl wait --for=condition=Ready pod -l ffs-e2e=scratch --timeout=5m > /dev/null || fail "the scratch database servers not Ready"
  if [[ -n "${EXTERNAL}" ]]; then
    ts=scratchdb-0 st=scratchdb-0
  elif [[ "${BACKEND}" == postgres ]]; then
    ts=scratch-postgres st=scratch-postgres
  else
    ts=scratch-tokenserver-db st=scratch-storage-db
  fi
  ts_ip=$(kubectl get pod "${ts}" -o jsonpath='{.status.podIP}')
  st_ip=$(kubectl get pod "${st}" -o jsonpath='{.status.podIP}')
  local like="the chart's"
  [[ -z "${EXTERNAL}" ]] || like="your own, with its SQL"
  check "empty database servers like ${like}: ${ts} ${st}"

  # 4. the tokenserver (PostgreSQL: the one database), with ADMIN.md's commands
  local restore
  restore=$(admin_md_restore "$([[ "${BACKEND}" == postgres ]] && echo 2 || echo 1)")
  [[ -n "${restore}" ]] || fail "no restore command of step 4 in ADMIN.md#restoring"
  [[ "${BACKEND}" == mysql ]] && restore=$(sed 's/^\( *\)mariadb /\1mysql /' <<< "${restore}")
  if [[ "${BACKEND}" == postgres && -z "${EXTERNAL}" ]]; then
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
  if [[ -n "${EXTERNAL}" ]]; then
    users_now=$(count extdb-0 users) items_now=$(count extdb-0 "${bso}")
  elif [[ "${BACKEND}" == postgres ]]; then
    users_now=$(count "${FULL}-postgres-0" users) items_now=$(count "${FULL}-postgres-0" "${bso}")
  else
    users_now=$(count "${FULL}-tokenserver-db-0" users) items_now=$(count "${FULL}-storage-db-0" "${bso}")
  fi
  [[ "${users_now}" =~ ^[1-9][0-9]*$ && "${items_now}" =~ ^[1-9][0-9]*$ ]] || fail "no users or Sync items to back up: ${users_now} ${items_now}"
  [[ "$(count "${ts}" users)" == "${users_now}" ]] || fail "users: $(count "${ts}" users) restored, ${users_now} in the chart's database"
  [[ "$(count "${st}" "${bso}")" == "${items_now}" ]] || fail "${bso}: $(count "${st}" "${bso}") restored, ${items_now} in the chart's database"
  check "the same rows of users (${users_now}) and ${bso} (${items_now}) restored"
  kubectl delete pod -l ffs-e2e --wait=false > /dev/null
  [[ -z "${EXTERNAL}" ]] || kubectl delete sts,svc scratchdb --wait=false > /dev/null
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
  if [[ -n "${EXTERNAL}" ]]; then
    case "${BACKEND}" in
      mysql)
        if [[ $2 == users ]]; then
          kubectl exec "$1" -- env MYSQL_PWD="$(secret TOKENSERVER_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -N -u "${EXT_TS_USER}" "${EXT_TS_DB}" -e "SELECT COUNT(*) FROM $2"
        else
          kubectl exec "$1" -- env MYSQL_PWD="$(secret STORAGE_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -N -u "${EXT_ST_USER}" "${EXT_ST_DB}" -e "SELECT COUNT(*) FROM $2"
        fi ;;
      postgres) kubectl exec "$1" -- env PGPASSWORD="$(secret POSTGRES_PASSWORD)" \
        psql -X -tA -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "${EXT_PG_USER}" -d "${EXT_PG_DB}" -c "SELECT COUNT(*) FROM $2" ;;
    esac
    return
  fi
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
  if [[ -n "${EXTERNAL}" ]]; then
    case "${BACKEND}" in
      mysql) kubectl exec extdb-0 -- env MYSQL_PWD="$(secret TOKENSERVER_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -u "${EXT_TS_USER}" "${EXT_TS_DB}" -e "$1" "${@:2}" ;;
      postgres) kubectl exec extdb-0 -- env PGPASSWORD="$(secret POSTGRES_PASSWORD)" \
        psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "${EXT_PG_USER}" -d "${EXT_PG_DB}" -c "$1" "${@:2}" ;;
    esac
    return
  fi
  case "${BACKEND}" in
    mariadb) kubectl exec "${FULL}-tokenserver-db-0" -- sh -c 'mariadb -u"${MARIADB_USER}" -p"${MARIADB_PASSWORD}" "${MARIADB_DATABASE}" -e "$1"' sh "$1" ;;
    mysql) kubectl exec "${FULL}-tokenserver-db-0" -- sh -c 'mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${MYSQL_DATABASE}" -e "$1"' sh "$1" ;;
    # as the Sync server's own role: no superuser session on the tables it owns
    postgres) kubectl exec "${FULL}-postgres-0" -- env PGPASSWORD="$(secret POSTGRES_SYNC_PASSWORD)" \
      psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U syncserver_app -d syncserver -c "$1" "${@:2}" ;;
  esac
}

secret() { kubectl get secret "${SECRET}" -o jsonpath="{.data.$1}" | base64 -d; }

# who the Sync server is on its databases, and the admin UI's users that the databases and
# the init container create (db/mysql/admin-user.sh, db/postgres/init)
database_users() {
  local pod_ip env
  pod_ip=$(kubectl get pods -l "${POD_SELECTOR}" -o jsonpath='{.items[0].status.podIP}')
  env=$(kubectl get deploy "${FULL}-syncstorage" -o json)
  if [[ -n "${EXTERNAL}" ]]; then
    external_users "${pod_ip}"
    return
  fi
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

# EXTERNAL_DB=1: who the Sync server is on your own server (the users of its SQL, no
# administrator, no superuser), and the admin UI's users reaching only what DATABASES.md says
external_users() {
  local pod_ip=$1 users
  if [[ "${BACKEND}" == mysql ]]; then
    users=$(extdb_admin -e "SELECT GROUP_CONCAT(DISTINCT user ORDER BY user) FROM information_schema.processlist WHERE host LIKE '${pod_ip}:%'" < /dev/null)
    [[ "${users}" == "$(printf '%s\n' "${EXT_ST_USER}" "${EXT_TS_USER}" | sort | paste -sd, -)" ]] \
      || fail "the Sync server connects to your server as '${users}', not ${EXT_TS_USER} and ${EXT_ST_USER}"
    [[ "$(sql 'SELECT COUNT(*) FROM users' -N)" =~ ^[0-9]+$ ]] || fail "no users table in ${EXT_TS_DB}"
    check "the Sync server connects as ${EXT_TS_USER} and ${EXT_ST_USER}, its tables in ${EXT_TS_DB}"
    kubectl exec extdb-0 -- env MYSQL_PWD="$(secret ADMIN_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -u "${EXT_ADMIN_USER}" "${EXT_ADMIN_DB}" \
      -e 'SELECT 1' > /dev/null || fail "${EXT_ADMIN_USER} cannot reach ${EXT_ADMIN_DB}"
    kubectl exec extdb-0 -- env MYSQL_PWD="$(secret ADMIN_DB_PASSWORD)" mysql -h 127.0.0.1 --protocol=tcp -u "${EXT_ADMIN_SYNC}" "${EXT_TS_DB}" \
      -e 'SELECT COUNT(*) FROM users' > /dev/null || fail "${EXT_ADMIN_SYNC} cannot read ${EXT_TS_DB}"
    ! sql "SHOW TABLES FROM ${EXT_ADMIN_DB}" > /dev/null 2>&1 || fail "${EXT_TS_USER} reaches ${EXT_ADMIN_DB}"
  else
    users=$(extdb_admin -c "SELECT string_agg(DISTINCT usename, ',') FROM pg_stat_activity WHERE client_addr = '${pod_ip}'" < /dev/null)
    [[ "${users}" == "${EXT_PG_USER}" ]] || fail "the Sync server connects to your server as '${users}', not ${EXT_PG_USER}"
    [[ "$(extdb_admin -c "SELECT rolsuper OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname = '${EXT_PG_USER}'" < /dev/null)" == f ]] \
      || fail "${EXT_PG_USER} is a superuser, or creates roles or databases"
    [[ "$(sql "SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname = 'public'" -tA)" == "${EXT_PG_USER}" ]] \
      || fail "the Sync tables are not ${EXT_PG_USER}'s"
    check "the Sync server connects as ${EXT_PG_USER} (no superuser, CREATEROLE or CREATEDB), the owner of its tables"
    kubectl exec extdb-0 -- env PGPASSWORD="$(secret ADMIN_DB_PASSWORD)" psql -X -tA -h 127.0.0.1 -U "${EXT_ADMIN_USER}" -d "${EXT_ADMIN_DB}" \
      -c 'SELECT 1' > /dev/null || fail "${EXT_ADMIN_USER} cannot reach ${EXT_ADMIN_DB}"
    # the reader of the Sync data, given its grants by the init container
    kubectl exec extdb-0 -- env PGPASSWORD="$(secret ADMIN_DB_PASSWORD)" psql -X -tA -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "${EXT_ADMIN_SYNC}" -d "${EXT_PG_DB}" \
      -c 'SELECT COUNT(*) FROM users' > /dev/null || fail "${EXT_ADMIN_SYNC} cannot read the Sync tables"
    ! kubectl exec extdb-0 -- env PGPASSWORD="$(secret POSTGRES_PASSWORD)" psql -X -tA -h 127.0.0.1 -U "${EXT_PG_USER}" -d "${EXT_ADMIN_DB}" \
      -c 'SELECT 1' > /dev/null 2>&1 || fail "${EXT_PG_USER} reaches ${EXT_ADMIN_DB}"
  fi
  check "the admin UI's ${EXT_ADMIN_USER} reaches ${EXT_ADMIN_DB}, ${EXT_ADMIN_SYNC} reads the Sync data, the Sync server's user not ${EXT_ADMIN_DB}"
}

# EXTERNAL_DB=1: SQL as the administrator of your own server (MySQL: root; PostgreSQL: the
# image's superuser, only to create the administrator of extdb_server), on stdin; in the pod
# EXTDB_POD (extdb-0)
extdb_admin() {
  local pod=${EXTDB_POD:-extdb-0}
  if [[ "${BACKEND}" == mysql ]]; then
    kubectl exec -i "${pod}" -- sh -c 'MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" exec mysql -h 127.0.0.1 --protocol=tcp -uroot -sN "$@"' sh "$@"
  else
    kubectl exec -i "${pod}" -- sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" exec psql -X -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -tA "$@"' sh "$@"
  fi
}

# EXTERNAL_DB=1: a database server the chart does not manage, mirroring tests/e2e.sh's
# start_extdb (a plain StatefulSet and Service extdb, a test fixture: MySQL 8.4 with binary
# logging, or PostgreSQL 18 administered by a role that is no superuser), the databases and
# users of DATABASES.md (db/<engine>/sync.sql with its placeholders filled in) under names
# other than the defaults, and the Secret of existingSecret with the same passwords
start_extdb() {
  EXT_ADMIN_DB=own_admin EXT_ADMIN_USER=own_admin_ui EXT_ADMIN_SYNC=own_admin_sync
  EXT_TS_DB=own_tokenserver EXT_TS_USER=own_ts EXT_ST_DB=own_storage EXT_ST_USER=own_st
  EXT_PG_DB=own_sync EXT_PG_USER=own_sync_owner
  local ts st pg admin
  ts=$(rnd) st=$(rnd) pg=$(rnd) admin=$(rnd)
  EXT_SQL=$(mktemp)
  if [[ "${BACKEND}" == mysql ]]; then
    sed -e "s|@TOKENSERVER_DATABASE@|${EXT_TS_DB}|g" -e "s|@TOKENSERVER_USER@|${EXT_TS_USER}|g" -e "s|@TOKENSERVER_PASSWORD@|${ts}|g" \
      -e "s|@SYNCSTORAGE_DATABASE@|${EXT_ST_DB}|g" -e "s|@SYNCSTORAGE_USER@|${EXT_ST_USER}|g" -e "s|@SYNCSTORAGE_PASSWORD@|${st}|g" \
      -e "s|@ADMIN_DATABASE@|${EXT_ADMIN_DB}|g" -e "s|@ADMIN_USER@|${EXT_ADMIN_USER}|g" -e "s|@ADMIN_SYNC_USER@|${EXT_ADMIN_SYNC}|g" \
      -e "s|@ADMIN_PASSWORD@|${admin}|g" "${REPO_ROOT}/db/mysql/sync.sql" > "${EXT_SQL}"
  else
    sed -e "s|@POSTGRES_DATABASE@|${EXT_PG_DB}|g" -e "s|@POSTGRES_USER@|${EXT_PG_USER}|g" -e "s|@POSTGRES_PASSWORD@|${pg}|g" \
      -e "s|@ADMIN_DATABASE@|${EXT_ADMIN_DB}|g" -e "s|@ADMIN_USER@|${EXT_ADMIN_USER}|g" -e "s|@ADMIN_SYNC_USER@|${EXT_ADMIN_SYNC}|g" \
      -e "s|@ADMIN_PASSWORD@|${admin}|g" "${REPO_ROOT}/db/postgres/sync.sql" > "${EXT_SQL}"
  fi
  ! grep -q '@[A-Z_]*@' "${EXT_SQL}" || fail "placeholders left in db/${BACKEND}/sync.sql: $(grep -o '@[A-Z_]*@' "${EXT_SQL}" | sort -u | paste -sd' ' -)"
  extdb_server extdb
  check "your own database server (${EXTDB_IMAGE}, not the chart's) with DATABASES.md's SQL (db/${BACKEND}/sync.sql) run as the administrator$([[ ${BACKEND} == postgres ]] && echo ' (CREATEROLE, CREATEDB, no superuser)')"
  # your Secret: the stack's secrets and the passwords of that SQL
  local keys=(--from-literal=SYNC_MASTER_SECRET="$(rnd)" --from-literal=METRICS_HASH_SECRET="$(rnd)" --from-literal=ADMIN_PASSWORD="$(rnd)"
    --from-literal=ADMIN_DB_PASSWORD="${admin}" --from-literal=ADMIN_METRICS_TOKEN=e2e-token)
  if [[ "${BACKEND}" == mysql ]]; then
    keys+=(--from-literal=TOKENSERVER_DB_PASSWORD="${ts}" --from-literal=STORAGE_DB_PASSWORD="${st}")
  else
    keys+=(--from-literal=POSTGRES_PASSWORD="${pg}")
  fi
  kubectl create secret generic ffs-own "${keys[@]}" > /dev/null || fail "Secret ffs-own not created"
  check "Secret ffs-own with the passwords of that SQL"
}

# extdb_server <name>: a server like that (StatefulSet and Service <name>, empty), with EXT_SQL
# run there as its administrator (the restore check makes a second one, as on a new host)
extdb_server() {
  local name=$1 image port data env args probe
  if [[ "${BACKEND}" == mysql ]]; then
    # binary logging on (MySQL 8's default): the trigger needs log_bin_trust_function_creators
    image=mysql:8.4 port=3306 data=/var/lib/mysql env=MYSQL_ROOT_PASSWORD args='["--log-bin-trust-function-creators=ON"]'
    probe='mysqladmin ping -h 127.0.0.1 --protocol=tcp -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent'
  else
    image=postgres:18 port=5432 data=/var/lib/postgresql env=POSTGRES_PASSWORD args='[]'
    probe='pg_isready -h 127.0.0.1 -U postgres'
  fi
  EXTDB_IMAGE=${image}
  # (over TCP in the probe: while the image initializes, a temporary server on the socket only)
  jq -n --arg name "${name}" --arg image "${image}" --argjson port "${port}" --arg data "${data}" --arg env "${env}" --arg root "$(rnd)" \
    --argjson args "${args}" --arg probe "${probe}" '
    {apiVersion: "v1", kind: "List", items: [
      {apiVersion: "v1", kind: "Service", metadata: {name: $name},
       spec: {selector: {app: $name}, ports: [{port: $port, targetPort: $port}]}},
      {apiVersion: "apps/v1", kind: "StatefulSet", metadata: {name: $name},
       spec: {serviceName: $name, replicas: 1, selector: {matchLabels: {app: $name}},
         template: {metadata: {labels: {app: $name}}, spec: {
           containers: [{name: "db", image: $image, args: $args, env: [{name: $env, value: $root}],
             ports: [{containerPort: $port}],
             readinessProbe: {exec: {command: ["sh", "-c", $probe]}, periodSeconds: 5, timeoutSeconds: 5},
             volumeMounts: [{name: "data", mountPath: $data}]}],
           volumes: [{name: "data", emptyDir: {}}]}}}}]}' | kubectl apply -f - > /dev/null || fail "database server ${name} not created"
  kubectl rollout status "sts/${name}" --timeout=5m > /dev/null || fail "database server ${name} (${image}) not Ready"
  if [[ "${BACKEND}" == mysql ]]; then
    EXTDB_POD=${name}-0 extdb_admin < "${EXT_SQL}" > /dev/null || fail "db/mysql/sync.sql refused by ${name}"
  else
    # as a role with CREATEROLE and CREATEDB, no superuser: what managed services give
    local dbadmin
    dbadmin=$(rnd)
    EXTDB_POD=${name}-0 extdb_admin -c "CREATE ROLE dbadmin LOGIN CREATEROLE CREATEDB PASSWORD '${dbadmin}'" < /dev/null > /dev/null || fail "no administrator role on ${name}"
    kubectl exec -i "${name}-0" -- env PGPASSWORD="${dbadmin}" psql -X -h 127.0.0.1 -U dbadmin -d postgres -v ON_ERROR_STOP=1 -q < "${EXT_SQL}" > /dev/null \
      || fail "db/postgres/sync.sql refused by ${name} (as dbadmin)"
  fi
}

rnd() { tr -dc A-Za-z0-9 < /dev/urandom | head -c 32 || true; }

# ingress_is <name> <class> <host> <service> <port>: that Ingress, / of the host to the Service
ingress_is() {
  local got
  got=$(kubectl get ingress "$1" -o json 2> /dev/null | jq -c '[.spec.ingressClassName, [.spec.rules[] | .host, (.http.paths[] | .path, .pathType,
    .backend.service.name, .backend.service.port.number)]]') || true
  [[ "${got}" == "[\"$2\",[\"$3\",\"/\",\"Prefix\",\"$4\",$5]]" ]] || fail "Ingress $1: ${got:-none}"
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

# on a failure, what the pods did: every pod not Ready
# (but those that completed) in full, describe, each container's and init container's log,
# the current one and that of the previous run (a crash loop), and the events
diagnostics() {
  kubectl get pods -o wide 2>/dev/null || return 0
  local pod c
  for pod in $(kubectl get pods -o go-template='{{range .items}}{{if ne .status.phase "Succeeded"}}{{$ready := "False"}}{{range .status.conditions}}{{if eq .type "Ready"}}{{$ready = .status}}{{end}}{{end}}{{if ne $ready "True"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' 2>/dev/null); do
    echo "=== pod/${pod} not Ready"
    kubectl describe pod "${pod}" 2>/dev/null || true
    for c in $(kubectl get pod "${pod}" -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null); do
      echo "--- pod/${pod} ${c}: log"
      kubectl logs "${pod}" -c "${c}" --tail=200 2>&1 || true
      echo "--- pod/${pod} ${c}: log of the previous run"
      kubectl logs "${pod}" -c "${c}" --previous --tail=200 2>&1 || true
    done
  done
  echo "=== events"
  kubectl get events --sort-by=.lastTimestamp 2>/dev/null || true
  kubectl logs extdb-0 --tail=15 2> /dev/null || true
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
  parity)
    shift
    parity "$@"
    ;;
  e2e)
    e2e "${2:-}"
    ;;
  *)
    echo "Usage: $0 {lint|parity [case...]|e2e <mariadb|mysql|postgres>}"
    echo "  lint                              - helm lint and template checks (parity too)"
    echo "  parity [case...]                  - the chart's env, commands and probes against compose's (tests/helm_parity.py)"
    echo "  e2e <mariadb|mysql|postgres>      - install on a kind cluster and run the client flow"
    exit 1
    ;;
esac
