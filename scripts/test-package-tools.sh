#!/usr/bin/env bash
# Regression probes for fail-closed package-tool subprocess handling.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/holoscape-package-tool-tests.XXXXXX")"
trap 'rm -rf "${temp_dir}"' EXIT

assert_failed_with() {
    local status="$1"
    local output="$2"
    local expected="$3"
    local description="$4"

    if [[ "${status}" -eq 0 ]]; then
        echo "error: ${description} unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -Fq "${expected}" "${output}"; then
        echo "error: ${description} returned the wrong failure" >&2
        while IFS= read -r line; do
            printf '%s\n' "${line}" >&2
        done < "${output}"
        exit 1
    fi
}

mkdir "${temp_dir}/git-bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\0" scripts/validate-tools.sh' \
    'exit 19' \
    > "${temp_dir}/git-bin/git"
chmod +x "${temp_dir}/git-bin/git"

git_output="${temp_dir}/git-output"
set +e
PATH="${temp_dir}/git-bin:${PATH}" \
    "${REPO_ROOT}/scripts/validate-tools.sh" > "${git_output}" 2>&1
git_status=$?
set -e
assert_failed_with \
    "${git_status}" \
    "${git_output}" \
    "could not enumerate tracked shell scripts" \
    "failed tracked-script enumeration"

real_unzip="$(command -v unzip)"
mkdir "${temp_dir}/unzip-bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '"${REAL_UNZIP:?}" "$@"' \
    'status=$?' \
    'if [[ "${1:-}" == "-p" ]]; then exit 23; fi' \
    'exit "${status}"' \
    > "${temp_dir}/unzip-bin/unzip"
chmod +x "${temp_dir}/unzip-bin/unzip"

unzip_output="${temp_dir}/unzip-output"
set +e
REAL_UNZIP="${real_unzip}" PATH="${temp_dir}/unzip-bin:${PATH}" \
    "${REPO_ROOT}/tools/package_synthwave.sh" --check > "${unzip_output}" 2>&1
unzip_status=$?
set -e
assert_failed_with \
    "${unzip_status}" \
    "${unzip_output}" \
    "could not extract" \
    "failed archive extraction"

echo "validated package-tool failure propagation"