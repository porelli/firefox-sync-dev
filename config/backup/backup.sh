#!/bin/sh
# Backups of the stack's databases (COMPOSE_PROFILES=backup, or firefox-sync-backup.timer
# with the Quadlets), see ADMIN.md#backups. Runs in the database images already pulled:
# mariadb (mariadb-dump), postgres (pg_dump), mysql (mysqldump).
#
#   backup.sh loop    once a day at BACKUP_TIME (UTC), checked every minute (compose)
#   backup.sh now     one run now
#
# BACKUP_SCOPE=sync: the tokenserver and storage databases (TOKENSERVER_DB_*, STORAGE_DB_*;
# with PostgreSQL one database). BACKUP_SCOPE=accounts: those of the self-hosted accounts
# (FXA_DB_*). A run writes BACKUP_DIR/<scope>/<UTC time>/<database>.sql.gz, checked with
# gzip -t; the newest BACKUP_KEEP runs are kept, a failed run leaves nothing behind: it
# writes into .<UTC time>.partial, renamed when complete (a stopped or killed run's is
# removed on exit or by the next run).
# Each run is a row of ffs_backups in the tokenserver database, written by the sync scope
# as the tokenserver user: the accounts scope leaves its result in BACKUP_DIR/.status
# (its image has no PostgreSQL client), the sync scope records it on its next round.
set -u
umask 077

DIR=${BACKUP_DIR:-/backups}
KEEP=${BACKUP_KEEP:-7}
AT=${BACKUP_TIME:-03:00}
SCOPE=${BACKUP_SCOPE:-}
TMP=$(mktemp -d)
PARTIAL=
trap 'rm -rf "${TMP}" ${PARTIAL:+"${PARTIAL}"}' EXIT
# (sh runs it once the current dump ends, then the EXIT trap)
trap 'exit 0' TERM INT

log() { echo "backup ${SCOPE}: $*"; }
fail() { log "$*" >&2; exit 2; }

case "${SCOPE}" in sync|accounts) ;; *) fail "BACKUP_SCOPE must be sync or accounts" ;; esac
case "${KEEP}" in ''|*[!0-9]*|0) fail "BACKUP_KEEP must be a number of 1 or more, not '${KEEP}'" ;; esac
case "${AT}" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) fail "BACKUP_TIME must be HH:MM (UTC), not '${AT}'" ;; esac

# milliseconds (GNU date), or seconds * 1000
now_ms() {
  t=$(date +%s%3N)
  case "${t}" in *[!0-9]*) t=$(($(date +%s) * 1000)) ;; esac
  echo "${t}"
}

# one line of plain text for the status row: no quotes to escape in the SQL
clean() { tr '\n\r\t' '   ' | tr -cd 'A-Za-z0-9 .,:;_/@()=+#-' | cut -c1-400; }

# the client of the MySQL-like images: mariadb or mysql
if command -v mariadb-dump > /dev/null 2>&1; then
  MYSQL=mariadb DUMP=mariadb-dump
else
  MYSQL=mysql DUMP=mysqldump
fi

# an option file with the password, not the command line or the environment of the client.
# Its parser reads \\, \n, \s... as escapes: backslashes doubled; a new line cannot be written
cnf() { # file host port user password
  case "$5" in *"
"*) echo "the password of $4 has a line break, which an option file cannot hold"; return 1 ;; esac
  c_pw=$(printf '%sx' "$5" | sed 's/\\/\\\\/g')
  printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\n' "$2" "$3" "$4" "${c_pw%x}" > "$1"
  # MySQL's certificate is self-signed, which the MariaDB client refuses by default
  [ "${MYSQL}" = mariadb ] && [ "${MARIADB_TLS_VERIFY:-true}" = false ] && echo skip-ssl-verify-server-cert >> "$1"
  return 0
}

# dump_mysql cnf database out: a consistent dump with the procedures, triggers (and events)
dump_mysql() {
  set -- "$@" --single-transaction --routines --hex-blob --no-tablespaces
  # MySQL's own dump would add the GTIDs of the server, which a restore elsewhere refuses
  [ "${DUMP}" = mysqldump ] && set -- "$@" --set-gtid-purged=OFF
  # the accounts' databases have events (the tokenserver user has no EVENT grant). Their
  # only trigger is the sign-up policy's, which fxa-policy installs again at every start:
  # MariaDB dumps it as fxa.ffs_signup_policy ON fxa.accounts, a copy restored into another
  # database would put it on the real one
  if [ "${SCOPE}" = accounts ]; then
    set -- "$@" --events --skip-triggers
  else
    set -- "$@" --triggers
  fi
  # (no local variables in sh: names of their own)
  d_cnf=$1 d_db=$2 d_out=$3
  shift 3
  { "${DUMP}" --defaults-extra-file="${d_cnf}" "$@" "${d_db}" 2> "${TMP}/err"; echo $? > "${TMP}/rc"; } | gzip > "${d_out}"
  [ "$(cat "${TMP}/rc")" = 0 ] || { echo "${d_db}: $(clean < "${TMP}/err")"; return 1; }
}

