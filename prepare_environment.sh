#!/bin/bash

# Firefox Sync Environment Preparation Script
# Supports both Docker and Podman

# Set the locale to UTF-8
export LC_CTYPE=C
# set by the script itself only (env_file_read): one exported in the shell would redirect every read of .env
unset ENV_READ

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
# the checkout of this script (config/fxa/fixed-in), whatever directory the setup writes into
SELF_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

generate_random_string() {
  local length="${1}"
  tr -dc '[:alnum:]' < /dev/urandom | head -c "${length}"
}

# The temporary files that hold passwords (sed scripts, the .env being written, the units
# rendered aside) are removed at the exit, also on Ctrl-C (INT) and TERM: those of a subshell
# are in FFS_TMP, a directory of this user only (mktemp -d) that the main shell removes, the
# others listed with ffs_temp. The traps run after those set before (chained, not replaced)
FFS_TMP="" FFS_TEMPS=()
ffs_cleanup() {
    local f
    for f in ${FFS_TEMPS[@]+"${FFS_TEMPS[@]}"}; do rm -rf -- "${f}"; done
    FFS_TEMPS=()
    [ -n "${FFS_TMP}" ] && rm -rf -- "${FFS_TMP}"
    FFS_TMP=""
}
ffs_traps() {
    local sig before end main=yes
    # in a subshell the traps of the main shell are not set (trap -p still shows them): not
    # chained there (bash 3.2 has no BASHPID: the parent of a command of this shell)
    [ "$(exec sh -c 'echo "${PPID}"')" = "$$" ] || main=""
    for sig in EXIT INT TERM; do
        # (trap -p prints the trap as a command, quoted: its third word is the action)
        before=""
        [ -n "${main}" ] && { eval "set -- $(trap -p "${sig}")"; before=${3:-}; }
        case "${sig}" in INT) end="exit 130" ;; TERM) end="exit 143" ;; *) end="" ;; esac
        # shellcheck disable=SC2064 # (the action of before, as it is now)
        trap "ffs_cleanup${before:+; ${before}}${end:+; ${end}}" "${sig}"
    done
}
# ffs_temp <path>: removed at the exit
ffs_temp() { FFS_TEMPS+=("${1}"); }
# FFS_TMP and the traps, once, in the main shell (run: at the start; sourced: at the first need)
ffs_temp_init() {
    [ -n "${FFS_TMP}" ] && [ -d "${FFS_TMP}" ] && return 0
    FFS_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ffs.XXXXXX") || return 1
    ffs_traps
}
# (run, not sourced: return outside a function fails)
(return 0 2> /dev/null) || { ffs_temp_init || exit 1; }

# sed_script <script> <sed arguments...>: sed with its script in a file of this user only
# (in FFS_TMP; mktemp: 0600), never on the command line: the values of .env in it (passwords,
# secrets) would be in the arguments any user sees with ps while it runs
sed_script() {
    local script rc
    ffs_temp_init || return 1
    script=$(mktemp "${FFS_TMP}/sed.XXXXXX") || return 1
    printf '%s\n' "${1}" > "${script}" || { rm -f "${script}"; return 1; }
    shift
    sed -f "${script}" "$@"
    rc=$?
    rm -f "${script}"
    return "${rc}"
}

apply_sed() {
    local file=${1}
    shift
    local expression=${*}

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        # macOS: BSD sed requires an empty string with -i option
        sed_script "${expression}" -i '' "${file}"
    else
        # Linux and other Unix-like systems: GNU sed does not require anything after -i
        sed_script "${expression}" -i "${file}"
    fi
}

# escape a value for the replacement part of `sed s|...|...|`
sed_escape() {
    # (a line break: \ at the end of each line but the last)
    printf '%s' "${1}" | sed -e 's/[\\/&|]/\\&/g' -e '$!s/$/\\/'
}

# The Sync server's settings, renamed to the SYNC_ prefix (docs/upgrading.md#renamed-settings):
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

