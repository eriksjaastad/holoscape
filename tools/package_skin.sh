#!/usr/bin/env bash
# Package or validate an in-tree skin's .wamp archive.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: tools/package_skin.sh SKIN_NAME [--check]

Package Sources/Holoscape/Resources/Skins/SKIN_NAME as SKIN_NAME.wamp.
The default mode writes the archive atomically. --check verifies that the
existing archive contains exactly the current source files and bytes without
modifying it. Paths are resolved from this script, so any working directory is
supported.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

skin_name="${1:-}"
mode="${2:-package}"
if [[ -z "${skin_name}" || ("${mode}" != "package" && "${mode}" != "--check") || $# -gt 2 ]]; then
    usage >&2
    exit 64
fi
if [[ "${skin_name}" == */* || "${skin_name}" == "." || "${skin_name}" == ".." ]]; then
    echo "error: SKIN_NAME must be one directory name" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
skin_dir="${REPO_ROOT}/Sources/Holoscape/Resources/Skins/${skin_name}"
output="${REPO_ROOT}/Sources/Holoscape/Resources/Skins/${skin_name}.wamp"

if [[ ! -d "${skin_dir}" ]]; then
    echo "error: directory-layout skin not found at ${skin_dir}" >&2
    exit 1
fi
if [[ ! -f "${skin_dir}/skin.json" ]]; then
    echo "error: skin manifest not found at ${skin_dir}/skin.json" >&2
    exit 1
fi

if [[ "${mode}" == "--check" ]]; then
    if [[ ! -f "${output}" ]]; then
        echo "error: packaged skin not found at ${output}" >&2
        exit 1
    fi

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/holoscape-wamp-check.XXXXXX")"
    trap 'rm -rf "${temp_dir}"' EXIT

    source_list="${temp_dir}/source-files"
    archive_list="${temp_dir}/archive-files"
    archive_entry="${temp_dir}/archive-entry"
    if ! unzip -tqq "${output}"; then
        echo "error: ${skin_name}.wamp failed archive integrity validation" >&2
        exit 1
    fi
    (
        cd "${skin_dir}"
        find . -type f -print | while IFS= read -r relative_path; do
            printf '%s\n' "${relative_path#./}"
        done | LC_ALL=C sort
    ) > "${source_list}"
    zipinfo -1 "${output}" | while IFS= read -r relative_path; do
        [[ "${relative_path}" == */ ]] && continue
        case "${relative_path}" in
            /*|../*|*/../*|*/..)
                echo "error: ${skin_name}.wamp contains unsafe path ${relative_path}" >&2
                exit 1
                ;;
        esac
        printf '%s\n' "${relative_path}"
    done | LC_ALL=C sort > "${archive_list}"

    if ! cmp -s "${source_list}" "${archive_list}"; then
        echo "error: ${skin_name}.wamp file list does not match ${skin_name}/" >&2
        diff -u "${source_list}" "${archive_list}" >&2 || true
        exit 1
    fi

    while IFS= read -r relative_path; do
        if ! unzip -p "${output}" "${relative_path}" > "${archive_entry}"; then
            echo "error: could not extract ${relative_path} from ${skin_name}.wamp" >&2
            exit 1
        fi
        if ! cmp -s "${skin_dir}/${relative_path}" "${archive_entry}"; then
            echo "error: ${skin_name}.wamp has stale bytes for ${relative_path}" >&2
            exit 1
        fi
    done < "${source_list}"

    echo "validated: ${output}"
    exit 0
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/holoscape-wamp-package.XXXXXX")"
trap 'rm -rf "${temp_dir}"' EXIT
temp_output="${temp_dir}/${skin_name}.wamp"
(
    cd "${skin_dir}"
    zip -qrX "${temp_output}" .
)
mv "${temp_output}" "${output}"
echo "packaged: ${output}"
