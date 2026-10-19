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

# The Sync server's settings, renamed to the SYNC_ prefix (MIGRATING.md#renamed-settings):
# new=old. The old names still work, compose and the Quadlets read them when the new one is
# not set, and will be removed in a later release; --upgrade renames them in .env
RENAMED_SETTINGS=(
    SYNC_TOKENSERVER_DB_NAME=MARIADB_TOKENSERVER_DATABASE
    SYNC_TOKENSERVER_DB_USER=MARIADB_TOKENSERVER_USER
    SYNC_TOKENSERVER_DB_PASSWORD=MARIADB_TOKENSERVER_PASSWORD
    SYNC_TOKENSERVER_DB_HOST=MARIADB_TOKENSERVER_SERVER
    SYNC_TOKENSERVER_DB_PORT=MARIADB_TOKENSERVER_SERVER_PORT
    SYNC_STORAGE_DB_NAME=MARIADB_SYNCSTORAGE_DATABASE
    SYNC_STORAGE_DB_USER=MARIADB_SYNCSTORAGE_USER
    SYNC_STORAGE_DB_PASSWORD=MARIADB_SYNCSTORAGE_PASSWORD
    SYNC_STORAGE_DB_HOST=MARIADB_SYNCSTORAGE_SERVER
    SYNC_STORAGE_DB_PORT=MARIADB_SYNCSTORAGE_SERVER_PORT
    SYNC_POSTGRES_NAME=POSTGRES_DATABASE
    SYNC_POSTGRES_USER=POSTGRES_USER
    SYNC_POSTGRES_PASSWORD=POSTGRES_PASSWORD
    SYNC_POSTGRES_HOST=POSTGRES_SERVER
    SYNC_POSTGRES_PORT=POSTGRES_SERVER_PORT
    SYNC_POSTGRES_APP_USER=POSTGRES_SYNC_USER
    SYNC_POSTGRES_APP_PASSWORD=POSTGRES_SYNC_PASSWORD
    SYNC_POSTGRES_IMAGE=POSTGRES_IMAGE
    SYNC_DB_TLS_VERIFY=MARIADB_TLS_VERIFY
    SYNC_DB_CONTAINERS=DB_CONTAINERS
    SYNC_MAX_USERS=MAX_USERS
    SYNC_EXPORT_PORT=CONTAINER_EXPORT_PORT
    SYNC_PUBLIC_URL=SYNCSTORAGE_DOMAIN
    SYNC_METRICS_HASH_SECRET=METRICS_HASH_SECRET
    IMAGE_REPOSITORY=REPOSITORY
    SYNC_IMAGE=SYNCSTORAGE_IMAGE
    SYNC_IMAGE_TAG=SYNCSTORAGE_IMAGE_TAG
    SYNC_INIT_IMAGE=SYNCSTORAGE_INIT_IMAGE
    SYNC_INIT_IMAGE_TAG=SYNCSTORAGE_INIT_IMAGE_TAG
)
# the old name of a renamed setting ("" for the others)
old_name() {
    local pair
    for pair in "${RENAMED_SETTINGS[@]}"; do
        [ "${pair%%=*}" = "${1}" ] && { printf '%s' "${pair#*=}"; return; }
    done
}

# a value of .env, as it is written (not with `source`: it is no shell script); env_value
# of a renamed setting reads the old name when the new one is not set, as compose does
# (a line of compose's .env may be indented or start with export; CRLF line ends)
ENV_LEAD='[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}'
env_line() { grep "^${ENV_LEAD}${1}=" ${SCRIPT_DIR}/.env | sed -e "s/^[^=]*=//" | tr -d '\r'; }
env_has() { grep -q "^${ENV_LEAD}${1}=" ${SCRIPT_DIR}/.env; }
# the value as compose reads it: the last line; quoted, what is between the quotes (a
# comment after them dropped), otherwise without a comment ( # ...) and the spaces around
env_plain() {
    local v q
    v=$(env_line "${1}" | tail -n 1)
    v=${v#"${v%%[![:space:]]*}"}
    case "${v}" in
        \'*|\"*)
            q=${v:0:1} v=${v:1}
            case "${v}" in *"${q}"*) v=${v%%"${q}"*} ;; esac ;;
        *)
            v=$(printf '%s' "${v}" | sed -e 's/[[:space:]]#.*$//')
            v=${v%"${v##*[![:space:]]}"} ;;
    esac
    printf '%s' "${v}"
}
env_value() {
    local value old
    value=$(env_line "${1}")
    old=$(old_name "${1}")
    [ -z "$(env_plain "${1}")" ] && [ -n "${old}" ] && value=$(env_line "${old}")
    printf '%s\n' "${value}"
}
# the SQL for your own database server, with the names and passwords of .env (DATABASES.md)
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
        render_sql ${SCRIPT_DIR}/db/postgres/sync.sql ${SCRIPT_DIR}/database-setup.sql \
            SYNC_POSTGRES_DATABASE="$(env_value SYNC_POSTGRES_NAME)" SYNC_POSTGRES_USER="$(env_value SYNC_POSTGRES_USER)" \
            SYNC_POSTGRES_PASSWORD="$(env_value SYNC_POSTGRES_PASSWORD)" ADMIN_DATABASE="$(env_value ADMIN_DB_NAME)" \
            ADMIN_USER="$(env_value ADMIN_DB_USER)" ADMIN_SYNC_USER="$(env_value ADMIN_DB_SYNC_USER)" ADMIN_PASSWORD="$(env_value ADMIN_DB_PASSWORD)"
    else
        render_sql ${SCRIPT_DIR}/db/mysql/sync.sql ${SCRIPT_DIR}/database-setup.sql \
            SYNC_TOKENSERVER_DATABASE="$(env_value SYNC_TOKENSERVER_DB_NAME)" SYNC_TOKENSERVER_USER="$(env_value SYNC_TOKENSERVER_DB_USER)" \
            SYNC_TOKENSERVER_PASSWORD="$(env_value SYNC_TOKENSERVER_DB_PASSWORD)" \
            SYNC_STORAGE_DATABASE="$(env_value SYNC_STORAGE_DB_NAME)" SYNC_STORAGE_USER="$(env_value SYNC_STORAGE_DB_USER)" \
            SYNC_STORAGE_PASSWORD="$(env_value SYNC_STORAGE_DB_PASSWORD)" ADMIN_DATABASE="$(env_value ADMIN_DB_NAME)" \
            ADMIN_USER="$(env_value ADMIN_DB_USER)" ADMIN_SYNC_USER="$(env_value ADMIN_DB_SYNC_USER)" ADMIN_PASSWORD="$(env_value ADMIN_DB_PASSWORD)"
    fi
}

