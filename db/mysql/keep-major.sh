#!/bin/sh
# The MySQL containers of the stack (fxa-db, and the Sync databases with SYNC_DB=mysql) start
# through this, before the image's entrypoint: [sh, /ffs-db/keep-major.sh, <command>...].
# The image is mysql:lts by default, which moves to MySQL's next major by itself; MySQL then
# upgrades the data at its start, with no way back but a backup (and the accounts' users of
# the installs from before, on mysql_native_password, cannot log in on MySQL 9 at all). So on
# data of another major than the server's, it does not start unless the image was chosen:
# FFS_MYSQL_IMAGE is the setting of .env (FXA_MYSQL_IMAGE, SYNC_MYSQL_IMAGE), empty when it
# is not set (the default of the compose file); FFS_MYSQL_SETTING its name, for the message.
# A new database (no data yet), the same major, or a chosen image: the command as it is.
set -eu

data=/var/lib/mysql
if [ -z "${FFS_MYSQL_IMAGE:-}" ] && [ -f "${data}/mysql.ibd" ]; then
  # "/usr/sbin/mysqld  Ver 9.7.2 for Linux on aarch64 (MySQL Community Server - GPL)"
  server=$(mysqld --version 2> /dev/null | sed -n 's/.* Ver \([0-9][0-9]*\)\..*/\1/p')
  # the versions that ran on this data (8.4 and later write it); before: 8.0 or older
  was=8
  if [ -f "${data}/mysql_upgrade_history" ]; then
    was=$(grep -o '"version" *: *"[0-9]*' "${data}/mysql_upgrade_history" | tail -n 1 | sed 's/.*"//')
  fi
  if [ -n "${server}" ] && [ -n "${was}" ] && [ "${server}" != "${was}" ]; then
    setting=${FFS_MYSQL_SETTING:-the image setting}
    echo "keep-major.sh: this database is MySQL ${was}, the image is MySQL ${server} (${setting} is not set in .env:" >&2
    echo "  the default, mysql:lts). Not started: MySQL would upgrade the data to ${server} for good." >&2
    echo "  To stay on ${was}: ${setting}=mysql:${was} in .env (./prepare_environment.sh --upgrade writes it," >&2
    echo "  with what else the installs from before need). To move to ${server}: MIGRATING.md#mysql-lts first," >&2
    echo "  then ${setting}=mysql:lts in .env." >&2
    exit 1
  fi
fi
exec "$@"
