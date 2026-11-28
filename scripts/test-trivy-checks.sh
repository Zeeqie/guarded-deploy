#!/usr/bin/env bash
# Unit tests for the custom Trivy checks in .trivy/checks/ (run by CI and locally).
# Each .trivy/checks/testdata/<case>/main.tf.fixture is copied to a temp dir as main.tf
# (the .fixture suffix keeps the repo-wide `trivy fs` scan from failing on the bad cases).
# pos_* cases must produce >= 1 GD-0001 failure; neg_* cases must produce none.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKS="${ROOT}/.trivy/checks"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

for case_dir in "${CHECKS}"/testdata/*/; do
  name="$(basename "$case_dir")"
  mkdir -p "${WORK}/${name}"
  cp "${case_dir}main.tf.fixture" "${WORK}/${name}/main.tf"
  hits="$(trivy config --quiet --skip-check-update --config-check "$CHECKS" \
    --check-namespaces user --format json "${WORK}/${name}" |
    jq '[.Results[]?.Misconfigurations[]? | select(.ID == "GD-0001" and .Status == "FAIL")] | length')"
  case "$name" in
  pos_*) want="fail" ok=$((hits > 0)) ;;
  neg_*) want="pass" ok=$((hits == 0)) ;;
  *) echo "unknown case prefix: ${name}" >&2; exit 2 ;;
  esac
  if [[ "$ok" -eq 1 ]]; then
    echo "PASS ${name}: expected ${want}, GD-0001 failures=${hits}"
  else
    echo "FAIL ${name}: expected ${want}, GD-0001 failures=${hits}"
    failures=$((failures + 1))
  fi
done

echo "custom check self-test: ${failures} failing case(s)"
[[ "$failures" -eq 0 ]]
