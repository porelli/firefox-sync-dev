#!/bin/bash

# Firefox Sync Environment Preparation Script
# Supports both Docker and Podman

# Set the locale to UTF-8
export LC_CTYPE=C

# Detect container runtime
detect_runtime() {
    if command -v podman &> /dev/null; then
        echo "podman"
    elif command -v docker &> /dev/null; then
        echo "docker"
    else
        echo "none"
    fi
}

CONTAINER_RUNTIME=$(detect_runtime)

generate_random_string() {
  local length="${1}"
  tr -dc '[:alnum:]' < /dev/urandom | head -c "${length}"
}

apply_sed() {
    local file=${1}
    shift
    local expression=${@}

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        # macOS: BSD sed requires an empty string with -i option
        sed -i '' "${expression}" "${file}"
    else
        # Linux and other Unix-like systems: GNU sed does not require anything after -i
        sed -i "${expression}" "${file}"
    fi
}

# escape a value for the replacement part of `sed s|...|...|`
sed_escape() {
    printf '%s' "${1}" | sed -e 's/[\\/&|]/\\&/g'
}

# the SQL for your own database server, with the names and passwords of .env (DATABASES.md)
env_value() { grep "^${1}=" ${SCRIPT_DIR}/.env | cut -d= -f2-; }
render_sql() {
    local template=${1} out=${2} pair expressions=()
    shift 2
    for pair in "$@"; do
        expressions+=(-e "s|@${pair%%=*}@|$(sed_escape "${pair#*=}")|g")
    done
    rm -f "${out}"
    (umask 077; sed "${expressions[@]}" "${template}" > "${out}")
}
# database-setup.sql of the Sync databases and the admin UI's (postgres, or mariadb and mysql)
render_sync_sql() {
    if [ "${1}" = "postgres" ]; then
        render_sql ${SCRIPT_DIR}/config/database/sync-postgres.sql ${SCRIPT_DIR}/database-setup.sql \
            POSTGRES_DATABASE="$(env_value POSTGRES_DATABASE)" POSTGRES_USER="$(env_value POSTGRES_USER)" \
            POSTGRES_PASSWORD="$(env_value POSTGRES_PASSWORD)" ADMIN_DATABASE="$(env_value ADMIN_DB_NAME)" \
            ADMIN_USER="$(env_value ADMIN_DB_USER)" ADMIN_SYNC_USER="$(env_value ADMIN_DB_SYNC_USER)" ADMIN_PASSWORD="$(env_value ADMIN_DB_PASSWORD)"
    else
        render_sql ${SCRIPT_DIR}/config/database/sync-mariadb.sql ${SCRIPT_DIR}/database-setup.sql \
            TOKENSERVER_DATABASE="$(env_value MARIADB_TOKENSERVER_DATABASE)" TOKENSERVER_USER="$(env_value MARIADB_TOKENSERVER_USER)" \
            TOKENSERVER_PASSWORD="$(env_value MARIADB_TOKENSERVER_PASSWORD)" \
            SYNCSTORAGE_DATABASE="$(env_value MARIADB_SYNCSTORAGE_DATABASE)" SYNCSTORAGE_USER="$(env_value MARIADB_SYNCSTORAGE_USER)" \
            SYNCSTORAGE_PASSWORD="$(env_value MARIADB_SYNCSTORAGE_PASSWORD)" ADMIN_DATABASE="$(env_value ADMIN_DB_NAME)" \
            ADMIN_USER="$(env_value ADMIN_DB_USER)" ADMIN_SYNC_USER="$(env_value ADMIN_DB_SYNC_USER)" ADMIN_PASSWORD="$(env_value ADMIN_DB_PASSWORD)"
    fi
}

# ./prepare_environment.sh --upgrade: the .env of an install that runs (docker compose), given
# the settings of this release that need a value of their own (MIGRATING.md), nothing else
# changed: the admin UI's database users (ADMIN_DB_PASSWORD; the event log moves out of the
# Sync server's reach at the next start), the Sync server's own role in the PostgreSQL
# container (POSTGRES_SYNC_USER, POSTGRES_SYNC_PASSWORD). A value already set is kept; the
# old file is kept as .env.before-upgrade. With your own database server database-setup.sql
# is written again, to run there first. Quadlets: run this script again (MIGRATING.md).
upgrade_env() {
    local env_file name changed=()
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    env_file=${SCRIPT_DIR}/.env
    [ -f "${env_file}" ] || { echo "ERROR: no ${env_file} to upgrade: run ./prepare_environment.sh"; exit 1; }
    set_value() {
        if grep -q "^${1}=" "${env_file}"; then
            apply_sed "${env_file}" "s|^${1}=.*|${1}=$(sed_escape "${2}")|"
        else
            printf '%s=%s\n' "${1}" "${2}" >> "${env_file}"
        fi
        changed+=("${1}")
    }
    cp -p "${env_file}" "${env_file}.upgrading" || exit 1
    # the names: those of .env-example
    for name in ADMIN_DB_NAME ADMIN_DB_USER ADMIN_DB_SYNC_USER; do
        grep -q "^${name}=" "${env_file}" || set_value "${name}" "$(grep "^${name}=" "${SCRIPT_DIR}/.env-example" | cut -d= -f2-)"
    done
    [ -n "$(env_value ADMIN_DB_PASSWORD)" ] || set_value ADMIN_DB_PASSWORD "$(generate_random_string 32)"
    if [ "$(env_value SYNCSTORAGE_IMAGE)" = "syncstorage-rs-postgres" ] && [ "$(env_value DB_CONTAINERS)" != 0 ] && [ -z "$(env_value POSTGRES_SYNC_PASSWORD)" ]; then
        [ -n "$(env_value POSTGRES_SYNC_USER)" ] || set_value POSTGRES_SYNC_USER syncserver_app
        set_value POSTGRES_SYNC_PASSWORD "$(generate_random_string 32)"
    fi
    if [ "${#changed[@]}" = 0 ]; then
        rm -f "${env_file}.upgrading"
        echo "Nothing to add: ${env_file} has every setting of this release."
    else
        mv "${env_file}.upgrading" "${env_file}.before-upgrade"
        echo "Added to ${env_file} (the old one is .env.before-upgrade): ${changed[*]}"
    fi
    if [ "$(env_value DB_CONTAINERS)" = 0 ]; then
        [ "$(env_value SYNCSTORAGE_IMAGE)" = "syncstorage-rs-postgres" ] && render_sync_sql postgres || render_sync_sql mariadb
        echo "Your own database server: run database-setup.sql there first, as its administrator (DATABASES.md)."
    fi
    echo "Then: docker compose pull && docker compose up -d"
    exit 0
}
[ "${1:-}" = "--upgrade" ] && upgrade_env

# domain
DOMAIN_EXAMPLE='firefox-sync.example.com'
read -e -p "Enter FQDN for your Firefox sync server [${DOMAIN_EXAMPLE}]: " SYNCSTORAGE_DOMAIN
SYNCSTORAGE_DOMAIN=${SYNCSTORAGE_DOMAIN:-${DOMAIN_EXAMPLE}}

# compose dir
CURRENT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
read -e -p "Enter full path for the docker-compose file [${CURRENT_DIR}]: " SCRIPT_DIR
SCRIPT_DIR=${SCRIPT_DIR:-${CURRENT_DIR}}

# listening port
DEFAULT_CONTAINER_EXPORT_PORT=5000
read -e -p "Listening port for syncstorage-rs [${DEFAULT_CONTAINER_EXPORT_PORT}]: " CONTAINER_EXPORT_PORT
CONTAINER_EXPORT_PORT=${CONTAINER_EXPORT_PORT:-${DEFAULT_CONTAINER_EXPORT_PORT}}

# a limit of accounts: a number (0: nobody new) or unlimited
valid_limit() {
    case "${2}" in
        unlimited) ;;
        ''|*[!0-9]*) echo "ERROR: ${1} must be a number or unlimited, got '${2}'"; exit 1 ;;
        *) [ "${#2}" -le 10 ] && [ "${2}" -le 2147483647 ] || { echo "ERROR: ${1} must be at most 2147483647, got '${2}'"; exit 1; } ;;
    esac
}

