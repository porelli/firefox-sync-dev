#!/bin/bash
# chart-unpublished.sh oci://<registry>/<path>/<chart> <version> [helm args...]: succeeds only
# when the registry clearly answers that this version of the chart is not there (a version is
# published once, .github/workflows/helm.yml). Fails closed: the version there ("already
# published"), or any other answer (unreachable, login, rate limit, an unknown message), fails
# with helm's error shown. Not found is helm's (oras') message for a missing tag or repository,
# as ghcr.io and registry:2 answer it (helm 3.22): '<ref>: not found'.
set -uo pipefail

chart=$1 version=$2
shift 2

out=$(helm show chart "${chart}" --version "${version}" "$@" 2>&1)
rc=$?
if [[ ${rc} -eq 0 ]]; then
  echo "::error::${chart} ${version} is already published: bump the version in Chart.yaml"
  exit 1
fi
# the tag as the registry has it: helm writes + as _ (OCI tags have no +)
ref="${chart#oci://}:${version//+/_}"
if [[ "${out}" == "Error: failed to perform \"FetchReference\" on source: ${ref}: not found" ]]; then
  echo "${chart} ${version}: not published yet"
  exit 0
fi
echo "::error::could not tell whether ${chart} ${version} is published (not pushing): ${out//$'\n'/ }"
exit 1
