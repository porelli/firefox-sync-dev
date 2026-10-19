#!/bin/sh
# Backups of the stack's databases (COMPOSE_PROFILES=backup, or firefox-sync-backup.timer
# with the Quadlets), see docs/backups.md#the-backup-service. Runs in the database images already pulled:
# mariadb (mariadb-dump), postgres (pg_dump), mysql (mysqldump).
#
#   backup.sh loop    once a day at BACKUP_TIME (UTC), checked every minute (compose)
#   backup.sh now     one run now
#   backup.sh health  the healthcheck of the loop (compose): fails when the loop no longer
#                     goes round, the last run failed, or the last good one is over 25 h old
#
# BACKUP_SCOPE=sync: the tokenserver and storage databases (TOKENSERVER_DB_*, STORAGE_DB_*;
# with PostgreSQL one database). BACKUP_SCOPE=accounts: those of the self-hosted accounts
# (FXA_DB_*). A run writes BACKUP_DIR/<scope>/<UTC time>/<database>.sql.gz, checked with
# gzip -t; the newest BACKUP_KEEP runs are kept, a failed run leaves nothing behind: it
# writes into .<UTC time>.partial, renamed when complete (a stopped or killed run's is
# removed on exit or by the next run).
# With ADMIN_DB_PASSWORD the sync scope also dumps the admin UI's database (ADMIN_DB_NAME on
# the tokenserver's server, the event log and the audit trail) as its user ADMIN_DB_USER.
# Each run is a row of ffs_backups there, written by the sync scope as that user (without
# ADMIN_DB_PASSWORD, an install from before it: in the tokenserver database, as the
# tokenserver user): the accounts scope leaves its result in BACKUP_DIR/.status (its image
# has no PostgreSQL client), the sync scope records it on its next round.
# For the healthcheck the loop writes BACKUP_DIR/.loop-<scope> (when it started, its last
# round, every minute) and each run BACKUP_DIR/.result-<scope> (1 or 0, when it finished).
# One run at a time per scope (the nightly one, one made by hand, the Quadlet timer's): a run
# holds BACKUP_DIR/.lock-<scope>, a directory (mkdir is atomic, the mysql image has no flock) with
# its owner, and a second one waits for it, at most BACKUP_LOCK_WAIT seconds (3600), then
# fails, recorded. A lock whose run is gone (killed) is taken over: at once in the same
# container (its process is no longer there), otherwise after MAX_RUN (a day).
set -u
umask 077

DIR=${BACKUP_DIR:-/backups}
KEEP=${BACKUP_KEEP:-7}
AT=${BACKUP_TIME:-03:00}
SCOPE=${BACKUP_SCOPE:-}
WAIT=${BACKUP_LOCK_WAIT:-3600}
PAUSE=${BACKUP_RETRY_PAUSE:-10}
# no run takes longer (also the healthcheck's limit)
MAX_RUN=86400
TMP=$(mktemp -d)
PARTIAL=
LOCK=${DIR}/.lock-${SCOPE}
LOCKED=
trap 'rm -rf "${TMP}" ${PARTIAL:+"${PARTIAL}"}; [ -z "${LOCKED}" ] || rm -rf "${LOCK}"' EXIT
# (sh runs it once the current dump ends, then the EXIT trap)
trap 'exit 0' TERM INT

log() { echo "backup ${SCOPE}: $*"; }
fail() { log "$*" >&2; exit 2; }

case "${SCOPE}" in sync|accounts) ;; *) fail "BACKUP_SCOPE must be sync or accounts" ;; esac
case "${KEEP}" in ''|*[!0-9]*|0) fail "BACKUP_KEEP must be a number of 1 or more, not '${KEEP}'" ;; esac
case "${AT}" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) fail "BACKUP_TIME must be HH:MM (UTC), not '${AT}'" ;; esac
case "${WAIT}" in ''|*[!0-9]*) fail "BACKUP_LOCK_WAIT must be a number of seconds, not '${WAIT}'" ;; esac
case "${PAUSE}" in ''|*[!0-9]*) fail "BACKUP_RETRY_PAUSE must be a number of seconds, not '${PAUSE}'" ;; esac

# the state of the loop and of the last run, for the healthcheck (written then renamed: the
# check never reads half a line; a run that cannot write to DIR fails its check anyway)
state() { # file values...
  s_file=$1
  shift
  { echo "$*" > "${s_file}.new" && mv "${s_file}.new" "${s_file}"; } 2> /dev/null
}