# max users
DEFAULT_MAX_USERS=1
read -e -p "Max allowed users, a number or unlimited [${DEFAULT_MAX_USERS}]: " MAX_USERS
MAX_USERS=${MAX_USERS:-${DEFAULT_MAX_USERS}}
valid_limit "max users" "${MAX_USERS}"

# database backend
DEFAULT_DATABASE_BACKEND=mariadb
read -e -p "Database backend [mariadb/mysql/postgres] [${DEFAULT_DATABASE_BACKEND}]: " DATABASE_BACKEND
DATABASE_BACKEND=${DATABASE_BACKEND:-${DEFAULT_DATABASE_BACKEND}}
case "${DATABASE_BACKEND}" in
    mariadb|postgres) SYNC_DB=mariadb ;;
    # MySQL 8.4 containers (docker-compose.sync-mysql.yml), the same Sync images as MariaDB
    mysql|MySQL) DATABASE_BACKEND=mysql; SYNC_DB=mysql ;;
    *)
        echo "ERROR: unknown database backend '${DATABASE_BACKEND}'"
        exit 1
        ;;
esac

# Container runtime detection
echo ""
echo "Detected container runtime: ${CONTAINER_RUNTIME}"

if [ "${CONTAINER_RUNTIME}" = "none" ]; then
    echo "WARNING: Neither Docker nor Podman detected!"
    echo "Please install Docker or Podman before proceeding."
    read -e -p "Continue anyway? (y/N): " CONTINUE
    if [ "${CONTINUE}" != "y" ] && [ "${CONTINUE}" != "Y" ]; then
        exit 1
    fi
fi

# Ask about deployment method
if [ "${CONTAINER_RUNTIME}" = "podman" ]; then
    echo ""
    echo "Podman detected! Choose deployment method:"
    echo "  1) Quadlets (systemd integration, recommended, MariaDB and MySQL only)"
    echo "  2) docker compose with the Podman socket"
    read -e -p "Deployment method [1]: " DEPLOY_METHOD
    case "${DEPLOY_METHOD:-1}" in
        1) DEPLOY_METHOD=quadlets ;;
        2) DEPLOY_METHOD=compose ;;
        *) echo "ERROR: unknown deployment method '${DEPLOY_METHOD}'"; exit 1 ;;
    esac
    if [ "${DEPLOY_METHOD}" = "quadlets" ] && [ "${DATABASE_BACKEND}" = "postgres" ]; then
        echo "WARNING: Quadlets are only provided for MariaDB and MySQL, using docker compose with the Podman socket"
        DEPLOY_METHOD=compose
    fi
fi

# docker/podman user (for systemd service)
DEFAULT_CONTAINER_USER=${USER}
read -e -p "Container user [${DEFAULT_CONTAINER_USER}]: " CONTAINER_USER
CONTAINER_USER=${CONTAINER_USER:-${DEFAULT_CONTAINER_USER}}

# syncstorage image tag
DEFAULT_SYNCSTORAGE_IMAGE_TAG=latest
read -e -p "Syncstorage image tag [latest/<tag>] [${DEFAULT_SYNCSTORAGE_IMAGE_TAG}]: " SYNCSTORAGE_IMAGE_TAG
SYNCSTORAGE_IMAGE_TAG=${SYNCSTORAGE_IMAGE_TAG:-${DEFAULT_SYNCSTORAGE_IMAGE_TAG}}

# admin UI
read -r -e -p "Enable the admin UI? Max users, and sign-ups and accounts with self-hosted accounts, see ADMIN.md (Y/n): " ADMIN_UI
case "${ADMIN_UI}" in n|N|no) ADMIN_UI=no ;; *) ADMIN_UI=yes ;; esac
# with the admin UI, max users is managed there: MAX_USERS=initial:N sets it only on the
# first start. A plain number is set again on every start (read-only in the admin UI)
[ "${ADMIN_UI}" = "yes" ] && MAX_USERS=initial:${MAX_USERS}

# admin sign-in with the self-hosted accounts, asked below
ADMIN_ALLOWED_USERS=""
ADMIN_HOST=""