# Accounts images and the upstream pull requests of upstream-patches.yml they need: MariaDB 12
# and later (FXA_MARIADB_IMAGE=mariadb:lts, the default) need mozilla/fxa#21494, MySQL 9
# (FXA_MYSQL_IMAGE=mysql:lts, the default) and MySQL without mysql_native_password need
# mozilla/fxa#21554 (the mysql2 driver). Ours list what they have in their label
# org.firefox-sync.upstream-patches, Mozilla's (docker.io/mozilla/fxa-mono) and ours built
# before don't have them. The local image first (what starts), then the registry (docker buildx
# imagetools or skopeo). Here and not in the admin UI, which cannot inspect images
image_label() { grep -o '"org\.firefox-sync\.upstream-patches": *"[^"]*"' | head -n 1 | sed 's/.*: *"//; s/"$//'; }
fxa_image_patches_local() {
    local image=${1} runtime out
    for runtime in docker podman; do
        command -v "${runtime}" > /dev/null 2>&1 || continue
        out=$(${runtime} image inspect "${image}" 2> /dev/null) && { printf '%s' "${out}" | image_label; return 0; }
    done
    return 1
}
fxa_image_patches_remote() {
    local image=${1} out
    out=$(docker buildx imagetools inspect "${image}" --format '{{json .Image}}' 2> /dev/null) \
        || out=$(skopeo inspect "docker://${image}" 2> /dev/null) || return 1
    printf '%s' "${out}" | image_label
}
# has_fxa_patch <pull request> <label>: e.g. mozilla/fxa#21494 in "mozilla/fxa#21494@517651a..aa0b178 ..."
has_fxa_patch() { case " ${2} " in *" ${1}@"*) return 0 ;; esac; return 1; }
# fxa_image_has <pull request>: whether the accounts image of .env (FXA_IMAGE:FXA_VERSION) has
# it: 0 yes, 1 no, 2 not known (no local copy and no answer of the registry). An older local
# copy without it while the registry's has it: yes, and FXA_IMAGE_PULL=yes (pull before starting).
# Asked once per image and pull request (FXA_IMAGE_ANSWERS)
FXA_IMAGE_ANSWERS=""
fxa_image_has() {
    local pr=${1} image patches remote rc answer
    image=$(env_value FXA_IMAGE):$(env_value FXA_VERSION)
    for answer in ${FXA_IMAGE_ANSWERS}; do
        [ "${answer%=*}" = "${image}|${pr}" ] || continue
        rc=${answer##*=}; FXA_IMAGE_PULL=${rc#?}; return "${rc%"${FXA_IMAGE_PULL}"}"
    done
    FXA_IMAGE_PULL=""
    case "${image}" in
        mozilla/fxa-mono:*|docker.io/mozilla/fxa-mono:*|index.docker.io/mozilla/fxa-mono:*) rc=1 ;;
        *)
            if patches=$(fxa_image_patches_local "${image}"); then
                rc=1
                if has_fxa_patch "${pr}" "${patches}"; then
                    rc=0
                # an older local copy: the registry's may have it, then a pull is enough
                elif remote=$(fxa_image_patches_remote "${image}") && has_fxa_patch "${pr}" "${remote}"; then
                    rc=0 FXA_IMAGE_PULL=yes
                fi
            elif patches=$(fxa_image_patches_remote "${image}"); then
                has_fxa_patch "${pr}" "${patches}" && rc=0 || rc=1
            else
                rc=2
            fi ;;
    esac
    FXA_IMAGE_ANSWERS="${FXA_IMAGE_ANSWERS} ${image}|${pr}=${rc}${FXA_IMAGE_PULL}"
    return "${rc}"
}
fxa_mariadb_image_check() {
    local db_image image rc
    [ "$(env_value FXA_DB)" = mariadb ] || return 0
    db_image=$(env_value FXA_MARIADB_IMAGE)
    db_image=${db_image:-mariadb:lts}
    # your own server: its version is not known here
    if [ "$(env_value FXA_DB_CONTAINERS)" != 0 ]; then
        case "${db_image##*:}" in 10|10.*|11|11.*) return 0 ;; esac
    fi
    image=$(env_value FXA_IMAGE):$(env_value FXA_VERSION)
    fxa_image_has mozilla/fxa#21494; rc=$?
    if [ "${rc}" = 0 ]; then
        if [ -n "${FXA_IMAGE_PULL}" ]; then
            echo "NOTE: your local ${image} does not have mozilla/fxa#21494, needed on MariaDB 12,"
            echo "  the registry's has it: pull it before starting (docker compose pull, podman pull)"
            echo ""
        fi
        return 0
    fi
    if [ "${rc}" = 2 ]; then
        echo "NOTE: could not read the labels of ${image}: MariaDB 12 needs an accounts image with mozilla/fxa#21494"
        echo "  (label org.firefox-sync.upstream-patches, see FXA.md#mysql-or-mariadb)"
        echo ""
        return 0
    fi
    if [ "$(env_value FXA_DB_CONTAINERS)" = 0 ]; then
        echo "WARNING: if your MariaDB server is 12 or later, the accounts need an image with mozilla/fxa#21494,"
    else
        echo "WARNING: the accounts on MariaDB ${db_image##*:} (FXA_MARIADB_IMAGE=${db_image}) need an image with mozilla/fxa#21494,"
    fi
    echo "  which ${image} does not have (Mozilla's images, or ours built before it): on a new"
    echo "  database Mozilla's migrations stop. Use our images (FXA_IMAGE=ghcr.io/porelli/firefox-sync,"
    echo "  FXA_VERSION=fxa-mono-latest) or MariaDB 11 (FXA_MARIADB_IMAGE=mariadb:11), see FXA.md#mysql-or-mariadb"
    echo ""
}
# the options of fxa-db (FXA_MYSQL_ARGS) for accounts images without mozilla/fxa#21554: their
# driver speaks mysql_native_password only, which MySQL 8.4 has off by default and MySQL 9 not
# at all (mysqld 9 refuses these options and does not start)
FXA_MYSQL_NATIVE_ARGS="--mysql-native-password=ON --authentication-policy=mysql_native_password"
# a MySQL image of major 8 (mysql:8, mysql:8.4, a registry before it)
mysql_8() { case "${1##*:}" in 8|8.*) return 0 ;; esac; return 1; }
# the accounts on MySQL in fxa-db: the image of .env, its options and the accounts image agree
fxa_mysql_image_check() {
    local db_image args image rc native=no
    [ "$(env_value FXA_DB)" != mariadb ] || return 0
    [ "$(env_value FXA_DB_CONTAINERS)" != 0 ] || return 0
    db_image=$(env_plain FXA_MYSQL_IMAGE); db_image=${db_image:-mysql:lts}
    args=$(env_plain FXA_MYSQL_ARGS)
    case " ${args} " in *" --mysql-native-password=ON "*) native=yes ;; esac
    image=$(env_value FXA_IMAGE):$(env_value FXA_VERSION)
    if ! mysql_8 "${db_image}" && [ "${native}" = yes ]; then
        echo "WARNING: FXA_MYSQL_ARGS has --mysql-native-password=ON, which MySQL ${db_image##*:} (FXA_MYSQL_IMAGE=${db_image})"
        echo "  refuses: fxa-db would not start. On MySQL 9 the accounts need an image with mozilla/fxa#21554 and"
        echo "  their users on caching_sha2_password first: MIGRATING.md#mysql-lts (or FXA_MYSQL_IMAGE=mysql:8)"
        echo ""
        return 0
    fi
    fxa_image_has mozilla/fxa#21554; rc=$?
    if [ "${rc}" = 0 ]; then
        if [ -n "${FXA_IMAGE_PULL}" ]; then
            echo "NOTE: your local ${image} does not have mozilla/fxa#21554, needed on MySQL ${db_image##*:},"
            echo "  the registry's has it: pull it before starting (docker compose pull, podman pull)"
            echo ""
        elif [ "${native}" = yes ] && [ "${UPGRADING:-}" = yes ]; then
            echo "NOTE: ${image} has mozilla/fxa#21554 (caching_sha2_password): the accounts database can move"
            echo "  from MySQL 8 with mysql_native_password to MySQL lts, when you choose: MIGRATING.md#mysql-lts"
            echo ""
        fi
        return 0
    fi
    # without it: only mysql_native_password, on MySQL 8 with the options
    mysql_8 "${db_image}" && [ "${native}" = yes ] && return 0
    if [ "${rc}" = 2 ]; then
        echo "NOTE: could not read the labels of ${image}: MySQL ${db_image##*:} without mysql_native_password"
        echo "  needs an accounts image with mozilla/fxa#21554 (label org.firefox-sync.upstream-patches, FXA.md#mysql-or-mariadb)"
        echo ""
        return 0
    fi
    echo "WARNING: the accounts on MySQL ${db_image##*:} (FXA_MYSQL_IMAGE=${db_image}${args:+, FXA_MYSQL_ARGS=${args}}) need an image"
    echo "  with mozilla/fxa#21554, which ${image} does not have (Mozilla's images, or ours built before it):"
    echo "  they cannot log in. Use our images (FXA_IMAGE=ghcr.io/porelli/firefox-sync, FXA_VERSION=fxa-mono-latest)"
    echo "  or FXA_MYSQL_IMAGE=mysql:8 with FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}"
    echo "  (on a new database only: MySQL 8 cannot open MySQL 9's data), see FXA.md#mysql-or-mariadb"
    echo ""
}
# the accounts of this install self-hosted (prepare_environment.sh wrote their passwords)
fxa_installed() {
    local pw
    pw=$(env_plain FXA_MYSQL_PASSWORD)
    [ -n "${pw}" ] && [[ "${pw}" != *"<REPLACE_WITH_"* ]]
}

