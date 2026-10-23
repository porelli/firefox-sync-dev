#!/bin/bash
# pasta-apparmor.sh: lets pasta receive the SIGTERM of podman, on a runner whose AppArmor
# profile of pasta refuses it (Ubuntu 26.04, https://bugs.launchpad.net/bugs/2154379). Podman
# stops the pasta of its rootless network namespace when the last container of its bridge
# networks goes (as compose's on the Podman socket); the profile denies the signal, so removing
# the container fails: "rootless netns: kill network process: permission denied". The
# workaround of the bug report, which docs/troubleshooting.md#podman gives users; nothing when
# there is no such profile or it already allows the signal.
set -euo pipefail

profile=/etc/apparmor.d/usr.bin.pasta
if [[ ! -f "${profile}" ]]; then
  echo "no ${profile}: nothing to do"
  exit 0
fi
if grep -qE '^\s*signal\b.*peer=podman' "${profile}"; then
  echo "${profile} already lets podman signal pasta"
  exit 0
fi
sudo sed -i 's|^\(\s*include <abstractions/pasta>\)$|\1\n  signal (receive) set=(term) peer=podman,|' "${profile}"
grep -qE '^\s*signal \(receive\) set=\(term\) peer=podman,$' "${profile}" \
  || { echo "::error::no 'include <abstractions/pasta>' line in ${profile} to add the rule after"; exit 1; }
sudo apparmor_parser -r "${profile}"
echo "${profile}: pasta now receives podman's SIGTERM"
