#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
runner=("$BASH" "$script_dir/gameplay-quality-gate.sh")
evidence_root=$(mktemp -d)
trap 'rm -rf -- "$evidence_root"' EXIT

set +e
output=$("${runner[@]}" 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]] || grep -Fq QUALITY_GATE_PASS <<<"$output"; then
    printf 'empty evidence must fail closed without PASS\n%s\n' "$output" >&2
    exit 1
fi
grep -Fq QUALITY_GATE_BLOCKED <<<"$output"

candidate="$evidence_root/candidate"
oracle="$evidence_root/oracle"
printf '#!/usr/bin/env bash\nexit 0\n' >"$candidate"
printf '#!/usr/bin/env bash\nexit 0\n' >"$oracle"
chmod +x "$candidate" "$oracle"
for report in coverage mutation candidate oracle; do
    printf 'GAMEPLAY_CANDIDATE_SHA=0000000000000000000000000000000000000000\n' >"$evidence_root/$report.report"
done

set +e
output=$("${runner[@]}" \
    --candidate-sha 1111111111111111111111111111111111111111 \
    --candidate-benchmark "$candidate" --candidate-report "$evidence_root/candidate.report" \
    --oracle-benchmark "$oracle" --oracle-report "$evidence_root/oracle.report" \
    --coverage-report "$evidence_root/coverage.report" \
    --mutation-report "$evidence_root/mutation.report" 2>&1)
status=$?
set -e
if [[ $status -eq 0 ]] || grep -Fq QUALITY_GATE_PASS <<<"$output"; then
    printf 'unbound/incomplete evidence must fail closed without PASS\n%s\n' "$output" >&2
    exit 1
fi
grep -Fq QUALITY_GATE_BLOCKED <<<"$output"
printf 'GAMEPLAY_QUALITY_GATE_BLOCKED_PATH=PASS\n'