# ./prepare_environment.sh --upgrade: the .env of an install that runs (docker compose), given
# the settings of this release that need a value of their own (MIGRATING.md), nothing else
# changed: the admin UI's database users (ADMIN_DB_PASSWORD; the event log moves out of the
# Sync server's reach at the next start), the Sync server's own role in the PostgreSQL
# container (SYNC_POSTGRES_APP_USER, SYNC_POSTGRES_APP_PASSWORD), and in COMPOSE_FILE the new name of
# docker-compose.postgres.yml (docker-compose.sync-postgres.yml), and with the accounts on
# MariaDB FXA_MARIADB_IMAGE=mariadb:11, the major they run (the compose default is now
# mariadb:lts, 12: written out, they stay on 11; a move is up to the admin, FXA.md), on MySQL
# FXA_MYSQL_IMAGE=mysql:8 and FXA_MYSQL_ARGS with mysql_native_password, Sync on MySQL
# SYNC_MYSQL_IMAGE=mysql:8 (the default is now mysql:lts, 9; MIGRATING.md#mysql-lts). A value already set is kept; the
# old file is kept as .env.before-upgrade. With your own database server database-setup.sql
# is written again, to run there first. Quadlets: run this script again (MIGRATING.md).
# First the settings of RENAMED_SETTINGS get their new names, their values as they are.
upgrade_env() {
    local env_file name changed=()
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    env_file=${SCRIPT_DIR}/.env
    [ -f "${env_file}" ] || { echo "ERROR: no ${env_file} to upgrade: run ./prepare_environment.sh"; exit 1; }
    # the old names of RENAMED_SETTINGS: the line renamed where it is (indented or with
    # export, as compose reads it too), the rest of it as it is written. Both names there:
    # the new one is kept, unless it has no value of its own (empty, a placeholder or the
    # default of .env-example, e.g. added from it: then the old one's value); the old line
    # goes. A WARNING when what compose runs with changes; every value of before stays in
    # .env.before-upgrade
    rename_settings() {
        local pair new old new_value old_value example effective after kind moved=() notes=() warnings=()
        for pair in "${RENAMED_SETTINGS[@]}"; do
            new=${pair%%=*} old=${pair#*=}
            env_has "${old}" || continue
            old_value=$(env_plain "${old}")
            if env_has "${new}"; then
                new_value=$(env_plain "${new}")
                example=$(grep "^${new}=" "${SCRIPT_DIR}/.env-example" | cut -d= -f2- | tr -d '\r')
                # what compose runs with now: the new name, the old one when it is empty
                effective=${new_value:-${old_value}}
                if [ "${new_value}" = "${old_value}" ]; then
                    apply_sed "${env_file}" "/^${ENV_LEAD}${old}=/d"
                    notes+=("${old}: removed, ${new} has the same value")
                elif [ -z "${new_value}" ] || [[ "${new_value}" == *"<REPLACE_WITH_"* ]] || [ "${new_value}" = "${example}" ]; then
                    apply_sed "${env_file}" "/^${ENV_LEAD}${new}=/d"
                    apply_sed "${env_file}" "s/^\(${ENV_LEAD}\)${old}=/\1${new}=/"
                    if [ -z "${new_value}" ]; then kind="no value"; elif [[ "${new_value}" == *"<REPLACE_WITH_"* ]]; then kind="the placeholder of .env-example"; else kind="the default of .env-example"; fi
                    notes+=("${new}: had ${kind}, now the value of ${old}")
                else
                    apply_sed "${env_file}" "/^${ENV_LEAD}${old}=/d"
                    notes+=("${old}: removed, its value differs from that of ${new}, which is kept")
                fi
                after=$(env_plain "${new}")
                if [ "${effective}" != "${after}" ]; then
                    case "${new}" in
                        *PASSWORD*|*SECRET*) warnings+=("${new}: effective value changed (a secret, not shown): that of ${old}") ;;
                        *) warnings+=("${new}: effective value '${effective}' -> '${after}' (that of ${old})") ;;
                    esac
                fi
            else
                apply_sed "${env_file}" "s/^\(${ENV_LEAD}\)${old}=/\1${new}=/"
            fi
            moved+=("${old} -> ${new}")
            changed+=("${new}")
        done
        [ "${#moved[@]}" = 0 ] && return
        echo "Renamed in .env, the values as they were (MIGRATING.md#renamed-settings):"
        printf '  %s\n' "${moved[@]}"
        [ "${#notes[@]}" = 0 ] || printf '  NOTE: %s\n' "${notes[@]}"
        if [ "${#warnings[@]}" != 0 ]; then
            printf 'WARNING: %s\n' "${warnings[@]}"
            echo "  Check them before starting: .env.before-upgrade has the previous file."
        fi
        echo "  Rename them in your own scripts too (docker compose run -e, systemd units...)."
    }
    # old names exported where this runs: docker compose run from here would get both names
    # and refuse to start, which no change of .env clears
    old_names_in_environment() {
        local pair old found=()
        for pair in "${RENAMED_SETTINGS[@]}"; do
            old=${pair#*=}
            [ -n "$(printenv "${old}")" ] && found+=("${old} (${pair%%=*} in .env)")
        done
        [ "${#found[@]}" = 0 ] && return
        echo "WARNING: old setting names in the environment of this shell, which docker compose would also"
        echo "  see next to the new names of .env, and refuse to start: unset them in your shell (and CI):"
        printf '  %s\n' "${found[@]}"
    }
    set_value() {
        if grep -q "^${1}=" "${env_file}"; then
            apply_sed "${env_file}" "s|^${1}=.*|${1}=$(sed_escape "${2}")|"
        else
            printf '%s=%s\n' "${1}" "${2}" >> "${env_file}"
        fi
        changed+=("${1}")
    }
    cp -p "${env_file}" "${env_file}.upgrading" || exit 1
    rename_settings
    # the names: those of .env-example
    for name in ADMIN_DB_NAME ADMIN_DB_USER ADMIN_DB_SYNC_USER; do
        grep -q "^${name}=" "${env_file}" || set_value "${name}" "$(grep "^${name}=" "${SCRIPT_DIR}/.env-example" | cut -d= -f2-)"
    done
    [ -n "$(env_value ADMIN_DB_PASSWORD)" ] || set_value ADMIN_DB_PASSWORD "$(generate_random_string 32)"
    # docker-compose.postgres.yml is now docker-compose.sync-postgres.yml (the old name is a
    # symlink to it for a transition period, MIGRATING.md): the new name in COMPOSE_FILE
    local compose_file compose_new part parts=() renamed=no
    compose_file=$(env_value COMPOSE_FILE | tail -n 1)
    case "${compose_file}" in
        \'*\') compose_file=${compose_file:1:${#compose_file}-2} ;;
        \"*\") compose_file=${compose_file:1:${#compose_file}-2} ;;
    esac
    IFS=: read -r -a parts <<< "${compose_file}"
    for part in "${parts[@]}"; do
        case "${part}" in
            docker-compose.postgres.yml|*/docker-compose.postgres.yml) part=${part%docker-compose.postgres.yml}docker-compose.sync-postgres.yml; renamed=yes ;;
        esac
        compose_new=${compose_new:+${compose_new}:}${part}
    done
    if [ "${renamed}" = yes ]; then
        set_value COMPOSE_FILE "${compose_new}"
        echo "COMPOSE_FILE: docker-compose.postgres.yml renamed to docker-compose.sync-postgres.yml (now ${compose_new})"
    fi
    if [ "$(env_value SYNC_IMAGE)" = "syncstorage-rs-postgres" ] && [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ] && [ -z "$(env_value SYNC_POSTGRES_APP_PASSWORD)" ]; then
        [ -n "$(env_value SYNC_POSTGRES_APP_USER)" ] || set_value SYNC_POSTGRES_APP_USER syncserver_app
        set_value SYNC_POSTGRES_APP_PASSWORD "$(generate_random_string 32)"
    fi
    # Sync on PostgreSQL, from before SYNC_POSTGRES_IMAGE: postgres:18, the major it runs (every
    # release so far used 18, git log -- docker-compose.sync-postgres.yml confirms it)
    if [ "$(env_value SYNC_IMAGE)" = "syncstorage-rs-postgres" ] && ! grep -q '^SYNC_POSTGRES_IMAGE=' "${env_file}"; then
        set_value SYNC_POSTGRES_IMAGE postgres:18
        echo "SYNC_POSTGRES_IMAGE=postgres:18: the Sync database stays on PostgreSQL 18. To move it to"
        echo "  a newer major: a dump and restore (ADMIN.md#restoring) or pg_upgrade (DATABASES.md#another-postgresql-major)"
    fi
    # the accounts on MariaDB, from before FXA_MARIADB_IMAGE: on 11, they stay there (unset
    # it is now mariadb:lts, which would upgrade their data to 12 at the next start)
    if [ "$(env_value FXA_DB)" = mariadb ] && ! grep -q '^FXA_MARIADB_IMAGE=' "${env_file}"; then
        set_value FXA_MARIADB_IMAGE mariadb:11
        echo "FXA_MARIADB_IMAGE=mariadb:11: the accounts database stays on MariaDB 11. To move it to"
        echo "  MariaDB lts, 12 (a backup first, there is no way back): FXA.md#moving-to-a-newer-mariadb"
    fi
    # the accounts on MySQL, from before FXA_MYSQL_IMAGE: on 8 with mysql_native_password, they
    # stay there. Unset it is now mysql:lts (9), which would upgrade their data at the next start
    # (fxa-db refuses, db/mysql/keep-major.sh), and where their users, created with
    # mysql_native_password, could not log in at all. Your own server: the backups' client
    if [ "$(env_value FXA_DB)" != mariadb ] && fxa_installed && ! env_has FXA_MYSQL_IMAGE; then
        set_value FXA_MYSQL_IMAGE mysql:8
        env_has FXA_MYSQL_ARGS || set_value FXA_MYSQL_ARGS "${FXA_MYSQL_NATIVE_ARGS}"
        echo "FXA_MYSQL_IMAGE=mysql:8, FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}: the accounts database"
        echo "  stays on MySQL 8 with mysql_native_password. To move it to MySQL lts, 9 (its users first, a backup, no"
        echo "  way back): MIGRATING.md#mysql-lts"
    fi
    # Sync on MySQL containers, from before SYNC_MYSQL_IMAGE: on 8, they stay there (unset it
    # is now mysql:lts, 9)
    if [ "$(env_value SYNC_DB)" = mysql ] && [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ] && ! env_has SYNC_MYSQL_IMAGE; then
        set_value SYNC_MYSQL_IMAGE mysql:8
        echo "SYNC_MYSQL_IMAGE=mysql:8: the Sync databases stay on MySQL 8. To move them to MySQL lts, 9"
        echo "  (a backup first, there is no way back): MIGRATING.md#mysql-lts"
    fi
    old_names_in_environment
    if [ "${#changed[@]}" = 0 ]; then
        rm -f "${env_file}.upgrading"
        echo "Nothing to add: ${env_file} has every setting of this release."
    else
        mv "${env_file}.upgrading" "${env_file}.before-upgrade"
        echo "Updated ${env_file} (the old one is .env.before-upgrade): ${changed[*]}"
    fi
    if [ "$(env_value SYNC_DB_CONTAINERS)" = 0 ]; then
        [ "$(env_value SYNC_IMAGE)" = "syncstorage-rs-postgres" ] && render_sync_sql postgres || render_sync_sql mariadb
        echo "Your own database server: run database-setup.sql there first, as its administrator (DATABASES.md)."
    fi
    fxa_mariadb_image_check
    fxa_installed && UPGRADING=yes fxa_mysql_image_check
    echo "Then: docker compose pull && docker compose up -d"
    exit 0
}
[ "${1:-}" = "--upgrade" ] && upgrade_env

