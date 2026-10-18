# shellcheck shell=bash
# Runs of the tests next to each other on one host, sourced by the tests first.

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
