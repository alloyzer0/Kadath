#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runner="$script_dir/phase-quality-gate.sh"
repository_root="$(cd -- "$script_dir/.." && pwd)"

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

evidence_root="$(mktemp -d)"
trap 'rm -rf -- "$evidence_root"' EXIT

candidate_sha="$(git -C "$repository_root" rev-parse HEAD)"
oracle_sha="$(git -C "$repository_root" rev-parse bfc5504^{commit})"
mkdir -p "$evidence_root/oracle"
git -C "$repository_root" worktree add --detach "$evidence_root/oracle" "$oracle_sha" >/dev/null
trap 'git -C "$repository_root" worktree remove --force "$evidence_root/oracle" >/dev/null 2>&1 || true; rm -rf -- "$evidence_root"' EXIT

candidate_benchmark="$evidence_root/candidate-benchmark"
oracle_benchmark="$evidence_root/oracle-benchmark"
printf '#!/usr/bin/env bash\nexit 0\n' >"$candidate_benchmark"
printf '#!/usr/bin/env bash\nexit 0\n' >"$oracle_benchmark"
chmod +x "$candidate_benchmark" "$oracle_benchmark"
candidate_benchmark_sha="$(sha256sum "$candidate_benchmark" | awk '{print $1}')"
oracle_benchmark_sha="$(sha256sum "$oracle_benchmark" | awk '{print $1}')"

write_report() {
    local path=$1
    local status_key=$2
    cat >"$path" <<EOF
PHASE3_REPORT_VERSION=1
PHASE3_CANDIDATE_SHA=$candidate_sha
PHASE3_ORACLE_SHA=$oracle_sha
PHASE3_COMMAND=forged-token-only
${status_key}=PASS
EOF
}
write_report "$evidence_root/coverage.report" PHASE3_COVERAGE_STATUS
write_report "$evidence_root/mutation.report" PHASE3_MUTATION_STATUS
write_report "$evidence_root/performance.report" PHASE3_PERF_STATUS
write_report "$evidence_root/oracle.report" PHASE3_ORACLE_STATUS

set +e
forged_output="$($runner \
    --candidate-sha "$candidate_sha" \
    --candidate-benchmark "$candidate_benchmark" \
    --oracle-worktree "$evidence_root/oracle" \
    --oracle-benchmark "$oracle_benchmark" \
    --coverage-report "$evidence_root/coverage.report" \
    --mutation-report "$evidence_root/mutation.report" \
    --performance-report "$evidence_root/performance.report" \
    --oracle-report "$evidence_root/oracle.report" 2>&1)"
forged_status=$?
set -e

if [[ "$forged_status" -ne 2 ]]; then
    printf 'token-only forged reports must be blocked, got %s\n%s\n' "$forged_status" "$forged_output" >&2
    exit 1
fi
grep -Fqx 'PHASE3_QUALITY_GATE=BLOCKED' <<<"$forged_output"
if grep -Fq 'QUALITY_GATE_STATUS=PASS' <<<"$forged_output"; then
    printf 'token-only forged reports must never publish PASS\n' >&2
    exit 1
fi

