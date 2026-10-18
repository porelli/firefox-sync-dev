#!/bin/sh
# A mariadb-dump (or mysqldump) that fails with error 1412, as when a table changes while
# it dumps, the first FAKE_1412 times it is called (tests/e2e.sh, put before the real one
# in PATH); then the real one
count=/tmp/ffs-1412/count
n=$(cat "${count}" 2> /dev/null || echo 0)
echo $((n + 1)) > "${count}"
name=$(basename "$0")
if [ "${n}" -lt "${FAKE_1412:-1}" ]; then
  echo "${name}: Error 1412: Table definition has changed, please retry transaction when dumping table \`ffs_events\` at row: 0" >&2
  exit 2
fi
exec "/usr/bin/${name}" "$@"
