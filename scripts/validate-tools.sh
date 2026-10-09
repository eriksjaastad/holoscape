#!/usr/bin/env bash
# Validate tracked shell tooling and bundled skin package contracts without
# rewriting generated artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

shell_scripts=()
while IFS= read -r relative_path; do
    shell_scripts+=("${relative_path}")
done < <(git -C "${REPO_ROOT}" ls-files '*.sh')
for relative_path in "${shell_scripts[@]}"; do
    bash -n "${REPO_ROOT}/${relative_path}"
done

package_tools=(
    "tools/package_synthwave.sh"
    "tools/package_holoscape_classic_live.sh"
)
for relative_path in "${package_tools[@]}"; do
    tool="${REPO_ROOT}/${relative_path}"
    if [[ ! -x "${tool}" ]]; then
        echo "error: expected executable package tool at ${relative_path}" >&2
        exit 1
    fi
    "${tool}" --help >/dev/null
    "${tool}" --check
done

missing_skin="HoloscapeValidationMissingSkin"
missing_output="$(mktemp "${TMPDIR:-/tmp}/holoscape-missing-skin.XXXXXX")"
trap 'rm -f "${missing_output}"' EXIT
if "${REPO_ROOT}/tools/package_skin.sh" "${missing_skin}" --check >"${missing_output}" 2>&1; then
    echo "error: missing skin package validation unexpectedly passed" >&2
    exit 1
fi
if ! grep -Fq "directory-layout skin not found" "${missing_output}"; then
    echo "error: missing skin package validation returned the wrong failure" >&2
    cat "${missing_output}" >&2
    exit 1
fi

printf 'validated %d shell scripts and %d skin package contracts\n' \
    "${#shell_scripts[@]}" "${#package_tools[@]}"