# domain
DOMAIN_EXAMPLE='firefox-sync.example.com'
read -e -p "Enter FQDN for your Firefox sync server [${DOMAIN_EXAMPLE}]: " SYNC_FQDN
SYNC_FQDN=${SYNC_FQDN:-${DOMAIN_EXAMPLE}}

# compose dir
CURRENT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
read -e -p "Enter full path for the docker-compose file [${CURRENT_DIR}]: " SCRIPT_DIR
SCRIPT_DIR=${SCRIPT_DIR:-${CURRENT_DIR}}

# listening port
DEFAULT_CONTAINER_EXPORT_PORT=5000
read -e -p "Listening port for syncstorage-rs [${DEFAULT_CONTAINER_EXPORT_PORT}]: " SYNC_EXPORT_PORT
SYNC_EXPORT_PORT=${SYNC_EXPORT_PORT:-${DEFAULT_CONTAINER_EXPORT_PORT}}

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
read -e -p "Max allowed users, a number or unlimited [${DEFAULT_MAX_USERS}]: " SYNC_MAX_USERS
SYNC_MAX_USERS=${SYNC_MAX_USERS:-${DEFAULT_MAX_USERS}}
valid_limit "max users" "${SYNC_MAX_USERS}"

# database backend
DEFAULT_DATABASE_BACKEND=mariadb
read -e -p "Database backend [mariadb/mysql/postgres] [${DEFAULT_DATABASE_BACKEND}]: " DATABASE_BACKEND
DATABASE_BACKEND=${DATABASE_BACKEND:-${DEFAULT_DATABASE_BACKEND}}
case "${DATABASE_BACKEND}" in
    mariadb|postgres) SYNC_DB=mariadb ;;
    # MySQL containers (docker-compose.sync-mysql.yml), the same Sync images as MariaDB
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
read -e -p "Syncstorage image tag [latest/<tag>] [${DEFAULT_SYNCSTORAGE_IMAGE_TAG}]: " SYNC_IMAGE_TAG
SYNC_IMAGE_TAG=${SYNC_IMAGE_TAG:-${DEFAULT_SYNCSTORAGE_IMAGE_TAG}}

# admin UI
read -r -e -p "Enable the admin UI? Max users, and sign-ups and accounts with self-hosted accounts, see ADMIN.md (Y/n): " ADMIN_UI
case "${ADMIN_UI}" in n|N|no) ADMIN_UI=no ;; *) ADMIN_UI=yes ;; esac
# with the admin UI, max users is managed there: SYNC_MAX_USERS=initial:N sets it only on the
# first start. A plain number is set again on every start (read-only in the admin UI)
[ "${ADMIN_UI}" = "yes" ] && SYNC_MAX_USERS=initial:${SYNC_MAX_USERS}

# admin sign-in with the self-hosted accounts, asked below
ADMIN_ALLOWED_USERS=""
ADMIN_HOST=""

# self-hosted Mozilla accounts (FXA.md)
read -r -e -p "Also self-host Mozilla accounts? See FXA.md (y/N): " SELF_HOST_FXA
case "${SELF_HOST_FXA}" in y|Y|yes) SELF_HOST_FXA=yes ;; *) SELF_HOST_FXA=no ;; esac
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    DEFAULT_FXA_DOMAIN=${SYNC_FQDN#*.}
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
        read -r -e -p "Database [syncserver]: " SYNC_POSTGRES_NAME
        SYNC_POSTGRES_NAME=${SYNC_POSTGRES_NAME:-syncserver}
        read -r -e -p "Database user [syncserver]: " SYNC_POSTGRES_USER
        SYNC_POSTGRES_USER=${SYNC_POSTGRES_USER:-syncserver}
        valid_name "${SYNC_POSTGRES_NAME}"; valid_name "${SYNC_POSTGRES_USER}"
    else
        read -r -e -p "Tokenserver database [tokenserver]: " SYNC_TOKENSERVER_DB_NAME
        SYNC_TOKENSERVER_DB_NAME=${SYNC_TOKENSERVER_DB_NAME:-tokenserver}
        read -r -e -p "Tokenserver database user [tokenserver]: " SYNC_TOKENSERVER_DB_USER
        SYNC_TOKENSERVER_DB_USER=${SYNC_TOKENSERVER_DB_USER:-tokenserver}
        read -r -e -p "Storage database [syncstorage]: " SYNC_STORAGE_DB_NAME
        SYNC_STORAGE_DB_NAME=${SYNC_STORAGE_DB_NAME:-syncstorage}
        read -r -e -p "Storage database user [syncstorage]: " SYNC_STORAGE_DB_USER
        SYNC_STORAGE_DB_USER=${SYNC_STORAGE_DB_USER:-syncstorage}
        for name in "${SYNC_TOKENSERVER_DB_NAME}" "${SYNC_TOKENSERVER_DB_USER}" "${SYNC_STORAGE_DB_NAME}" "${SYNC_STORAGE_DB_USER}"; do
            valid_name "${name}"
        done
        [ "${SYNC_TOKENSERVER_DB_NAME}" != "${SYNC_STORAGE_DB_NAME}" ] || { echo "ERROR: the tokenserver and the storage need two databases"; exit 1; }
    fi
fi
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    read -r -e -p "Use an existing MySQL 8.4/9 or MariaDB 11.4+ server for the accounts$([ "${EXTERNAL_DB}" = "yes" ] && echo " too")? See DATABASES.md (y/N): " EXTERNAL_FXA_DB
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
        read -r -e -p "Accounts database: mysql (MySQL lts, what Mozilla runs) or mariadb (MariaDB lts, see FXA.md) [mysql]: " FXA_DB
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

# the security history of the accounts (FXA.md), asked last for the same reason
FXA_ACCOUNT_EVENTS=false
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    echo "Security history: every sign-in, password and 2-step change is kept with its IP address, for the owner and the admin UI to see (FXA.md)."
    read -r -e -p "Record the security history of the accounts? (y/N): " FXA_ACCOUNT_EVENTS
    case "${FXA_ACCOUNT_EVENTS}" in y|Y|yes) FXA_ACCOUNT_EVENTS=true ;; *) FXA_ACCOUNT_EVENTS=false ;; esac
