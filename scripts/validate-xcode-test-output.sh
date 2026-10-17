#!/bin/bash
set -euo pipefail

output_file=${1:-}

if [[ -z "$output_file" || ! -r "$output_file" ]]; then
    echo "error: cannot read test output: ${output_file:-<missing>}" >&2
    exit 1
fi

set +e
test_case_count=$(grep -Ec '^Test Case .* (passed|failed|skipped)' "$output_file")
grep_status=$?
set -e

if [[ "$grep_status" -gt 1 ]]; then
    echo "error: failed to inspect test output: $output_file" >&2
    exit "$grep_status"
fi
if [[ "$test_case_count" -eq 0 ]]; then
    echo "error: no test cases executed according to test output: $output_file" >&2
    exit 1
fi