# self-hosted Mozilla accounts (experimental, docker compose only for now)
read -r -e -p "Also self-host Mozilla accounts? Experimental, see FXA.md (y/N): " SELF_HOST_FXA
case "${SELF_HOST_FXA}" in y|Y|yes) SELF_HOST_FXA=yes ;; *) SELF_HOST_FXA=no ;; esac
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    DEFAULT_FXA_DOMAIN=${SYNCSTORAGE_DOMAIN#*.}
    read -r -e -p "Domain for the accounts host names (accounts., api. and profile. are prepended) [${DEFAULT_FXA_DOMAIN}]: " FXA_DOMAIN
    FXA_DOMAIN=${FXA_DOMAIN:-${DEFAULT_FXA_DOMAIN}}
    read -r -e -p "SMTP server for the confirmation emails: " FXA_SMTP_HOST
    read -r -e -p "SMTP port [587]: " FXA_SMTP_PORT
    FXA_SMTP_PORT=${FXA_SMTP_PORT:-587}
    read -r -e -p "SMTP user: " FXA_SMTP_USER
    read -r -e -s -p "SMTP password: " FXA_SMTP_PASS
    echo ""
    case "${FXA_SMTP_PASS}" in *"'"*) echo "ERROR: the SMTP password cannot contain a single quote, set FXA_SMTP_PASS in .env by hand"; exit 1 ;; esac
    DEFAULT_FXA_SMTP_SENDER="Mozilla accounts <no-reply@${FXA_DOMAIN}>"
    read -r -e -p "Sender of the emails [${DEFAULT_FXA_SMTP_SENDER}]: " FXA_SMTP_SENDER
    FXA_SMTP_SENDER=${FXA_SMTP_SENDER:-${DEFAULT_FXA_SMTP_SENDER}}
    [ "${FXA_SMTP_PORT}" = "465" ] && FXA_SMTP_SECURE=true || FXA_SMTP_SECURE=false
    read -r -e -p "Who can create an account? Emails and @domains, comma-separated (empty: anybody): " FXA_SIGNUP_ALLOWLIST
    FXA_SIGNUP_ALLOWLIST=$(printf '%s' "${FXA_SIGNUP_ALLOWLIST}" | tr -d ' ')
    case "${FXA_SIGNUP_ALLOWLIST}" in *[!A-Za-z0-9@._+,-]*) echo "ERROR: not a list of emails and domains: ${FXA_SIGNUP_ALLOWLIST}"; exit 1 ;; esac
    [ -n "${FXA_SIGNUP_ALLOWLIST}" ] && FXA_SIGNUPS=allowlist || FXA_SIGNUPS=open
    # asked last, so that scripted answers for the questions above still line up
    if [ "${ADMIN_UI}" = "yes" ]; then
        read -r -e -p "Sign in to the admin UI with these accounts? Admin emails, comma-separated (empty: password only): " ADMIN_ALLOWED_USERS
        ADMIN_ALLOWED_USERS=$(printf '%s' "${ADMIN_ALLOWED_USERS}" | tr -d ' ')
        case "${ADMIN_ALLOWED_USERS}" in *[!A-Za-z0-9@._+,-]*) echo "ERROR: not a list of emails and domains: ${ADMIN_ALLOWED_USERS}"; exit 1 ;; esac
        if [ -n "${ADMIN_ALLOWED_USERS}" ]; then
            DEFAULT_ADMIN_HOST=admin.${FXA_DOMAIN}
            read -r -e -p "Host name of the admin UI, where the accounts pages send you back [${DEFAULT_ADMIN_HOST}]: " ADMIN_HOST
            ADMIN_HOST=${ADMIN_HOST:-${DEFAULT_ADMIN_HOST}}
            case "${ADMIN_HOST}" in *[!A-Za-z0-9.:-]*|"") echo "ERROR: not a host name: ${ADMIN_HOST}"; exit 1 ;; esac
        fi
    fi
fi

# your own database server (DATABASES.md), asked last so that scripted answers for the
# questions above still line up
EXTERNAL_DB=no
EXTERNAL_FXA_DB=no
FXA_DB=mysql
# names end up unquoted in SQL and in the database URLs
valid_name() { [[ "${1}" =~ ^[a-z_][a-z0-9_]{0,31}$ ]] || { echo "ERROR: not a valid database or user name (a-z, 0-9, _): '${1}'"; exit 1; }; }
# the containers reach the server over the network: localhost is the container itself
valid_host() {
    case "${1}" in
        "") echo "ERROR: the database host is required"; exit 1 ;;
        localhost|127.*|0.0.0.0)
            echo "ERROR: '${1}' would be the container itself: use an address of this host the containers"
            echo "  can reach (e.g. 172.17.0.1 for Docker, host.containers.internal for Podman), see DATABASES.md"
            exit 1 ;;
        # IPv6 literals would need [ ] in the database URLs, which not every client parses
        *:*) echo "ERROR: '${1}': use a host name or an IPv4 address (no IPv6 address)"; exit 1 ;;
        *[!A-Za-z0-9._-]*) echo "ERROR: not a host name: '${1}'"; exit 1 ;;
    esac
}
valid_port() { case "${1}" in ''|*[!0-9]*) echo "ERROR: not a port: '${1}'"; exit 1 ;; esac; }
read -r -e -p "Use an existing database server instead of starting one? See DATABASES.md (y/N): " EXTERNAL_DB
case "${EXTERNAL_DB}" in y|Y|yes) EXTERNAL_DB=yes ;; *) EXTERNAL_DB=no ;; esac
if [ "${EXTERNAL_DB}" = "yes" ]; then
    read -r -e -p "Database server host, as the containers reach it: " DB_HOST
    valid_host "${DB_HOST}"
    [ "${DATABASE_BACKEND}" = "postgres" ] && DEFAULT_DB_PORT=5432 || DEFAULT_DB_PORT=3306
    read -r -e -p "Database server port [${DEFAULT_DB_PORT}]: " DB_PORT
    DB_PORT=${DB_PORT:-${DEFAULT_DB_PORT}}
    valid_port "${DB_PORT}"
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        read -r -e -p "Database [syncserver]: " POSTGRES_DATABASE
        POSTGRES_DATABASE=${POSTGRES_DATABASE:-syncserver}
        read -r -e -p "Database user [syncserver]: " POSTGRES_USER
        POSTGRES_USER=${POSTGRES_USER:-syncserver}
        valid_name "${POSTGRES_DATABASE}"; valid_name "${POSTGRES_USER}"
    else
        read -r -e -p "Tokenserver database [tokenserver]: " MARIADB_TOKENSERVER_DATABASE
        MARIADB_TOKENSERVER_DATABASE=${MARIADB_TOKENSERVER_DATABASE:-tokenserver}
        read -r -e -p "Tokenserver database user [tokenserver]: " MARIADB_TOKENSERVER_USER
        MARIADB_TOKENSERVER_USER=${MARIADB_TOKENSERVER_USER:-tokenserver}
        read -r -e -p "Storage database [syncstorage]: " MARIADB_SYNCSTORAGE_DATABASE
        MARIADB_SYNCSTORAGE_DATABASE=${MARIADB_SYNCSTORAGE_DATABASE:-syncstorage}
        read -r -e -p "Storage database user [syncstorage]: " MARIADB_SYNCSTORAGE_USER
        MARIADB_SYNCSTORAGE_USER=${MARIADB_SYNCSTORAGE_USER:-syncstorage}
        for name in "${MARIADB_TOKENSERVER_DATABASE}" "${MARIADB_TOKENSERVER_USER}" "${MARIADB_SYNCSTORAGE_DATABASE}" "${MARIADB_SYNCSTORAGE_USER}"; do
            valid_name "${name}"
        done
        [ "${MARIADB_TOKENSERVER_DATABASE}" != "${MARIADB_SYNCSTORAGE_DATABASE}" ] || { echo "ERROR: the tokenserver and the storage need two databases"; exit 1; }
    fi
