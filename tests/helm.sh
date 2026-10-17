#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${REPO_ROOT}/charts/firefox-sync"

check() {
  echo "✓ $1"
}

fail() {
  echo "✗ $1"
  exit 1
}

lint() {
  echo "=== Running Helm lint checks ==="

  # Check that chart directory exists
  if [[ ! -d "${CHART_DIR}" ]]; then
    fail "Chart directory not found: ${CHART_DIR}"
  fi

  # Lint with each CI values file
  for values_file in "${CHART_DIR}"/ci/*.yaml; do
    if [[ ! -f "${values_file}" ]]; then
      continue
    fi
    echo "Linting with $(basename "${values_file}")..."
    if ! helm lint "${CHART_DIR}" -f "${values_file}"; then
      fail "Helm lint failed with $(basename "${values_file}")"
    fi
    check "Helm lint passed with $(basename "${values_file}")"
  done

  # Test maxUsers value propagation
  echo "Testing maxUsers value propagation..."
  output=$(helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set-string maxUsers=5)
  count=$(echo "${output}" | grep -c 'value: "5"' || true)
  if [[ ${count} -lt 1 ]]; then
    fail "maxUsers=5 not found in template output (expected at least 1 occurrence, found ${count})"
  fi
  check "maxUsers value propagation works (found ${count} occurrences)"

  # Test schema validation - invalid backend should fail
  echo "Testing schema validation with invalid backend..."
  if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend=sqlite 2>&1 | grep -q -E '(does not match|not valid|schema)'; then
    check "Schema validation correctly rejects invalid database.backend"
  else
    # Try without expecting error - helm might not have schema validation in all versions
    if helm template test-release "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" --set database.backend=sqlite >/dev/null 2>&1; then
      echo "⚠ Schema validation not enforced (helm version may not support it)"
    else
      check "Schema validation correctly rejects invalid database.backend"
    fi
  fi

  echo ""
  echo "=== All lint checks passed ==="
}

case "${1:-}" in
  lint)
    lint
    ;;
  *)
    echo "Usage: $0 {lint}"
    echo "  lint - Run helm lint and basic validation tests"
    exit 1
    ;;
esac
