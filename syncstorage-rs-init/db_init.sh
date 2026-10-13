#!/bin/bash
set -e  # Exit on error
set -u  # Exit on undefined variable

# Configuration
readonly MAX_WAIT=120  # Wait up to 2 minutes
readonly SLEEP_INTERVAL=2
readonly REQUIRED_TABLES=("users" "services" "nodes")
readonly SQL_TEMPLATE="/scripts/db_init.sql"
readonly SQL_FILE="/tmp/db_init_processed.sql"

echo "=========================================="
echo "Firefox Sync Database Initialization"
echo "=========================================="
echo "Domain: ${DOMAIN}"
echo "Max Users: ${MAX_USERS:-}"
echo "Database: ${MARIADB_DATABASE}"
echo "=========================================="

# MAX_USERS: N or fixed:N is applied on every start (the admin UI shows it read-only),
# initial:N only when there is no limit yet (first start), then it is managed in the
# admin UI. Anything else stops here: the stack must not start with a broken limit.
parse_max_users() {
  local value=$1 number
  case "${value}" in
    initial:*) MAX_USERS_MODE=initial; number=${value#initial:} ;;
    fixed:*)   MAX_USERS_MODE=fixed;   number=${value#fixed:} ;;
    *)         MAX_USERS_MODE=fixed;   number=${value} ;;
  esac
  case "${number}" in ''|*[!0-9]*) return 1 ;; esac
  # no leading zeros, and it must fit the INT the triggers read it into
  number=${number#"${number%%[!0]*}"}
  number=${number:-0}
  [ "${#number}" -le 10 ] && [ "${number}" -le 2147483647 ] || return 1
  MAX_USERS_VALUE=${number}
}

if ! parse_max_users "${MAX_USERS:-}"; then
  echo "✗ ERROR: MAX_USERS='${MAX_USERS:-}' is not valid: use a number from 0 to 2147483647,"
  echo "  optionally prefixed with fixed: (the default, applied on every start) or"
  echo "  initial: (applied on the first start only, then managed in the admin UI)"
  exit 1
fi
[ "${MAX_USERS_MODE}" = fixed ] && MAX_USERS_FIXED=1 || MAX_USERS_FIXED=0

# MARIADB_TLS_VERIFY=false: MySQL's certificate is self-signed, which this client refuses
# by default; syncstorage-rs itself connects without TLS (DATABASES.md)
TLS_ARGS=()
[ "${MARIADB_TLS_VERIFY:-true}" = false ] && TLS_ARGS=(--skip-ssl-verify-server-cert)
db() {
  mariadb --host="${MARIADB_SERVER}" \
          --port="${MARIADB_SERVER_PORT}" \
          --user="${MARIADB_USER}" \
          --password="${MARIADB_PASSWORD}" \
          "${TLS_ARGS[@]}" \
          "$@"
}

# Function to check if database is accessible
check_db_connection() {
  db --connect-timeout=5 -e "SELECT 1;" >/dev/null 2>&1
}

# Function to check if a table exists
table_exists() {
  local table_name="$1"
  local count
  count=$(db "${MARIADB_DATABASE}" -sN \
                   -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MARIADB_DATABASE}' AND table_name='${table_name}';" 2>/dev/null || echo "0")
  [ "${count}" = "1" ]
}

# Wait for database connection
echo "Checking database connection..."
WAIT_COUNT=0
while [ ${WAIT_COUNT} -lt ${MAX_WAIT} ]; do
  if check_db_connection; then
    echo "✓ Database connection established!"
    break
  fi
  echo "  Waiting for database... (${WAIT_COUNT}/${MAX_WAIT}s)"
  sleep ${SLEEP_INTERVAL}
  ((WAIT_COUNT+=SLEEP_INTERVAL))
done

if [ ${WAIT_COUNT} -ge ${MAX_WAIT} ]; then
  echo "✗ ERROR: Timeout waiting for database connection"
  exit 1
fi

# Wait for required tables to be created by syncstorage migrations
echo ""
echo "Waiting for syncstorage migrations to create tables..."
WAIT_COUNT=0

while [ ${WAIT_COUNT} -lt ${MAX_WAIT} ]; do
  all_tables_exist=true
  missing_tables=""
  
  for table in "${REQUIRED_TABLES[@]}"; do
    if ! table_exists "${table}"; then
      all_tables_exist=false
      missing_tables="${missing_tables} ${table}"
    fi
  done
  
  if [ "${all_tables_exist}" = true ]; then
    echo "✓ All required tables found!"
    break
  fi
  
  echo "  Missing tables:${missing_tables} (${WAIT_COUNT}/${MAX_WAIT}s)"
  sleep ${SLEEP_INTERVAL}
  ((WAIT_COUNT+=SLEEP_INTERVAL))
done

if [ ${WAIT_COUNT} -ge ${MAX_WAIT} ]; then
  echo "✗ ERROR: Timeout waiting for tables to be created"
  echo "  Missing tables:${missing_tables}"
  exit 1
fi

# Process SQL template with environment variables
echo ""
echo "Processing SQL template..."
sed -e "s|@DOMAIN@|${DOMAIN}|g" \
    -e "s|@MAX_USERS@|${MAX_USERS_VALUE}|g" \
    -e "s|@MAX_USERS_FIXED@|${MAX_USERS_FIXED}|g" \
    "${SQL_TEMPLATE}" > "${SQL_FILE}"

# Apply SQL initialization
echo "Applying database initialization..."
if db "${MARIADB_DATABASE}" < "${SQL_FILE}"; then
  echo "✓ SQL initialization completed successfully!"
else
  echo "✗ ERROR: Failed to apply SQL initialization"
  exit 1
fi

# Display current status
current_users=$(db "${MARIADB_DATABASE}" -sN -e 'SELECT COUNT(DISTINCT email) FROM users;')

max_users_in_db=$(db "${MARIADB_DATABASE}" -sN -e "SELECT config_value FROM config WHERE config_key='max_users';")

echo ""
echo "=========================================="
echo "✓ Database initialization completed!"
echo "=========================================="
echo "Current users: ${current_users}"
echo "Max users (configured): ${max_users_in_db}"
echo "Domain: ${DOMAIN}"
echo ""
if [ "${MAX_USERS_MODE}" = fixed ]; then
  echo "MAX_USERS=${MAX_USERS}: applied on every start, read-only in the admin UI."
  echo "  To manage it in the admin UI (ADMIN.md) set MAX_USERS=initial:${MAX_USERS_VALUE} in .env."
else
  echo "MAX_USERS=${MAX_USERS}: applied only when there was no limit yet (first start),"
  echo "  change it in the admin UI (ADMIN.md). A plain MAX_USERS=N in .env sets it on every start."
fi
[ "${max_users_in_db}" = "${MAX_USERS_VALUE}" ] || echo "  Kept the value in the database, set in the admin UI."
echo "After changing MAX_USERS in .env:"
echo "  docker compose up -d   (the init container and the admin UI)"
echo "  (Quadlets: systemctl --user restart firefox-sync-tokenserver-db-init.service firefox-sync-admin.service)"
echo "=========================================="

exit 0