dump_postgres() { # database out
  { PGPASSWORD=${TOKENSERVER_DB_PASSWORD} pg_dump --no-password -h "${TOKENSERVER_DB_HOST}" -p "${TOKENSERVER_DB_PORT:-5432}" \
      -U "${TOKENSERVER_DB_USER}" -d "$1" 2> "${TMP}/err"; echo $? > "${TMP}/rc"; } | gzip > "$2"
  [ "$(cat "${TMP}/rc")" = 0 ] || { echo "$1: $(clean < "${TMP}/err")"; return 1; }
}

# SQL as the tokenserver user (sync scope only)
ts_sql() {
  if [ "${TOKENSERVER_DB_TYPE:-mysql}" = postgres ]; then
    PGPASSWORD=${TOKENSERVER_DB_PASSWORD} psql --no-password -q -v ON_ERROR_STOP=1 -h "${TOKENSERVER_DB_HOST}" -p "${TOKENSERVER_DB_PORT:-5432}" \
      -U "${TOKENSERVER_DB_USER}" -d "${TOKENSERVER_DB_NAME}" -c "$1" > /dev/null
  else
    "${MYSQL}" --defaults-extra-file="${TMP}/tokenserver.cnf" "${TOKENSERVER_DB_NAME}" -e "$1"
  fi
}

# the table of the admin UI (it creates it too), see ADMIN.md#backups
ts_table() {
  if [ "${TOKENSERVER_DB_TYPE:-mysql}" = postgres ]; then
    ts_sql "CREATE TABLE IF NOT EXISTS ffs_backups (id BIGSERIAL PRIMARY KEY, scope VARCHAR(32) NOT NULL, started BIGINT NOT NULL,
      finished BIGINT NOT NULL, ok SMALLINT NOT NULL, bytes BIGINT NOT NULL, error VARCHAR(512) NOT NULL DEFAULT '', location VARCHAR(255) NOT NULL DEFAULT '')"
  else
    ts_sql "CREATE TABLE IF NOT EXISTS ffs_backups (id BIGINT AUTO_INCREMENT PRIMARY KEY, scope VARCHAR(32) NOT NULL, started BIGINT NOT NULL,
      finished BIGINT NOT NULL, ok SMALLINT NOT NULL, bytes BIGINT NOT NULL, error VARCHAR(512) NOT NULL DEFAULT '', location VARCHAR(255) NOT NULL DEFAULT '',
      KEY ffs_backups_started (started))"
  fi
}

# record scope started finished ok bytes location error: a row of ffs_backups, or with the
# accounts scope a file for the sync scope (the values are numbers and clean text)
record() {
  if [ "${SCOPE}" = accounts ]; then
    mkdir -p "${DIR}/.status"
    # (- for no location: read splits on spaces)
    printf '%s %s %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" "${6:--}" "$7" > "${DIR}/.status/.$1-$2" && mv "${DIR}/.status/.$1-$2" "${DIR}/.status/$1-$2"
    return
  fi
  ts_table && ts_sql "INSERT INTO ffs_backups (scope, started, finished, ok, bytes, location, error) VALUES ('$1', $2, $3, $4, $5, '$6', '$7')"
}