fi

# the alerts of the admin UI to other destinations than email (ADMIN.md#alerts), asked last
# for the same reason. Not shown as typed: the URLs hold tokens
ADMIN_NOTIFY=""
if [ "${ADMIN_UI}" = "yes" ]; then
    echo "Alerts of the admin UI: by email (ADMIN_ALERT_EMAIL in .env, with an SMTP server), and/or to Slack, Discord, Teams, ntfy, Gotify, Telegram, Matrix or a webhook (ADMIN.md#alerts)."
    read -r -s -p "Also send alerts to Slack, Discord, ntfy...? Paste a destination URL (e.g. ntfy://ntfy.sh/<topic>, slack://hooks.slack.com/services/...) or leave empty: " ADMIN_NOTIFY
    echo ""
    # scheme://host of a destination, … for what cannot be named safely (an @ after the
    # host is the end of a user or password with / ? # in it, not the host)
    notify_name() {
        local scheme rest host tail
        scheme=$(printf '%s' "${1%%://*}" | tr '[:upper:]' '[:lower:]'); rest=${1#*://}
        [[ "${scheme}" =~ ^[a-z][a-z0-9+]*$ ]] || { printf '…'; return; }
        case "${scheme}" in telegram*) printf '%s://api.telegram.org' "${scheme}"; return ;; esac
        host=${rest%%[/?#]*}; tail=${rest#"${host}"}
        tail=${tail//\?@/}; tail=${tail//&@/}
        case "${tail}" in *@*) printf '%s://…' "${scheme}"; return ;; esac
        host=${host##*@}
        [[ "${host}" =~ ^[A-Za-z0-9.:-]+$ ]] || { printf '%s://…' "${scheme}"; return; }
        printf '%s://%s' "${scheme}" "${host}"
    }
    notify_in=${ADMIN_NOTIFY}; ADMIN_NOTIFY=""; notify_names=""
    # separated by commas or spaces
    IFS=$', \t\r' read -r -a notify_entries <<< "${notify_in}"
    for notify_entry in "${notify_entries[@]}"; do
        [ -n "${notify_entry}" ] || continue
        case "${notify_entry}" in *"'"*) echo "ERROR: a destination URL cannot contain a single quote, set ADMIN_NOTIFY in .env by hand"; exit 1 ;; esac
        # the webhook URL of Slack or Discord as they give it: their scheme instead of https://
        notify_kind=""
        case "${notify_entry}" in
            https://hooks.slack.com/*) notify_kind=slack ;;
            https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) notify_kind=discord ;;
        esac
        if [ -n "${notify_kind}" ]; then
            read -r -e -p "That is a ${notify_kind} webhook URL: use it as ${notify_kind}://... (Y/n): " notify_convert
            case "${notify_convert}" in n|N|no) echo "ERROR: https:// is no destination of ADMIN_NOTIFY, see ADMIN.md#alerts"; exit 1 ;; esac
            notify_entry="${notify_kind}://${notify_entry#https://}"
        fi
        notify_base="" notify_shown="…"
        if [[ "${notify_entry}" == *://* ]]; then
            notify_base=$(printf '%s' "${notify_entry%%://*}" | tr '[:upper:]' '[:lower:]'); notify_base=${notify_base%+http}; notify_base=${notify_base%+https}
            notify_shown=$(notify_name "${notify_entry}")
        fi
        if ! [[ "${notify_base}" =~ ^(slack|discord|teams|ntfy|gotify|telegram|matrix|webhook)$ ]]; then
            echo "ERROR: ${notify_shown} is no destination of ADMIN_NOTIFY: slack://, discord://, teams://, ntfy://, gotify://, telegram://, matrix:// or webhook://, see ADMIN.md#alerts"
            exit 1
        fi
        if [ "${notify_base}" != telegram ] && [ "${notify_shown}" = "${notify_shown%://…}://…" ]; then
            echo "ERROR: ${notify_shown}: an @ after the host, percent-encode / ? # in the user or password (%2F %3F %23)"
            exit 1
        fi
        ADMIN_NOTIFY="${ADMIN_NOTIFY:+${ADMIN_NOTIFY},}${notify_entry}"
        notify_names="${notify_names:+${notify_names}, }$(notify_name "${notify_entry}")"
    done
    [ -z "${ADMIN_NOTIFY}" ] || echo "Alerts also to ${notify_names} (ADMIN_NOTIFY in .env; more destinations there, separated by commas)"
fi

# SYNC_DB=mysql: the Sync databases in MySQL containers; with your own server there are none,
# SYNC_DB then only says what it is
[ "${SYNC_DB}" = "mysql" ] && [ "${EXTERNAL_DB}" != "yes" ] && SYNC_COMPOSE_MYSQL=yes || SYNC_COMPOSE_MYSQL=no

# random passwords
SYNC_TOKENSERVER_DB_PASSWORD=$(generate_random_string 24)
SYNC_STORAGE_DB_PASSWORD=$(generate_random_string 24)
SYNC_POSTGRES_PASSWORD=$(generate_random_string 24)
SYNC_MASTER_SECRET=$(generate_random_string 24)
SYNC_METRICS_HASH_SECRET=$(generate_random_string 24)
ADMIN_PASSWORD=$(generate_random_string 24)
ADMIN_DB_PASSWORD=$(generate_random_string 32)

# a database volume of an earlier install (the .env gone, or for another database):
# "<runtime> volume <name>", for any of the names given (compose: <project>_<name>, Quadlets:
# firefox-sync-<name>), e.g. db_volume fxa-db-mariadb
db_volume() {
    local project runtime volume name
    project=$(basename "${SCRIPT_DIR}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    for runtime in docker podman; do
        command -v "${runtime}" > /dev/null 2>&1 || continue
        for name in "$@"; do
            for volume in "${project}_${name}" "firefox-sync-${name}"; do
                ${runtime} volume inspect "${volume}" > /dev/null 2>&1 && { echo "${runtime} volume ${volume}"; return 0; }
            done
        done
    done
    return 1
}

# the major of postgres:latest, from its own server ("postgres (PostgreSQL) 18.1 (Debian ...)"):
# pulled if needed (Docker's first, a Docker without its daemon fails at once, then Podman's)
postgres_latest_major() {
    local runtime image=postgres:latest out
    for runtime in docker podman; do
        command -v "${runtime}" > /dev/null 2>&1 || continue
        [ "${runtime}" = podman ] && image=docker.io/library/postgres:latest
        out=$(${runtime} run --rm --pull=missing --entrypoint postgres "${image}" --version 2> /dev/null) || continue
        out=$(printf '%s' "${out}" | sed -n 's/^postgres (PostgreSQL) \([0-9][0-9]*\)[^0-9].*/\1/p')
        [ -n "${out}" ] && { echo "${out}"; return 0; }
    done
    return 1
}

# run again on an install: its databases stay on the PostgreSQL, MariaDB or MySQL versions they run
PREVIOUS_SYNCSTORAGE_IMAGE="" PREVIOUS_POSTGRES_IMAGE=""
PREVIOUS_FXA_DB="" PREVIOUS_FXA_MARIADB_IMAGE=""
PREVIOUS_FXA_MYSQL=no PREVIOUS_FXA_MYSQL_IMAGE="" PREVIOUS_FXA_MYSQL_ARGS=""
PREVIOUS_SYNC_MYSQL=no PREVIOUS_SYNC_MYSQL_IMAGE=""
if [ -f "${SCRIPT_DIR}/.env" ]; then
    PREVIOUS_SYNCSTORAGE_IMAGE=$(env_value SYNC_IMAGE)
    PREVIOUS_POSTGRES_IMAGE=$(env_value SYNC_POSTGRES_IMAGE)
    PREVIOUS_FXA_DB=$(env_value FXA_DB)
    PREVIOUS_FXA_MARIADB_IMAGE=$(env_value FXA_MARIADB_IMAGE)
    # the accounts on MySQL (FXA_DB=mysql is also in .env-example: with their passwords)
    if [ "${PREVIOUS_FXA_DB}" != mariadb ] && fxa_installed; then
        PREVIOUS_FXA_MYSQL=yes
        PREVIOUS_FXA_MYSQL_IMAGE=$(env_plain FXA_MYSQL_IMAGE)
        PREVIOUS_FXA_MYSQL_ARGS=$(env_plain FXA_MYSQL_ARGS)
    fi
    if [ "$(env_value SYNC_DB)" = mysql ] && [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ]; then
        PREVIOUS_SYNC_MYSQL=yes
        PREVIOUS_SYNC_MYSQL_IMAGE=$(env_plain SYNC_MYSQL_IMAGE)
    fi
fi

# prepare .env file
cp ${SCRIPT_DIR}/.env-example ${SCRIPT_DIR}/.env
apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_TOKENSERVER_DB_PASSWORD=.*|SYNC_TOKENSERVER_DB_PASSWORD=${SYNC_TOKENSERVER_DB_PASSWORD}|"
apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_STORAGE_DB_PASSWORD=.*|SYNC_STORAGE_DB_PASSWORD=${SYNC_STORAGE_DB_PASSWORD}|"
apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_POSTGRES_PASSWORD=.*|SYNC_POSTGRES_PASSWORD=${SYNC_POSTGRES_PASSWORD}|"
apply_sed ${SCRIPT_DIR}/.env "s|SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=${SYNC_MASTER_SECRET}|"
apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_METRICS_HASH_SECRET=.*|SYNC_METRICS_HASH_SECRET=${SYNC_METRICS_HASH_SECRET}|"
apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_PUBLIC_URL=.*|SYNC_PUBLIC_URL=https://${SYNC_FQDN}|"
apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_EXPORT_PORT=.*|SYNC_EXPORT_PORT=${SYNC_EXPORT_PORT}|"
apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_MAX_USERS=.*|SYNC_MAX_USERS=${SYNC_MAX_USERS}|"
apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_IMAGE_TAG=.*|SYNC_IMAGE_TAG=${SYNC_IMAGE_TAG}|"
apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PASSWORD}|"
# the admin UI's database user, also for the backups: with or without the admin UI
apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=${ADMIN_DB_PASSWORD}|"
[ "${ADMIN_UI}" = "yes" ] && apply_sed ${SCRIPT_DIR}/.env "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=admin|"
[ -n "${ADMIN_NOTIFY}" ] && apply_sed ${SCRIPT_DIR}/.env "s|^ADMIN_NOTIFY=.*|ADMIN_NOTIFY='$(sed_escape "${ADMIN_NOTIFY}")'|"
apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_DB=.*|SYNC_DB=${SYNC_DB}|"
if [ "${SYNC_COMPOSE_MYSQL}" = "yes" ]; then
    # MySQL's certificate is self-signed: the init container's client does not check it
    # (docker-compose.sync-mysql.yml does the same, this is for the Quadlets)
    apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_DB_TLS_VERIFY=.*|SYNC_DB_TLS_VERIFY=false|"
    # with the accounts, set below with theirs
    [ "${SELF_HOST_FXA}" = "yes" ] || apply_sed ${SCRIPT_DIR}/.env "s|^# COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.yml:docker-compose.sync-mysql.yml|"
    # MySQL lts for new installs (9 today), written out (also the default when unset). One that
    # ran MySQL before SYNC_MYSQL_IMAGE, or whose MySQL volumes are still there, runs 8: pinned,
    # so that its data does not move to 9 by itself
    SYNC_MYSQL_IMAGE=mysql:lts
    if [ "${PREVIOUS_SYNC_MYSQL}" = yes ]; then
        SYNC_MYSQL_IMAGE=${PREVIOUS_SYNC_MYSQL_IMAGE:-mysql:8}
        [ -n "${PREVIOUS_SYNC_MYSQL_IMAGE}" ] || PINNED_SYNC_MYSQL=yes
    elif SYNC_MYSQL_VOLUME=$(db_volume syncstorage-db-mysql tokenserver-db-mysql); then
        SYNC_MYSQL_IMAGE=mysql:8
    fi
    apply_sed ${SCRIPT_DIR}/.env "s|^# SYNC_MYSQL_IMAGE=.*|SYNC_MYSQL_IMAGE=$(sed_escape "${SYNC_MYSQL_IMAGE}")|"
fi
if [ "${EXTERNAL_DB}" = "yes" ]; then
    apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_DB_CONTAINERS=.*|SYNC_DB_CONTAINERS=0|"
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        for name in SYNC_POSTGRES_NAME SYNC_POSTGRES_USER; do
            apply_sed ${SCRIPT_DIR}/.env "s|^${name}=.*|${name}=${!name}|"
        done
        apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_POSTGRES_HOST=.*|SYNC_POSTGRES_HOST=${DB_HOST}|"
        apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_POSTGRES_PORT=.*|SYNC_POSTGRES_PORT=${DB_PORT}|"
    else
        # the init container's client checks the certificate by default, MySQL's is self-signed
        apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_DB_TLS_VERIFY=.*|SYNC_DB_TLS_VERIFY=false|"
        for name in SYNC_TOKENSERVER_DB_NAME SYNC_TOKENSERVER_DB_USER SYNC_STORAGE_DB_NAME SYNC_STORAGE_DB_USER; do
            apply_sed ${SCRIPT_DIR}/.env "s|^${name}=.*|${name}=${!name}|"
        done
        for part in TOKENSERVER STORAGE; do
            apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_${part}_DB_HOST=.*|SYNC_${part}_DB_HOST=${DB_HOST}|"
            apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_${part}_DB_PORT=.*|SYNC_${part}_DB_PORT=${DB_PORT}|"
        done
    fi
fi
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    for name in FXA_MYSQL_PASSWORD FXA_ADMIN_DB_PASSWORD FXA_AUTH_SECRET FXA_OAUTH_SECRET FXA_PROFILE_SECRET FXA_FLOW_ID_KEY FXA_SESSION_TOKEN_HANDLE_KEY FXA_CONTENT_SESSION_SECRET; do
        apply_sed ${SCRIPT_DIR}/.env "s|^${name}=.*|${name}=$(generate_random_string 32)|"
    done
    # the accounts images come from the same registry as the sync images, for this host's architecture
    FXA_REGISTRY=$(grep '^IMAGE_REPOSITORY=' ${SCRIPT_DIR}/.env | cut -d= -f2)
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
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_ACCOUNT_EVENTS=.*|FXA_ACCOUNT_EVENTS=${FXA_ACCOUNT_EVENTS}|"
    if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
        apply_sed ${SCRIPT_DIR}/.env "s|^FXA_DB_CONTAINERS=.*|FXA_DB_CONTAINERS=0|"
        for name in FXA_MYSQL_HOST FXA_MYSQL_PORT FXA_MYSQL_USER FXA_MYSQL_POLICY_USER; do
            apply_sed ${SCRIPT_DIR}/.env "s|^${name}=.*|${name}=${!name}|"
        done
        apply_sed ${SCRIPT_DIR}/.env "s|^FXA_MYSQL_POLICY_PASSWORD=.*|FXA_MYSQL_POLICY_PASSWORD=$(generate_random_string 32)|"
    fi
    apply_sed ${SCRIPT_DIR}/.env "s|^FXA_DB=.*|FXA_DB=${FXA_DB}|"
    # MariaDB lts for new installs (12 today, with the patched migrations), written out (also
    # the default when unset). One that ran MariaDB before FXA_MARIADB_IMAGE, or whose MariaDB
    # volume is still there, runs 11: pinned, so that its data does not move to 12 by itself
    if [ "${FXA_DB}" = "mariadb" ]; then
        FXA_MARIADB_IMAGE=mariadb:lts
        if [ "${PREVIOUS_FXA_DB}" = "mariadb" ]; then
            FXA_MARIADB_IMAGE=${PREVIOUS_FXA_MARIADB_IMAGE:-mariadb:11}
            [ -n "${PREVIOUS_FXA_MARIADB_IMAGE}" ] || PINNED_FXA_MARIADB=yes
        elif [ "${EXTERNAL_FXA_DB}" != "yes" ] && FXA_MARIADB_VOLUME=$(db_volume fxa-db-mariadb); then
            FXA_MARIADB_IMAGE=mariadb:11
        fi
        apply_sed ${SCRIPT_DIR}/.env "s|^# FXA_MARIADB_IMAGE=.*|FXA_MARIADB_IMAGE=$(sed_escape "${FXA_MARIADB_IMAGE}")|"
    fi
    # MySQL lts for new installs (9 today), written out (also the default when unset), when the
    # accounts image has mozilla/fxa#21554; else MySQL 8 with mysql_native_password, the only
    # authentication of the images without it (Mozilla's, ours from before). One that ran MySQL
    # before FXA_MYSQL_IMAGE, or whose fxa-db volume is still there, runs 8 like that: pinned,
    # its users are on mysql_native_password (MIGRATING.md#mysql-lts). Your own server: the
    # image is the backups' client, and without the patch the accounts' user is created with
    # mysql_native_password in database-setup-fxa.sql
    if [ "${FXA_DB}" = "mysql" ]; then
        fxa_image_has mozilla/fxa#21554; FXA_MYSQL2=$?
        FXA_MYSQL_IMAGE=mysql:lts FXA_MYSQL_ARGS=""
        if [ "${PREVIOUS_FXA_MYSQL}" = yes ]; then
            if [ -n "${PREVIOUS_FXA_MYSQL_IMAGE}" ]; then
                FXA_MYSQL_IMAGE=${PREVIOUS_FXA_MYSQL_IMAGE} FXA_MYSQL_ARGS=${PREVIOUS_FXA_MYSQL_ARGS}
            else
                FXA_MYSQL_IMAGE=mysql:8 FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS} PINNED_FXA_MYSQL=yes
            fi
        elif [ "${EXTERNAL_FXA_DB}" != "yes" ] && FXA_MYSQL_VOLUME=$(db_volume fxa-db); then
            FXA_MYSQL_IMAGE=mysql:8 FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}
        elif [ "${FXA_MYSQL2}" != 0 ]; then
            FXA_MYSQL_IMAGE=mysql:8 FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}
        fi
        apply_sed ${SCRIPT_DIR}/.env "s|^# FXA_MYSQL_IMAGE=.*|FXA_MYSQL_IMAGE=$(sed_escape "${FXA_MYSQL_IMAGE}")|"
        [ -z "${FXA_MYSQL_ARGS}" ] || apply_sed ${SCRIPT_DIR}/.env "s|^# FXA_MYSQL_ARGS=.*|FXA_MYSQL_ARGS=$(sed_escape "${FXA_MYSQL_ARGS}")|"
    fi
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
        COMPOSE_FILES=docker-compose.sync-postgres.yml:docker-compose.fxa.yml
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
    [ "${SELF_HOST_FXA}" = "yes" ] || apply_sed ${SCRIPT_DIR}/.env "s|# COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.sync-postgres.yml|"
    apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_IMAGE=.*|SYNC_IMAGE=syncstorage-rs-postgres|"
    apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_INIT_IMAGE=.*|SYNC_INIT_IMAGE=syncstorage-rs-postgres-init|"
    # the database container: the Sync server gets a role of its own, SYNC_POSTGRES_USER is the
    # container's superuser (your own server: SYNC_POSTGRES_USER is the plain owner, DATABASES.md)
    if [ "${EXTERNAL_DB}" != "yes" ]; then
        apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_POSTGRES_APP_USER=.*|SYNC_POSTGRES_APP_USER=syncserver_app|"
        apply_sed ${SCRIPT_DIR}/.env "s|^SYNC_POSTGRES_APP_PASSWORD=.*|SYNC_POSTGRES_APP_PASSWORD=$(generate_random_string 32)|"
    fi
    # PostgreSQL has no lts (every major is supported for 5 years) and no major opens another's
    # data: new installs get the major postgres:latest is at now, read from the image itself,
    # written out (postgres:<major>; unset it is postgres:latest, which a new major would
    # leave unable to start). One that ran PostgreSQL before SYNC_POSTGRES_IMAGE runs
    # postgres:18 (every release before it used 18, git log -- docker-compose.sync-postgres.yml)
    if [ "${PREVIOUS_SYNCSTORAGE_IMAGE}" = "syncstorage-rs-postgres" ]; then
        SYNC_POSTGRES_IMAGE=${PREVIOUS_POSTGRES_IMAGE:-postgres:18}
    elif SYNC_POSTGRES_MAJOR=$(postgres_latest_major); then
        SYNC_POSTGRES_IMAGE=postgres:${SYNC_POSTGRES_MAJOR}
    else
        SYNC_POSTGRES_IMAGE=""
    fi
    [ -z "${SYNC_POSTGRES_IMAGE}" ] || apply_sed ${SCRIPT_DIR}/.env "s|^# SYNC_POSTGRES_IMAGE=.*|SYNC_POSTGRES_IMAGE=$(sed_escape "${SYNC_POSTGRES_IMAGE}")|"