# A report that satisfies every older aggregate token but omits a newly frozen
# source or per-mutant manifest must remain blocked.
cat >>"$evidence_root/coverage.report" <<'EOF'
PHASE3_COVERAGE_PHASE_COMMIT_PERCENT=100
PHASE3_COVERAGE_PUBLIC_C_PERCENT=100
PHASE3_COVERAGE_ZIG_ADAPTER_PERCENT=100
PHASE3_DECISION_MATRIX_PERCENT=100
EOF
cat >>"$evidence_root/mutation.report" <<'EOF'
PHASE3_MUTATION_SCORE_PERCENT=100
PHASE3_CRITICAL_SURVIVORS=0
PHASE3_MUTATION_MANIFEST_SHA256=0000000000000000000000000000000000000000000000000000000000000000
EOF
cat >>"$evidence_root/performance.report" <<'EOF'
PHASE3_PERF_P95_RATIO=1.0
PHASE3_CANDIDATE_WORST_P95_MEDIAN_NS=1
PHASE3_PERF_OVERHEAD_NS_PER_ITEM=0
PHASE3_PERF_PAIRED_RUNS=5
PHASE3_PERF_RSS_RATIO=1.0
PHASE3_STEADY_STATE_ALLOCATION_DELTA=0
EOF
cat >>"$evidence_root/performance.report" <<EOF
PHASE3_CANDIDATE_BENCHMARK=$candidate_benchmark
PHASE3_CANDIDATE_BENCHMARK_SHA256=$candidate_benchmark_sha
EOF
cat >>"$evidence_root/oracle.report" <<EOF
PHASE3_ORACLE_WORKTREE_CLEAN=true
PHASE3_ORACLE_SOURCE_SHA256=0000000000000000000000000000000000000000000000000000000000000000
PHASE3_ORACLE_AUTHORITY_SHA256=0000000000000000000000000000000000000000000000000000000000000000
PHASE3_ORACLE_BENCHMARK=$oracle_benchmark
PHASE3_ORACLE_BENCHMARK_SHA256=$oracle_benchmark_sha
PHASE3_ORACLE_FIXED_P95_NS=1
PHASE3_ORACLE_FRAME_P95_NS=1
EOF
set +e
missing_detail_output="$($runner \
    --candidate-sha "$candidate_sha" \
    --candidate-benchmark "$candidate_benchmark" \
    --oracle-worktree "$evidence_root/oracle" \
    --oracle-benchmark "$oracle_benchmark" \
    --coverage-report "$evidence_root/coverage.report" \
    --mutation-report "$evidence_root/mutation.report" \
    --performance-report "$evidence_root/performance.report" \
    --oracle-report "$evidence_root/oracle.report" 2>&1)"
missing_detail_status=$?
set -e
if [[ "$missing_detail_status" -ne 2 ]]; then
    printf 'reports missing Behavior coverage and mutant counts must be blocked, got %s\n%s\n' \
        "$missing_detail_status" "$missing_detail_output" >&2
    exit 1
fi
grep -Fqx 'PHASE3_QUALITY_GATE=BLOCKED' <<<"$missing_detail_output"

