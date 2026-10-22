#!/bin/sh
# A mariadb-dump (or mysqldump) that fails with error 1412, as when a table changes while
# it dumps (FAKE_ERROR=1146: a table dropped after the dump listed it; a pg_dump: its error
# then), the first FAKE_1412 times it is called (tests/e2e.sh, put before the real one in
# PATH); then the real one
count=/tmp/ffs-1412/count
n=$(cat "${count}" 2> /dev/null || echo 0)
echo $((n + 1)) > "${count}"
name=$(basename "$0")
if [ "${n}" -lt "${FAKE_1412:-1}" ]; then
  if [ "${name}" = pg_dump ]; then
    printf '%s\n' 'pg_dump: error: query failed: ERROR:  relation "public.ffs_metrics" does not exist' \
      'pg_dump: detail: Query was: LOCK TABLE public.users, public.ffs_metrics IN ACCESS SHARE MODE' >&2
  elif [ "${FAKE_ERROR:-1412}" = 1146 ]; then
    echo "${name}: Couldn't execute 'SELECT /*!40001 SQL_NO_CACHE */ \`id\`, \`at\`, \`kind\`, \`detail\` FROM \`ffs_events\`': Table 'tokenserver.ffs_events' doesn't exist (1146)" >&2
  else
    echo "${name}: Error 1412: Table definition has changed, please retry transaction when dumping table \`ffs_events\` at row: 0" >&2
  fi
  exit 2
fi
exec "/usr/bin/${name}" "$@"
