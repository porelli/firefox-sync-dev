#!/bin/sh
# The MariaDB and MySQL containers of the stack (the Sync databases, fxa-db) start through this,
# before the image's entrypoint: [sh, /ffs-db/keep-major.sh, <command>...]. Their images are
# mariadb:lts and mysql:lts by default, which move to the next long-term major by themselves;
# the server then upgrades the data at its start (MariaDB: MARIADB_AUTO_UPGRADE), with no way
# back but a backup (and the accounts' users of the installs from before, on
# mysql_native_password, cannot log in on MySQL 9 at all). So on data of another major than the
# server's, it does not start unless the image was chosen: FFS_MYSQL_IMAGE is the setting of
# .env (SYNC_MARIADB_IMAGE, SYNC_MYSQL_IMAGE, FXA_MARIADB_IMAGE, FXA_MYSQL_IMAGE), empty when it
# is not set (the default of the compose file); FFS_MYSQL_SETTING its name, for the message.
# A new database (no data yet), the same major, or a chosen image: the command as it is.
set -eu

data=/var/lib/mysql
if [ -z "${FFS_MYSQL_IMAGE:-}" ] && [ -d "${data}/mysql" ]; then
  if command -v mariadbd > /dev/null 2>&1; then
    # "mariadbd  Ver 12.3.3-MariaDB-ubu2404 for debian-linux-gnu ..."; the data: what
    # mariadb-install-db and mariadb-upgrade wrote, "11.8.9-MariaDB" (mysql_upgrade_info before 10.11)
    name=mariadb label=MariaDB
    server=$(mariadbd --version 2> /dev/null | sed -n 's/.* Ver \([0-9][0-9]*\)\..*/\1/p')
    was=$(cat "${data}/mariadb_upgrade_info" "${data}/mysql_upgrade_info" 2> /dev/null | tr -d '\0' | sed -n '1s/^\([0-9][0-9]*\)\..*/\1/p')
  else
    # "/usr/sbin/mysqld  Ver 9.7.2 for Linux on aarch64 (MySQL Community Server - GPL)"; the
    # versions that ran on this data (8.4 and later write them), before: 8.0 or older
    name=mysql label=MySQL
    server=$(mysqld --version 2> /dev/null | sed -n 's/.* Ver \([0-9][0-9]*\)\..*/\1/p')
    was=8
    if [ -f "${data}/mysql_upgrade_history" ]; then
      was=$(grep -o '"version" *: *"[0-9]*' "${data}/mysql_upgrade_history" | tail -n 1 | sed 's/.*"//')
    fi
  fi
  if [ -n "${server}" ] && [ -n "${was}" ] && [ "${server}" != "${was}" ]; then
    setting=${FFS_MYSQL_SETTING:-the image setting}
    echo "keep-major.sh: this database is ${label} ${was}, the image is ${label} ${server} (${setting} is not set in .env:" >&2
    echo "  the default, ${name}:lts). Not started: the server would upgrade the data to ${server} for good." >&2
    echo "  To stay on ${was}: ${setting}=${name}:${was} in .env (./prepare_environment.sh --upgrade writes it," >&2
    echo "  with what else the installs from before need). To move to ${server}: a backup first, then" >&2
    echo "  ${setting}=${name}:lts in .env (MySQL: MIGRATING.md#mysql-lts first)." >&2
    exit 1
  fi
fi
exec "$@"