fi
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    read -r -e -p "Use an existing MySQL 8 or MariaDB 11.4-11.8 server for the accounts$([ "${EXTERNAL_DB}" = "yes" ] && echo " too")? See DATABASES.md (y/N): " EXTERNAL_FXA_DB
    case "${EXTERNAL_FXA_DB}" in y|Y|yes) EXTERNAL_FXA_DB=yes ;; *) EXTERNAL_FXA_DB=no ;; esac
    if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
        read -r -e -p "Accounts database server host${DB_HOST:+ [${DB_HOST}]}: " FXA_MYSQL_HOST
        FXA_MYSQL_HOST=${FXA_MYSQL_HOST:-${DB_HOST:-}}
        valid_host "${FXA_MYSQL_HOST}"
        read -r -e -p "Accounts database server port [3306]: " FXA_MYSQL_PORT
        FXA_MYSQL_PORT=${FXA_MYSQL_PORT:-3306}
        valid_port "${FXA_MYSQL_PORT}"
        read -r -e -p "Accounts database user [fxa]: " FXA_MYSQL_USER
        FXA_MYSQL_USER=${FXA_MYSQL_USER:-fxa}
        read -r -e -p "User installing the sign-up policy [ffs_policy]: " FXA_MYSQL_POLICY_USER
        FXA_MYSQL_POLICY_USER=${FXA_MYSQL_POLICY_USER:-ffs_policy}
        valid_name "${FXA_MYSQL_USER}"; valid_name "${FXA_MYSQL_POLICY_USER}"
    fi
    # MySQL by default, whatever Sync uses: it is what Mozilla supports and runs
    if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
        read -r -e -p "Is that server MySQL or MariaDB? (mysql/mariadb) [mysql]: " FXA_DB
    else
        read -r -e -p "Accounts database: mysql (MySQL 8.4, what Mozilla supports) or mariadb (MariaDB 11.8, see FXA.md) [mysql]: " FXA_DB
    fi
    case "${FXA_DB}" in
        ""|mysql|MySQL) FXA_DB=mysql ;;
        mariadb|MariaDB) FXA_DB=mariadb ;;
        *) echo "ERROR: mysql or mariadb, not '${FXA_DB}'"; exit 1 ;;
    esac
fi

# the most accounts of the self-hosted accounts, asked last so that scripted answers for
# the questions above still line up; with the admin UI it manages them (initial:)
FXA_MAX_ACCOUNTS=initial:unlimited
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    read -r -e -p "Max accounts that can be created on the accounts service, a number or unlimited [unlimited]: " FXA_MAX_ACCOUNTS
    FXA_MAX_ACCOUNTS=${FXA_MAX_ACCOUNTS:-unlimited}
    valid_limit "max accounts" "${FXA_MAX_ACCOUNTS}"
    [ "${ADMIN_UI}" = "yes" ] && FXA_MAX_ACCOUNTS=initial:${FXA_MAX_ACCOUNTS}
fi

# SYNC_DB=mysql: the Sync databases in MySQL containers; with your own server there are none,
# SYNC_DB then only says what it is
[ "${SYNC_DB}" = "mysql" ] && [ "${EXTERNAL_DB}" != "yes" ] && SYNC_COMPOSE_MYSQL=yes || SYNC_COMPOSE_MYSQL=no

# random passwords
MARIADB_TOKENSERVER_PASSWORD=$(generate_random_string 24)
MARIADB_SYNCSTORAGE_PASSWORD=$(generate_random_string 24)
POSTGRES_PASSWORD=$(generate_random_string 24)
SYNC_MASTER_SECRET=$(generate_random_string 24)
METRICS_HASH_SECRET=$(generate_random_string 24)
ADMIN_PASSWORD=$(generate_random_string 24)
ADMIN_DB_PASSWORD=$(generate_random_string 32)

# prepare .env file
cp ${SCRIPT_DIR}/.env-example ${SCRIPT_DIR}/.env
apply_sed ${SCRIPT_DIR}/.env "s|MARIADB_TOKENSERVER_PASSWORD=.*|MARIADB_TOKENSERVER_PASSWORD=${MARIADB_TOKENSERVER_PASSWORD}|"
apply_sed ${SCRIPT_DIR}/.env "s|MARIADB_SYNCSTORAGE_PASSWORD=.*|MARIADB_SYNCSTORAGE_PASSWORD=${MARIADB_SYNCSTORAGE_PASSWORD}|"
apply_sed ${SCRIPT_DIR}/.env "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|"
apply_sed ${SCRIPT_DIR}/.env "s|SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=${SYNC_MASTER_SECRET}|"
apply_sed ${SCRIPT_DIR}/.env "s|METRICS_HASH_SECRET=.*|METRICS_HASH_SECRET=${METRICS_HASH_SECRET}|"
apply_sed ${SCRIPT_DIR}/.env "s|SYNCSTORAGE_DOMAIN=.*|SYNCSTORAGE_DOMAIN=https://${SYNCSTORAGE_DOMAIN}|"
apply_sed ${SCRIPT_DIR}/.env "s|CONTAINER_EXPORT_PORT=.*|CONTAINER_EXPORT_PORT=${CONTAINER_EXPORT_PORT}|"
apply_sed ${SCRIPT_DIR}/.env "s|MAX_USERS=.*|MAX_USERS=${MAX_USERS}|"
apply_sed ${SCRIPT_DIR}/.env "s|SYNCSTORAGE_IMAGE_TAG=.*|SYNCSTORAGE_IMAGE_TAG=${SYNCSTORAGE_IMAGE_TAG}|"
apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PASSWORD}|"
# the admin UI's database user, also for the backups: with or without the admin UI
apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=${ADMIN_DB_PASSWORD}|"
[ "${ADMIN_UI}" = "yes" ] && apply_sed ${SCRIPT_DIR}/.env "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=admin|"
apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_DB=.*|SYNC_DB=${SYNC_DB}|"
if [ "${SYNC_COMPOSE_MYSQL}" = "yes" ]; then
    # MySQL's certificate is self-signed: the init container's client does not check it
    # (docker-compose.sync-mysql.yml does the same, this is for the Quadlets)
    apply_sed ${SCRIPT_DIR}/.env "s|^MARIADB_TLS_VERIFY=.*|MARIADB_TLS_VERIFY=false|"
    # with the accounts, set below with theirs
    [ "${SELF_HOST_FXA}" = "yes" ] || apply_sed ${SCRIPT_DIR}/.env "s|^# COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.yml:docker-compose.sync-mysql.yml|"
