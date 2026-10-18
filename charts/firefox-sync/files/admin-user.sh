#!/bin/sh
# The admin UI's user in the MariaDB and MySQL containers of the stack (DATABASES.md), run
# as their command before the image's entrypoint: [sh, /ffs-db/admin-user.sh, mariadbd, ...].
# It writes the statements below into a file the server runs at every start with all
# privileges (--init-file, also on the first start and on the volumes of an install from
# before, whose root password is random and unknown): no administrator password anywhere.
#
#   ADMIN_DB_ROLE=tokenserver  the database ADMIN_DB_NAME (ffs_admin: the event log, the audit
#                              trail, the notes...), only for ADMIN_DB_USER (also DROP and
#                              LOCK TABLES there: a restore of its dump); for ADMIN_DB_SYNC_USER
#                              on the tokenserver database SELECT, and EXECUTE for the
#                              procedures of the init container (max users, rows of users)
#   ADMIN_DB_ROLE=storage      for ADMIN_DB_SYNC_USER on the storage database SELECT and DELETE
#                              (sizes, purges, resets)
#
# Two users, with ADMIN_DB_PASSWORD: what the Sync server's user puts in its databases
# (procedures, views, functions with SQL SECURITY INVOKER) runs as the one that reads them,
# which has nothing on ADMIN_DB_NAME. The Sync server's users get nothing here. Without
# ADMIN_DB_PASSWORD (an install from before it) nothing is created: the admin UI keeps its
# tables in the tokenserver database.
set -eu

if [ -n "${ADMIN_DB_PASSWORD:-}" ]; then
  user=${ADMIN_DB_USER:-ffs_admin_ui} reader=${ADMIN_DB_SYNC_USER:-ffs_admin_sync}
  # the images' own setting of the Sync database
  sync_db=${MARIADB_DATABASE:-${MYSQL_DATABASE:-}}
  fail() { echo "admin-user.sh: $*" >&2; exit 1; }
  # they end up in SQL: names and passwords as DATABASES.md allows them
  for name in "${user}" "${reader}" "${sync_db}" ${ADMIN_DB_NAME:+"${ADMIN_DB_NAME}"}; do
    printf '%s' "${name}" | grep -Eqx '[a-z_][a-z0-9_]{0,31}' || fail "not a database or user name (a-z, 0-9, _): '${name}'"
  done
  [ "${user}" != "${reader}" ] || fail "ADMIN_DB_USER and ADMIN_DB_SYNC_USER must be two users"
  printf '%s' "${ADMIN_DB_PASSWORD}" | grep -Eqx '[A-Za-z0-9._~-]+' || fail "ADMIN_DB_PASSWORD: only A-Z a-z 0-9 . _ ~ -"
  # (again with a new password: ADMIN_DB_PASSWORD changed in .env)
  account() {
    printf '%s\n' "CREATE USER IF NOT EXISTS '$1'@'%' IDENTIFIED BY '${ADMIN_DB_PASSWORD}';" "ALTER USER '$1'@'%' IDENTIFIED BY '${ADMIN_DB_PASSWORD}';"
  }
  case "${ADMIN_DB_ROLE:-}" in
    tokenserver)
      db=${ADMIN_DB_NAME:-ffs_admin}
      [ "${db}" != "${sync_db}" ] || fail "ADMIN_DB_NAME must not be the tokenserver database"
      statements="$(account "${user}")
$(account "${reader}")
CREATE DATABASE IF NOT EXISTS \`${db}\`;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, LOCK TABLES ON \`${db}\`.* TO '${user}'@'%';
GRANT SELECT, EXECUTE ON \`${sync_db}\`.* TO '${reader}'@'%';" ;;
    storage)
      statements="$(account "${reader}")
GRANT SELECT, DELETE ON \`${sync_db}\`.* TO '${reader}'@'%';" ;;
    *) fail "ADMIN_DB_ROLE must be tokenserver or storage" ;;
  esac
  # readable by the server only: it runs as mysql, this as root
  umask 077
  mkdir -p /run/ffs-admin
  printf '%s\n' "${statements}" > /run/ffs-admin/init.sql
  chown -R mysql:mysql /run/ffs-admin
  set -- "$@" --init-file=/run/ffs-admin/init.sql
fi
exec docker-entrypoint.sh "$@"