fi

# the SQL for your own database server, with the names and passwords of .env (DATABASES.md)
[ "${EXTERNAL_DB}" = "yes" ] && render_sync_sql "${DATABASE_BACKEND}"
if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
    fxa_template=${SCRIPT_DIR}/db/mysql/fxa-${FXA_DB}.sql
    # MySQL and an accounts image without mozilla/fxa#21554: their user on mysql_native_password
    # (the commented lines of fxa-mysql.sql instead of those after them)
    if [ "${FXA_DB}" = mysql ] && [ "${FXA_MYSQL2}" != 0 ]; then
        fxa_template=${SCRIPT_DIR}/database-setup-fxa.native
        sed -e "/^-- native: /{s/^-- native: //;n;d;}" "${SCRIPT_DIR}/db/mysql/fxa-mysql.sql" > "${fxa_template}"
    fi
    render_sql "${fxa_template}" ${SCRIPT_DIR}/database-setup-fxa.sql \
        FXA_USER="$(env_value FXA_MYSQL_USER)" FXA_PASSWORD="$(env_value FXA_MYSQL_PASSWORD)" \
        FXA_POLICY_USER="$(env_value FXA_MYSQL_POLICY_USER)" FXA_POLICY_PASSWORD="$(env_value FXA_MYSQL_POLICY_PASSWORD)" \
        FXA_ADMIN_PASSWORD="$(env_value FXA_ADMIN_DB_PASSWORD)"
    [ "${fxa_template}" = "${SCRIPT_DIR}/db/mysql/fxa-${FXA_DB}.sql" ] || rm -f "${fxa_template}"