fi
if [ "${EXTERNAL_DB}" = "yes" ]; then
    apply_sed ${SCRIPT_DIR}/.env "s|^DB_CONTAINERS=.*|DB_CONTAINERS=0|"
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        for name in POSTGRES_DATABASE POSTGRES_USER; do
            apply_sed ${SCRIPT_DIR}/.env "s|^${name}=.*|${name}=${!name}|"
        done
        apply_sed ${SCRIPT_DIR}/.env "s|^POSTGRES_SERVER=.*|POSTGRES_SERVER=${DB_HOST}|"
        apply_sed ${SCRIPT_DIR}/.env "s|^POSTGRES_SERVER_PORT=.*|POSTGRES_SERVER_PORT=${DB_PORT}|"
    else
        # the init container's client checks the certificate by default, MySQL's is self-signed
        apply_sed ${SCRIPT_DIR}/.env "s|^MARIADB_TLS_VERIFY=.*|MARIADB_TLS_VERIFY=false|"
        for name in MARIADB_TOKENSERVER_DATABASE MARIADB_TOKENSERVER_USER MARIADB_SYNCSTORAGE_DATABASE MARIADB_SYNCSTORAGE_USER; do
            apply_sed ${SCRIPT_DIR}/.env "s|^${name}=.*|${name}=${!name}|"
        done
        for part in TOKENSERVER SYNCSTORAGE; do
            apply_sed ${SCRIPT_DIR}/.env "s|^MARIADB_${part}_SERVER=.*|MARIADB_${part}_SERVER=${DB_HOST}|"
            apply_sed ${SCRIPT_DIR}/.env "s|^MARIADB_${part}_SERVER_PORT=.*|MARIADB_${part}_SERVER_PORT=${DB_PORT}|"
        done
    fi
