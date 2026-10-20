#!/bin/bash
# The functions of prepare_environment.sh that need no container, on tables: the values of
# .env as compose reads them (env_plain), the addresses of SYNC_EXPORT_PORT
# (valid_export_port), .env written through a symlink (replace_env), the substitutions without
# the values on a command line (sed_script, sed_escape), and whether an accounts image has a
# fix of upstream-patches.yml (fxa_has_fix, config/fxa/fixed-in). The script is sourced: its
# functions only, nothing asked or written. No container runtime needed; with docker compose
# (COMPOSE=1, or found) the .env table is also compared with what `docker compose config` reads.
#
# Usage: tests/prepare_functions.sh   (bash 3.2, macOS, too)
set -u

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CODE=$(dirname "${TESTS}")
WORK=$(mktemp -d)
trap 'chmod -R u+w "${WORK}" 2> /dev/null; rm -rf "${WORK}"' EXIT
FAILED=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; FAILED=1; fi; }

# sed_script's files there
export TMPDIR=${WORK}/tmp
mkdir -p "${TMPDIR}"
# shellcheck source=prepare_environment.sh
source "${CODE}/prepare_environment.sh" || { echo "FAIL: source prepare_environment.sh"; exit 1; }
check "$(type -t env_plain) $(type -t valid_export_port) $(type -t replace_env) $(type -t fxa_has_fix)" "function function function function" \
  "prepare_environment.sh sourced: its functions, nothing run"