# Even otherwise complete reports must not pass when the evidence-only oracle
# is not proven to be extracted from the frozen bfc5504 authority source.
decision_manifest="$evidence_root/decision-matrix.tsv"
mutation_manifest="$evidence_root/mutation-manifest.tsv"
performance_manifest="$evidence_root/performance-manifest.tsv"
printf 'decision\tPASS\texecuted-public-seam\n' >"$decision_manifest"
printf 'id\tKILLED\tdiff-sha\tpublic-seam\n' >"$mutation_manifest"
printf 'run\tcandidate\toracle\n1\tsha\tsha\n' >"$performance_manifest"
decision_manifest_sha="$(sha256sum "$decision_manifest" | awk '{print $1}')"
mutation_manifest_sha="$(sha256sum "$mutation_manifest" | awk '{print $1}')"
performance_manifest_sha="$(sha256sum "$performance_manifest" | awk '{print $1}')"
cat >"$evidence_root/coverage.report" <<EOF
PHASE3_REPORT_VERSION=1
PHASE3_CANDIDATE_SHA=$candidate_sha
PHASE3_COMMAND=complete-coverage-probe
PHASE3_COVERAGE_STATUS=PASS
PHASE3_COVERAGE_PHASE_COMMIT_PERCENT=100
PHASE3_COVERAGE_PUBLIC_C_PERCENT=100
PHASE3_COVERAGE_ZIG_ADAPTER_PERCENT=100
PHASE3_COVERAGE_BEHAVIOR_HOST_PERCENT=100
PHASE3_DECISION_MATRIX_PERCENT=100
PHASE3_DECISION_MATRIX_MANIFEST_SHA256=$decision_manifest_sha
PHASE3_DECISION_MATRIX_EVIDENCE=$decision_manifest
EOF
cat >"$evidence_root/mutation.report" <<EOF
PHASE3_REPORT_VERSION=1
PHASE3_CANDIDATE_SHA=$candidate_sha
PHASE3_COMMAND=complete-mutation-probe
PHASE3_MUTATION_STATUS=PASS
PHASE3_MUTATION_SCORE_PERCENT=100
PHASE3_MUTATION_TOTAL=1
PHASE3_MUTATION_KILLED=1
PHASE3_MUTATION_SURVIVED=0
PHASE3_MUTATION_UNVIABLE=0
PHASE3_CRITICAL_SURVIVORS=0
PHASE3_MUTATION_MANIFEST_SHA256=$mutation_manifest_sha
PHASE3_MUTATION_MANIFEST=$mutation_manifest
EOF
cat >"$evidence_root/performance.report" <<EOF
PHASE3_REPORT_VERSION=1
PHASE3_CANDIDATE_SHA=$candidate_sha
PHASE3_COMMAND=complete-performance-probe
PHASE3_PERF_STATUS=PASS
PHASE3_PERF_P95_RATIO=1.0
PHASE3_CANDIDATE_WORST_P95_MEDIAN_NS=1
PHASE3_PERF_OVERHEAD_NS_PER_ITEM=0
PHASE3_PERF_PAIRED_RUNS=5
PHASE3_PERF_MANIFEST=$performance_manifest
PHASE3_PERF_MANIFEST_SHA256=$performance_manifest_sha
PHASE3_PERF_RSS_RATIO=1.0
PHASE3_STEADY_STATE_ALLOCATION_DELTA=0
PHASE3_CANDIDATE_BENCHMARK=$candidate_benchmark
PHASE3_CANDIDATE_BENCHMARK_SHA256=$candidate_benchmark_sha
EOF
cat >"$evidence_root/oracle.report" <<EOF
PHASE3_REPORT_VERSION=1
PHASE3_CANDIDATE_SHA=$candidate_sha
PHASE3_ORACLE_SHA=$oracle_sha
PHASE3_COMMAND=complete-oracle-probe
PHASE3_ORACLE_STATUS=PASS
PHASE3_ORACLE_WORKTREE_CLEAN=true
PHASE3_ORACLE_SOURCE_MATCH=false
PHASE3_ORACLE_SOURCE_SHA256=0000000000000000000000000000000000000000000000000000000000000000
PHASE3_ORACLE_AUTHORITY_SHA256=0000000000000000000000000000000000000000000000000000000000000000
PHASE3_ORACLE_BENCHMARK=$oracle_benchmark
PHASE3_ORACLE_BENCHMARK_SHA256=$oracle_benchmark_sha
PHASE3_ORACLE_FIXED_P95_NS=1
PHASE3_ORACLE_FRAME_P95_NS=1
EOF
set +e
unbound_oracle_output="$($runner \
    --candidate-sha "$candidate_sha" \
    --candidate-benchmark "$candidate_benchmark" \
    --oracle-worktree "$evidence_root/oracle" \
    --oracle-benchmark "$oracle_benchmark" \
    --coverage-report "$evidence_root/coverage.report" \
    --mutation-report "$evidence_root/mutation.report" \
    --performance-report "$evidence_root/performance.report" \
    --oracle-report "$evidence_root/oracle.report" 2>&1)"
unbound_oracle_status=$?
set -e
if [[ "$unbound_oracle_status" -ne 2 ]]; then
    printf 'oracle source mismatch must be blocked, got %s\n%s\n' \
        "$unbound_oracle_status" "$unbound_oracle_output" >&2
    exit 1
fi
grep -Fqx 'PHASE3_QUALITY_GATE=BLOCKED' <<<"$unbound_oracle_output"
