#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: phase-quality-gate.sh [options]

Required evidence options:
  --candidate-sha SHA       exact candidate commit described by every report
  --candidate-benchmark PATH  executable for the current Rust Core candidate
  --oracle-worktree PATH      worktree checked out at bfc5504
  --oracle-benchmark PATH     executable for the bfc5504 Zig queue/flush oracle
  --coverage-report PATH      report containing PHASE3_COVERAGE_STATUS=PASS
  --mutation-report PATH      report containing PHASE3_MUTATION_STATUS=PASS
  --performance-report PATH   report containing PHASE3_PERF_STATUS=PASS
  --oracle-report PATH        report containing PHASE3_ORACLE_STATUS=PASS
  --help                      show this help

Exit status 0 means every required evidence source is present and marked PASS.
Exit status 2 means the gate is blocked. Exit status 1 means invalid usage.
USAGE
}

candidate_sha=""
candidate_benchmark=""
oracle_worktree=""
oracle_benchmark=""
coverage_report=""
mutation_report=""
performance_report=""
oracle_report=""

while (($# > 0)); do
    case "$1" in
        --candidate-sha)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            candidate_sha=$2
            shift 2
            ;;
        --candidate-benchmark)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            candidate_benchmark=$2
            shift 2
            ;;
        --oracle-worktree)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            oracle_worktree=$2
            shift 2
            ;;
        --oracle-benchmark)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            oracle_benchmark=$2
            shift 2
            ;;
        --coverage-report)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            coverage_report=$2
            shift 2
            ;;
        --mutation-report)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            mutation_report=$2
            shift 2
            ;;
        --performance-report)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            performance_report=$2
            shift 2
            ;;
        --oracle-report)
            (($# >= 2)) || { printf '%s\n' "missing value for $1" >&2; exit 1; }
            oracle_report=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf '%s\n' "unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

blocked=()
coverage_status=READY
coverage_reason=ok
mutation_status=READY
mutation_reason=ok
perf_status=READY
perf_reason=ok
oracle_status=READY
oracle_reason=ok
candidate_status=READY
candidate_reason=ok

report_has_key() {
    local report=$1
    local key=$2
    local expected=$3
    [[ -f "$report" ]] && grep -Fqx "${key}=${expected}" "$report"
}

report_bound_to_candidate() {
    local report=$1
    report_has_key "$report" PHASE3_REPORT_VERSION 1 &&
        report_has_key "$report" PHASE3_CANDIDATE_SHA "$candidate_sha" &&
        grep -Eq '^PHASE3_COMMAND=.+' "$report"
}

report_bound_to_oracle() {
    local report=$1
    local expected_oracle=$2
    report_has_key "$report" PHASE3_ORACLE_SHA "$expected_oracle"
}

report_file_matches_hash() {
    local report=$1
    local path_key=$2
    local hash_key=$3
    local path expected actual
    path=$(sed -n "s/^${path_key}=//p" "$report")
    expected=$(sed -n "s/^${hash_key}=//p" "$report")
    [[ -n "$path" && -f "$path" && "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256sum "$path" | awk '{print $1}')
    [[ "$actual" == "$expected" ]]
}

metric_at_most() {
    local report=$1
    local key=$2
    local limit=$3
    local value
    value=$(sed -n "s/^${key}=//p" "$report")
    [[ -n "$value" ]] && awk -v value="$value" -v limit="$limit" 'BEGIN { exit !(value <= limit) }'
}

if [[ -z "$candidate_sha" ]] || ! resolved_candidate=$(git rev-parse --verify "${candidate_sha}^{commit}" 2>/dev/null) ||
    [[ "$resolved_candidate" != "$(git rev-parse HEAD)" ]]; then
    candidate_status=BLOCKED
    candidate_reason="candidate SHA is missing or is not current HEAD"
    blocked+=("candidate SHA mismatch")
else
    candidate_sha=$resolved_candidate
fi

rust_llvm_bin="$(rustc --print sysroot 2>/dev/null)/lib/rustlib/$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')/bin"
if [[ ! -x "$rust_llvm_bin/llvm-cov" || ! -x "$rust_llvm_bin/llvm-profdata" ]] &&
    { ! command -v llvm-cov >/dev/null 2>&1 || ! command -v llvm-profdata >/dev/null 2>&1; }; then
    coverage_status=BLOCKED
    coverage_reason="llvm-cov/llvm-profdata unavailable"
    blocked+=("coverage tools unavailable")
fi
if [[ -z "$coverage_report" ]]; then
    coverage_status=BLOCKED
    coverage_reason="coverage report not supplied"
    blocked+=("coverage report missing")
elif ! report_bound_to_candidate "$coverage_report" ||
    ! report_has_key "$coverage_report" PHASE3_COVERAGE_STATUS PASS ||
    ! grep -Eq '^PHASE3_COVERAGE_PHASE_COMMIT_PERCENT=([9][0-9]|100)(\.[0-9]+)?$' "$coverage_report" ||
    ! grep -Eq '^PHASE3_COVERAGE_PUBLIC_C_PERCENT=([9][0-9]|100)(\.[0-9]+)?$' "$coverage_report" ||
    ! grep -Eq '^PHASE3_COVERAGE_ZIG_ADAPTER_PERCENT=([9][0-9]|100)(\.[0-9]+)?$' "$coverage_report" ||
    ! grep -Eq '^PHASE3_COVERAGE_BEHAVIOR_HOST_PERCENT=([9][0-9]|100)(\.[0-9]+)?$' "$coverage_report" ||
    ! report_has_key "$coverage_report" PHASE3_DECISION_MATRIX_PERCENT 100 ||
    ! grep -Eq '^PHASE3_DECISION_MATRIX_MANIFEST_SHA256=[0-9a-f]{64}$' "$coverage_report" ||
    ! report_file_matches_hash "$coverage_report" PHASE3_DECISION_MATRIX_EVIDENCE PHASE3_DECISION_MATRIX_MANIFEST_SHA256; then
    coverage_status=BLOCKED
    coverage_reason="coverage report schema, SHA, command, or metrics invalid"
    blocked+=("coverage report is not verifiable PASS")
fi

if [[ -z "${PHASE_MUTATION_RUNNER:-}" ]] && ! command -v cargo-mutants >/dev/null 2>&1; then
    mutation_status=BLOCKED
    mutation_reason="cargo-mutants unavailable"
    blocked+=("mutation tool unavailable")
fi
if [[ -z "$mutation_report" ]]; then
    mutation_status=BLOCKED
    mutation_reason="mutation report not supplied"
    blocked+=("mutation report missing")
elif ! report_bound_to_candidate "$mutation_report" ||
    ! report_has_key "$mutation_report" PHASE3_MUTATION_STATUS PASS ||
    ! grep -Eq '^PHASE3_MUTATION_SCORE_PERCENT=([8-9][0-9]|100)(\.[0-9]+)?$' "$mutation_report" ||
    ! grep -Eq '^PHASE3_MUTATION_TOTAL=[1-9][0-9]*$' "$mutation_report" ||
    ! grep -Eq '^PHASE3_MUTATION_KILLED=[1-9][0-9]*$' "$mutation_report" ||
    ! report_has_key "$mutation_report" PHASE3_MUTATION_SURVIVED 0 ||
    ! report_has_key "$mutation_report" PHASE3_MUTATION_UNVIABLE 0 ||
    ! report_has_key "$mutation_report" PHASE3_CRITICAL_SURVIVORS 0 ||
    ! grep -Eq '^PHASE3_MUTATION_MANIFEST_SHA256=[0-9a-f]{64}$' "$mutation_report" ||
    ! report_file_matches_hash "$mutation_report" PHASE3_MUTATION_MANIFEST PHASE3_MUTATION_MANIFEST_SHA256; then
    mutation_status=BLOCKED
    mutation_reason="mutation report schema, SHA, command, or metrics invalid"
    blocked+=("mutation report is not verifiable PASS")
fi

if [[ -z "$performance_report" ]]; then
    perf_status=BLOCKED
    perf_reason="performance report not supplied"
    blocked+=("performance report missing")
elif ! report_bound_to_candidate "$performance_report" ||
    ! report_has_key "$performance_report" PHASE3_PERF_STATUS PASS ||
    ! metric_at_most "$performance_report" PHASE3_PERF_P95_RATIO 1.25 ||
    ! metric_at_most "$performance_report" PHASE3_PERF_RSS_RATIO 1.25 ||
    ! report_has_key "$performance_report" PHASE3_STEADY_STATE_ALLOCATION_DELTA 0; then
    perf_status=BLOCKED
    perf_reason="performance report schema, SHA, command, or metrics invalid"
    blocked+=("performance report is not verifiable PASS")
fi

if [[ -z "$candidate_benchmark" || ! -x "$candidate_benchmark" ]]; then
    candidate_status=BLOCKED
    candidate_reason="candidate benchmark executable missing"
    blocked+=("candidate benchmark missing")
elif [[ -n "$performance_report" ]] &&
    ! report_file_matches_hash "$performance_report" PHASE3_CANDIDATE_BENCHMARK PHASE3_CANDIDATE_BENCHMARK_SHA256; then
    candidate_status=BLOCKED
    candidate_reason="candidate benchmark hash is not bound to performance report"
    blocked+=("candidate benchmark hash mismatch")
fi

if [[ -z "$oracle_worktree" || ! -d "$oracle_worktree" ]]; then
    oracle_status=BLOCKED
    oracle_reason="oracle worktree not supplied"
    blocked+=("oracle worktree missing")
elif ! oracle_sha=$(git -C "$oracle_worktree" rev-parse --verify bfc5504^{commit} 2>/dev/null) ||
    [[ "$(git -C "$oracle_worktree" rev-parse HEAD 2>/dev/null)" != "$oracle_sha" ]]; then
    oracle_status=BLOCKED
    oracle_reason="oracle worktree is not checked out at bfc5504"
    blocked+=("oracle worktree is not bfc5504")
fi
if [[ -z "$oracle_benchmark" || ! -x "$oracle_benchmark" ]]; then
    oracle_status=BLOCKED
    oracle_reason="oracle benchmark executable missing"
    blocked+=("oracle benchmark missing")
elif [[ -n "$oracle_report" ]] &&
    ! report_file_matches_hash "$oracle_report" PHASE3_ORACLE_BENCHMARK PHASE3_ORACLE_BENCHMARK_SHA256; then
    oracle_status=BLOCKED
    oracle_reason="oracle benchmark hash is not bound to oracle report"
    blocked+=("oracle benchmark hash mismatch")
fi
if [[ -z "$oracle_report" ]]; then
    oracle_status=BLOCKED
    oracle_reason="oracle report not supplied"
    blocked+=("oracle report missing")
elif ! report_bound_to_candidate "$oracle_report" ||
    ! report_bound_to_oracle "$oracle_report" "$oracle_sha" ||
    ! report_has_key "$oracle_report" PHASE3_ORACLE_STATUS PASS ||
    ! report_has_key "$oracle_report" PHASE3_ORACLE_WORKTREE_CLEAN true ||
    ! report_has_key "$oracle_report" PHASE3_ORACLE_SOURCE_MATCH true ||
    ! grep -Eq '^PHASE3_ORACLE_SOURCE_SHA256=[0-9a-f]{64}$' "$oracle_report" ||
    ! grep -Eq '^PHASE3_ORACLE_AUTHORITY_SHA256=[0-9a-f]{64}$' "$oracle_report" ||
    ! grep -Eq '^PHASE3_ORACLE_FIXED_P95_NS=[1-9][0-9]*$' "$oracle_report" ||
    ! grep -Eq '^PHASE3_ORACLE_FRAME_P95_NS=[1-9][0-9]*$' "$oracle_report"; then
    oracle_status=BLOCKED
    oracle_reason="oracle report schema, SHA, command, or metrics invalid"
    blocked+=("oracle report is not verifiable PASS")
fi

printf 'PHASE3_COVERAGE=%s\n' "$coverage_status"
printf 'PHASE3_COVERAGE_REASON=%s\n' "$coverage_reason"
printf 'PHASE3_MUTATION=%s\n' "$mutation_status"
printf 'PHASE3_MUTATION_REASON=%s\n' "$mutation_reason"
printf 'PHASE3_PERF=%s\n' "$perf_status"
printf 'PHASE3_PERF_REASON=%s\n' "$perf_reason"
printf 'PHASE3_CANDIDATE=%s\n' "$candidate_status"
printf 'PHASE3_CANDIDATE_REASON=%s\n' "$candidate_reason"
printf 'PHASE3_ORACLE=%s\n' "$oracle_status"
printf 'PHASE3_ORACLE_REASON=%s\n' "$oracle_reason"

if ((${#blocked[@]} != 0)); then
    printf 'PHASE3_QUALITY_GATE=BLOCKED\n'
    for reason in "${blocked[@]}"; do
        printf 'PHASE3_BLOCKER=%s\n' "$reason"
    done
    exit 2
fi

printf 'PHASE3_QUALITY_GATE=PASS\n'
printf 'QUALITY_GATE_STATUS=PASS\n'