# the healthcheck: one line on what is wrong (no names, no secrets), exit 1
health() {
  h_now=$(date +%s)
  { [ -f "${DIR}/.loop-${SCOPE}" ] && read -r h_since h_beat < "${DIR}/.loop-${SCOPE}"; } || { echo "the backup loop has not started"; return 1; }
  # a run going on: its lock or its .partial directory, the loop only goes round again after it
  h_run=$(stat -c %Y "${LOCK}" "${DIR}/${SCOPE}"/.*.partial 2> /dev/null | sort -n | head -1)
  if [ -n "${h_run}" ]; then
    [ $((h_now - h_run)) -le "${MAX_RUN}" ] || { echo "a run has been going on for over a day"; return 1; }
  elif [ $((h_now - h_beat)) -gt 300 ]; then
    echo "the backup loop stopped going round $(((h_now - h_beat) / 60)) minutes ago"
    return 1
  fi
  h_ok=1 h_last=${h_since}
  [ -f "${DIR}/.result-${SCOPE}" ] && read -r h_ok h_last < "${DIR}/.result-${SCOPE}"
  [ "${h_ok}" = 1 ] || { echo "the last backup failed, see the logs of this container"; return 1; }
  # once a day: 25 h leave an hour for a run that takes longer than the one before
  if [ -z "${h_run}" ] && [ $((h_now - h_last)) -gt 90000 ]; then
    echo "no backup for $(((h_now - h_last) / 3600)) hours"
    return 1
  fi
  echo "ok"
}
if [ "${1:-}" = health ]; then
  health
  exit
fi

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
  set -- "$@" --single-transaction --routines --hex-blob --no-tablespaces --skip-add-locks
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
  # a table created, dropped or altered while it dumps (error 1412, e.g. the admin UI moving
  # its tables at an upgrade, once): again, once, after BACKUP_RETRY_PAUSE seconds
  if [ "$(cat "${TMP}/rc")" != 0 ] && grep -q 'Table definition has changed' "${TMP}/err"; then
    log "${d_db}: $(clean < "${TMP}/err"), once more in ${PAUSE} s" >&2
    sleep "${PAUSE}"
    { "${DUMP}" --defaults-extra-file="${d_cnf}" "$@" "${d_db}" 2> "${TMP}/err"; echo $? > "${TMP}/rc"; } | gzip > "${d_out}"
  fi
  [ "$(cat "${TMP}/rc")" = 0 ] || { echo "${d_db}: $(clean < "${TMP}/err")"; return 1; }
}

# without owners and grants: they name roles (the Sync server's, the admin UI's) that a new
# server has only once the init container ran, and it gives them again at every start.
# The admin UI's database with DROP ... IF EXISTS: restored over the tables it has
dump_postgres() { # database out [user password [options]]
  # shellcheck disable=SC2086 # (options: words)
  { PGPASSWORD=${4:-${TOKENSERVER_DB_PASSWORD}} pg_dump --no-password -h "${TOKENSERVER_DB_HOST}" -p "${TOKENSERVER_DB_PORT:-5432}" \
      -U "${3:-${TOKENSERVER_DB_USER}}" --no-owner --no-privileges ${5:-} -d "$1" 2> "${TMP}/err"; echo $? > "${TMP}/rc"; } | gzip > "$2"
  [ "$(cat "${TMP}/rc")" = 0 ] || { echo "$1: $(clean < "${TMP}/err")"; return 1; }
}

# where the runs are recorded (sync scope only): the admin UI's database as its user, or
# without ADMIN_DB_PASSWORD the tokenserver database as the tokenserver user
if [ -n "${ADMIN_DB_PASSWORD:-}" ]; then
  STATUS_USER=${ADMIN_DB_USER:-ffs_admin_ui} STATUS_PASSWORD=${ADMIN_DB_PASSWORD} STATUS_DB=${ADMIN_DB_NAME:-ffs_admin}
else
  STATUS_USER=${TOKENSERVER_DB_USER:-} STATUS_PASSWORD=${TOKENSERVER_DB_PASSWORD:-} STATUS_DB=${TOKENSERVER_DB_NAME:-}