fi

# prepare nginx example
cp ${SCRIPT_DIR}/config/nginx/syncstorage-rs-example.conf ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf
apply_sed ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf "s/firefox-sync.example.com/${SYNC_FQDN}/g"
apply_sed ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf "s|<SYNC_EXPORT_PORT>|${SYNC_EXPORT_PORT}|"

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
    # the database images from .env only (not this shell's environment); unset: lts, as the
    # compose files. podman needs the registry in the image name (compose is fine with
    # mariadb:lts): a first part with a dot or a port, or localhost, is one
    podman_image() {
        local image first
        image=$(env_plain "${1}")
        image=${image:-${2}}
        first=${image%%/*}
        if [ "${first}" != "${image}" ] && { [[ "${first}" == *[.:]* ]] || [ "${first}" = localhost ]; }; then
            :
        elif [[ "${image}" == */* ]]; then
            image=docker.io/${image}
        else
            image=docker.io/library/${image}
        fi
        export "${1}=${image}"
    }
    podman_image FXA_MARIADB_IMAGE mariadb:lts
    podman_image FXA_MYSQL_IMAGE mysql:lts
    podman_image SYNC_MYSQL_IMAGE mysql:lts
    # fxa-db's extra options, none when not set
    FXA_MYSQL_ARGS=$(env_plain FXA_MYSQL_ARGS)
    export FXA_MYSQL_ARGS

    # the database containers: the .env names (syncstorage_db) are compose's, here the
    # containers are reached by their names. Your own server: none of them
    SKIP_UNITS=""
    DROP_DEPS=""
    if [ "${SYNC_DB_CONTAINERS:-1}" = 0 ]; then
        SKIP_UNITS='^firefox-sync-(syncstorage|tokenserver)-db(-mysql)?\.(container|volume)$'
        DROP_DEPS='firefox-sync-(syncstorage|tokenserver)-db\.service'
    else
        export SYNC_STORAGE_DB_HOST=firefox-sync-syncstorage-db SYNC_STORAGE_DB_PORT=3306
        export SYNC_TOKENSERVER_DB_HOST=firefox-sync-tokenserver-db SYNC_TOKENSERVER_DB_PORT=3306
        if [ "${SYNC_DB:-mariadb}" = "mysql" ]; then
            # MariaDB's volumes, unused (the volumes themselves are kept); MySQL's certificate
            # is self-signed, the init container's client does not check it
            SKIP_UNITS='^firefox-sync-(syncstorage|tokenserver)-db\.volume$'
            export SYNC_DB_TLS_VERIFY=false
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
    # SYNC_DB=mysql: sync-mysql/ replaces the database units of the same name (without the
    # database containers, SKIP_UNITS leaves them out)
    [ "${SYNC_DB:-mariadb}" = "mysql" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/sync-mysql")
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
            [ "${SYNC_DB:-mariadb}" = "mysql" ] && [ -f "${source}/sync-mysql/${filename}" ] && continue
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
        echo "  MariaDB 11.4 or later (12: with our accounts images, FXA.md), with binary logging: log_bin_trust_function_creators=ON"
    else
        echo "  mysql -h ${FXA_MYSQL_HOST} -P ${FXA_MYSQL_PORT} -u root -p < database-setup-fxa.sql"
        if [ "${FXA_MYSQL2}" = 0 ]; then
            echo "  MySQL 8.4 or 9 with log_bin_trust_function_creators=ON"
        else
            echo "  MySQL 8.4 started with mysql_native_password=ON and log_bin_trust_function_creators=ON: the accounts"
            echo "  image has no mozilla/fxa#21554, its driver speaks mysql_native_password only (FXA.md#mysql-or-mariadb)"
        fi
    fi
fi
[ "${EXTERNAL_DB}" = "yes" ] || [ "${EXTERNAL_FXA_DB}" = "yes" ] && echo ""
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    if [ "${PINNED_FXA_MARIADB:-}" = "yes" ]; then
        echo "FXA_MARIADB_IMAGE=mariadb:11: the accounts database of this install stays on MariaDB 11."
        echo "  To move it to MariaDB lts, 12 (a backup first, there is no way back): FXA.md#moving-to-a-newer-mariadb"
    fi
    if [ -n "${FXA_MARIADB_VOLUME:-}" ]; then
        echo "FXA_MARIADB_IMAGE=mariadb:11: found the accounts database of an earlier install (${FXA_MARIADB_VOLUME}),"
        echo "  its data stays on MariaDB 11. Already on 12: set FXA_MARIADB_IMAGE=mariadb:lts. A new install: remove the volume"
        echo "  (its accounts are lost) and run this again. Moving it to lts: FXA.md#moving-to-a-newer-mariadb"
    fi
    if [ "${PINNED_FXA_MYSQL:-}" = "yes" ]; then
        echo "FXA_MYSQL_IMAGE=mysql:8, FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}: the accounts database"
        echo "  of this install stays on MySQL 8 with mysql_native_password. To move it to MySQL lts, 9: MIGRATING.md#mysql-lts"
    fi
    if [ -n "${FXA_MYSQL_VOLUME:-}" ]; then
        echo "FXA_MYSQL_IMAGE=mysql:8, FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}: found the accounts database"
        echo "  of an earlier install (${FXA_MYSQL_VOLUME}), its data stays on MySQL 8 with mysql_native_password."
        echo "  Already on 9: set FXA_MYSQL_IMAGE=mysql:lts and remove FXA_MYSQL_ARGS. A new install: remove the volume"
        echo "  (its accounts are lost) and run this again. Moving it to lts: MIGRATING.md#mysql-lts"
    elif [ "${FXA_DB}" = mysql ] && [ "${EXTERNAL_FXA_DB}" != yes ] && [ "${PREVIOUS_FXA_MYSQL}" != yes ] && [ "${FXA_MYSQL2}" != 0 ]; then
        if [ "${FXA_MYSQL2}" = 2 ]; then
            echo "NOTE: could not read the labels of $(env_value FXA_IMAGE):$(env_value FXA_VERSION): MySQL lts (9) needs"
        else
            echo "NOTE: $(env_value FXA_IMAGE):$(env_value FXA_VERSION) does not have mozilla/fxa#21554 (Mozilla's images, ours"
            echo "  built before it), which MySQL lts (9) needs"
        fi
        echo "  an accounts image with mozilla/fxa#21554 (the mysql2 driver): fxa-db runs MySQL 8 with mysql_native_password"
        echo "  (FXA_MYSQL_IMAGE=mysql:8, FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}), see FXA.md#mysql-or-mariadb"
    fi
    fxa_mariadb_image_check
    [ "${FXA_DB}" = mysql ] && fxa_mysql_image_check
fi
if [ "${DATABASE_BACKEND}" = postgres ] && [ -n "${SYNC_POSTGRES_MAJOR:-}" ]; then
    echo "SYNC_POSTGRES_IMAGE=postgres:${SYNC_POSTGRES_MAJOR}: PostgreSQL ${SYNC_POSTGRES_MAJOR}, the major of postgres:latest today, pinned: a newer"
    echo "  major cannot open its data. Moving later: DATABASES.md#another-postgresql-major"
elif [ "${DATABASE_BACKEND}" = postgres ] && [ "${PREVIOUS_SYNCSTORAGE_IMAGE}" != "syncstorage-rs-postgres" ]; then
    echo "WARNING: could not read the major of postgres:latest (docker or podman run postgres:latest postgres --version):"
    echo "  SYNC_POSTGRES_IMAGE is not set, postgres:latest, which a new PostgreSQL major leaves unable to start."
    echo "  Pin it in .env to the major it runs: SYNC_POSTGRES_IMAGE=postgres:<major> (DATABASES.md#another-postgresql-major)"
fi
if [ "${PINNED_SYNC_MYSQL:-}" = "yes" ]; then
    echo "SYNC_MYSQL_IMAGE=mysql:8: the Sync databases of this install stay on MySQL 8. To move them to MySQL lts, 9:"
    echo "  MIGRATING.md#mysql-lts"
fi
if [ -n "${SYNC_MYSQL_VOLUME:-}" ]; then
    echo "SYNC_MYSQL_IMAGE=mysql:8: found the Sync databases of an earlier install (${SYNC_MYSQL_VOLUME}), their data"
    echo "  stays on MySQL 8. Already on 9: set SYNC_MYSQL_IMAGE=mysql:lts. A new install: remove the volumes and run"
    echo "  this again. Moving them to lts: MIGRATING.md#mysql-lts"
fi

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
        COMPOSE_FILES="-f docker-compose.sync-postgres.yml"
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