# the results the accounts scope left
import() {
  for f in "${DIR}"/.status/*; do
    [ -f "${f}" ] || continue
    read -r scope started finished ok bytes location error < "${f}"
    case "${scope}${started}${finished}${ok}${bytes}" in *[!a-z0-9]*) rm -f "${f}"; continue ;; esac
    [ "${location}" = - ] && location=""
    location=$(printf "%s" "${location}" | clean)
    record "${scope}" "${started}" "${finished}" "${ok}" "${bytes}" "${location}" "$(printf '%s' "${error:-}" | clean)" && rm -f "${f}"
  done
}

run() {
  started=$(now_ms)
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  out=${DIR}/${SCOPE}/${stamp}
  # what a stopped (SIGKILL) run left
  rm -rf "${DIR}/${SCOPE}"/.*.partial 2> /dev/null
  PARTIAL=${DIR}/${SCOPE}/.${stamp}.partial
  mkdir -p "${PARTIAL}" || { PARTIAL=; record "${SCOPE}" "${started}" "$(now_ms)" 0 0 "" "cannot write to ${DIR}"; return 1; }
  errors=""
  if [ "${SCOPE}" = sync ] && [ "${TOKENSERVER_DB_TYPE:-mysql}" = postgres ]; then
    # tokenserver and storage share the database
    dump_postgres "${TOKENSERVER_DB_NAME}" "${PARTIAL}/${TOKENSERVER_DB_NAME}.sql.gz" > "${TMP}/msg" || errors="${errors}$(cat "${TMP}/msg"); "
  elif [ "${SCOPE}" = sync ]; then
    parts="tokenserver storage"
    [ -z "${STORAGE_DB_HOST:-}" ] && parts=tokenserver
    cnf "${TMP}/storage.cnf" "${STORAGE_DB_HOST:-}" "${STORAGE_DB_PORT:-3306}" "${STORAGE_DB_USER:-}" "${STORAGE_DB_PASSWORD:-}" > "${TMP}/msg" ||
      { errors="${errors}$(cat "${TMP}/msg"); "; parts=tokenserver; }
    for part in ${parts}; do
      eval "db=\${$(echo "${part}" | tr a-z A-Z)_DB_NAME}"
      dump_mysql "${TMP}/${part}.cnf" "${db}" "${PARTIAL}/${db}.sql.gz" > "${TMP}/msg" || errors="${errors}$(cat "${TMP}/msg"); "
    done
  elif cnf "${TMP}/accounts.cnf" "${FXA_DB_HOST:-fxa-db}" "${FXA_DB_PORT:-3306}" "${FXA_DB_USER:-root}" "${FXA_DB_PASSWORD:-}" > "${TMP}/msg"; then
    # ffs last: its views read the others
    for db in ${FXA_DATABASES:-fxa fxa_oauth fxa_profile pushbox ffs}; do
      dump_mysql "${TMP}/accounts.cnf" "${db}" "${PARTIAL}/${db}.sql.gz" > "${TMP}/msg" || errors="${errors}$(cat "${TMP}/msg"); "
    done
  else
    errors="$(cat "${TMP}/msg"); "
  fi
  bytes=0
  for f in "${PARTIAL}"/*.sql.gz; do
    [ -f "${f}" ] || continue
    gzip -t "${f}" 2> /dev/null || errors="${errors}$(basename "${f}"): gzip -t failed; "
    bytes=$((bytes + $(wc -c < "${f}")))
  done
  [ "${bytes}" -gt 0 ] || errors="${errors:-nothing was written}"
  # (mv would put it inside a run of the same second)
  [ -n "${errors}" ] || { [ ! -e "${out}" ] && mv "${PARTIAL}" "${out}"; } || errors="cannot rename ${PARTIAL} to ${out}"
  if [ -n "${errors}" ]; then
    rm -rf "${PARTIAL}"
    PARTIAL=
    log "FAILED: ${errors}" >&2
    record "${SCOPE}" "${started}" "$(now_ms)" 0 "${bytes}" "" "$(printf '%s' "${errors}" | clean)"
    return 1
  fi
  # the newest BACKUP_KEEP runs (the names sort by time), older ones go
  ls -1 "${DIR}/${SCOPE}" | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do
    rm -rf "${DIR:?}/${SCOPE}/${old}"
  done
  PARTIAL=
  log "ok: ${out}, ${bytes} bytes"
  record "${SCOPE}" "${started}" "$(now_ms)" 1 "${bytes}" "${out}" ""
}

# (without it nothing can be recorded)
if [ "${SCOPE}" = sync ] && [ "${TOKENSERVER_DB_TYPE:-mysql}" != postgres ]; then
  cnf "${TMP}/tokenserver.cnf" "${TOKENSERVER_DB_HOST:-}" "${TOKENSERVER_DB_PORT:-3306}" "${TOKENSERVER_DB_USER:-}" "${TOKENSERVER_DB_PASSWORD:-}" > "${TMP}/msg" ||
    fail "$(cat "${TMP}/msg")"
fi

case "${1:-}" in
  now)
    rc=0
    run || rc=1
    [ "${SCOPE}" = sync ] && import
    exit ${rc}
    ;;
  loop)
    mkdir -p "${DIR}"
    log "every day at ${AT} UTC, keeping ${KEEP}"
    while :; do
      [ "${SCOPE}" = sync ] && import
      today=$(date -u +%F)
      # once a day from BACKUP_TIME on: a container started later that day runs at once
      if [ "$(date -u +%H%M)" -ge "$(echo "${AT}" | tr -d :)" ] && [ "$(cat "${DIR}/.last-${SCOPE}" 2> /dev/null)" != "${today}" ]; then
        # written after the run, failed or not: a stopped one runs again at the next start
        run
        echo "${today}" > "${DIR}/.last-${SCOPE}"
      fi
      sleep 60 &
      wait $!
    done
    ;;
  *) fail "usage: backup.sh now | loop" ;;
esac