fi
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    for name in FXA_MYSQL_PASSWORD FXA_ADMIN_DB_PASSWORD FXA_AUTH_SECRET FXA_OAUTH_SECRET FXA_PROFILE_SECRET FXA_FLOW_ID_KEY FXA_SESSION_TOKEN_HANDLE_KEY FXA_CONTENT_SESSION_SECRET; do
        apply_sed ${SCRIPT_DIR}/.env "s|^${name}=.*|${name}=$(generate_random_string 32)|"
    done
    # the accounts images come from the same registry as the sync images, for this host's architecture
    FXA_REGISTRY=$(grep '^REPOSITORY=' ${SCRIPT_DIR}/.env | cut -d= -f2)
    case "$(uname -m)" in aarch64|arm64) FXA_ARCH=arm64 ;; *) FXA_ARCH=amd64 ;; esac
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_IMAGE=.*|FXA_IMAGE=${FXA_REGISTRY}|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_PAIRING_IMAGE=.*|FXA_PAIRING_IMAGE=${FXA_REGISTRY}:fxa-channelserver-latest|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_ARCH=.*|FXA_ARCH=${FXA_ARCH}|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_CONTENT_URL=.*|FXA_CONTENT_URL=https://accounts.${FXA_DOMAIN}|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_AUTH_URL=.*|FXA_AUTH_URL=https://api.${FXA_DOMAIN}|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_PROFILE_URL=.*|FXA_PROFILE_URL=https://profile.${FXA_DOMAIN}|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_OAUTH_SERVER_URL=.*|FXA_OAUTH_SERVER_URL=http://fxa-auth:9000/v1|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_EMAIL_DOMAIN=.*|FXA_EMAIL_DOMAIN=api.${FXA_DOMAIN}|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_SMTP_HOST=.*|FXA_SMTP_HOST=${FXA_SMTP_HOST}|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_SMTP_PORT=.*|FXA_SMTP_PORT=${FXA_SMTP_PORT}|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_SMTP_USER=.*|FXA_SMTP_USER='$(sed_escape "${FXA_SMTP_USER}")'|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_SMTP_PASS=.*|FXA_SMTP_PASS='$(sed_escape "${FXA_SMTP_PASS}")'|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_SMTP_SECURE=.*|FXA_SMTP_SECURE=${FXA_SMTP_SECURE}|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_SMTP_SENDER=.*|FXA_SMTP_SENDER=\"$(sed_escape "${FXA_SMTP_SENDER}")\"|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_SIGNUPS=.*|FXA_SIGNUPS=${FXA_SIGNUPS}|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_SIGNUP_ALLOWLIST=.*|FXA_SIGNUP_ALLOWLIST=${FXA_SIGNUP_ALLOWLIST}|"
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_MAX_ACCOUNTS=.*|FXA_MAX_ACCOUNTS=${FXA_MAX_ACCOUNTS}|"
    if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
        apply_sed ${SCRIPT_DIR}/.env "s|^FXA_DB_CONTAINERS=.*|FXA_DB_CONTAINERS=0|"
        for name in FXA_MYSQL_HOST FXA_MYSQL_PORT FXA_MYSQL_USER FXA_MYSQL_POLICY_USER; do
            apply_sed ${SCRIPT_DIR}/.env "s|^${name}=.*|${name}=${!name}|"
        done
        apply_sed ${SCRIPT_DIR}/.env "s|^FXA_MYSQL_POLICY_PASSWORD=.*|FXA_MYSQL_POLICY_PASSWORD=$(generate_random_string 32)|"
    fi
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_DB=.*|FXA_DB=${FXA_DB}|"
    if [ -n "${ADMIN_ALLOWED_USERS:-}" ]; then
        # the admin UI signs in with these accounts: a public OAuth client (PKCE, no secret:
        # the accounts service refuses PKCE from clients with one), registered by fxa-auth
        ADMIN_FXA_CLIENT_ID=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
        apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_FXA_CLIENT_ID=.*|ADMIN_FXA_CLIENT_ID=${ADMIN_FXA_CLIENT_ID}|"
        apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_ALLOWED_USERS=.*|ADMIN_ALLOWED_USERS=${ADMIN_ALLOWED_USERS}|"
        apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_OIDC_REDIRECT_URL=.*|ADMIN_OIDC_REDIRECT_URL=https://${ADMIN_HOST}/auth/callback|"
        # written out for the Quadlets too, which have no defaults like docker-compose.fxa.yml
        apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_OIDC_ISSUER=.*|ADMIN_OIDC_ISSUER=https://accounts.${FXA_DOMAIN}|"
        apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_OIDC_CLIENT_ID=.*|ADMIN_OIDC_CLIENT_ID=${ADMIN_FXA_CLIENT_ID}|"
        apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_OIDC_NAME=.*|ADMIN_OIDC_NAME=\"Mozilla account\"|"
        # the accounts service has no email_verified claim, but only lets confirmed
        # sessions through to the admin UI (SERVICES_WITH_EMAIL_VERIFICATION in fxa-auth)
        apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=.*|ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true|"
    fi
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        COMPOSE_FILES=docker-compose.postgres.yml:docker-compose.fxa.yml
    elif [ "${SYNC_COMPOSE_MYSQL}" = "yes" ]; then
        COMPOSE_FILES=docker-compose.yml:docker-compose.sync-mysql.yml:docker-compose.fxa.yml
    else
        COMPOSE_FILES=docker-compose.yml:docker-compose.fxa.yml
    fi
    [ "${FXA_DB}" = "mariadb" ] && COMPOSE_FILES="${COMPOSE_FILES}:docker-compose.fxa-mariadb.yml"
    apply_sed ${SCRIPT_DIR}/.env "s|# COMPOSE_FILE=.*|COMPOSE_FILE=${COMPOSE_FILES}|"
    # nginx example for the accounts host names
    cp ${SCRIPT_DIR}/config/nginx/fxa-example.conf ${SCRIPT_DIR}/config/nginx/fxa.conf
    apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<ACCOUNTS_HOST>|accounts.${FXA_DOMAIN}|g"
    apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<API_HOST>|api.${FXA_DOMAIN}|g"
    apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<PROFILE_HOST>|profile.${FXA_DOMAIN}|g"
    for port in CONTENT AUTH PROFILE PROFILE_STATIC PAIRING; do
        value=$(grep "^FXA_${port}_EXPORT_PORT=" ${SCRIPT_DIR}/.env | cut -d= -f2)
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<${port}_EXPORT_PORT>|${value}|g"
    done
    if [ "${ADMIN_UI}" = "yes" ]; then
        value=$(grep "^ADMIN_GATE_EXPORT_PORT=" ${SCRIPT_DIR}/.env | cut -d= -f2)
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<ADMIN_GATE_EXPORT_PORT>|${value}|g"
    else
        # no sign-up gate without the admin UI
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "/# admin UI only/,/^  }$/d"
    fi
    if [ -n "${ADMIN_ALLOWED_USERS:-}" ]; then
        value=$(grep "^ADMIN_EXPORT_PORT=" ${SCRIPT_DIR}/.env | cut -d= -f2)
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<ADMIN_HOST>|${ADMIN_HOST}|g"
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<ADMIN_EXPORT_PORT>|${value}|g"
    else
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "/# admin UI sign-in only/,/# end of the admin UI sign-in/d"
    fi
fi
if [ "${DATABASE_BACKEND}" = "postgres" ]; then
    [ "${SELF_HOST_FXA}" = "yes" ] || apply_sed ${SCRIPT_DIR}/.env "s|# COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.postgres.yml|"
    apply_sed ${SCRIPT_DIR}/.env "s|SYNCSTORAGE_IMAGE=.*|SYNCSTORAGE_IMAGE=syncstorage-rs-postgres|"
    apply_sed ${SCRIPT_DIR}/.env "s|SYNCSTORAGE_INIT_IMAGE=.*|SYNCSTORAGE_INIT_IMAGE=syncstorage-rs-postgres-init|"
    # the database container: the Sync server gets a role of its own, POSTGRES_USER is the
    # container's superuser (your own server: POSTGRES_USER is the plain owner, DATABASES.md)
    if [ "${EXTERNAL_DB}" != "yes" ]; then
        apply_sed ${SCRIPT_DIR}/.env "s|^POSTGRES_SYNC_USER=.*|POSTGRES_SYNC_USER=syncserver_app|"
        apply_sed ${SCRIPT_DIR}/.env "s|^POSTGRES_SYNC_PASSWORD=.*|POSTGRES_SYNC_PASSWORD=$(generate_random_string 32)|"
    fi
fi

# the SQL for your own database server, with the names and passwords of .env (DATABASES.md)
[ "${EXTERNAL_DB}" = "yes" ] && render_sync_sql "${DATABASE_BACKEND}"
if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
    render_sql ${SCRIPT_DIR}/config/database/fxa-${FXA_DB}.sql ${SCRIPT_DIR}/database-setup-fxa.sql \
        FXA_USER="$(env_value FXA_MYSQL_USER)" FXA_PASSWORD="$(env_value FXA_MYSQL_PASSWORD)" \
        FXA_POLICY_USER="$(env_value FXA_MYSQL_POLICY_USER)" FXA_POLICY_PASSWORD="$(env_value FXA_MYSQL_POLICY_PASSWORD)" \
        FXA_ADMIN_PASSWORD="$(env_value FXA_ADMIN_DB_PASSWORD)"
fi

# prepare nginx example
cp ${SCRIPT_DIR}/config/nginx/syncstorage-rs-example.conf ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf
apply_sed ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf "s/firefox-sync.example.com/${SYNCSTORAGE_DOMAIN}/g"
apply_sed ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf "s|<CONTAINER_EXPORT_PORT>|${CONTAINER_EXPORT_PORT}|"

