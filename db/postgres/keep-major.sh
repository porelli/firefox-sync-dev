#!/bin/sh
# The stack's PostgreSQL container (postgres_db) starts through this, before the image's
# entrypoint: [sh, /ffs-db/keep-major.sh, docker-entrypoint.sh, postgres]. No major opens
# another's data, and the official image keeps it in /var/lib/postgresql/<major>/docker: an
# image of another major (postgres:latest moving on, or another pin) finds no data of its own.
# Its entrypoint then refuses to start (checked with postgres:19rc1 on 18's data: exit 1, an
# empty 19/docker left), with a long text; this stops first, whatever the image setting says,
# and says what to set or how to move. The data of the image's major there, or none at all (a
# new database): the command as it is.
set -eu

if [ -n "${PG_MAJOR:-}" ] && [ ! -s "${PGDATA:-/nonexistent}/PG_VERSION" ]; then
  for f in /var/lib/postgresql/PG_VERSION /var/lib/postgresql/data/PG_VERSION /var/lib/postgresql/*/docker/PG_VERSION; do
    [ -s "${f}" ] || continue
    was=$(cat "${f}")
    [ "${was}" != "${PG_MAJOR}" ] || continue
    # FFS_POSTGRES_SETTING: where the image is chosen (compose: SYNC_POSTGRES_IMAGE in .env, the
    # Helm chart: database.image.postgres)
    setting=${FFS_POSTGRES_SETTING:-SYNC_POSTGRES_IMAGE}
    echo "keep-major.sh: this database is PostgreSQL ${was} (${f%/PG_VERSION}), the image is PostgreSQL ${PG_MAJOR}," >&2
    echo "  which cannot open it (${setting}: ${FFS_POSTGRES_IMAGE:-not set, postgres:latest}). Not started." >&2
    echo "  Set ${setting} to the major of the data, postgres:${was}. Moving to ${PG_MAJOR}: a dump and restore or" >&2
    echo "  pg_upgrade (docs/upgrading.md#postgresql)." >&2
    exit 1
  done
fi
exec "$@"
