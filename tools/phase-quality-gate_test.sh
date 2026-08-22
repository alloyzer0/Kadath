#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runner="$script_dir/phase-quality-gate.sh"

set +e
output="$($runner 2>&1)"
status=$?
set -e

if [[ "$status" -ne 2 ]]; then
    printf 'expected blocked exit status 2, got %s\n%s\n' "$status" "$output" >&2
    exit 1
fi
grep -Fqx 'PHASE3_QUALITY_GATE=BLOCKED' <<<"$output"
grep -Fq 'PHASE3_COVERAGE=BLOCKED' <<<"$output"
grep -Fq 'PHASE3_MUTATION=BLOCKED' <<<"$output"
grep -Fq 'PHASE3_ORACLE=BLOCKED' <<<"$output"
if grep -Fq 'QUALITY_GATE_STATUS=PASS' <<<"$output"; then
    printf 'blocked preflight must never report a quality PASS\n' >&2
    exit 1
fi