# prepare systemd example (for docker compose; with Podman, Quadlets start at boot instead)
cp ${SCRIPT_DIR}/config/systemd/syncstorage-rs-example.service ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service
apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|<DOCKER_USER>|${CONTAINER_USER}|"
apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|<COMPOSE_DIR>|${SCRIPT_DIR}|"

# Setup Quadlets if requested
if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "quadlets" ]; then
    echo ""
    echo "Setting up Podman Quadlets..."
    
    QUADLET_DIR="${QUADLET_DIR:-${HOME}/.config/containers/systemd}"
    # timers are plain systemd units, not Quadlets
    SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user}"

    # load the generated values (database names, users, FxA endpoints, etc.); not with
    # `source`: unused sections keep placeholders like <REPLACE_WITH_...>, not shell
    while IFS= read -r line || [ -n "${line}" ]; do
        [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        key=${line%%=*}
        value=${line#*=}
        case "${value}" in
            \'*\') value=${value:1:${#value}-2} ;;
            \"*\") value=${value:1:${#value}-2} ;;
        esac
        export "${key}=${value}"
    done < ${SCRIPT_DIR}/.env
    mkdir -p "${QUADLET_DIR}" "${SYSTEMD_USER_DIR}"

    # the database containers: the .env names (syncstorage_db) are compose's, here the
    # containers are reached by their names. Your own server: none of them
    SKIP_UNITS=""
    DROP_DEPS=""
    if [ "${DB_CONTAINERS:-1}" = 0 ]; then
        SKIP_UNITS='^firefox-sync-(syncstorage|tokenserver)-db(-mysql)?\.(container|volume)$'
        DROP_DEPS='firefox-sync-(syncstorage|tokenserver)-db\.service'
    else
        export MARIADB_SYNCSTORAGE_SERVER=firefox-sync-syncstorage-db MARIADB_SYNCSTORAGE_SERVER_PORT=3306
        export MARIADB_TOKENSERVER_SERVER=firefox-sync-tokenserver-db MARIADB_TOKENSERVER_SERVER_PORT=3306
        if [ "${SYNC_DB:-mariadb}" = "mysql" ]; then
            # MariaDB's volumes, unused (the volumes themselves are kept); MySQL's certificate
            # is self-signed, the init container's client does not check it
            SKIP_UNITS='^firefox-sync-(syncstorage|tokenserver)-db\.volume$'
            export MARIADB_TLS_VERIFY=false
        fi
    fi
    if [ "${FXA_DB_CONTAINERS:-1}" = 0 ]; then
        SKIP_UNITS="${SKIP_UNITS:+${SKIP_UNITS}|}^firefox-sync-fxa-db(-mariadb)?\.(container|volume)$"
        DROP_DEPS="${DROP_DEPS:+${DROP_DEPS}|}firefox-sync-fxa-db\.service"
    elif [ "${FXA_DB:-mysql}" = "mariadb" ]; then
        # MySQL's volume, unused (the volume itself is kept)
        SKIP_UNITS="${SKIP_UNITS:+${SKIP_UNITS}|}^firefox-sync-fxa-db\.volume$"
    fi
    # Requires= on a unit that is not installed fails the start: drop those dependencies
    drop_deps() {
        [ -n "${DROP_DEPS}" ] || { cat; return; }
        sed -E -e "/^(After|Requires)=/{s/(=| )(${DROP_DEPS})/\1/g; s/= +/=/; s/ +$//; s/  +/ /g;}" -e '/^Requires=$/d'
    }
    
    # fill the %NAME% placeholders from .env (and SCRIPT_DIR); systemd expands %, double it
    render_quadlet() {
        local file=${1} content name value
        content=$(cat "${file}")
        for name in $(grep -o '%[A-Z][A-Z0-9_]*%' "${file}" | sort -u | tr -d '%'); do
            if [ -z "${!name+x}" ]; then
                echo "ERROR: ${file} needs ${name}, which is not set in .env" >&2
                return 1
            fi
            value=$(printf '%s' "${!name}" | sed -e 's/%/%%/g')
            content=$(printf '%s\n' "${content}" | sed -e "s|%${name}%|$(sed_escape "${value}")|g")
        done
        printf '%s\n' "${content}"
    }

    QUADLET_SOURCES=("${SCRIPT_DIR}/config/quadlet")
    # SYNC_DB=mysql: mysql/ replaces the database units of the same name (without the
    # database containers, SKIP_UNITS leaves them out)
    [ "${SYNC_DB:-mariadb}" = "mysql" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/mysql")
    [ "${SELF_HOST_FXA}" = "yes" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/fxa")
    # FXA_DB=mariadb: fxa/mariadb/ replaces the files of the same name in fxa/
    [ "${SELF_HOST_FXA}" = "yes" ] && [ "${FXA_DB:-mysql}" = "mariadb" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/fxa/mariadb")
    if [ "${ADMIN_UI}" = "yes" ]; then
        # with the accounts, the admin UI also manages them
        [ "${SELF_HOST_FXA}" = "yes" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/fxa/admin") || QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/admin")
    fi
    echo "Processing quadlet files..."
    for source in "${QUADLET_SOURCES[@]}"; do
        for file in "${source}"/*.{network,volume,container,timer}; do
            [ -f "${file}" ] || continue
            filename=$(basename "${file}")
            target_dir=${QUADLET_DIR}
            [[ "${filename}" == *.timer ]] && target_dir=${SYSTEMD_USER_DIR}
            [ "${FXA_DB:-mysql}" = "mariadb" ] && [ -f "${source}/mariadb/${filename}" ] && continue
            [ "${SYNC_DB:-mariadb}" = "mysql" ] && [ -f "${source}/mysql/${filename}" ] && continue
            if [ -n "${SKIP_UNITS}" ] && [[ "${filename}" =~ ${SKIP_UNITS} ]]; then
                # left from a setup with the database containers (the volume is kept)
                rm -f "${QUADLET_DIR}/${filename}"
                continue
            fi
            render_quadlet "${file}" | drop_deps > "${target_dir}/${filename}"
            [ "${PIPESTATUS[0]}" = 0 ] || exit 1
            echo "  ✓ ${filename}"
        done
    done
    
    echo ""
    echo "Reloading systemd daemon..."
    systemctl --user daemon-reload
fi

echo ""
echo "=========================================="
echo "Configuration complete!"
echo "=========================================="
echo ""
echo "Container Runtime: ${CONTAINER_RUNTIME}"
echo "Database Backend: ${DATABASE_BACKEND}"
echo "Configuration files created:"
echo "  - .env"
[ "${EXTERNAL_DB}" = "yes" ] && echo "  - database-setup.sql (the databases and users for your server)"
[ "${EXTERNAL_FXA_DB}" = "yes" ] && echo "  - database-setup-fxa.sql (the accounts users for your $([ "${FXA_DB}" = "mariadb" ] && echo MariaDB || echo MySQL) server)"
echo "  - config/nginx/syncstorage-rs.conf"
echo "  - config/systemd/syncstorage-rs.service"
[ "${SELF_HOST_FXA}" = "yes" ] && echo "  - config/nginx/fxa.conf (accounts.${FXA_DOMAIN}, api.${FXA_DOMAIN}, profile.${FXA_DOMAIN}${ADMIN_HOST:+, ${ADMIN_HOST}})"

if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "quadlets" ]; then
    echo "  - Quadlet files in ${QUADLET_DIR}"
fi
if [ "${ADMIN_UI}" = "yes" ]; then
    echo ""
    echo "Admin UI: http://localhost:8090 on this host (over SSH: ssh -L 8090:127.0.0.1:8090 <host>),"
    echo "  password: ADMIN_PASSWORD in .env. See ADMIN.md"
    [ -n "${ADMIN_ALLOWED_USERS:-}" ] && echo "  or https://${ADMIN_HOST}, signed in with the accounts of ${ADMIN_ALLOWED_USERS}"
fi

echo ""

# your own database server: what to run there first
if [ "${EXTERNAL_DB}" = "yes" ]; then
    echo "First, on your database server (see DATABASES.md):"
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        echo "  psql -h ${DB_HOST} -p ${DB_PORT} -U postgres -f database-setup.sql"
        echo "  pg_hba.conf: a host line (not hostssl) for the containers' addresses, scram-sha-256"
    else
        echo "  MySQL:   mysql -h ${DB_HOST} -P ${DB_PORT} -u root -p < database-setup.sql"
        echo "  MariaDB: mariadb -h ${DB_HOST} -P ${DB_PORT} -u root -p < database-setup.sql"
        echo "  with binary logging (MySQL's default): log_bin_trust_function_creators=ON"
        echo "  plain connections allowed (require_secure_transport=OFF): the Sync server has no TLS"
    fi
fi
if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
    [ "${EXTERNAL_DB}" = "yes" ] || echo "First, on your database server (see DATABASES.md):"
    if [ "${FXA_DB}" = "mariadb" ]; then
        echo "  mariadb -h ${FXA_MYSQL_HOST} -P ${FXA_MYSQL_PORT} -u root -p < database-setup-fxa.sql"
        echo "  MariaDB 11.4 to 11.8 (not 12), with binary logging: log_bin_trust_function_creators=ON"
    else
        echo "  mysql -h ${FXA_MYSQL_HOST} -P ${FXA_MYSQL_PORT} -u root -p < database-setup-fxa.sql"
        echo "  MySQL 8.4 started with mysql_native_password=ON and log_bin_trust_function_creators=ON"
    fi
fi
[ "${EXTERNAL_DB}" = "yes" ] || [ "${EXTERNAL_FXA_DB}" = "yes" ] && echo ""

if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "quadlets" ]; then
    echo "Next steps for Quadlet deployment:"
    # the admin UI first: the Sync server sends its metrics only if it runs then
    if [ "${ADMIN_UI}" = "yes" ]; then
        echo "  1. systemctl --user start firefox-sync-admin.service firefox-sync-syncstorage.service"
    else
        echo "  1. systemctl --user start firefox-sync-syncstorage.service"
    fi
    if [ "${SELF_HOST_FXA}" = "yes" ]; then
        echo "     systemctl --user start firefox-sync-fxa-content.service firefox-sync-fxa-profile.service \\"
        echo "       firefox-sync-fxa-profile-worker.service firefox-sync-fxa-profile-static.service"
        echo "     then in Firefox set identity.fxaccounts.autoconfig.uri to https://accounts.${FXA_DOMAIN} (see FXA.md)"
    fi
    echo "  2. (Optional) loginctl enable-linger \$USER"
    echo "  3. (Optional) nightly backups: systemctl --user enable --now firefox-sync-backup.timer (ADMIN.md#backups)"
    echo ""
    echo "To check status:"
    echo "  systemctl --user status firefox-sync-syncstorage.service"
    echo ""
    echo "See PODMAN.md for detailed instructions"
elif [ "${CONTAINER_RUNTIME}" = "podman" ]; then
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        COMPOSE_FILES="-f docker-compose.postgres.yml"
    else
        COMPOSE_FILES="-f docker-compose.yml -f docker-compose.podman.yml"
    fi
    [ "${SYNC_COMPOSE_MYSQL}" = "yes" ] && COMPOSE_FILES="${COMPOSE_FILES} -f docker-compose.sync-mysql.yml"
    [ "${SELF_HOST_FXA}" = "yes" ] && COMPOSE_FILES="${COMPOSE_FILES} -f docker-compose.fxa.yml"
    [ "${SELF_HOST_FXA}" = "yes" ] && [ "${FXA_DB}" = "mariadb" ] && COMPOSE_FILES="${COMPOSE_FILES} -f docker-compose.fxa-mariadb.yml"
    echo "Next steps for docker compose with the Podman socket:"
    echo "  1. systemctl --user enable --now podman.socket"
    echo "  2. export DOCKER_HOST=unix://\${XDG_RUNTIME_DIR}/podman/podman.sock"
    echo "  3. docker compose ${COMPOSE_FILES} up -d"
    echo "  (Optional) nightly backups: add backup to COMPOSE_PROFILES in .env (ADMIN.md#backups)"
    echo ""
    echo "See PODMAN.md for detailed instructions (podman-compose is not supported)"
else
    echo "Next steps:"
    echo "  1. docker compose up -d"
    [ "${SELF_HOST_FXA}" = "yes" ] && echo "     then in Firefox set identity.fxaccounts.autoconfig.uri to https://accounts.${FXA_DOMAIN} (see FXA.md)"
    echo "  (Optional) nightly backups: add backup to COMPOSE_PROFILES in .env (ADMIN.md#backups)"
    echo "  2. (Optional) Install systemd service:"
    echo "     sudo cp config/systemd/syncstorage-rs.service /etc/systemd/system/"
    echo "     sudo systemctl enable --now syncstorage-rs.service"
fi

echo "=========================================="