echo "== .env values as compose reads them (env_plain)"
# "<line of .env> => <value compose reads>"; no $NAME in them, which compose would replace
# with another value (env_plain does not)
ENV_CASES=(
  'A01=plain => plain'
  'A02=plain # comment => plain'
  'A03=plain#nocomment => plain#nocomment'
  'A04="dq # not comment" # comment => dq # not comment'
  "A05='sq # x' # c => sq # x"
  'A06="a\"b" => a"b'
  'A07="a\\b" => a\b'
  $'A08="a\\nb" => a\nb'
  "A09='a\\'b' => a'b"
  "A10='a\\nb' => a\\nb"
  'A11="a$$b" => a$b'
  'A12="a\$b" => a$b'
  $'A13="x\\ty" => x\ty'
  'A14=  spaced   => spaced'
  "A15=\"a'b\" => a'b"
  "A16='a\"b' => a\"b"
  'A17="a&b|c/d#e" => a&b|c/d#e'
  'A18=a\b => a\b'
  'export A20=exp => exp'
  '  A21=indented => indented'
  'A23= => '
  'A24="" => '
  'A25="a\\" => a\'
  'A26="a\\\"b" => a\"b'
  "A28='a\\\\b' => a\\\\b"
  'A29=a "b" => a "b"'
  'A30=x$$y => x$y'
  "A31='x\$y' => x\$y"
  'A32="x\\\\y" => x\\y'
  "A33=\"q\\'s\" => q\\'s"
  "A34='d\\\"q' => d\\\"q"
  'A35=a\"b => a\"b'
  'A36="  pad  " =>   pad  '
  'A37="a" # c "b" => a'
  'A38=a #c => a'
  $'A39=a\t#tab => a\t#tab'
  "A41='p@ss|w&rd\\#1 \$x' => p@ss|w&rd\\#1 \$x"
  'A42="a&b|c/d\\e" => a&b|c/d\e'
)
: > "${WORK}/.env"
for c in "${ENV_CASES[@]}"; do printf '%s\n' "${c% => *}" >> "${WORK}/.env"; done
# (the line ends of Windows too)
printf 'A43=crlf\r\nA44="crlf"\r\n' >> "${WORK}/.env"
ENV_CASES+=('A43=crlf => crlf' 'A44="crlf" => crlf')
SCRIPT_DIR=${WORK}
compose_json=""
if [ "${COMPOSE:-}" = 1 ] || { [ -z "${COMPOSE:-}" ] && docker compose version > /dev/null 2>&1; }; then
  { echo "services:"; echo "  t:"; echo "    image: busybox"; echo "    environment:"
    for c in "${ENV_CASES[@]}"; do n=${c%%=*}; n=${n##* }; echo "      ${n}: \${${n}}"; done; } > "${WORK}/compose.yml"
  compose_json=$(cd "${WORK}" && env -i PATH="${PATH}" HOME="${HOME}" docker compose -p ffs-env-parse -f compose.yml config --format json 2>&1) \
    || { echo "FAIL: docker compose config of the table: ${compose_json}"; FAILED=1; compose_json=""; }
fi
for c in "${ENV_CASES[@]}"; do
  line=${c% => *} want=${c#* => }
  name=${line%%=*} name=${name##* }
  got=$(env_plain "${name}"; echo x); got=${got%x}
  check "${got}" "${want}" "env_plain: ${line}"
  if [ -n "${compose_json}" ]; then
    # (compose's config writes a $ of a value as $$)
    from_compose=$(printf '%s' "${compose_json}" | python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["t"]["environment"][sys.argv[1]].replace("$$", "$"), end="")' "${name}"; echo x)
    check "${from_compose%x}" "${want}" "docker compose reads ${line} as the table says"
  fi
done
[ -n "${compose_json}" ] || echo "(no docker compose: the table only)"
# what the setup writes in double quotes reads back as it was (env_dq)
sender='Mozilla "accounts" \ $HOME <no-reply@example.org>'
printf 'S1="%s"\n' "$(env_dq "${sender}")" > "${WORK}/.env"
check "$(env_plain S1)" "${sender}" "a value written with env_dq reads back as it was"

echo "== the address and port of SYNC_EXPORT_PORT (valid_export_port)"
for p in 5000 1 65535 127.0.0.1:5000 0.0.0.0:5000 255.255.255.255:80 '[::]:5000' '[::1]:5000' '[fe80::1]:443' \
  '[2001:db8::8a2e:370:7334]:5000' '[2001:db8:0:0:0:0:2:1]:5000' '[1:2:3:4:5:6:7::]:5000' '[::ffff:192.0.2.1]:5000' '[64:ff9b::192.0.2.33]:80'; do
  check "$(valid_export_port "${p}" && echo valid)" valid "valid_export_port accepts ${p}"
done
for p in "" 0 65536 123456 abc localhost:5000 256.1.1.1:5000 1.2.3:5000 1.2.3.4.5:5000 :5000 '[:]:5000' '[:::]:5000' '[::]' '[]:5000' \
  '[1::2::3]:5000' '[12345::]:5000' '[1:2:3:4:5:6:7:8:9]:5000' '[1:2:3:4:5:6:7]:5000' '[1:2:3:4:5:6:7:8::]:5000' '[:1::]:5000' '[1::2:]:5000' \
  '[::g]:5000' '[::1.2.3]:5000' '[::256.1.1.1]:5000' '[1.2.3.4]:5000' '[::1]:0' '[::1]:70000' '::1:5000' '[::1]5000'; do
  check "$(valid_export_port "${p}" || echo refused)" refused "valid_export_port refuses '${p}'"
done

echo "== .env written through a symlink (replace_env)"
mkdir -p "${WORK}/real" "${WORK}/dir" "${WORK}/ro"
mode() { stat -c %a "$1" 2> /dev/null || stat -f %Lp "$1"; }
new_env() { (umask 077; printf 'NEW=%s\n' "$1" > "${WORK}/dir/.env.new"); }
printf 'OLD=1\n' > "${WORK}/real/env"; chmod 644 "${WORK}/real/env"
ln -s ../real/env "${WORK}/dir/.env"
new_env 1; replace_env "${WORK}/dir/.env.new" "${WORK}/dir/.env"
check "$? $([ -L "${WORK}/dir/.env" ] && echo link) $(cat "${WORK}/real/env") $(mode "${WORK}/real/env") $(ls "${WORK}/dir/.env.new" "${WORK}/real"/.env* 2> /dev/null | wc -l | tr -d ' ')" \
  "0 link NEW=1 600 0" "a relative symlink stays one, its target replaced, 0600, nothing left aside"
# a symlink to a symlink, absolute
ln -s "${WORK}/dir/.env" "${WORK}/dir/.env2"
new_env 2; replace_env "${WORK}/dir/.env.new" "${WORK}/dir/.env2"
check "$([ -L "${WORK}/dir/.env2" ] && [ -L "${WORK}/dir/.env" ] && echo links) $(cat "${WORK}/real/env")" "links NEW=2" "a chain of symlinks: the file at its end replaced"
# the target's directory not writable: the content written into the file
printf 'OLD=1\n' > "${WORK}/ro/env"; ln -s "${WORK}/ro/env" "${WORK}/dir/.env3"; chmod 555 "${WORK}/ro"
new_env 3; replace_env "${WORK}/dir/.env.new" "${WORK}/dir/.env3"
check "$? $([ -L "${WORK}/dir/.env3" ] && echo link) $(cat "${WORK}/ro/env") $(mode "${WORK}/ro/env")" "0 link NEW=3 600" \
  "the target's directory not writable: its content replaced in place, 0600"
chmod 755 "${WORK}/ro"
# a plain file: renamed over it
printf 'OLD=1\n' > "${WORK}/dir/plain"
new_env 4; replace_env "${WORK}/dir/.env.new" "${WORK}/dir/plain"
check "$([ -L "${WORK}/dir/plain" ] || echo file) $(cat "${WORK}/dir/plain") $(mode "${WORK}/dir/plain")" "file NEW=4 600" "a plain .env: replaced by the new file"

echo "== substitutions with the values in a file, not on the command line (sed_script, sed_escape)"
tricky='a&b|c/d\e"f'"'"'g$h#i%j'
printf 'X=@V@ %%V%%\n' > "${WORK}/template"
check "$(sed_script "s|@V@|$(sed_escape "${tricky}")|g" "${WORK}/template")" "X=${tricky} %V%" "sed_script with sed_escape: & | / \\ quotes \$ # % as they are"
two_lines=$'one\ntwo'
check "$(sed_script "s|@V@|$(sed_escape "${two_lines}")|g" "${WORK}/template")" "X=one
two %V%" "sed_escape: a line break in the value"
check "$(find "${TMPDIR}" -type f | wc -l | tr -d ' ')" 0 "sed_script leaves no script behind"
# the script's file is this user's only while sed runs
check "$(s=$(mktemp "${TMPDIR}/ffs-sed.XXXXXX"); mode "${s}"; rm -f "${s}")" 600 "mktemp's files (sed_script's): 0600"
# no value on sed's command line: the arguments sed gets, as ps shows them
mkdir -p "${WORK}/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/argv\nexec %s "$@"\n' "${WORK}" "$(command -v sed)" > "${WORK}/bin/sed"; chmod +x "${WORK}/bin/sed"
secret=ffsSECRETvalue
(PATH=${WORK}/bin:${PATH}; printf 'P=x\n' > "${WORK}/plain"; apply_sed "${WORK}/plain" "s|^P=.*|P=${secret}|"
  render_sql "${WORK}/template" "${WORK}/out.sql" V="${secret}")
check "$(grep -c "${secret}" "${WORK}/argv") $(cat "${WORK}/plain") $(cut -d' ' -f1 "${WORK}/out.sql") $(mode "${WORK}/out.sql")" "0 P=${secret} X=${secret} 600" \
  "apply_sed and render_sql: the value written, never in sed's arguments"

# stopped while sed runs (TERM, INT): its script removed all the same, and a trap of before
# (EXIT) still runs after
printf '#!/bin/sh\nsleep 2\n' > "${WORK}/bin/sed"; chmod +x "${WORK}/bin/sed"
for sig in TERM INT; do
  TMPDIR=${WORK}/stop-${sig}; mkdir -p "${TMPDIR}"
  TMPDIR=${TMPDIR} bash -c 'trap "echo before > \"${TMPDIR}/../before-$1\"" EXIT; source "$0"; PATH=$2:${PATH}; sed_script "s/x/y/" /dev/null' \
    "${CODE}/prepare_environment.sh" "${sig}" "${WORK}/bin" &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(find "${TMPDIR}" -type f)" ] && break; sleep 0.2; done
  during=$(find "${TMPDIR}" -type f | wc -l | tr -d ' ')
  kill -s "${sig}" "${pid}"; wait "${pid}"
  check "${during} $(find "${TMPDIR}" -type f | wc -l | tr -d ' ') $(cat "${WORK}/before-${sig}" 2> /dev/null)" "1 0 before" \
    "a ${sig} while sed runs: its script removed, the EXIT trap of before kept"
done
TMPDIR=${WORK}/tmp

echo "== accounts images with a fix of upstream-patches.yml (fxa_has_fix, config/fxa/fixed-in)"
has() { fxa_has_fix "$@"; echo $?; }
check "$(fxa_fixed_in mozilla/fxa#21554)|$(fxa_fixed_in mozilla/fxa#21494)" "|" "config/fxa/fixed-in: no release has them yet"
LABEL='mozilla/fxa#21494@3e2cb67..0eaa3a2 mozilla/fxa#21554@3e2cb67..84d71e2+v1.347.3'
# not released: the label only
check "$(has mozilla/fxa#21554 "${LABEL}" v1.347.3 fxa-mono-latest) $(has mozilla/fxa#21494 "${LABEL}" "" fxa-mono-latest)" "0 0" "not released: an image with the patch in its label has it"
check "$(has mozilla/fxa#21554 none v1.400.0 fxa-mono-latest) $(has mozilla/fxa#21554 "" "" v1.400.0) $(has mozilla/fxa#21494 "mozilla/fxa#21554@a..b" "" fxa-mono-v1.400.0)" "1 1 1" \
  "not released: without it in the label, none has it, whatever its release"
check "$(has mozilla/fxa#2155 "${LABEL}" "" "") $(has fxa#21554 "${LABEL}" "" "")" "1 1" "another pull request's number is not it"
# released in v1.352.0 (a fixed-in of a test checkout)
SELF_DIR=${WORK}/checkout
mkdir -p "${SELF_DIR}/config/fxa"
cp "${CODE}/config/fxa/fixed-in" "${SELF_DIR}/config/fxa/fixed-in"
printf 'mozilla/fxa#21554 v1.352.0\n' >> "${SELF_DIR}/config/fxa/fixed-in"
check "$(fxa_fixed_in mozilla/fxa#21554)|$(fxa_fixed_in mozilla/fxa#21494)" "v1.352.0|" "fixed-in: the release of a pull request, the others none"
check "$(has mozilla/fxa#21554 none v1.352.0 fxa-mono-latest) $(has mozilla/fxa#21554 "" v1.360.2 latest) $(has mozilla/fxa#21554 "" "" v1.352.1) $(has mozilla/fxa#21554 "" "" fxa-mono-v1.400.0) $(has mozilla/fxa#21554 "" 1.352.0 "")" \
  "0 0 0 0 0" "released: an image of that release or a later one has it, its version label or its tag (ours, Mozilla's)"
check "$(has mozilla/fxa#21554 none v1.351.9 fxa-mono-latest) $(has mozilla/fxa#21554 "" "" v1.347.3) $(has mozilla/fxa#21554 "" v1.35.0 v1.400.0)" "1 1 1" \
  "released: an older image has not (the version label first, then the tag)"
check "$(has mozilla/fxa#21554 "${LABEL}" v1.347.3 fxa-mono-v1.347.3)" 0 "released: an older image of ours with the patch in its label still has it"
check "$(has mozilla/fxa#21554 "" "" latest) $(has mozilla/fxa#21554 "" "" "sha256:abc")" "2 2" "released: an image of no known release, not known"
check "$(has mozilla/fxa#21494 none v1.400.0 latest)" 1 "released: another pull request still by its label"
check "$(version_at_least 1.352.0 1.352.0 && echo y) $(version_at_least 1.352.10 1.352.9 && echo y) $(version_at_least 1.400 1.352.1 && echo y) $(version_at_least 1.352 1.352.1 || echo n) $(version_at_least 2.0.0 1.999.999 && echo y)" \
  "y y y n y" "version_at_least: part by part, numbers"
check "$(fxa_release v1.347.3) $(fxa_release fxa-mono-v1.347.3) $(fxa_release 1.347.3) [$(fxa_release fxa-mono-latest)] [$(fxa_release v1.347.3-rc1)] [$(fxa_release 1)] [$(fxa_release 20261020)] [$(fxa_release v1.347)] [$(fxa_release 1.2.3.4)]" "1.347.3 1.347.3 1.347.3 [] [] [] [] [] []" \
  "fxa_release: of the version label or the tag"
# the JSON of an image (docker, podman inspect, buildx imagetools)
json='[{"Config":{"Labels":{"org.firefox-sync.upstream-patches":"none","org.opencontainers.image.version":"v1.353.0"}}}]'
check "$(fxa_inspected_has mozilla/fxa#21554 "${json}" fxa-mono-latest; echo $?) $(fxa_inspected_has mozilla/fxa#21494 "${json}" fxa-mono-latest; echo $?)" "0 1" \
  "the labels of an image's JSON: released and newer has it, the other not"

[ "${FAILED}" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "${FAILED}"
