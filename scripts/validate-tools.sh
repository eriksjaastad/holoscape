#!/usr/bin/env bash
# Validate tracked shell tooling and bundled skin package contracts without
# rewriting generated artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/holoscape-tool-validation.XXXXXX")"
trap 'rm -rf "${temp_dir}"' EXIT

tracked_scripts="${temp_dir}/tracked-shell-scripts"
if ! git -C "${REPO_ROOT}" ls-files -z '*.sh' > "${tracked_scripts}"; then
    echo "error: could not enumerate tracked shell scripts" >&2
    exit 1
fi

shell_script_count=0
while IFS= read -r -d '' relative_path; do
    bash -n "${REPO_ROOT}/${relative_path}"
    shell_script_count=$((shell_script_count + 1))
done < "${tracked_scripts}"
if [[ "${shell_script_count}" -eq 0 ]]; then
    echo "error: tracked shell-script enumeration returned no files" >&2
    exit 1
fi

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
missing_output="${temp_dir}/missing-skin-output"
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
    "${shell_script_count}" "${#package_tools[@]}"