# a value of .env, as compose reads it (not with `source`: it is no shell script); env_value
# of a renamed setting reads the old name when the new one is not set, as compose does
# (a line of compose's .env may be indented or start with export; CRLF line ends). ENV_READ:
# another file to read (the copy --upgrade and the setup edit before it replaces .env)
ENV_LEAD='[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}'
env_file_read() { printf '%s' "${ENV_READ:-${SCRIPT_DIR}/.env}"; }
env_line() { grep "^${ENV_LEAD}${1}=" "$(env_file_read)" | sed -e "s/^[^=]*=//" | tr -d '\r'; }
env_has() { grep -q "^${ENV_LEAD}${1}=" "$(env_file_read)"; }
# the value as compose reads it (its dotenv parser), from the last line:
# - in single quotes: what is between them as written, but \' for a quote;
# - in double quotes: up to the first quote without a backslash, with the escapes \" \\ \n
#   \r \t (\a \b \f \v), \$ and $$ for a $; another backslash stays as it is;
# - otherwise: without a comment (" #..."), the spaces around, and $$ for a $.
# A comment after the quotes is dropped. Not as compose: ${NAME} and $NAME are not replaced
# with other values, and a quoted value goes on to the end of its line only
env_plain() {
    local v q c out="" i=1 esc=""
    v=$(env_line "${1}" | tail -n 1)
    v=${v#"${v%%[![:space:]]*}"}
    case "${v}" in
        \'*|\"*)
            q=${v:0:1}
            while [ "${i}" -lt "${#v}" ]; do
                c=${v:i:1} i=$((i + 1))
                if [ -n "${esc}" ]; then
                    esc=""
                    if [ "${c}" = "${q}" ]; then
                        out=${out}${c}
                    elif [ "${q}" = '"' ]; then
                        case "${c}" in
                            n) out=${out}$'\n' ;; r) out=${out}$'\r' ;; t) out=${out}$'\t' ;;
                            a) out=${out}$'\a' ;; b) out=${out}$'\b' ;; f) out=${out}$'\f' ;; v) out=${out}$'\v' ;;
                            \\|\$) out=${out}${c} ;;
                            *) out=${out}\\${c} ;;
                        esac
                    else
                        out=${out}\\${c}
                    fi
                elif [ "${c}" = \\ ]; then
                    esc=yes
                elif [ "${c}" = "${q}" ]; then
                    printf '%s' "${out}"
                    return
                elif [ "${q}" = '"' ] && [ "${c}" = \$ ] && [ "${v:i:1}" = \$ ]; then
                    out=${out}\$ i=$((i + 1))
                else
                    out=${out}${c}
                fi
            done
            # no closing quote (compose refuses the file): the rest of the line
            printf '%s' "${out}${esc:+\\}" ;;
        *)
            v=${v%% #*}
            v=${v%"${v##*[![:space:]]}"}
            while [[ "${v}" == *'$$'* ]]; do out=${out}${v%%'$$'*}\$ v=${v#*'$$'}; done
            printf '%s' "${out}${v}" ;;
    esac
}
# env_plain, with the old name of a renamed setting when the new one has no value
env_value() {
    local value old
    value=$(env_plain "${1}")
    old=$(old_name "${1}")
    [ -z "${value}" ] && [ -n "${old}" ] && value=$(env_plain "${old}")
    printf '%s\n' "${value}"
}
# a value for double quotes in .env, read back as it is (env_plain, compose): \ " and $ escaped
env_dq() { printf '%s' "${1}" | sed -e 's/[\\"$]/\\&/g'; }
# a backup name that is not taken: <path>-<UTC time>, -2, -3... after it within a second
backup_name() {
    local base n=2
    base=${1}-$(date -u +%Y%m%dT%H%M%SZ)
    [ ! -e "${base}" ] && { printf '%s' "${base}"; return; }
    while [ -e "${base}-${n}" ]; do n=$((n + 1)); done
    printf '%s' "${base}-${n}"
}
# a copy of an .env (passwords): this user only, whatever the mode of the original
private_copy() { rm -f "${2}" && (umask 077; cp "${1}" "${2}"); }
# the file a path names, its symlinks followed (readlink without -f: macOS before 12.3 has none)
resolve_path() {
    local path=${1} link n=0
    while [ -L "${path}" ] && [ "${n}" -lt 40 ]; do
        link=$(readlink "${path}") || break
        case "${link}" in /*) path=${link} ;; *) path=$(dirname "${path}")/${link} ;; esac
        n=$((n + 1))
    done
    printf '%s' "${path}"
}
# private_temp <path> <variable>: a new file of this user only (0600) next to path, named
# after it (mktemp: a name nobody could have put a symlink at), in the variable; removed at
# the exit unless moved (in this shell: not in a $(...))
private_temp() {
    local ffs_new
    ffs_new=$(mktemp "$(dirname "${1}")/.$(basename "${1}").XXXXXX") || return 1
    ffs_temp "${ffs_new}"
    printf -v "${2}" '%s' "${ffs_new}"
}
# replace_env <new> <.env>: the new file (this user only) in place of .env. A symlink stays one:
# its target is replaced, by a rename in the target's own directory, else (that directory not
# writable) by writing the content into it; 0600 in both cases
replace_env() {
    local new=${1} dest=${2} target tmp
    target=$(resolve_path "${dest}")
    [ "${target}" = "${dest}" ] && { mv "${new}" "${dest}"; return; }
    tmp=""
    if private_temp "${target}" tmp 2> /dev/null && cat "${new}" > "${tmp}" && chmod 600 "${tmp}" && mv "${tmp}" "${target}"; then
        rm -f "${new}"
        return 0
    fi
    [ -n "${tmp}" ] && rm -f "${tmp}"
    (umask 077; cat "${new}" > "${target}") && chmod 600 "${target}" && rm -f "${new}"
}
# the SQL for your own database server, with the names and passwords of .env (docs/databases.md#create-the-databases-and-users)
render_sql() {
    local template=${1} out=${2} pair script=""
    shift 2
    for pair in "$@"; do
        script="${script}s|@${pair%%=*}@|$(sed_escape "${pair#*=}")|g
"
    done
    rm -f "${out}"
    (umask 077; sed_script "${script}" "${template}" > "${out}")
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
# mozilla/fxa#21554 (the mysql2 driver). An image has one when its label
# org.firefox-sync.upstream-patches lists it (ours, while Mozilla has not released it), or when
# it is of the release that has it or a later one (config/fxa/fixed-in, once Mozilla released
# it: every image then, Mozilla's too; its release from the label org.opencontainers.image.version,
# else from the tag). Mozilla's (docker.io/mozilla/fxa-mono) and ours built before have no
# label. The local image first (what starts), then the registry (docker buildx imagetools or
# skopeo). Here and not in the admin UI, which cannot inspect images
# a label of the JSON of an image (docker or podman inspect, buildx imagetools, skopeo)
json_label() { grep -o "\"${1//./\\.}\": *\"[^\"]*\"" | head -n 1 | sed 's/.*: *"//; s/"$//'; }
fxa_image_inspect_local() {
    local image=${1} runtime out runtimes="docker podman"
    # the store of what runs the units: Podman's for the Quadlets (also on a host with Docker)
    [ "${DEPLOY_METHOD:-}" = quadlets ] && runtimes=podman
    for runtime in ${runtimes}; do
        command -v "${runtime}" > /dev/null 2>&1 || continue
        out=$(${runtime} image inspect "${image}" 2> /dev/null) && { printf '%s' "${out}"; return 0; }
    done
    return 1
}
fxa_image_inspect_remote() {
    local image=${1} out
    out=$(docker buildx imagetools inspect "${image}" --format '{{json .Image}}' 2> /dev/null) \
        || out=$(skopeo inspect "docker://${image}" 2> /dev/null) || return 1
    printf '%s' "${out}"
}
# has_fxa_patch <pull request> <label>: e.g. mozilla/fxa#21494 in "mozilla/fxa#21494@517651a..aa0b178 ..."
has_fxa_patch() { case " ${2} " in *" ${1}@"*) return 0 ;; esac; return 1; }
# fxa_fixed_in <pull request>: the first accounts release with it, once Mozilla released it
# (config/fxa/fixed-in of this checkout), nothing before
fxa_fixed_in() {
    local pr release rest file=${SELF_DIR}/config/fxa/fixed-in
    [ -f "${file}" ] || return 0
    while read -r pr release rest || [ -n "${pr}" ]; do
        [ "${pr}" = "${1}" ] && { printf '%s' "${release}"; return 0; }
    done < "${file}"
    return 0
}
# fxa_release <version or tag>: the release, 1.347.3 of v1.347.3, fxa-mono-v1.347.3 or
# 1.347.3; nothing for another tag (fxa-mono-latest, a digest...)
fxa_release() {
    local v=${1#fxa-mono-}
    v=${v#v}
    [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "${v}"
    return 0
}
# version_at_least <a> <b>: release a is b or later, part by part (1.350.0 after 1.347.10)
version_at_least() {
    local a=${1} b=${2} x y
    while [ -n "${a}${b}" ]; do
        x=${a%%.*} y=${b%%.*}
        x=$((10#${x:-0})) y=$((10#${y:-0}))
        [ "${x}" -gt "${y}" ] && return 0
        [ "${x}" -lt "${y}" ] && return 1
        [[ "${a}" == *.* ]] && a=${a#*.} || a=""
        [[ "${b}" == *.* ]] && b=${b#*.} || b=""
    done
    return 0
}
# fxa_has_fix <pull request> <patches label> <version label> <tag>: whether an accounts
# image with these has it: 0 yes, 1 no, 2 not known (released, but the image's release is not)
fxa_has_fix() {
    local fixed release
    has_fxa_patch "${1}" "${2}" && return 0
    fixed=$(fxa_release "$(fxa_fixed_in "${1}")")
    [ -n "${fixed}" ] || return 1
    release=$(fxa_release "${3}")
    [ -n "${release}" ] || release=$(fxa_release "${4}")
    [ -n "${release}" ] || return 2
    version_at_least "${release}" "${fixed}"
}
# the same for the JSON of an image <pull request> <json> <tag>
fxa_inspected_has() {
    fxa_has_fix "${1}" "$(printf '%s' "${2}" | json_label org.firefox-sync.upstream-patches)" \
        "$(printf '%s' "${2}" | json_label org.opencontainers.image.version)" "${3}"
}
# fxa_image_has <pull request>: whether the accounts image of .env (FXA_IMAGE:FXA_VERSION) has
# it: 0 yes, 1 no, 2 not known (no local copy and no answer of the registry). An older local
# copy without it while the registry's has it: yes, and FXA_IMAGE_PULL=yes (pull before starting).
# Asked once per image and pull request (FXA_IMAGE_ANSWERS)
FXA_IMAGE_ANSWERS=""
fxa_image_has() {
    local pr=${1} image tag info remote rc answer
    tag=$(env_value FXA_VERSION)
    image=$(env_value FXA_IMAGE):${tag}
    for answer in ${FXA_IMAGE_ANSWERS}; do
        [ "${answer%=*}" = "${image}|${pr}" ] || continue
        rc=${answer##*=}; FXA_IMAGE_PULL=${rc#?}; return "${rc%"${FXA_IMAGE_PULL}"}"
    done
    FXA_IMAGE_PULL=""
    case "${image}" in
        # Mozilla's: without the label, until the release that has it
        mozilla/fxa-mono:*|docker.io/mozilla/fxa-mono:*|index.docker.io/mozilla/fxa-mono:*)
            [ -n "$(fxa_fixed_in "${pr}")" ] || rc=1 ;;
    esac
    if [ -n "${rc}" ]; then
        :
    # Quadlets of another architecture (--arch): the units pull the registry's at every
    # start, so that one is what runs
    elif [ "${DEPLOY_METHOD:-}" = quadlets ] && [ -n "$(env_plain FXA_ARCH)" ] && [ "$(env_plain FXA_ARCH)" != "$(host_arch)" ] \
        && info=$(fxa_image_inspect_remote "${image}"); then
        fxa_inspected_has "${pr}" "${info}" "${tag}"; rc=$?
    elif info=$(fxa_image_inspect_local "${image}"); then
        fxa_inspected_has "${pr}" "${info}" "${tag}"; rc=$?
        # an older local copy: the registry's may have it, then a pull is enough
        if [ "${rc}" != 0 ] && remote=$(fxa_image_inspect_remote "${image}") && fxa_inspected_has "${pr}" "${remote}" "${tag}"; then
            rc=0 FXA_IMAGE_PULL=yes
        fi
    elif info=$(fxa_image_inspect_remote "${image}"); then
        fxa_inspected_has "${pr}" "${info}" "${tag}"; rc=$?
    else
        # nothing to read: once released, the release of its tag says it; else not known
        fxa_has_fix "${pr}" "" "" "${tag}"; rc=$?
        [ "${rc}" = 1 ] && { [ -z "$(fxa_fixed_in "${pr}")" ] || [ -z "$(fxa_release "${tag}")" ]; } && rc=2
    fi
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
        echo "  (label org.firefox-sync.upstream-patches, see docs/accounts.md#mysql-or-mariadb)"
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
    echo "  FXA_VERSION=fxa-mono-latest) or MariaDB 11 (FXA_MARIADB_IMAGE=mariadb:11), see docs/accounts.md#mysql-or-mariadb"
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
        echo "  their users on caching_sha2_password first: docs/upgrading.md#mysql-8-to-9 (or FXA_MYSQL_IMAGE=mysql:8)"
        echo ""
        return 0
    fi
    fxa_image_has mozilla/fxa#21554; rc=$?
    if [ "${rc}" = 0 ]; then
        if [ -n "${FXA_IMAGE_PULL}" ] && ! { mysql_8 "${db_image}" && [ "${native}" = yes ]; }; then
            echo "WARNING: your local ${image} does not have mozilla/fxa#21554, without which the accounts cannot"
            echo "  log in on MySQL ${db_image##*:}; the registry's has it: pull it before starting (docker compose pull, podman pull)"
            echo ""
        elif [ "${native}" = yes ] && [ "${UPGRADING:-}" = yes ]; then
            echo "NOTE: ${image} has mozilla/fxa#21554 (caching_sha2_password): the accounts database can move"
            echo "  from MySQL 8 with mysql_native_password to MySQL lts, when you choose: docs/upgrading.md#mysql-8-to-9"
            echo ""
        elif mysql_8 "${db_image}" && [ "${UPGRADING:-}" = yes ]; then
            # (the users' plugins are not known here)
            echo "NOTE: fxa-db is on MySQL 8 without FXA_MYSQL_ARGS (mysql_native_password off): users created before on"
            echo "  mysql_native_password cannot log in. Moving from the pin: step 2 (the users) before step 3 (the options),"
            echo "  docs/upgrading.md#mysql-8-to-9; SELECT user, host, plugin FROM mysql.user shows them"
            echo ""
        fi
        return 0
    fi
    # without it: only mysql_native_password, on MySQL 8 with the options
    mysql_8 "${db_image}" && [ "${native}" = yes ] && return 0
    if [ "${rc}" = 2 ]; then
        echo "NOTE: could not read the labels of ${image}: MySQL ${db_image##*:} without mysql_native_password"
        echo "  needs an accounts image with mozilla/fxa#21554 (label org.firefox-sync.upstream-patches, docs/accounts.md#mysql-or-mariadb)"
        echo ""
        return 0
    fi
    echo "WARNING: the accounts on MySQL ${db_image##*:} (FXA_MYSQL_IMAGE=${db_image}${args:+, FXA_MYSQL_ARGS=${args}}) need an image"
    echo "  with mozilla/fxa#21554, which ${image} does not have (Mozilla's images, or ours built before it):"
    echo "  they cannot log in. Use our images (FXA_IMAGE=ghcr.io/porelli/firefox-sync, FXA_VERSION=fxa-mono-latest)"
    echo "  or FXA_MYSQL_IMAGE=mysql:8 with FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}"
    echo "  (on a new database only: MySQL 8 cannot open MySQL 9's data), see docs/accounts.md#mysql-or-mariadb"
    echo ""
}
# this host's architecture as the images name it
host_arch() { case "$(uname -m)" in aarch64|arm64) echo arm64 ;; *) echo amd64 ;; esac; }
# the accounts of this install self-hosted (prepare_environment.sh wrote their passwords)
fxa_installed() {
    local pw
    pw=$(env_plain FXA_MYSQL_PASSWORD)
    [ -n "${pw}" ] && [[ "${pw}" != *"<REPLACE_WITH_"* ]]
}

# a database volume of an earlier install (the .env gone, or for another database):
# "<runtime> volume <name>", for any of the names given (compose: <project>_<name>, Quadlets:
# firefox-sync-<name>), e.g. db_volume fxa-db-mariadb
db_volume() {
    local project runtime volume name
    # compose's project: COMPOSE_PROJECT_NAME (this shell's, then .env's), else the directory
    project=${COMPOSE_PROJECT_NAME:-$( [ -f "${SCRIPT_DIR}/.env" ] && env_plain COMPOSE_PROJECT_NAME)}
    project=$(printf '%s' "${project:-$(basename "${SCRIPT_DIR}")}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    for runtime in docker podman; do
        command -v "${runtime}" > /dev/null 2>&1 || continue
        for name in "$@"; do
            # (the Quadlets' names only for them: they are the same on every install of this user)
            for volume in "${project}_${name}" $([ "${DEPLOY_METHOD:-}" = quadlets ] && echo "firefox-sync-${name}"); do
                ${runtime} volume inspect "${volume}" > /dev/null 2>&1 && { echo "${runtime} volume ${volume}"; return 0; }
            done
        done
    done
    return 1
}

# the major of postgres:latest, from its own server ("postgres (PostgreSQL) 18.1 (Debian ...)"):
# pulled first (a local copy may be older than latest), with Docker, else Podman (a Docker
# without its daemon fails at once); without a registry, the local copy
postgres_latest_major() {
    local runtime image pull out
    for pull in always missing; do
        for runtime in docker podman; do
            command -v "${runtime}" > /dev/null 2>&1 || continue
            image=postgres:latest
            [ "${runtime}" = podman ] && image=docker.io/library/postgres:latest
            out=$(${runtime} run --rm --pull="${pull}" --entrypoint postgres "${image}" --version 2> /dev/null) || continue
            out=$(printf '%s' "${out}" | sed -n 's/^postgres (PostgreSQL) \([0-9][0-9]*\)[^0-9].*/\1/p')
            [ -n "${out}" ] && { echo "${out}"; return 0; }
        done
    done
    return 1
}
# the major of the MySQL data in a volume of db_volume ("<runtime> volume <name>"): the last
# version of its mysql_upgrade_history (8.4 and later write it); none, an empty volume or one of
# 8.0: nothing (fails)
mysql_volume_major() {
    local runtime=${1} volume=${3} image=mysql:lts
    [ "${runtime}" = podman ] && image=docker.io/library/mysql:lts
    ${runtime} run --rm --pull=missing -v "${volume}:/v:ro" --entrypoint sh "${image}" -c 'cat /v/mysql_upgrade_history' 2> /dev/null \
        | grep -o '"version" *: *"[0-9]*' | tail -n 1 | sed 's/.*"//' | grep -x '[0-9][0-9]*'
}
# the major of the PostgreSQL data in a volume of db_volume ("<runtime> volume <name>"): its
# PG_VERSION (at the top or in data/ before 18, in <major>/docker/ since)
postgres_volume_major() {
    local runtime=${1} volume=${3} image=postgres:latest
    [ "${runtime}" = podman ] && image=docker.io/library/postgres:latest
    ${runtime} run --rm --pull=missing -v "${volume}:/v:ro" --entrypoint sh "${image}" -c \
        'for f in /v/PG_VERSION /v/data/PG_VERSION /v/*/docker/PG_VERSION; do [ -s "$f" ] && { cat "$f"; exit 0; }; done; exit 1' 2> /dev/null \
        | grep -x '[0-9][0-9]*'
}

# the major of the MariaDB data in a volume of db_volume: what mariadb-install-db and
# mariadb-upgrade wrote ("11.8.9-MariaDB"; mysql_upgrade_info before 10.11)
mariadb_volume_major() {
    local runtime=${1} volume=${3} image=mariadb:lts
    [ "${runtime}" = podman ] && image=docker.io/library/mariadb:lts
    ${runtime} run --rm --pull=missing -v "${volume}:/v:ro" --entrypoint sh "${image}" -c \
        'cat /v/mariadb_upgrade_info /v/mysql_upgrade_info 2> /dev/null | tr -d "\0"' 2> /dev/null \
        | sed -n '1s/^\([0-9][0-9]*\)\..*/\1/p' | grep -x '[0-9][0-9]*'
}
# the major of the MariaDB a running Sync database container runs (compose's tokenserver_db of
# the project, the Quadlets' firefox-sync-tokenserver-db)
mariadb_running_major() {
    local project runtime ctr
    project=${COMPOSE_PROJECT_NAME:-$( [ -f "${SCRIPT_DIR}/.env" ] && env_plain COMPOSE_PROJECT_NAME)}
    project=$(printf '%s' "${project:-$(basename "${SCRIPT_DIR}")}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    for runtime in docker podman; do
        command -v "${runtime}" > /dev/null 2>&1 || continue
        for ctr in $(${runtime} ps -q --filter "label=com.docker.compose.project=${project}" --filter label=com.docker.compose.service=tokenserver_db 2> /dev/null) \
            $([ "${DEPLOY_METHOD:-}" = quadlets ] && echo firefox-sync-tokenserver-db); do
            ${runtime} exec "${ctr}" mariadbd --version 2> /dev/null | sed -n 's/.* Ver \([0-9][0-9]*\)\..*/\1/p' | grep -x '[0-9][0-9]*' && return 0
        done
    done
    return 1
}
# the major of the Sync MariaDB data of this install: its volume, else its running server
sync_mariadb_major() {
    local volume
    volume=$(db_volume tokenserver-db syncstorage-db) && mariadb_volume_major ${volume} && return 0
    mariadb_running_major
}

# where the Quadlet units go; timers are plain systemd units, not Quadlets
QUADLET_DIR="${QUADLET_DIR:-${HOME}/.config/containers/systemd}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user}"
# the units of this install: installed, and rendered from this directory (they mount its
# config/backup and db/), not from another checkout
units_installed() { [ -f "${QUADLET_DIR}/firefox-sync-syncstorage.container" ]; }
# the directory the installed units were rendered from ("": not known)
units_dir() {
    grep -h '^Volume=/.*/config/backup:' "${QUADLET_DIR}"/firefox-sync-backup.container 2> /dev/null \
        | head -n 1 | sed -e 's|^Volume=||; s|/config/backup:.*||'
}
# a directory without its symlinks (cd -P: macOS and Linux), as it is when it is gone
canonical_dir() { (cd -P -- "${1}" 2> /dev/null && pwd -P) || printf '%s' "${1}"; }
units_of_here() {
    local dir
    dir=$(units_dir)
    [ -n "${dir}" ] && [ "$(canonical_dir "${dir}")" = "$(canonical_dir "${SCRIPT_DIR}")" ]
}
# units of this project that name no checkout: those of an earlier release, before the
# units mounted files of it (the releases before the backups, firefox-sync's main branch).
# Ours: the Sync server's unit runs the container firefox-sync-syncstorage of a syncstorage-rs image
units_without_dir() {
    local unit=${QUADLET_DIR}/firefox-sync-syncstorage.container
    units_installed && [ -z "$(units_dir)" ] && grep -qx 'ContainerName=firefox-sync-syncstorage' "${unit}" \
        && grep -q '^Image=.*syncstorage-rs' "${unit}"
}
# whether the installed Sync server's unit has the SYNC_MASTER_SECRET of .env, as a unit
# rendered from it has (compared here, not on a command line; systemd's %% for a %)
units_have_env_secret() {
    local unit env
    env=$(env_value SYNC_MASTER_SECRET)
    unit=$(sed -n 's/^Environment=\("\{0,1\}\)SYNC_MASTER_SECRET=/\1/p' "${QUADLET_DIR}/firefox-sync-syncstorage.container" | head -n 1)
    case "${unit}" in \"*\") unit=${unit:1:${#unit}-2} ;; esac
    [ -n "${env}" ] && [[ "${env}" != *"<REPLACE_WITH_"* ]] || return 1
    [ "${unit}" = "${env}" ] || [ "${unit}" = "${env//\%/%%}" ]
}

# the Quadlet units of .env, with the units SELF_HOST_FXA and ADMIN_UI say (the answers of
# the setup, or what the install has with --upgrade): rendered aside, then only the units
# that differ installed, the units of before kept first in quadlets.before-<UTC time>/; none
# differ: nothing written (run again, nothing changes)
render_units() {
    local key stage file filename source target_dir changed=() removed=() backup repository
    local sync_containers sync_db fxa_containers fxa_db
    # the values of the units: those of .env (database names, users, FxA endpoints, etc.) as
    # compose reads them (env_plain: quotes, a comment after the value, export, CRLF), and the
    # ones set below; never this shell's environment (a name .env lacks: .env-example's
    # default). Not with `source`: unused sections keep placeholders like <REPLACE_WITH_...>
    RENDER_KEYS=" "
    # (shell variables, not exported: no other process gets the passwords in its environment)
    render_set() { printf -v "${1}" '%s' "${2}"; RENDER_KEYS="${RENDER_KEYS}${1} "; }
    render_set SCRIPT_DIR "${SCRIPT_DIR}"
    for key in $(sed -n "s/^${ENV_LEAD}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p" "${SCRIPT_DIR}/.env" | sort -u); do
        render_set "${key}" "$(env_plain "${key}")"
    done
    sync_containers=$(env_plain SYNC_DB_CONTAINERS) sync_db=$(env_plain SYNC_DB)
    fxa_containers=$(env_plain FXA_DB_CONTAINERS) fxa_db=$(env_plain FXA_DB)
    mkdir -p "${QUADLET_DIR}" "${SYSTEMD_USER_DIR}"
    # the images from .env only (not this shell's environment); unset: lts, as the compose
    # files (the admin UI's: IMAGE_REPOSITORY's admin-latest). podman needs the registry in
    # the image name (compose is fine with mariadb:lts): a first part with a dot or a port,
    # or localhost, is one
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
        render_set "${1}" "${image}"
    }
    podman_image SYNC_MARIADB_IMAGE mariadb:lts
    podman_image FXA_MARIADB_IMAGE mariadb:lts
    podman_image FXA_MYSQL_IMAGE mysql:lts
    podman_image SYNC_MYSQL_IMAGE mysql:lts
    repository=$(env_value IMAGE_REPOSITORY)
    podman_image ADMIN_IMAGE "${repository:-ghcr.io/porelli/firefox-sync}:admin-latest"
    # fxa-db's extra options, none when not set
    render_set FXA_MYSQL_ARGS "$(env_plain FXA_MYSQL_ARGS)"
    # fxa-auth's log level, INFO when not set (as compose)
    FXA_LOG_LEVEL=$(env_plain FXA_LOG_LEVEL)
    render_set FXA_LOG_LEVEL "${FXA_LOG_LEVEL:-INFO}"
    # the accounts' units: --arch only for another architecture than this host's (an emulated
    # image). With it podman 4 pulls the tag from the registry at every start, over the local
    # image: the units would not run the image whose label chose FXA_MYSQL_IMAGE above
    FXA_ARCH_ARGS=""
    # (none in an .env from before FXA_ARCH: the host's)
    [ -z "$(env_plain FXA_ARCH)" ] || [ "$(env_plain FXA_ARCH)" = "$(host_arch)" ] || FXA_ARCH_ARGS="--arch=$(env_plain FXA_ARCH)"
    render_set FXA_ARCH_ARGS "${FXA_ARCH_ARGS}"

    # the database containers: the .env names (syncstorage_db) are compose's, here the
    # containers are reached by their names. Your own server: none of them
    SKIP_UNITS=""
    DROP_DEPS=""
    if [ "${sync_containers:-1}" = 0 ]; then
        SKIP_UNITS='^firefox-sync-(syncstorage|tokenserver)-db(-mysql)?\.(container|volume)$'
        DROP_DEPS='firefox-sync-(syncstorage|tokenserver)-db\.service'
    else
        render_set SYNC_STORAGE_DB_HOST firefox-sync-syncstorage-db; render_set SYNC_STORAGE_DB_PORT 3306
        render_set SYNC_TOKENSERVER_DB_HOST firefox-sync-tokenserver-db; render_set SYNC_TOKENSERVER_DB_PORT 3306
        if [ "${sync_db:-mariadb}" = "mysql" ]; then
            # MariaDB's volumes, unused (the volumes themselves are kept); MySQL's certificate
            # is self-signed, the init container's client does not check it
            SKIP_UNITS='^firefox-sync-(syncstorage|tokenserver)-db\.volume$'
            render_set SYNC_DB_TLS_VERIFY false
        fi
    fi
    if [ "${fxa_containers:-1}" = 0 ]; then
        SKIP_UNITS="${SKIP_UNITS:+${SKIP_UNITS}|}^firefox-sync-fxa-db(-mariadb)?\.(container|volume)$"
        DROP_DEPS="${DROP_DEPS:+${DROP_DEPS}|}firefox-sync-fxa-db\.service"
    elif [ "${fxa_db:-mysql}" = "mariadb" ]; then
        # MySQL's volume, unused (the volume itself is kept)
        SKIP_UNITS="${SKIP_UNITS:+${SKIP_UNITS}|}^firefox-sync-fxa-db\.volume$"
    fi
    # Requires= on a unit that is not installed fails the start: drop those dependencies
    drop_deps() {
        [ -n "${DROP_DEPS}" ] || { cat; return; }
        sed -E -e "/^(After|Requires)=/{s/(=| )(${DROP_DEPS})/\1/g; s/= +/=/; s/ +$//; s/  +/ /g;}" -e '/^Requires=$/d'
    }

    # fill the %NAME% placeholders from .env (and SCRIPT_DIR); systemd expands %, double it.
    # One sed script (a file, sed_script: the values are passwords), its substitutions in the
    # order of the names
    render_quadlet() {
        local file=${1} content name value script=""
        for name in $(grep -o '%[A-Z][A-Z0-9_]*%' "${file}" | sort -u | tr -d '%'); do
            if [[ "${RENDER_KEYS}" == *" ${name} "* ]]; then
                value=${!name}
            elif ENV_READ="${SCRIPT_DIR}/.env-example" env_has "${name}"; then
                value=$(ENV_READ="${SCRIPT_DIR}/.env-example" env_plain "${name}")
            else
                echo "ERROR: ${file} needs ${name}, which is not set in .env" >&2
                return 1
            fi
            value=$(printf '%s' "${value}" | sed -e 's/%/%%/g')
            script="${script}s|%${name}%|$(sed_escape "${value}")|g
"
        done
        content=$(sed_script "${script}" "${file}") || return 1
        printf '%s\n' "${content}"
    }

    QUADLET_SOURCES=("${SCRIPT_DIR}/config/quadlet")
    # SYNC_DB=mysql: sync-mysql/ replaces the database units of the same name (without the
    # database containers, SKIP_UNITS leaves them out)
    [ "${sync_db:-mariadb}" = "mysql" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/sync-mysql")
    [ "${SELF_HOST_FXA}" = "yes" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/fxa")
    # FXA_DB=mariadb: fxa/mariadb/ replaces the files of the same name in fxa/
    [ "${SELF_HOST_FXA}" = "yes" ] && [ "${fxa_db:-mysql}" = "mariadb" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/fxa/mariadb")
    if [ "${ADMIN_UI}" = "yes" ]; then
        # with the accounts, the admin UI also manages them
        [ "${SELF_HOST_FXA}" = "yes" ] && QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/fxa/admin") || QUADLET_SOURCES+=("${SCRIPT_DIR}/config/quadlet/admin")
    fi
    echo "Processing quadlet files..."
    stage=$(mktemp -d) || exit 1
    ffs_temp "${stage}"
    for source in "${QUADLET_SOURCES[@]}"; do
        for file in "${source}"/*.{network,volume,container,timer}; do
            [ -f "${file}" ] || continue
            filename=$(basename "${file}")
            [ "${fxa_db:-mysql}" = "mariadb" ] && [ -f "${source}/mariadb/${filename}" ] && continue
            [ "${sync_db:-mariadb}" = "mysql" ] && [ -f "${source}/sync-mysql/${filename}" ] && continue
            if [ -n "${SKIP_UNITS}" ] && [[ "${filename}" =~ ${SKIP_UNITS} ]]; then
                # left from a setup with the database containers (the volume is kept)
                [ -f "${QUADLET_DIR}/${filename}" ] && removed+=("${filename}")
                continue
            fi
            # (an empty PodmanArgs= would reset the ones before it, the network aliases)
            render_quadlet "${file}" | drop_deps | sed -e '/^PodmanArgs=$/d' > "${stage}/${filename}"
            [ "${PIPESTATUS[0]}" = 0 ] || { rm -rf "${stage}"; exit 1; }
        done
    done
    for file in "${stage}"/*; do
        filename=$(basename "${file}")
        target_dir=${QUADLET_DIR}
        [[ "${filename}" == *.timer ]] && target_dir=${SYSTEMD_USER_DIR}
        cmp -s "${file}" "${target_dir}/${filename}" || changed+=("${filename}")
    done
    if [ "${#changed[@]}" = 0 ] && [ "${#removed[@]}" = 0 ]; then
        rm -rf "${stage}"
        echo "  the units in ${QUADLET_DIR} are those of .env already: nothing changed"
        UNITS_CHANGED=""
        return 0
    fi
    # the units of before (their passwords too: this user only), all of them
    # (nothing is written when that copy fails)
    if ls "${QUADLET_DIR}"/firefox-sync-* "${SYSTEMD_USER_DIR}"/firefox-sync-*.timer > /dev/null 2>&1; then
        backup=$(backup_name "${SCRIPT_DIR}/quadlets.before")
        if ! (umask 077; mkdir "${backup}" && for file in "${QUADLET_DIR}"/firefox-sync-* "${SYSTEMD_USER_DIR}"/firefox-sync-*.timer; do
                [ -e "${file}" ] || continue; cp "${file}" "${backup}/" || exit 1; done); then
            rm -rf "${stage}" "${backup}"
            echo "ERROR: could not keep the units of before in ${backup}: no unit written" >&2
            exit 1
        fi
        echo "  the units of before: ${backup}"
    fi
    for filename in "${changed[@]}"; do
        target_dir=${QUADLET_DIR}
        [[ "${filename}" == *.timer ]] && target_dir=${SYSTEMD_USER_DIR}
        cp "${stage}/${filename}" "${target_dir}/${filename}" || { rm -rf "${stage}"; exit 1; }
        echo "  ✓ ${filename}"
    done
    for filename in "${removed[@]}"; do
        rm -f "${QUADLET_DIR}/${filename}"
        echo "  - ${filename} (removed)"
    done
    rm -rf "${stage}"
    UNITS_CHANGED="${changed[*]} ${removed[*]}"

    echo ""
    echo "Reloading systemd daemon..."
    systemctl --user daemon-reload
}

# ./prepare_environment.sh --upgrade: the .env of an install that runs (docker compose), given
# the settings of this release that need a value of their own (docs/upgrading.md#older-firefox-sync-releases), nothing else
# changed: the admin UI's database users (ADMIN_DB_PASSWORD; the event log moves out of the
# Sync server's reach at the next start), the Sync server's own role in the PostgreSQL
# container (SYNC_POSTGRES_APP_USER, SYNC_POSTGRES_APP_PASSWORD), and in COMPOSE_FILE the new name of
# docker-compose.postgres.yml (docker-compose.sync-postgres.yml), and with the accounts on
# MariaDB FXA_MARIADB_IMAGE=mariadb:11, the major they run (the compose default is now
# mariadb:lts, 12: written out, they stay on 11; a move is up to the admin, docs/upgrading.md#mariadb), on MySQL
# FXA_MYSQL_IMAGE=mysql:8 and FXA_MYSQL_ARGS with mysql_native_password, Sync on MySQL
# SYNC_MYSQL_IMAGE=mysql:8 (the default is now mysql:lts, 9; docs/upgrading.md#mysql-8-to-9). A value already set is kept; the
# old file is kept as .env.before-upgrade-<UTC time>. With your own database server database-setup.sql
# is written again, to run there first. First the settings of RENAMED_SETTINGS get their new
# names, their values as they are.
# The Quadlets (their units installed from this directory, or --render-units): the same, then
# the settings of .env-example that .env lacks added with their defaults (a new secret only
# for a secret that is missing: every password and secret of .env stays), and the units
# rendered again from .env (render_units), with the units of before kept; no question asked.
# Also to apply a setting changed in .env, or an image pinned there. Run again, nothing
# changes (docs/upgrading.md#quadlets)
upgrade_env() {
    local env_file dot_env backup name changed=() quadlets=no here
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    dot_env=${SCRIPT_DIR}/.env
    [ -f "${dot_env}" ] || { echo "ERROR: no ${dot_env} to upgrade: run ./prepare_environment.sh"; exit 1; }
    if [ "${RENDER_UNITS:-}" = yes ]; then
        quadlets=yes
        # a compose install is no Quadlet one: a first render only when asked for
        if ! units_installed && [ "${RENDER_FRESH:-}" != yes ]; then
            echo "ERROR: no Quadlet units in ${QUADLET_DIR}: --render-units renders those of an install again."
            echo "  To install the units of this .env (it then runs with Quadlets): ./prepare_environment.sh --render-units --fresh"
            exit 1
        fi
        if units_installed && ! units_of_here; then
            here=$(units_dir)
            if [ -n "${here}" ]; then
                echo "WARNING: the units in ${QUADLET_DIR} were rendered from ${here}, not ${SCRIPT_DIR}:"
            else
                echo "WARNING: the units in ${QUADLET_DIR} name no checkout (an earlier release of firefox-sync, or none of its):"
            fi
            echo "  rendered again from this .env (the units of before are kept)"
        fi
    elif units_installed; then
        here=$(units_dir)
        if units_of_here; then
            quadlets=yes
        # an earlier release's units, without the checkout in them: this install's when they have
        # its SYNC_MASTER_SECRET, else they are only said (docs/upgrading.md#quadlets)
        elif units_without_dir && units_have_env_secret; then
            quadlets=yes
            echo "NOTE: the Quadlet units in ${QUADLET_DIR} are of an earlier release of firefox-sync (they name no"
            echo "  checkout), with the SYNC_MASTER_SECRET of ${dot_env}: rendered again from it"
            echo ""
        elif units_without_dir; then
            echo "NOTE: found the Quadlet units of an earlier release of firefox-sync in ${QUADLET_DIR} (they name no"
            echo "  checkout), with another SYNC_MASTER_SECRET than ${dot_env}: not rendered again. If they are those of"
            echo "  this install, ./prepare_environment.sh --render-units renders them from this .env (docs/upgrading.md#quadlets)"
            echo ""
        else
            echo "NOTE: the Quadlet units in ${QUADLET_DIR} are those of ${here:-another directory}, not of ${SCRIPT_DIR}:"
            echo "  not rendered again (./prepare_environment.sh --render-units renders them from this .env)"
            echo ""
        fi
    fi
    if [ "${quadlets}" = yes ]; then
        command -v podman > /dev/null 2>&1 || { echo "ERROR: --render-units: the Quadlets need podman, which is not installed"; exit 1; }
        [ "$(env_value SYNC_IMAGE)" != "syncstorage-rs-postgres" ] \
            || { echo "ERROR: the Quadlets are for MariaDB and MySQL only, this .env is PostgreSQL's (docker compose)"; exit 1; }
        DEPLOY_METHOD=quadlets
    fi
    # the old names of RENAMED_SETTINGS: the line renamed where it is (indented or with
    # export, as compose reads it too), the rest of it as it is written. Both names there:
    # the new one is kept, unless it has no value of its own (empty, a placeholder or the
    # default of .env-example, e.g. added from it: then the old one's value); the old line
    # goes. A WARNING when what compose runs with changes; every value of before stays in
    # .env.before-upgrade-<UTC time>
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
        echo "Renamed in .env, the values as they were (docs/upgrading.md#renamed-settings):"
        printf '  %s\n' "${moved[@]}"
        [ "${#notes[@]}" = 0 ] || printf '  NOTE: %s\n' "${notes[@]}"
        if [ "${#warnings[@]}" != 0 ]; then
            printf 'WARNING: %s\n' "${warnings[@]}"
            echo "  Check them before starting: .env.before-upgrade-<UTC time> has the previous file."
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
        if env_has "${1}"; then
            apply_sed "${env_file}" "s|^\(${ENV_LEAD}\)${1}=.*|\1${1}=$(sed_escape "${2}")|"
        else
            printf '%s=%s\n' "${1}" "${2}" >> "${env_file}"
        fi
        changed+=("${1}")
    }
    # every change on a copy (this user only), which replaces .env at the end: a run that stops
    # halfway leaves .env as it was
    # (mktemp in the directory of .env: the rename at the end stays one)
    private_temp "${dot_env}.upgrading" env_file && cat "${dot_env}" > "${env_file}" || exit 1
    ENV_READ=${env_file}
    rename_settings
    # the names: those of .env-example
    for name in ADMIN_DB_NAME ADMIN_DB_USER ADMIN_DB_SYNC_USER; do
        env_has "${name}" || set_value "${name}" "$(grep "^${name}=" "${SCRIPT_DIR}/.env-example" | cut -d= -f2-)"
    done
    [ -n "$(env_value ADMIN_DB_PASSWORD)" ] || set_value ADMIN_DB_PASSWORD "$(generate_random_string 32)"
    # docker-compose.postgres.yml is now docker-compose.sync-postgres.yml (the old name is a
    # symlink to it for a transition period, docs/upgrading.md#files-that-moved): the new name in COMPOSE_FILE
    local compose_file compose_new part parts=() renamed=no
    compose_file=$(env_value COMPOSE_FILE)
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
    if [ "$(env_value SYNC_IMAGE)" = "syncstorage-rs-postgres" ] && ! env_has SYNC_POSTGRES_IMAGE; then
        set_value SYNC_POSTGRES_IMAGE postgres:18
        echo "SYNC_POSTGRES_IMAGE=postgres:18: the Sync database stays on PostgreSQL 18. To move it to"
        echo "  a newer major: a dump and restore or pg_upgrade (docs/upgrading.md#postgresql)"
    fi
    # the accounts on MariaDB, from before FXA_MARIADB_IMAGE: on 11, they stay there (unset
    # it is now mariadb:lts, which would upgrade their data to 12 at the next start)
    if [ "$(env_value FXA_DB)" = mariadb ] && ! env_has FXA_MARIADB_IMAGE; then
        set_value FXA_MARIADB_IMAGE mariadb:11
        echo "FXA_MARIADB_IMAGE=mariadb:11: the accounts database stays on MariaDB 11. To move it to"
        echo "  MariaDB lts, 12 (a backup first, there is no way back): docs/upgrading.md#mariadb"
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
        echo "  way back): docs/upgrading.md#mysql-8-to-9"
    fi
    # Sync on MariaDB containers, from before SYNC_MARIADB_IMAGE (they ran mariadb:lts): on the
    # major their data holds, they stay there (unset, a pull after the next major would upgrade
    # it; the containers refuse that, db/mysql/keep-major.sh)
    if [ "$(env_value SYNC_DB)" != mysql ] && [ "$(env_value SYNC_IMAGE)" != "syncstorage-rs-postgres" ] \
        && [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ] && ! env_has SYNC_MARIADB_IMAGE; then
        if major=$(sync_mariadb_major); then
            set_value SYNC_MARIADB_IMAGE "mariadb:${major}"
            echo "SYNC_MARIADB_IMAGE=mariadb:${major}: the Sync databases stay on MariaDB ${major}, the major of their data. To follow"
            echo "  MariaDB lts again (a backup first, there is no way back): SYNC_MARIADB_IMAGE=mariadb:lts (docs/upgrading.md#database-majors)"
        else
            echo "WARNING: could not read the MariaDB major of the Sync databases (no volume or running container found):"
            echo "  SYNC_MARIADB_IMAGE is not set; set it to the major they run, SYNC_MARIADB_IMAGE=mariadb:<major>. Until then the"
            echo "  containers refuse data of another major than mariadb:lts's (db/mysql/keep-major.sh)"
        fi
    fi
    # Sync on MySQL containers, from before SYNC_MYSQL_IMAGE: on 8, they stay there (unset it
    # is now mysql:lts, 9)
    if [ "$(env_value SYNC_DB)" = mysql ] && [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ] && ! env_has SYNC_MYSQL_IMAGE; then
        set_value SYNC_MYSQL_IMAGE mysql:8
        echo "SYNC_MYSQL_IMAGE=mysql:8: the Sync databases stay on MySQL 8. To move them to MySQL lts, 9"
        echo "  (a backup first, there is no way back): docs/upgrading.md#mysql-8-to-9"
    fi
    # the Quadlets have no defaults of their own: every setting of .env-example in .env, as a
    # new setup writes it. A secret only when it is not there at all, the accounts' only
    # with the accounts (their placeholders say they are not set up)
    add_missing_settings() {
        local line key value fxa=no added=() generated=()
        fxa_installed && fxa=yes
        # (an .env without a line end at its end)
        [ -z "$(tail -c 1 "${env_file}")" ] || echo "" >> "${env_file}"
        while IFS= read -r line || [ -n "${line}" ]; do
            [[ "${line}" =~ ^[A-Z][A-Z0-9_]*= ]] || continue
            key=${line%%=*}
            env_has "${key}" && continue
            case "${key}" in
                # the units of an .env from before it ran the accounts on this host's architecture
                FXA_ARCH) line="FXA_ARCH=$(host_arch)" ;;
            esac
            if [[ "${line}" == *"<REPLACE_WITH_SOMETHING_SECURE>"* ]] && { [[ "${key}" != FXA_* ]] || [ "${fxa}" = yes ]; }; then
                line="${key}=$(generate_random_string 32)"
                generated+=("${key}")
            else
                added+=("${key}")
            fi
            printf '%s\n' "${line}" >> "${env_file}"
            changed+=("${key}")
        done < "${SCRIPT_DIR}/.env-example"
        [ "${#added[@]}" = 0 ] || echo "Added from .env-example, with their defaults: ${added[*]}"
        [ "${#generated[@]}" = 0 ] || echo "Generated, as they were not in .env: ${generated[*]}"
    }
    [ "${quadlets}" = yes ] && add_missing_settings
    old_names_in_environment
    if [ "${#changed[@]}" = 0 ]; then
        rm -f "${env_file}"
        echo "Nothing to add: ${dot_env} has every setting of this release."
    else
        backup=$(backup_name "${dot_env}.before-upgrade")
        private_copy "${dot_env}" "${backup}" || { echo "ERROR: could not keep ${dot_env} as ${backup}: .env not changed"; rm -f "${env_file}"; exit 1; }
        replace_env "${env_file}" "${dot_env}" || exit 1
        echo "Updated ${dot_env} (the old one is $(basename "${backup}")): ${changed[*]}"
    fi
    unset ENV_READ
    # the passwords: this user only
    chmod 600 "${dot_env}"
    if [ "$(env_value SYNC_DB_CONTAINERS)" = 0 ]; then
        [ "$(env_value SYNC_IMAGE)" = "syncstorage-rs-postgres" ] && render_sync_sql postgres || render_sync_sql mariadb
        echo "Your own database server: run database-setup.sql there first, as its administrator (docs/databases.md#create-the-databases-and-users)."
    fi
    fxa_mariadb_image_check
    fxa_installed && UPGRADING=yes fxa_mysql_image_check
    if [ "${quadlets}" = yes ]; then
        # the units of this install: the accounts' with them, the admin UI's when it is on
        SELF_HOST_FXA=no ADMIN_UI=no
        fxa_installed && SELF_HOST_FXA=yes
        case ",$(env_plain COMPOSE_PROFILES)," in *,admin,*) ADMIN_UI=yes ;; esac
        [ -f "${QUADLET_DIR}/firefox-sync-admin.container" ] && ADMIN_UI=yes
        echo ""
        echo "Rendering the Quadlet units from ${dot_env}..."
        render_units
        echo ""
        echo "Then: the new images (podman does not pull a tag it has),"
        echo "  grep -h '^Image=' ${QUADLET_DIR}/firefox-sync-*.container | cut -d= -f2 | sort -u | xargs -n1 podman pull"
        if [ -n "${UNITS_CHANGED// /}" ]; then
            echo "  and start the units again: stopped, systemctl --user start$([ "${ADMIN_UI}" = yes ] && echo " firefox-sync-admin.service") firefox-sync-syncstorage.service"
            echo "  (running: systemctl --user restart of the units changed above)"
        fi
    else
        echo "Then: docker compose pull && docker compose up -d"
    fi
    exit 0
}
# an IPv4 address: four numbers up to 255
valid_ipv4() {
    local octet
    [[ "${1}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for octet in ${1//./ }; do [ "$((10#${octet}))" -le 255 ] || return 1; done
}
# an IPv6 address (without the brackets): eight groups of 1 to 4 hex digits separated by
# colons, or fewer with one :: for the zeros; the last two groups may be an IPv4 address
valid_ipv6() {
    local ip=${1} last group groups=() n=0 max=8
    [[ "${ip}" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    case "${ip}" in *:*:*) ;; *) return 1 ;; esac
    case "${ip}" in *:::*) return 1 ;; esac
    # a single colon at either end
    case "${ip}" in :[!:]*|*[!:]:) return 1 ;; esac
    if [[ "${ip}" == *::* ]]; then
        [[ "${ip#*::}" == *::* ]] && return 1
        max=7
    fi
    last=${ip##*:}
    if [[ "${last}" == *.* ]]; then
        valid_ipv4 "${last}" || return 1
        ip=${ip%"${last}"}0:0
    fi
    IFS=: read -r -a groups <<< "${ip}"
    for group in "${groups[@]}"; do
        [ -n "${group}" ] || continue
        [[ "${group}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        n=$((n + 1))
    done
    if [ "${max}" = 8 ]; then [ "${n}" = 8 ]; else [ "${n}" -le 7 ]; fi
}
# [address:]port: an IPv4 address or an IPv6 one in brackets ([::]:5000), a port 1 to 65535
valid_export_port() {
    local port=${1} addr
    case "${1}" in
        \[*\]:*) addr=${1%\]:*} port=${1##*\]:}; valid_ipv6 "${addr#\[}" || return 1 ;;
        *:*) addr=${1%:*} port=${1##*:}; valid_ipv4 "${addr}" || return 1 ;;
    esac
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] && [ "$((10#${port}))" -ge 1 ] && [ "$((10#${port}))" -le 65535 ]
}

# sourced (tests/prepare_functions.sh, and the tests that ask fxa_has_fix): the functions only
(return 0 2> /dev/null) && return 0

case "${1:-}" in
    --upgrade) upgrade_env ;;
    --render-units)
        case "${2:-}" in
            "") RENDER_UNITS=yes upgrade_env ;;
            --fresh) RENDER_UNITS=yes RENDER_FRESH=yes upgrade_env ;;
            *) echo "ERROR: --render-units [--fresh], not '${2}'"; exit 2 ;;
        esac ;;
esac

# domain
DOMAIN_EXAMPLE='firefox-sync.example.com'
read -e -p "Enter FQDN for your Firefox sync server [${DOMAIN_EXAMPLE}]: " SYNC_FQDN
SYNC_FQDN=${SYNC_FQDN:-${DOMAIN_EXAMPLE}}

# compose dir
CURRENT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
read -e -p "Enter full path for the docker-compose file [${CURRENT_DIR}]: " SCRIPT_DIR
SCRIPT_DIR=${SCRIPT_DIR:-${CURRENT_DIR}}

# where the Sync server listens for your reverse proxy, [address:]port: on this host only by
# default, as the other ports; a port alone is 127.0.0.1:<port>, 0.0.0.0:<port> (or [::]:<port>)
# every interface. Run again on an install: what its .env has, as it is
DEFAULT_SYNC_EXPORT_PORT=127.0.0.1:5000
if [ -f "${SCRIPT_DIR}/.env" ]; then
    previous=$(env_plain SYNC_EXPORT_PORT); previous=${previous:-$(env_plain CONTAINER_EXPORT_PORT)}
    DEFAULT_SYNC_EXPORT_PORT=${previous:-${DEFAULT_SYNC_EXPORT_PORT}}
fi
read -e -p "Listening address and port for syncstorage-rs, a port alone on 127.0.0.1 [${DEFAULT_SYNC_EXPORT_PORT}]: " SYNC_EXPORT_PORT
case "${SYNC_EXPORT_PORT}" in
    "")
        SYNC_EXPORT_PORT=${DEFAULT_SYNC_EXPORT_PORT}
        # what an install has is kept as it is, also a value this check does not know
        if ! valid_export_port "${SYNC_EXPORT_PORT}"; then
            echo "WARNING: SYNC_EXPORT_PORT='${SYNC_EXPORT_PORT}' of .env is not [address:]port as this script knows it: kept"
            SYNC_EXPORT_KEPT=yes
        fi ;;
    *[!0-9]*) ;;
    *) SYNC_EXPORT_PORT=127.0.0.1:${SYNC_EXPORT_PORT} ;;
esac
if [ -z "${SYNC_EXPORT_KEPT:-}" ] && ! valid_export_port "${SYNC_EXPORT_PORT}"; then
    echo "ERROR: not a port or an address and port: '${SYNC_EXPORT_PORT}' (e.g. 5000, 127.0.0.1:5000, 0.0.0.0:5000, [::]:5000)"
    exit 1
fi

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
read -r -e -p "Enable the admin UI? Max users, and sign-ups and accounts with self-hosted accounts, see docs/admin/README.md (Y/n): " ADMIN_UI
case "${ADMIN_UI}" in n|N|no) ADMIN_UI=no ;; *) ADMIN_UI=yes ;; esac
# with the admin UI, max users is managed there: SYNC_MAX_USERS=initial:N sets it only on the
# first start. A plain number is set again on every start (read-only in the admin UI)
[ "${ADMIN_UI}" = "yes" ] && SYNC_MAX_USERS=initial:${SYNC_MAX_USERS}

# admin sign-in with the self-hosted accounts, asked below
ADMIN_ALLOWED_USERS=""
ADMIN_HOST=""

# self-hosted Mozilla accounts (docs/accounts.md)
read -r -e -p "Also self-host Mozilla accounts? See docs/accounts.md (y/N): " SELF_HOST_FXA
case "${SELF_HOST_FXA}" in y|Y|yes) SELF_HOST_FXA=yes ;; *) SELF_HOST_FXA=no ;; esac
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    DEFAULT_FXA_DOMAIN=${SYNC_FQDN#*.}
    read -r -e -p "Domain for the accounts host names (accounts., api. and profile. are prepended) [${DEFAULT_FXA_DOMAIN}]: " FXA_DOMAIN
    FXA_DOMAIN=${FXA_DOMAIN:-${DEFAULT_FXA_DOMAIN}}
    read -r -e -p "SMTP server for the confirmation emails: " FXA_SMTP_HOST
    read -r -e -p "SMTP port [587]: " FXA_SMTP_PORT
    FXA_SMTP_PORT=${FXA_SMTP_PORT:-587}
    read -r -e -p "SMTP user: " FXA_SMTP_USER
    case "${FXA_SMTP_USER}" in *"'"*|*\\) echo "ERROR: the SMTP user cannot contain a single quote nor end with a backslash, set FXA_SMTP_USER in .env by hand"; exit 1 ;; esac
    read -r -e -s -p "SMTP password: " FXA_SMTP_PASS
    echo ""
    # (written in single quotes, as typed: compose reads \' there as a quote, so not at the end either)
    case "${FXA_SMTP_PASS}" in
        *"'"*) echo "ERROR: the SMTP password cannot contain a single quote, set FXA_SMTP_PASS in .env by hand"; exit 1 ;;
        *\\) echo "ERROR: the SMTP password cannot end with a backslash, set FXA_SMTP_PASS in .env by hand"; exit 1 ;;
    esac
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

# your own database server (docs/databases.md#your-own-server), asked last so that scripted answers for the
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
            echo "  can reach (e.g. 172.17.0.1 for Docker, host.containers.internal for Podman), see docs/databases.md#server-requirements"
            exit 1 ;;
        # IPv6 literals would need [ ] in the database URLs, which not every client parses
        *:*) echo "ERROR: '${1}': use a host name or an IPv4 address (no IPv6 address)"; exit 1 ;;
        *[!A-Za-z0-9._-]*) echo "ERROR: not a host name: '${1}'"; exit 1 ;;
    esac
}
valid_port() { case "${1}" in ''|*[!0-9]*) echo "ERROR: not a port: '${1}'"; exit 1 ;; esac; }
read -r -e -p "Use an existing database server instead of starting one? See docs/databases.md#your-own-server (y/N): " EXTERNAL_DB
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
    read -r -e -p "Use an existing MySQL 8.4/9 or MariaDB 11.4+ server for the accounts$([ "${EXTERNAL_DB}" = "yes" ] && echo " too")? See docs/databases.md#your-own-server (y/N): " EXTERNAL_FXA_DB
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
        read -r -e -p "Accounts database: mysql (MySQL lts, what Mozilla runs) or mariadb (MariaDB lts, see docs/accounts.md#mysql-or-mariadb) [mysql]: " FXA_DB
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

# the security history of the accounts (docs/accounts.md#security-history), asked last for the same reason
FXA_ACCOUNT_EVENTS=false
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    echo "Security history: every sign-in, password and 2-step change is kept with its IP address, for the owner and the admin UI to see (docs/accounts.md#security-history)."
    read -r -e -p "Record the security history of the accounts? (y/N): " FXA_ACCOUNT_EVENTS
    case "${FXA_ACCOUNT_EVENTS}" in y|Y|yes) FXA_ACCOUNT_EVENTS=true ;; *) FXA_ACCOUNT_EVENTS=false ;; esac
fi

# the alerts of the admin UI to other destinations than email (docs/admin/alerts.md#destinations), asked last
# for the same reason. Not shown as typed: the URLs hold tokens
ADMIN_NOTIFY=""
if [ "${ADMIN_UI}" = "yes" ]; then
    echo "Alerts of the admin UI: by email (ADMIN_ALERT_EMAIL in .env, with an SMTP server), and/or to Slack, Discord, Teams, ntfy, Gotify, Telegram, Matrix or a webhook (docs/admin/alerts.md#destinations)."
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
        case "${notify_entry}" in *"'"*|*\\) echo "ERROR: a destination URL cannot contain a single quote nor end with a backslash, set ADMIN_NOTIFY in .env by hand"; exit 1 ;; esac
        # the webhook URL of Slack or Discord as they give it: their scheme instead of https://
        notify_kind=""
        case "${notify_entry}" in
            https://hooks.slack.com/*) notify_kind=slack ;;
            https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) notify_kind=discord ;;
        esac
        if [ -n "${notify_kind}" ]; then
            read -r -e -p "That is a ${notify_kind} webhook URL: use it as ${notify_kind}://... (Y/n): " notify_convert
            case "${notify_convert}" in n|N|no) echo "ERROR: https:// is no destination of ADMIN_NOTIFY, see docs/admin/alerts.md#destinations"; exit 1 ;; esac
            notify_entry="${notify_kind}://${notify_entry#https://}"
        fi
        notify_base="" notify_shown="…"
        if [[ "${notify_entry}" == *://* ]]; then
            notify_base=$(printf '%s' "${notify_entry%%://*}" | tr '[:upper:]' '[:lower:]'); notify_base=${notify_base%+http}; notify_base=${notify_base%+https}
            notify_shown=$(notify_name "${notify_entry}")
        fi
        if ! [[ "${notify_base}" =~ ^(slack|discord|teams|ntfy|gotify|telegram|matrix|webhook)$ ]]; then
            echo "ERROR: ${notify_shown} is no destination of ADMIN_NOTIFY: slack://, discord://, teams://, ntfy://, gotify://, telegram://, matrix:// or webhook://, see docs/admin/alerts.md#destinations"
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

# PostgreSQL has no lts (every major is supported for 5 years) and no major opens another's
# data: the major of the install, decided before .env is written. One that ran PostgreSQL
# before keeps its SYNC_POSTGRES_IMAGE (postgres:18 without one: every release before it used
# 18, git log -- docker-compose.sync-postgres.yml); a new setup over the PostgreSQL volume of an
# earlier install the major of its data; a new install the major postgres:latest is at now, read
# from the image itself. Unset it would be postgres:latest, which a new major leaves unable to
# start: not knowing the major is an error
SYNC_POSTGRES_PIN="" SYNC_POSTGRES_MAJOR="" SYNC_POSTGRES_VOLUME=""
if [ "${DATABASE_BACKEND}" = postgres ]; then
    if [ "${PREVIOUS_SYNCSTORAGE_IMAGE}" = "syncstorage-rs-postgres" ]; then
        SYNC_POSTGRES_PIN=${PREVIOUS_POSTGRES_IMAGE:-postgres:18}
    elif [ "${EXTERNAL_DB}" != "yes" ] && SYNC_POSTGRES_VOLUME=$(db_volume postgres-db) \
        && SYNC_POSTGRES_VOLUME_MAJOR=$(postgres_volume_major ${SYNC_POSTGRES_VOLUME}); then
        SYNC_POSTGRES_PIN=postgres:${SYNC_POSTGRES_VOLUME_MAJOR}
    elif SYNC_POSTGRES_MAJOR=$(postgres_latest_major); then
        SYNC_POSTGRES_PIN=postgres:${SYNC_POSTGRES_MAJOR}
        SYNC_POSTGRES_VOLUME=""
    else
        echo "ERROR: could not read the major of postgres:latest, which this install is pinned to (SYNC_POSTGRES_IMAGE):"
        echo "  docker (or podman) run --rm --pull=always --entrypoint postgres postgres:latest --version failed."
        echo "  Check the container runtime and the access to Docker Hub, and run this again; nothing was written."
        exit 1
    fi
fi

# Sync on the MariaDB containers: lts for new installs; one that ran them before keeps its
# SYNC_MARIADB_IMAGE, or without one the major its data holds (its volume, else its running
# server), as a new setup over the MariaDB volumes of an earlier install
SYNC_MARIADB_PIN=mariadb:lts SYNC_MARIADB_FOUND=""
if [ "${DATABASE_BACKEND}" = mariadb ] && [ "${EXTERNAL_DB}" != "yes" ]; then
    if [ -f "${SCRIPT_DIR}/.env" ] && [ "$(env_value SYNC_DB)" != mysql ] && [ "${PREVIOUS_SYNCSTORAGE_IMAGE}" != "syncstorage-rs-postgres" ] \
        && [ "$(env_value SYNC_DB_CONTAINERS)" != 0 ] && [ -n "$(env_plain SYNC_MARIADB_IMAGE)" ]; then
        SYNC_MARIADB_PIN=$(env_plain SYNC_MARIADB_IMAGE)
    elif major=$(sync_mariadb_major); then
        SYNC_MARIADB_PIN=mariadb:${major} SYNC_MARIADB_FOUND=${major}
    fi
fi

# prepare .env file: new passwords and secrets, written into a copy (this user only) that
# replaces .env at the end. Run again on an install, its .env of before is kept as
# .env.before-setup-<UTC time> (the passwords its databases have); ./prepare_environment.sh
# --upgrade keeps them instead
private_temp "${SCRIPT_DIR}/.env.setup" NEW_ENV && cat "${SCRIPT_DIR}/.env-example" > "${NEW_ENV}" || exit 1
ENV_READ=${NEW_ENV}
apply_sed "${NEW_ENV}" "s|^SYNC_TOKENSERVER_DB_PASSWORD=.*|SYNC_TOKENSERVER_DB_PASSWORD=${SYNC_TOKENSERVER_DB_PASSWORD}|"
apply_sed "${NEW_ENV}" "s|^SYNC_STORAGE_DB_PASSWORD=.*|SYNC_STORAGE_DB_PASSWORD=${SYNC_STORAGE_DB_PASSWORD}|"
apply_sed "${NEW_ENV}" "s|^SYNC_POSTGRES_PASSWORD=.*|SYNC_POSTGRES_PASSWORD=${SYNC_POSTGRES_PASSWORD}|"
apply_sed "${NEW_ENV}" "s|SYNC_MASTER_SECRET=.*|SYNC_MASTER_SECRET=${SYNC_MASTER_SECRET}|"
apply_sed "${NEW_ENV}" "s|^SYNC_METRICS_HASH_SECRET=.*|SYNC_METRICS_HASH_SECRET=${SYNC_METRICS_HASH_SECRET}|"
apply_sed "${NEW_ENV}" "s|^SYNC_PUBLIC_URL=.*|SYNC_PUBLIC_URL=https://${SYNC_FQDN}|"
apply_sed "${NEW_ENV}" "s|^SYNC_EXPORT_PORT=.*|SYNC_EXPORT_PORT=${SYNC_EXPORT_PORT}|"
apply_sed "${NEW_ENV}" "s|^SYNC_MAX_USERS=.*|SYNC_MAX_USERS=${SYNC_MAX_USERS}|"
apply_sed "${NEW_ENV}" "s|^SYNC_IMAGE_TAG=.*|SYNC_IMAGE_TAG=${SYNC_IMAGE_TAG}|"
apply_sed "${NEW_ENV}" "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PASSWORD}|"
# the admin UI's database user, also for the backups: with or without the admin UI
apply_sed "${NEW_ENV}" "s|^ADMIN_DB_PASSWORD=.*|ADMIN_DB_PASSWORD=${ADMIN_DB_PASSWORD}|"
[ "${ADMIN_UI}" = "yes" ] && apply_sed "${NEW_ENV}" "s|^# COMPOSE_PROFILES=.*|COMPOSE_PROFILES=admin|"
[ -n "${ADMIN_NOTIFY}" ] && apply_sed "${NEW_ENV}" "s|^ADMIN_NOTIFY=.*|ADMIN_NOTIFY='$(sed_escape "${ADMIN_NOTIFY}")'|"
apply_sed "${NEW_ENV}" "s|^SYNC_DB=.*|SYNC_DB=${SYNC_DB}|"
[ "${DATABASE_BACKEND}" = mariadb ] && [ "${EXTERNAL_DB}" != "yes" ] && \
    apply_sed "${NEW_ENV}" "s|^# SYNC_MARIADB_IMAGE=.*|SYNC_MARIADB_IMAGE=$(sed_escape "${SYNC_MARIADB_PIN}")|"
if [ "${SYNC_COMPOSE_MYSQL}" = "yes" ]; then
    # MySQL's certificate is self-signed: the init container's client does not check it
    # (docker-compose.sync-mysql.yml does the same, this is for the Quadlets)
    apply_sed "${NEW_ENV}" "s|^SYNC_DB_TLS_VERIFY=.*|SYNC_DB_TLS_VERIFY=false|"
    # with the accounts, set below with theirs
    [ "${SELF_HOST_FXA}" = "yes" ] || apply_sed "${NEW_ENV}" "s|^# COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.yml:docker-compose.sync-mysql.yml|"
    # MySQL lts for new installs (9 today), written out (also the default when unset). One that
    # ran MySQL before SYNC_MYSQL_IMAGE, or whose MySQL volumes are still there, runs 8: pinned,
    # so that its data does not move to 9 by itself
    SYNC_MYSQL_IMAGE=mysql:lts
    if [ "${PREVIOUS_SYNC_MYSQL}" = yes ]; then
        SYNC_MYSQL_IMAGE=${PREVIOUS_SYNC_MYSQL_IMAGE:-mysql:8}
        [ -n "${PREVIOUS_SYNC_MYSQL_IMAGE}" ] || PINNED_SYNC_MYSQL=yes
    elif SYNC_MYSQL_VOLUME=$(db_volume syncstorage-db-mysql tokenserver-db-mysql); then
        # (already on 9 or later: lts, MySQL cannot go back to 8)
        SYNC_MYSQL_VOLUME_MAJOR=$(mysql_volume_major ${SYNC_MYSQL_VOLUME}) || SYNC_MYSQL_VOLUME_MAJOR=8
        [ "${SYNC_MYSQL_VOLUME_MAJOR}" -ge 9 ] || SYNC_MYSQL_IMAGE=mysql:8
    fi
    apply_sed "${NEW_ENV}" "s|^# SYNC_MYSQL_IMAGE=.*|SYNC_MYSQL_IMAGE=$(sed_escape "${SYNC_MYSQL_IMAGE}")|"
fi
if [ "${EXTERNAL_DB}" = "yes" ]; then
    apply_sed "${NEW_ENV}" "s|^SYNC_DB_CONTAINERS=.*|SYNC_DB_CONTAINERS=0|"
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        for name in SYNC_POSTGRES_NAME SYNC_POSTGRES_USER; do
            apply_sed "${NEW_ENV}" "s|^${name}=.*|${name}=${!name}|"
        done
        apply_sed "${NEW_ENV}" "s|^SYNC_POSTGRES_HOST=.*|SYNC_POSTGRES_HOST=${DB_HOST}|"
        apply_sed "${NEW_ENV}" "s|^SYNC_POSTGRES_PORT=.*|SYNC_POSTGRES_PORT=${DB_PORT}|"
    else
        # the init container's client checks the certificate by default, MySQL's is self-signed
        apply_sed "${NEW_ENV}" "s|^SYNC_DB_TLS_VERIFY=.*|SYNC_DB_TLS_VERIFY=false|"
        for name in SYNC_TOKENSERVER_DB_NAME SYNC_TOKENSERVER_DB_USER SYNC_STORAGE_DB_NAME SYNC_STORAGE_DB_USER; do
            apply_sed "${NEW_ENV}" "s|^${name}=.*|${name}=${!name}|"
        done
        for part in TOKENSERVER STORAGE; do
            apply_sed "${NEW_ENV}" "s|^SYNC_${part}_DB_HOST=.*|SYNC_${part}_DB_HOST=${DB_HOST}|"
            apply_sed "${NEW_ENV}" "s|^SYNC_${part}_DB_PORT=.*|SYNC_${part}_DB_PORT=${DB_PORT}|"
        done
    fi
fi
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    for name in FXA_MYSQL_PASSWORD FXA_ADMIN_DB_PASSWORD FXA_AUTH_SECRET FXA_OAUTH_SECRET FXA_PROFILE_SECRET FXA_FLOW_ID_KEY FXA_SESSION_TOKEN_HANDLE_KEY FXA_CONTENT_SESSION_SECRET; do
        apply_sed "${NEW_ENV}" "s|^${name}=.*|${name}=$(generate_random_string 32)|"
    done
    # the accounts images come from the same registry as the sync images, for this host's architecture
    FXA_REGISTRY=$(grep '^IMAGE_REPOSITORY=' "${NEW_ENV}" | cut -d= -f2)
    FXA_ARCH=$(host_arch)
    apply_sed "${NEW_ENV}" "s|^FXA_IMAGE=.*|FXA_IMAGE=${FXA_REGISTRY}|"
    apply_sed "${NEW_ENV}" "s|^FXA_PAIRING_IMAGE=.*|FXA_PAIRING_IMAGE=${FXA_REGISTRY}:fxa-channelserver-latest|"
    apply_sed "${NEW_ENV}" "s|^FXA_ARCH=.*|FXA_ARCH=${FXA_ARCH}|"
    apply_sed "${NEW_ENV}" "s|^FXA_CONTENT_URL=.*|FXA_CONTENT_URL=https://accounts.${FXA_DOMAIN}|"
    apply_sed "${NEW_ENV}" "s|^FXA_AUTH_URL=.*|FXA_AUTH_URL=https://api.${FXA_DOMAIN}|"
    apply_sed "${NEW_ENV}" "s|^FXA_PROFILE_URL=.*|FXA_PROFILE_URL=https://profile.${FXA_DOMAIN}|"
    apply_sed "${NEW_ENV}" "s|^FXA_OAUTH_SERVER_URL=.*|FXA_OAUTH_SERVER_URL=http://fxa-auth:9000/v1|"
    apply_sed "${NEW_ENV}" "s|^FXA_EMAIL_DOMAIN=.*|FXA_EMAIL_DOMAIN=api.${FXA_DOMAIN}|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_HOST=.*|FXA_SMTP_HOST=${FXA_SMTP_HOST}|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_PORT=.*|FXA_SMTP_PORT=${FXA_SMTP_PORT}|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_USER=.*|FXA_SMTP_USER='$(sed_escape "${FXA_SMTP_USER}")'|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_PASS=.*|FXA_SMTP_PASS='$(sed_escape "${FXA_SMTP_PASS}")'|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_SECURE=.*|FXA_SMTP_SECURE=${FXA_SMTP_SECURE}|"
    apply_sed "${NEW_ENV}" "s|^FXA_SMTP_SENDER=.*|FXA_SMTP_SENDER=\"$(sed_escape "$(env_dq "${FXA_SMTP_SENDER}")")\"|"
    apply_sed "${NEW_ENV}" "s|^FXA_SIGNUPS=.*|FXA_SIGNUPS=${FXA_SIGNUPS}|"
    apply_sed "${NEW_ENV}" "s|^FXA_SIGNUP_ALLOWLIST=.*|FXA_SIGNUP_ALLOWLIST=${FXA_SIGNUP_ALLOWLIST}|"
    apply_sed "${NEW_ENV}" "s|^FXA_MAX_ACCOUNTS=.*|FXA_MAX_ACCOUNTS=${FXA_MAX_ACCOUNTS}|"
    apply_sed "${NEW_ENV}" "s|^FXA_ACCOUNT_EVENTS=.*|FXA_ACCOUNT_EVENTS=${FXA_ACCOUNT_EVENTS}|"
    if [ "${EXTERNAL_FXA_DB}" = "yes" ]; then
        apply_sed "${NEW_ENV}" "s|^FXA_DB_CONTAINERS=.*|FXA_DB_CONTAINERS=0|"
        for name in FXA_MYSQL_HOST FXA_MYSQL_PORT FXA_MYSQL_USER FXA_MYSQL_POLICY_USER; do
            apply_sed "${NEW_ENV}" "s|^${name}=.*|${name}=${!name}|"
        done
        apply_sed "${NEW_ENV}" "s|^FXA_MYSQL_POLICY_PASSWORD=.*|FXA_MYSQL_POLICY_PASSWORD=$(generate_random_string 32)|"
    fi
    apply_sed "${NEW_ENV}" "s|^FXA_DB=.*|FXA_DB=${FXA_DB}|"
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
        apply_sed "${NEW_ENV}" "s|^# FXA_MARIADB_IMAGE=.*|FXA_MARIADB_IMAGE=$(sed_escape "${FXA_MARIADB_IMAGE}")|"
    fi
    # MySQL lts for new installs (9 today), written out (also the default when unset), when the
    # accounts image has mozilla/fxa#21554; else MySQL 8 with mysql_native_password, the only
    # authentication of the images without it (Mozilla's, ours from before). One that ran MySQL
    # before FXA_MYSQL_IMAGE, or whose fxa-db volume is still there, runs 8 like that: pinned,
    # its users are on mysql_native_password (docs/upgrading.md#mysql-8-to-9). Your own server: the
    # image is the backups' client, and without the patch the accounts' user is created with
    # mysql_native_password in database-setup-fxa.sql
    if [ "${FXA_DB}" = "mysql" ]; then
        fxa_image_has mozilla/fxa#21554; FXA_MYSQL2=$?
        # the local copy without it (the registry's has it): it is what would start, so MySQL 8
        # with mysql_native_password, which works with both; 3: said below
        [ "${FXA_MYSQL2}" = 0 ] && [ -n "${FXA_IMAGE_PULL}" ] && FXA_MYSQL2=3
        FXA_MYSQL_IMAGE=mysql:lts FXA_MYSQL_ARGS=""
        if [ "${PREVIOUS_FXA_MYSQL}" = yes ]; then
            if [ -n "${PREVIOUS_FXA_MYSQL_IMAGE}" ]; then
                FXA_MYSQL_IMAGE=${PREVIOUS_FXA_MYSQL_IMAGE} FXA_MYSQL_ARGS=${PREVIOUS_FXA_MYSQL_ARGS}
            else
                FXA_MYSQL_IMAGE=mysql:8 FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS} PINNED_FXA_MYSQL=yes
            fi
        elif [ "${EXTERNAL_FXA_DB}" != "yes" ] && FXA_MYSQL_VOLUME=$(db_volume fxa-db); then
            # (already on 9 or later: lts, its users cannot be on mysql_native_password, and MySQL
            # cannot go back to 8)
            FXA_MYSQL_VOLUME_MAJOR=$(mysql_volume_major ${FXA_MYSQL_VOLUME}) || FXA_MYSQL_VOLUME_MAJOR=8
            [ "${FXA_MYSQL_VOLUME_MAJOR}" -ge 9 ] || FXA_MYSQL_IMAGE=mysql:8 FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}
        elif [ "${FXA_MYSQL2}" != 0 ]; then
            FXA_MYSQL_IMAGE=mysql:8 FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}
        fi
        apply_sed "${NEW_ENV}" "s|^# FXA_MYSQL_IMAGE=.*|FXA_MYSQL_IMAGE=$(sed_escape "${FXA_MYSQL_IMAGE}")|"
        [ -z "${FXA_MYSQL_ARGS}" ] || apply_sed "${NEW_ENV}" "s|^# FXA_MYSQL_ARGS=.*|FXA_MYSQL_ARGS=$(sed_escape "${FXA_MYSQL_ARGS}")|"
    fi
    if [ -n "${ADMIN_ALLOWED_USERS:-}" ]; then
        # the admin UI signs in with these accounts: a public OAuth client (PKCE, no secret:
        # the accounts service refuses PKCE from clients with one), registered by fxa-auth
        ADMIN_FXA_CLIENT_ID=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
        apply_sed "${NEW_ENV}" "s|^ADMIN_FXA_CLIENT_ID=.*|ADMIN_FXA_CLIENT_ID=${ADMIN_FXA_CLIENT_ID}|"
        apply_sed "${NEW_ENV}" "s|^ADMIN_ALLOWED_USERS=.*|ADMIN_ALLOWED_USERS=${ADMIN_ALLOWED_USERS}|"
        apply_sed "${NEW_ENV}" "s|^ADMIN_OIDC_REDIRECT_URL=.*|ADMIN_OIDC_REDIRECT_URL=https://${ADMIN_HOST}/auth/callback|"
        # written out for the Quadlets too, which have no defaults like docker-compose.fxa.yml
        apply_sed "${NEW_ENV}" "s|^ADMIN_OIDC_ISSUER=.*|ADMIN_OIDC_ISSUER=https://accounts.${FXA_DOMAIN}|"
        apply_sed "${NEW_ENV}" "s|^ADMIN_OIDC_CLIENT_ID=.*|ADMIN_OIDC_CLIENT_ID=${ADMIN_FXA_CLIENT_ID}|"
        apply_sed "${NEW_ENV}" "s|^ADMIN_OIDC_NAME=.*|ADMIN_OIDC_NAME=\"Mozilla account\"|"
        # the accounts service has no email_verified claim, but only lets confirmed
        # sessions through to the admin UI (SERVICES_WITH_EMAIL_VERIFICATION in fxa-auth)
        apply_sed "${NEW_ENV}" "s|^ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=.*|ADMIN_OIDC_TRUST_UNVERIFIED_EMAIL=true|"
    fi
    if [ "${DATABASE_BACKEND}" = "postgres" ]; then
        COMPOSE_FILES=docker-compose.sync-postgres.yml:docker-compose.fxa.yml
    elif [ "${SYNC_COMPOSE_MYSQL}" = "yes" ]; then
        COMPOSE_FILES=docker-compose.yml:docker-compose.sync-mysql.yml:docker-compose.fxa.yml
    else
        COMPOSE_FILES=docker-compose.yml:docker-compose.fxa.yml
    fi
    [ "${FXA_DB}" = "mariadb" ] && COMPOSE_FILES="${COMPOSE_FILES}:docker-compose.fxa-mariadb.yml"
    apply_sed "${NEW_ENV}" "s|# COMPOSE_FILE=.*|COMPOSE_FILE=${COMPOSE_FILES}|"
    # nginx example for the accounts host names
    cp ${SCRIPT_DIR}/config/nginx/fxa-example.conf ${SCRIPT_DIR}/config/nginx/fxa.conf
    apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<ACCOUNTS_HOST>|accounts.${FXA_DOMAIN}|g"
    apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<API_HOST>|api.${FXA_DOMAIN}|g"
    apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<PROFILE_HOST>|profile.${FXA_DOMAIN}|g"
    for port in CONTENT AUTH PROFILE PROFILE_STATIC PAIRING; do
        value=$(grep "^FXA_${port}_EXPORT_PORT=" "${NEW_ENV}" | cut -d= -f2)
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<${port}_EXPORT_PORT>|${value}|g"
    done
    if [ "${ADMIN_UI}" = "yes" ]; then
        value=$(grep "^ADMIN_GATE_EXPORT_PORT=" "${NEW_ENV}" | cut -d= -f2)
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<ADMIN_GATE_EXPORT_PORT>|${value}|g"
    else
        # no sign-up gate without the admin UI
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "/# admin UI only/,/^  }$/d"
    fi
    if [ -n "${ADMIN_ALLOWED_USERS:-}" ]; then
        value=$(grep "^ADMIN_EXPORT_PORT=" "${NEW_ENV}" | cut -d= -f2)
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<ADMIN_HOST>|${ADMIN_HOST}|g"
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "s|<ADMIN_EXPORT_PORT>|${value}|g"
    else
        apply_sed ${SCRIPT_DIR}/config/nginx/fxa.conf "/# admin UI sign-in only/,/# end of the admin UI sign-in/d"
    fi
fi
if [ "${DATABASE_BACKEND}" = "postgres" ]; then
    [ "${SELF_HOST_FXA}" = "yes" ] || apply_sed "${NEW_ENV}" "s|# COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.sync-postgres.yml|"
    apply_sed "${NEW_ENV}" "s|^SYNC_IMAGE=.*|SYNC_IMAGE=syncstorage-rs-postgres|"
    apply_sed "${NEW_ENV}" "s|^SYNC_INIT_IMAGE=.*|SYNC_INIT_IMAGE=syncstorage-rs-postgres-init|"
    # the database container: the Sync server gets a role of its own, SYNC_POSTGRES_USER is the
    # container's superuser (your own server: SYNC_POSTGRES_USER is the plain owner, docs/reference/database-users.md#postgresql)
    if [ "${EXTERNAL_DB}" != "yes" ]; then
        apply_sed "${NEW_ENV}" "s|^SYNC_POSTGRES_APP_USER=.*|SYNC_POSTGRES_APP_USER=syncserver_app|"
        apply_sed "${NEW_ENV}" "s|^SYNC_POSTGRES_APP_PASSWORD=.*|SYNC_POSTGRES_APP_PASSWORD=$(generate_random_string 32)|"
    fi
    # the major of the install, above
    apply_sed "${NEW_ENV}" "s|^# SYNC_POSTGRES_IMAGE=.*|SYNC_POSTGRES_IMAGE=$(sed_escape "${SYNC_POSTGRES_PIN}")|"
fi
# the new .env in place, the one of before kept
if [ -f "${SCRIPT_DIR}/.env" ]; then
    ENV_BACKUP=$(backup_name "${SCRIPT_DIR}/.env.before-setup")
    private_copy "${SCRIPT_DIR}/.env" "${ENV_BACKUP}" || { echo "ERROR: could not keep ${SCRIPT_DIR}/.env as ${ENV_BACKUP}: nothing written"; rm -f "${NEW_ENV}"; exit 1; }
    echo "NOTE: ${SCRIPT_DIR}/.env written again with new passwords, the one of before is $(basename "${ENV_BACKUP}")"
    echo "  (to keep the passwords of an install: ./prepare_environment.sh --upgrade, Quadlets too)"
fi
replace_env "${NEW_ENV}" "${SCRIPT_DIR}/.env" || exit 1
unset ENV_READ

# the SQL for your own database server, with the names and passwords of .env (docs/databases.md#create-the-databases-and-users)
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
# the Sync server where it listens: its address (127.0.0.1 for every interface, 0.0.0.0, or a
# port alone in an .env of before), not localhost, which nginx tries on ::1 first
# (IPv6: [::] every interface, nginx on [::1])
SYNC_UPSTREAM=${SYNC_EXPORT_PORT}
case "${SYNC_UPSTREAM}" in
    0.0.0.0:*) SYNC_UPSTREAM=127.0.0.1:${SYNC_UPSTREAM##*:} ;;
    "[::]:"*) SYNC_UPSTREAM=[::1]:${SYNC_UPSTREAM##*:} ;;
    *:*) ;;
    *) SYNC_UPSTREAM=127.0.0.1:${SYNC_UPSTREAM} ;;
esac
apply_sed ${SCRIPT_DIR}/config/nginx/syncstorage-rs.conf "s|localhost:<SYNC_EXPORT_PORT>|${SYNC_UPSTREAM}|; s|<SYNC_EXPORT_PORT>|${SYNC_UPSTREAM##*:}|"

# prepare systemd example (for docker compose; with Podman, Quadlets start at boot instead)
cp ${SCRIPT_DIR}/config/systemd/syncstorage-rs-example.service ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service
apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|<DOCKER_USER>|${CONTAINER_USER}|"
apply_sed ${SCRIPT_DIR}/config/systemd/syncstorage-rs.service "s|<COMPOSE_DIR>|${SCRIPT_DIR}|"

# Setup Quadlets if requested
if [ "${CONTAINER_RUNTIME}" = "podman" ] && [ "${DEPLOY_METHOD}" = "quadlets" ]; then
    echo ""
    echo "Setting up Podman Quadlets..."
    render_units
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
    echo "  password: ADMIN_PASSWORD in .env. See docs/admin/README.md"
    [ -n "${ADMIN_ALLOWED_USERS:-}" ] && echo "  or https://${ADMIN_HOST}, signed in with the accounts of ${ADMIN_ALLOWED_USERS}"
fi

echo ""

# your own database server: what to run there first
if [ "${EXTERNAL_DB}" = "yes" ]; then
    echo "First, on your database server (see docs/databases.md#create-the-databases-and-users):"
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
    [ "${EXTERNAL_DB}" = "yes" ] || echo "First, on your database server (see docs/databases.md#create-the-databases-and-users):"
    if [ "${FXA_DB}" = "mariadb" ]; then
        echo "  mariadb -h ${FXA_MYSQL_HOST} -P ${FXA_MYSQL_PORT} -u root -p < database-setup-fxa.sql"
        echo "  MariaDB 11.4 or later (12: with our accounts images, docs/accounts.md#mariadb-12), with binary logging: log_bin_trust_function_creators=ON"
    else
        echo "  mysql -h ${FXA_MYSQL_HOST} -P ${FXA_MYSQL_PORT} -u root -p < database-setup-fxa.sql"
        if [ "${FXA_MYSQL2}" = 0 ]; then
            echo "  MySQL 8.4 or 9 with log_bin_trust_function_creators=ON"
        else
            echo "  MySQL 8.4 started with mysql_native_password=ON and log_bin_trust_function_creators=ON: the accounts"
            echo "  image has no mozilla/fxa#21554, its driver speaks mysql_native_password only (docs/accounts.md#mysql-or-mariadb)"
        fi
    fi
fi
[ "${EXTERNAL_DB}" = "yes" ] || [ "${EXTERNAL_FXA_DB}" = "yes" ] && echo ""
if [ "${SELF_HOST_FXA}" = "yes" ]; then
    if [ "${PINNED_FXA_MARIADB:-}" = "yes" ]; then
        echo "FXA_MARIADB_IMAGE=mariadb:11: the accounts database of this install stays on MariaDB 11."
        echo "  To move it to MariaDB lts, 12 (a backup first, there is no way back): docs/upgrading.md#mariadb"
    fi
    if [ -n "${FXA_MARIADB_VOLUME:-}" ]; then
        echo "FXA_MARIADB_IMAGE=mariadb:11: found the accounts database of an earlier install (${FXA_MARIADB_VOLUME}),"
        echo "  its data stays on MariaDB 11. Already on 12: set FXA_MARIADB_IMAGE=mariadb:lts. A new install: remove the volume"
        echo "  (its accounts are lost) and run this again. Moving it to lts: docs/upgrading.md#mariadb"
    fi
    if [ "${PINNED_FXA_MYSQL:-}" = "yes" ]; then
        echo "FXA_MYSQL_IMAGE=mysql:8, FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}: the accounts database"
        echo "  of this install stays on MySQL 8 with mysql_native_password. To move it to MySQL lts, 9: docs/upgrading.md#mysql-8-to-9"
    fi
    if [ -n "${FXA_MYSQL_VOLUME:-}" ] && [ "${FXA_MYSQL_VOLUME_MAJOR}" -ge 9 ]; then
        echo "FXA_MYSQL_IMAGE=mysql:lts: found the accounts database of an earlier install (${FXA_MYSQL_VOLUME}), on"
        echo "  MySQL ${FXA_MYSQL_VOLUME_MAJOR} already: it stays on lts. A new install: remove the volume (its accounts are lost) and run this again"
    elif [ -n "${FXA_MYSQL_VOLUME:-}" ]; then
        echo "FXA_MYSQL_IMAGE=mysql:8, FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}: found the accounts database"
        echo "  of an earlier install (${FXA_MYSQL_VOLUME}), its data stays on MySQL 8 with mysql_native_password."
        echo "  A new install: remove the volume"
        echo "  (its accounts are lost) and run this again. Moving it to lts: docs/upgrading.md#mysql-8-to-9"
    elif [ "${FXA_DB}" = mysql ] && [ "${EXTERNAL_FXA_DB}" != yes ] && [ "${PREVIOUS_FXA_MYSQL}" != yes ] && [ "${FXA_MYSQL2}" != 0 ]; then
        if [ "${FXA_MYSQL2}" = 2 ]; then
            echo "NOTE: could not read the labels of $(env_value FXA_IMAGE):$(env_value FXA_VERSION): MySQL lts (9) needs"
        elif [ "${FXA_MYSQL2}" = 3 ]; then
            echo "NOTE: your local $(env_value FXA_IMAGE):$(env_value FXA_VERSION) is older than the registry's: it does not have"
            echo "  mozilla/fxa#21554, the registry's has it. For MySQL lts (9) on this new install: pull it, then before the"
            echo "  first start set FXA_MYSQL_IMAGE=mysql:lts and remove FXA_MYSQL_ARGS in .env. Until then MySQL lts needs"
        else
            echo "NOTE: $(env_value FXA_IMAGE):$(env_value FXA_VERSION) does not have mozilla/fxa#21554 (Mozilla's images, ours"
            echo "  built before it), which MySQL lts (9) needs"
        fi
        echo "  an accounts image with mozilla/fxa#21554 (the mysql2 driver): fxa-db runs MySQL 8 with mysql_native_password"
        echo "  (FXA_MYSQL_IMAGE=mysql:8, FXA_MYSQL_ARGS=${FXA_MYSQL_NATIVE_ARGS}), see docs/accounts.md#mysql-or-mariadb"
    fi
    fxa_mariadb_image_check
    [ "${FXA_DB}" = mysql ] && fxa_mysql_image_check
fi
if [ "${DATABASE_BACKEND}" = postgres ] && [ -n "${SYNC_POSTGRES_MAJOR:-}" ]; then
    echo "SYNC_POSTGRES_IMAGE=postgres:${SYNC_POSTGRES_MAJOR}: PostgreSQL ${SYNC_POSTGRES_MAJOR}, the major of postgres:latest today, pinned: a newer"
    echo "  major cannot open its data. Moving later: docs/upgrading.md#postgresql"
elif [ "${DATABASE_BACKEND}" = postgres ] && [ -n "${SYNC_POSTGRES_VOLUME}" ]; then
    echo "SYNC_POSTGRES_IMAGE=${SYNC_POSTGRES_PIN}: found the Sync database of an earlier install (${SYNC_POSTGRES_VOLUME}),"
    echo "  PostgreSQL ${SYNC_POSTGRES_VOLUME_MAJOR}: it stays on it. A new install: remove the volume (its data is lost) and run this"
    echo "  again. Moving to a newer major: docs/upgrading.md#postgresql"
fi
if [ -n "${SYNC_MARIADB_FOUND}" ]; then
    echo "SYNC_MARIADB_IMAGE=${SYNC_MARIADB_PIN}: found the Sync databases of an earlier install on MariaDB ${SYNC_MARIADB_FOUND}: they stay on it."
    echo "  A new install: remove their volumes (the data is lost) and run this again. To follow lts: SYNC_MARIADB_IMAGE=mariadb:lts"
fi
if [ "${PINNED_SYNC_MYSQL:-}" = "yes" ]; then
    echo "SYNC_MYSQL_IMAGE=mysql:8: the Sync databases of this install stay on MySQL 8. To move them to MySQL lts, 9:"
    echo "  docs/upgrading.md#mysql-8-to-9"
fi
if [ -n "${SYNC_MYSQL_VOLUME:-}" ] && [ "${SYNC_MYSQL_VOLUME_MAJOR}" -ge 9 ]; then
    echo "SYNC_MYSQL_IMAGE=mysql:lts: found the Sync databases of an earlier install (${SYNC_MYSQL_VOLUME}), on MySQL"
    echo "  ${SYNC_MYSQL_VOLUME_MAJOR} already: they stay on lts. A new install: remove the volumes and run this again"
elif [ -n "${SYNC_MYSQL_VOLUME:-}" ]; then
    echo "SYNC_MYSQL_IMAGE=mysql:8: found the Sync databases of an earlier install (${SYNC_MYSQL_VOLUME}), their data"
    echo "  stays on MySQL 8. A new install: remove the volumes and run"
    echo "  this again. Moving them to lts: docs/upgrading.md#mysql-8-to-9"
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
        echo "     then in Firefox set identity.fxaccounts.autoconfig.uri to https://accounts.${FXA_DOMAIN} (see docs/firefox.md#self-hosted-accounts)"
    fi
    echo "  2. (Optional) loginctl enable-linger \$USER"
    echo "  3. (Optional) nightly backups: systemctl --user enable --now firefox-sync-backup.timer (docs/backups.md#the-backup-service)"
    echo ""
    echo "To check status:"
    echo "  systemctl --user status firefox-sync-syncstorage.service"
    echo ""
    echo "See docs/install/podman.md for detailed instructions"
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
    echo "  (Optional) nightly backups: add backup to COMPOSE_PROFILES in .env (docs/backups.md#the-backup-service)"
    echo ""
    echo "See docs/install/podman.md for detailed instructions (podman-compose is not supported)"
else
    echo "Next steps:"
    echo "  1. docker compose up -d"
    [ "${SELF_HOST_FXA}" = "yes" ] && echo "     then in Firefox set identity.fxaccounts.autoconfig.uri to https://accounts.${FXA_DOMAIN} (see docs/firefox.md#self-hosted-accounts)"
    echo "  (Optional) nightly backups: add backup to COMPOSE_PROFILES in .env (docs/backups.md#the-backup-service)"
    echo "  2. (Optional) Install systemd service:"
    echo "     sudo cp config/systemd/syncstorage-rs.service /etc/systemd/system/"
    echo "     sudo systemctl enable --now syncstorage-rs.service"
fi

echo "=========================================="
