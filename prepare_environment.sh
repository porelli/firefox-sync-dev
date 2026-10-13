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

# max users
DEFAULT_MAX_USERS=1
read -e -p "Max allowed users [${DEFAULT_MAX_USERS}]: " MAX_USERS
MAX_USERS=${MAX_USERS:-${DEFAULT_MAX_USERS}}

# database backend
DEFAULT_DATABASE_BACKEND=mariadb
read -e -p "Database backend [mariadb/postgres] [${DEFAULT_DATABASE_BACKEND}]: " DATABASE_BACKEND
DATABASE_BACKEND=${DATABASE_BACKEND:-${DEFAULT_DATABASE_BACKEND}}
case "${DATABASE_BACKEND}" in
    mariadb|postgres) ;;
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
    echo "  1) Quadlets (systemd integration, recommended, MariaDB only)"
    echo "  2) docker compose with the Podman socket"
    read -e -p "Deployment method [1]: " DEPLOY_METHOD
    case "${DEPLOY_METHOD:-1}" in
        1) DEPLOY_METHOD=quadlets ;;
        2) DEPLOY_METHOD=compose ;;
        *) echo "ERROR: unknown deployment method '${DEPLOY_METHOD}'"; exit 1 ;;
    esac
    if [ "${DEPLOY_METHOD}" = "quadlets" ] && [ "${DATABASE_BACKEND}" = "postgres" ]; then
        echo "WARNING: Quadlets are only provided for MariaDB, using docker compose with the Podman socket"
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

# random passwords
MARIADB_TOKENSERVER_PASSWORD=$(generate_random_string 24)
MARIADB_SYNCSTORAGE_PASSWORD=$(generate_random_string 24)
POSTGRES_PASSWORD=$(generate_random_string 24)
SYNC_MASTER_SECRET=$(generate_random_string 24)
METRICS_HASH_SECRET=$(generate_random_string 24)
ADMIN_PASSWORD=$(generate_random_string 24)

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
[ "${ADMIN_UI}" = "yes" ] && apply_sed ${SCRIPT_DIR}/.env "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=admin|"
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
    else
        COMPOSE_FILES=docker-compose.yml:docker-compose.fxa.yml
    fi
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
    mkdir -p "${QUADLET_DIR}"
    
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
    [ "${SELF_HOST_FXA}" = "yes" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/fxa")
    if [ "${ADMIN_UI}" = "yes" ]; then
        # with the accounts, the admin UI also manages them
        [ "${SELF_HOST_FXA}" = "yes" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/fxa/admin") || QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/admin")
    fi
    echo "Processing quadlet files..."
    for source in "${QUADLET_SOURCES[@]}"; do
        for file in "${source}"/*.{network,volume,container}; do
            [ -f "${file}" ] || continue
            filename=$(basename "${file}")
            render_quadlet "${file}" > "${QUADLET_DIR}/${filename}" || exit 1
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
    [ "${SELF_HOST_FXA}" = "yes" ] && COMPOSE_FILES="${COMPOSE_FILES} -f docker-compose.fxa.yml"
    echo "Next steps for docker compose with the Podman socket:"
    echo "  1. systemctl --user enable --now podman.socket"
    echo "  2. export DOCKER_HOST=unix://\${XDG_RUNTIME_DIR}/podman/podman.sock"
    echo "  3. docker compose ${COMPOSE_FILES} up -d"
    echo ""
    echo "See PODMAN.md for detailed instructions (podman-compose is not supported)"
else
    echo "Next steps:"
    echo "  1. docker compose up -d"
    [ "${SELF_HOST_FXA}" = "yes" ] && echo "     then in Firefox set identity.fxaccounts.autoconfig.uri to https://accounts.${FXA_DOMAIN} (see FXA.md)"
    echo "  2. (Optional) Install systemd service:"
    echo "     sudo cp config/systemd/syncstorage-rs.service /etc/systemd/system/"
    echo "     sudo systemctl enable --now syncstorage-rs.service"
fi

echo "=========================================="
