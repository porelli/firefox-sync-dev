#!/bin/bash
# chart-version.sh <chart dir> [<tag> <default branch ref>]: the version of the chart's
# Chart.yaml, a semantic version, as version=<v> and prerelease=true|false (for GITHUB_OUTPUT).
# With a tag (the publishing, .github/workflows/helm.yml): fails unless the tag is
# chart-v<version>, and, for a stable version (no -<pre-release>; +<build> alone is stable),
# unless HEAD, the tagged commit, is on the default branch. Tested by tests/helm.sh lint.
set -euo pipefail

chart_dir=$1 tag=${2:-} default_ref=${3:-}

error() {
  echo "::error::$1" >&2
  exit 1
}

version=$(sed -n 's/^version:[[:space:]]*//p' "${chart_dir}/Chart.yaml" | tr -d "\"'" | sed 's/[[:space:]]*$//')
# semver.org's: MAJOR.MINOR.PATCH, no leading zeros, then -<pre-release> and +<build>
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
[[ ${version} =~ ${semver} ]] || error "${chart_dir}/Chart.yaml: version '${version}' is not a semantic version (MAJOR.MINOR.PATCH)"
prerelease=false
[[ -z ${BASH_REMATCH[4]} ]] || prerelease=true

if [[ -n ${tag} ]]; then
  [[ ${tag} == "chart-v${version}" ]] || error "tag ${tag} is not chart-v${version} (the version of ${chart_dir}/Chart.yaml)"
  if [[ ${prerelease} == false ]]; then
    [[ -n ${default_ref} ]] || error "a stable version needs the default branch to check"
    git merge-base --is-ancestor HEAD "${default_ref}" \
      || error "${version} is a stable version: tag a commit of ${default_ref#origin/} (or publish a pre-release, e.g. ${version%%+*}-rc.1)"
  fi
fi

echo "version=${version}"
echo "prerelease=${prerelease}"
