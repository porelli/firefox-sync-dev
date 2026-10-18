# shellcheck shell=bash disable=SC2034 # (used by the tests that source it)
# Runs of the tests next to each other on one host, sourced by the tests first.
# SLOT (default 0) gives a run its own compose projects, host ports and networks: 0 keeps
# the names, ports and networks the tests always had; 1, 2... add -s<SLOT> to the project
# names, 1000 * SLOT to the host ports and 10 * SLOT to the third byte of the test
# networks, so that the runs of different slots do not meet. Within one slot each suite
# has its own project, ports and networks already (tests/e2e.sh mysql and postgres, ...).
SLOT=${SLOT:-0}
case "${SLOT}" in '' | *[!0-9]*) echo "SLOT: a number, not ${SLOT}"; exit 2 ;; esac
SLOT_SUFFIX=""
[ "${SLOT}" = 0 ] || SLOT_SUFFIX=-s${SLOT}
SLOT_PORTS=$((SLOT * 1000))
SLOT_NET=$((SLOT * 10))

# slot_fxa_ports <env file>: the host ports of the accounts' services, the admin UI and the
# sign-up gate, which the tests with the accounts leave at those of .env-example, of their
# own in slots other than 0 (28700-28706 + SLOT_PORTS)
slot_fxa_ports() {
  [ "${SLOT}" = 0 ] && return
  local p=$((28700 + SLOT_PORTS))
  sed -i -e "s|^ADMIN_EXPORT_PORT=.*|ADMIN_EXPORT_PORT=127.0.0.1:${p}|" \
    -e "s|^ADMIN_GATE_EXPORT_PORT=.*|ADMIN_GATE_EXPORT_PORT=127.0.0.1:$((p + 1))|" \
    -e "s|^FXA_PAIRING_EXPORT_PORT=.*|FXA_PAIRING_EXPORT_PORT=127.0.0.1:$((p + 2))|" \
    -e "s|^FXA_CONTENT_EXPORT_PORT=.*|FXA_CONTENT_EXPORT_PORT=127.0.0.1:$((p + 3))|" \
    -e "s|^FXA_AUTH_EXPORT_PORT=.*|FXA_AUTH_EXPORT_PORT=127.0.0.1:$((p + 4))|" \
    -e "s|^FXA_PROFILE_EXPORT_PORT=.*|FXA_PROFILE_EXPORT_PORT=127.0.0.1:$((p + 5))|" \
    -e "s|^FXA_PROFILE_STATIC_EXPORT_PORT=.*|FXA_PROFILE_STATIC_EXPORT_PORT=127.0.0.1:$((p + 6))|" "$1"
}

# one_at_a_time <name> <command...>: the command, while no other run of the host runs one
# under that name (flock, where there is one): builds of the same image tag at the same
# time fail ("image ... already exists")
one_at_a_time() {
  local name=$1
  shift
  if command -v flock > /dev/null; then
    flock "${TMPDIR:-/tmp}/ffs-test-${name}.lock" "$@"
  else
    "$@"
  fi
}
