#!/bin/sh
# The stack's PostgreSQL container (postgres_db) starts through this, before the image's
# entrypoint: [sh, /ffs-db/keep-major.sh, docker-entrypoint.sh, postgres]. Without
# SYNC_POSTGRES_IMAGE in .env the image is postgres:latest, which moves to PostgreSQL's next
# major by itself, and no major opens another's data: the image's entrypoint then refuses to
# start. This says why and what to do, before it: FFS_POSTGRES_IMAGE is the setting of .env
# (empty when not set). A new database, the same major, or a chosen image: the command as it is.
set -eu

if [ -z "${FFS_POSTGRES_IMAGE:-}" ] && [ -n "${PG_MAJOR:-}" ] && [ ! -s "${PGDATA:-/nonexistent}/PG_VERSION" ]; then
  for f in /var/lib/postgresql/PG_VERSION /var/lib/postgresql/data/PG_VERSION /var/lib/postgresql/*/docker/PG_VERSION; do
    [ -s "${f}" ] || continue
    was=$(cat "${f}")
    [ "${was}" != "${PG_MAJOR}" ] || continue
    echo "keep-major.sh: this database is PostgreSQL ${was} (${f%/PG_VERSION}), the image is PostgreSQL ${PG_MAJOR}" >&2
    echo "  (SYNC_POSTGRES_IMAGE is not set in .env: the default, postgres:latest), which cannot open it." >&2
    echo "  Set SYNC_POSTGRES_IMAGE=postgres:${was} in .env (./prepare_environment.sh --upgrade writes it for the" >&2
    echo "  installs from before it). Moving to ${PG_MAJOR}: a dump and restore or pg_upgrade, DATABASES.md#another-postgresql-major" >&2
    exit 1
  done
fi
exec "$@"
