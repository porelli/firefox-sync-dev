#!/bin/bash
# sync-app-version.sh <registry> <owner/repository>: the newest syncstorage-rs release published
# as syncstorage-rs-mysql-<X.Y.Z> in this repository's image package, the version the chart's
# default (latest) images run: the appVersion of a published chart (helm package --app-version).
# TOKEN: a token that reads the package (GITHUB_TOKEN). Fails, prints nothing, when none is found.
set -euo pipefail
registry=$1 repository=$(printf "%s" "$2" | tr "[:upper:]" "[:lower:]")
auth="Authorization: Bearer $(printf '%s' "${TOKEN}" | base64 -w0)"
url="https://${registry}/v2/${repository}/tags/list?n=1000"
tags=$(mktemp)
trap 'rm -f "${tags}" "${tags}.h"' EXIT
# the tags list is paged: a Link header names the next page
while [ -n "${url}" ]; do
  curl -fsS -D "${tags}.h" -H "${auth}" "${url}" | python3 -I -c 'import json, sys; print("\n".join(json.load(sys.stdin).get("tags") or []))' >> "${tags}"
  next=$(sed -n 's/^[Ll]ink: *<\([^>]*\)>; *rel="next".*/\1/p' "${tags}.h" | tr -d '\r')
  url=""
  [ -z "${next}" ] || url="https://${registry}${next}"
done
version=$(sed -n 's/^syncstorage-rs-mysql-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' "${tags}" | sort -V | tail -n 1)
[ -n "${version}" ] || { echo "no syncstorage-rs-mysql-X.Y.Z tag in ${registry}/${repository}" >&2; exit 1; }
echo "${version}"