fi
ts_sql() {
  if [ "${TOKENSERVER_DB_TYPE:-mysql}" = postgres ]; then
    PGPASSWORD=${STATUS_PASSWORD} psql --no-password -q -v ON_ERROR_STOP=1 -h "${TOKENSERVER_DB_HOST}" -p "${TOKENSERVER_DB_PORT:-5432}" \
      -U "${STATUS_USER}" -d "${STATUS_DB}" -c "$1" > /dev/null
  else
    "${MYSQL}" --defaults-extra-file="${TMP}/status.cnf" "${STATUS_DB}" -e "$1"
  fi
}

# the table of the admin UI (it creates it too), see docs/backups.md#your-own-database-server
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

# the lock: who holds it, host (the container), pid and its start time (a pid used again
# after a restart has another), when
owner() { echo "$(cat /proc/sys/kernel/hostname) $$ $(cut -d' ' -f22 /proc/$$/stat) $(date +%s)"; }

# whether the run of a lock is gone: its process no longer there (same container), or
# older than MAX_RUN; a lock without its owner yet only after a minute (it is written right
# after the mkdir)
gone() { # owner
  # shellcheck disable=SC2086 # (its four words)
  set -- $1
  if [ $# -ne 4 ]; then
    [ $(($(date +%s) - $(stat -c %Y "${LOCK}" 2> /dev/null || date +%s))) -gt 60 ]
    return
  fi
  [ $(($(date +%s) - $4)) -gt "${MAX_RUN}" ] && return 0
  # (a zombie is gone too)
  [ "$1" = "$(cat /proc/sys/kernel/hostname)" ] && ! cut -d' ' -f3,22 "/proc/$2/stat" 2> /dev/null | grep -qx "[^Z] $3"
}

# lock: 0 with the lock, or when DIR cannot be written to (the run says so, recorded); 1
# after BACKUP_LOCK_WAIT, LOCK_ERROR says why
lock() {
  l_waited=0
  mkdir -p "${DIR}" 2> /dev/null
  while ! mkdir "${LOCK}" 2> /dev/null; do
    # (gone, or just released: again)
    { [ -d "${DIR}" ] && [ -w "${DIR}" ]; } || return 0
    [ -e "${LOCK}" ] || continue
    l_owner=$(cat "${LOCK}/owner" 2> /dev/null)
    if gone "${l_owner}"; then
      # one at a time takes it over (.break), and only the lock it found gone
      if mkdir "${LOCK}.break" 2> /dev/null; then
        [ "$(cat "${LOCK}/owner" 2> /dev/null)" = "${l_owner}" ] && rm -rf "${LOCK}" && log "took over the lock of a run that is gone (${l_owner:-no owner})"
        rmdir "${LOCK}.break"
      elif [ $(($(date +%s) - $(stat -c %Y "${LOCK}.break" 2> /dev/null || date +%s))) -gt 60 ]; then
        rmdir "${LOCK}.break" 2> /dev/null
      fi
      continue
    fi
    if [ "${l_waited}" -ge "${WAIT}" ]; then
      LOCK_ERROR="another backup run of the ${SCOPE} databases was still going on after ${WAIT} s (BACKUP_LOCK_WAIT)"
      return 1
    fi
    [ "${l_waited}" = 0 ] && log "waiting for the backup run going on (at most ${WAIT} s)"
    sleep 1
    l_waited=$((l_waited + 1))
  done
  LOCKED=1
  owner > "${LOCK}/owner"
}

unlock() {
  [ -z "${LOCKED}" ] || rm -rf "${LOCK}"
  LOCKED=
}

# one run, alone (lock): its result recorded, also when it could not start
run() {
  started=$(now_ms)
  if ! lock; then
    log "FAILED: ${LOCK_ERROR}" >&2
    state "${DIR}/.result-${SCOPE}" 0 "$(date +%s)"
    record "${SCOPE}" "${started}" "$(now_ms)" 0 0 "" "$(printf '%s' "${LOCK_ERROR}" | clean)"
    return 1
  fi
  run_alone
  r_rc=$?
  unlock
  return ${r_rc}
}

run_alone() {
  started=$(now_ms)
  # a run of the same second before (the names are by the second): the next one
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  while [ -e "${DIR}/${SCOPE}/${stamp}" ]; do
    sleep 1
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
  done
  out=${DIR}/${SCOPE}/${stamp}
  # what a stopped (SIGKILL) run left (with the lock, no other run is going on)
  rm -rf "${DIR}/${SCOPE}"/.*.partial 2> /dev/null
  PARTIAL=${DIR}/${SCOPE}/.${stamp}.partial
  mkdir -p "${PARTIAL}" || { PARTIAL=; state "${DIR}/.result-${SCOPE}" 0 "$(date +%s)"; record "${SCOPE}" "${started}" "$(now_ms)" 0 0 "" "cannot write to ${DIR}"; return 1; }
  errors=""
  if [ "${SCOPE}" = sync ] && [ "${TOKENSERVER_DB_TYPE:-mysql}" = postgres ]; then
    # tokenserver and storage share the database
    dump_postgres "${TOKENSERVER_DB_NAME}" "${PARTIAL}/${TOKENSERVER_DB_NAME}.sql.gz" > "${TMP}/msg" || errors="${errors}$(cat "${TMP}/msg"); "
    if [ -n "${ADMIN_DB_PASSWORD:-}" ]; then
      dump_postgres "${STATUS_DB}" "${PARTIAL}/${STATUS_DB}.sql.gz" "${STATUS_USER}" "${STATUS_PASSWORD}" "--clean --if-exists" > "${TMP}/msg" || errors="${errors}$(cat "${TMP}/msg"); "
    fi
  elif [ "${SCOPE}" = sync ]; then
    parts="tokenserver storage"
    [ -z "${STORAGE_DB_HOST:-}" ] && parts=tokenserver
    cnf "${TMP}/storage.cnf" "${STORAGE_DB_HOST:-}" "${STORAGE_DB_PORT:-3306}" "${STORAGE_DB_USER:-}" "${STORAGE_DB_PASSWORD:-}" > "${TMP}/msg" ||
      { errors="${errors}$(cat "${TMP}/msg"); "; parts=tokenserver; }
    for part in ${parts}; do
      eval "db=\${$(echo "${part}" | tr a-z A-Z)_DB_NAME}"
      dump_mysql "${TMP}/${part}.cnf" "${db}" "${PARTIAL}/${db}.sql.gz" > "${TMP}/msg" || errors="${errors}$(cat "${TMP}/msg"); "
    done
    # the event log and the audit trail, as the admin UI's user (status.cnf)
    if [ -n "${ADMIN_DB_PASSWORD:-}" ]; then
      dump_mysql "${TMP}/status.cnf" "${STATUS_DB}" "${PARTIAL}/${STATUS_DB}.sql.gz" > "${TMP}/msg" || errors="${errors}$(cat "${TMP}/msg"); "
    fi
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
    state "${DIR}/.result-${SCOPE}" 0 "$(date +%s)"
    record "${SCOPE}" "${started}" "$(now_ms)" 0 "${bytes}" "" "$(printf '%s' "${errors}" | clean)"
    return 1
  fi
  # the newest BACKUP_KEEP runs (the names sort by time), older ones go
  ls -1 "${DIR}/${SCOPE}" | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do
    rm -rf "${DIR:?}/${SCOPE}/${old}"
  done
  PARTIAL=
  log "ok: ${out}, ${bytes} bytes"
  state "${DIR}/.result-${SCOPE}" 1 "$(date +%s)"
  record "${SCOPE}" "${started}" "$(now_ms)" 1 "${bytes}" "${out}" ""
}

# (without them nothing can be recorded)
if [ "${SCOPE}" = sync ] && [ "${TOKENSERVER_DB_TYPE:-mysql}" != postgres ]; then
  cnf "${TMP}/tokenserver.cnf" "${TOKENSERVER_DB_HOST:-}" "${TOKENSERVER_DB_PORT:-3306}" "${TOKENSERVER_DB_USER:-}" "${TOKENSERVER_DB_PASSWORD:-}" > "${TMP}/msg" ||
    fail "$(cat "${TMP}/msg")"
  cnf "${TMP}/status.cnf" "${TOKENSERVER_DB_HOST:-}" "${TOKENSERVER_DB_PORT:-3306}" "${STATUS_USER}" "${STATUS_PASSWORD}" > "${TMP}/msg" ||
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
    since=$(date +%s)
    while :; do
      state "${DIR}/.loop-${SCOPE}" "${since}" "$(date +%s)"
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
  *) fail "usage: backup.sh now | loop | health" ;;
esac
