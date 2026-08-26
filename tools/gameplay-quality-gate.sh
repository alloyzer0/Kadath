#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: gameplay-quality-gate.sh --candidate-sha SHA --oracle-sha SHA --candidate-benchmark PATH
  --candidate-report PATH --oracle-benchmark PATH --oracle-report PATH
  --coverage-report PATH --mutation-report PATH
EOF
}

candidate_sha= oracle_sha= candidate_benchmark= candidate_report=
oracle_benchmark= oracle_report= coverage_report= mutation_report=
while (($#)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --oracle-sha) oracle_sha=${2-}; shift 2 ;;
        --candidate-benchmark) candidate_benchmark=${2-}; shift 2 ;;
        --candidate-report) candidate_report=${2-}; shift 2 ;;
        --oracle-benchmark) oracle_benchmark=${2-}; shift 2 ;;
        --oracle-report) oracle_report=${2-}; shift 2 ;;
        --coverage-report) coverage_report=${2-}; shift 2 ;;
        --mutation-report) mutation_report=${2-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

blocked=()
[[ "$(uname -s 2>/dev/null || true)" == Linux ]] || blocked+=("Linux evidence host unavailable")
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]] || blocked+=("candidate SHA is not a full commit")
[[ "$oracle_sha" == f114d755a927acd202872bb3468a1d9e7b87decb ]] || blocked+=("oracle SHA does not match the frozen Phase fixed point")
command -v cargo-llvm-cov >/dev/null 2>&1 || blocked+=("cargo-llvm-cov unavailable")
command -v cargo-mutants >/dev/null 2>&1 || blocked+=("cargo-mutants unavailable")
command -v sha256sum >/dev/null 2>&1 || blocked+=("sha256sum unavailable")
repository_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$repository_root" && "$(git -C "$repository_root" rev-parse HEAD 2>/dev/null || true)" == "$candidate_sha" ]] || blocked+=("checkout does not match candidate SHA")

value() {
    local file=$1 key=$2
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -n 1
}

require_file() {
    local path=$1 label=$2
    [[ -f "$path" ]] || blocked+=("$label missing")
}

require_file "$coverage_report" "coverage report"
require_file "$mutation_report" "mutation report"
require_file "$candidate_report" "candidate performance report"
require_file "$oracle_report" "oracle performance report"
[[ -x "$candidate_benchmark" ]] || blocked+=("candidate benchmark missing")
[[ -x "$oracle_benchmark" ]] || blocked+=("oracle benchmark missing")

candidate_report_bound() {
    local report=$1
    [[ "$(value "$report" GAMEPLAY_CANDIDATE_SHA)" == "$candidate_sha" ]]
}

oracle_report_bound() {
    local report=$1
    [[ "$(value "$report" GAMEPLAY_ORACLE_SHA)" == "$oracle_sha" ]]
}

verify_bound_file() {
    local report=$1 path_key=$2 hash_key=$3
    local path expected actual
    path=$(value "$report" "$path_key")
    expected=$(value "$report" "$hash_key")
    [[ -f "$path" && "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256sum "$path" | awk '{print $1}')
    [[ "$actual" == "$expected" ]]
}

if [[ -f "$coverage_report" ]]; then
    candidate_report_bound "$coverage_report" || blocked+=("coverage report SHA mismatch")
    [[ -n "$(value "$coverage_report" GAMEPLAY_COMMAND)" ]] || blocked+=("coverage command provenance missing")
    [[ "$(value "$coverage_report" GAMEPLAY_COVERAGE_STATUS)" == PASS ]] || blocked+=("coverage status is not PASS")
    for key in RUST_LINE PUBLIC_C_LINE ZIG_ADAPTER_LINE BEHAVIOR_LINE; do
        metric=$(value "$coverage_report" "GAMEPLAY_COVERAGE_${key}_PERCENT")
        awk -v n="$metric" 'BEGIN { exit !(n+0 >= 90) }' || blocked+=("$key coverage below 90%")
    done
    for key in RUST_BRANCH; do
        metric=$(value "$coverage_report" "GAMEPLAY_COVERAGE_${key}_PERCENT")
        awk -v n="$metric" 'BEGIN { exit !(n+0 >= 85) }' || blocked+=("$key branch coverage below 85%")
    done
    [[ "$(value "$coverage_report" GAMEPLAY_CRITICAL_DECISIONS_PERCENT)" == 100 ]] || blocked+=("critical decision coverage below 100%")
    verify_bound_file "$coverage_report" GAMEPLAY_COVERAGE_RUST_JSON GAMEPLAY_COVERAGE_RUST_JSON_SHA256 || blocked+=("Rust coverage artifact hash mismatch")
    verify_bound_file "$coverage_report" GAMEPLAY_COVERAGE_RUNTIME_BINARY GAMEPLAY_COVERAGE_RUNTIME_BINARY_SHA256 || blocked+=("runtime coverage binary hash mismatch")
    verify_bound_file "$coverage_report" GAMEPLAY_COVERAGE_PUBLIC_BINARY GAMEPLAY_COVERAGE_PUBLIC_BINARY_SHA256 || blocked+=("public C coverage binary hash mismatch")
    verify_bound_file "$coverage_report" GAMEPLAY_COVERAGE_BEHAVIOR_BINARY GAMEPLAY_COVERAGE_BEHAVIOR_BINARY_SHA256 || blocked+=("Behavior coverage binary hash mismatch")
    verify_bound_file "$coverage_report" GAMEPLAY_CRITICAL_DECISIONS_MANIFEST GAMEPLAY_CRITICAL_DECISIONS_MANIFEST_SHA256 || blocked+=("critical decision manifest hash mismatch")
fi

if [[ -f "$mutation_report" ]]; then
    candidate_report_bound "$mutation_report" || blocked+=("mutation report SHA mismatch")
    [[ -n "$(value "$mutation_report" GAMEPLAY_COMMAND)" ]] || blocked+=("mutation command provenance missing")
    [[ "$(value "$mutation_report" GAMEPLAY_MUTATION_STATUS)" == PASS ]] || blocked+=("mutation status is not PASS")
    score=$(value "$mutation_report" GAMEPLAY_MUTATION_SCORE_PERCENT)
    awk -v n="$score" 'BEGIN { exit !(n+0 >= 80) }' || blocked+=("mutation score below 80%")
    [[ "$(value "$mutation_report" GAMEPLAY_MUTATION_SURVIVED)" == 0 ]] || blocked+=("surviving mutants present")
    [[ "$(value "$mutation_report" GAMEPLAY_MUTATION_UNVIABLE)" == 0 ]] || blocked+=("unviable mutants were not audited")
    [[ "$(value "$mutation_report" GAMEPLAY_MUTATION_UNCLASSIFIED)" == 0 ]] || blocked+=("timeout or unclassified mutants were not audited")
    [[ "$(value "$mutation_report" GAMEPLAY_CRITICAL_SURVIVORS)" == 0 ]] || blocked+=("critical invariant mutant survived")
    [[ "$(value "$mutation_report" GAMEPLAY_MUTATION_CRITICAL_DOMAINS)" == timer_priority,contact_differencing,epoch_stale,capacity,snapshot_publication,outcome_sequence,abi_preflight ]] || blocked+=("critical mutation domain manifest missing")
    verify_bound_file "$mutation_report" GAMEPLAY_MUTATION_MANIFEST GAMEPLAY_MUTATION_MANIFEST_SHA256 || blocked+=("mutation manifest hash mismatch")
fi

check_benchmark() {
    local executable=$1 report=$2 prefix=$3
    [[ -x "$executable" && -f "$report" ]] || return 0
    if [[ "$prefix" == CANDIDATE ]]; then
        candidate_report_bound "$report" || blocked+=("candidate performance report SHA mismatch")
    else
        oracle_report_bound "$report" || blocked+=("oracle performance report SHA mismatch")
    fi
    [[ -n "$(value "$report" GAMEPLAY_COMMAND)" ]] || blocked+=("$prefix performance command provenance missing")
    actual=$(sha256sum "$executable" | awk '{print $1}')
    expected=$(value "$report" "GAMEPLAY_${prefix}_BENCHMARK_SHA256")
    [[ "$actual" == "$expected" ]] || blocked+=("$prefix benchmark hash mismatch")
}
check_benchmark "$candidate_benchmark" "$candidate_report" CANDIDATE
check_benchmark "$oracle_benchmark" "$oracle_report" ORACLE

if [[ -f "$candidate_report" && -f "$oracle_report" ]]; then
    candidate_p95=$(value "$candidate_report" GAMEPLAY_CANDIDATE_P95_NS)
    oracle_p95=$(value "$oracle_report" GAMEPLAY_ORACLE_P95_NS)
    candidate_rss=$(value "$candidate_report" GAMEPLAY_CANDIDATE_PEAK_RSS_KB)
    oracle_rss=$(value "$oracle_report" GAMEPLAY_ORACLE_PEAK_RSS_KB)
    allocations=$(value "$candidate_report" GAMEPLAY_CANDIDATE_ALLOCATIONS)
    [[ "$(value "$candidate_report" GAMEPLAY_CANDIDATE_ACTIVE_OBJECTS)" == 128 &&
       "$(value "$oracle_report" GAMEPLAY_ORACLE_ACTIVE_OBJECTS)" == 128 ]] || blocked+=("performance active-object shape mismatch")
    [[ "$(value "$candidate_report" GAMEPLAY_CANDIDATE_ITERATIONS)" == 10000 &&
       "$(value "$oracle_report" GAMEPLAY_ORACLE_ITERATIONS)" == 10000 ]] || blocked+=("performance iteration shape mismatch")
    [[ "$(value "$candidate_report" GAMEPLAY_CANDIDATE_DIRECTED_EVENTS)" == 64 &&
       "$(value "$oracle_report" GAMEPLAY_ORACLE_DIRECTED_EVENTS)" == 64 ]] || blocked+=("performance contact-output shape mismatch")
    [[ "$(value "$candidate_report" GAMEPLAY_CANDIDATE_RENDER_ITEMS)" == 128 &&
       "$(value "$oracle_report" GAMEPLAY_ORACLE_RENDER_ITEMS)" == 128 ]] || blocked+=("performance render-output shape mismatch")
    [[ "$allocations" == 0 ]] || blocked+=("steady-state Gameplay allocated")
    [[ "$candidate_p95" =~ ^[0-9]+$ && "$oracle_p95" =~ ^[0-9]+$ && "$oracle_p95" != 0 ]] || blocked+=("invalid p95 metrics")
    [[ "$candidate_rss" =~ ^[0-9]+$ && "$oracle_rss" =~ ^[0-9]+$ && "$oracle_rss" != 0 ]] || blocked+=("invalid RSS metrics")
    if [[ "$candidate_p95" =~ ^[0-9]+$ && "$oracle_p95" =~ ^[0-9]+$ && "$oracle_p95" != 0 ]]; then
        (( candidate_p95 * 100 <= oracle_p95 * 125 )) || blocked+=("candidate p95 exceeds 1.25x oracle")
    fi
    if [[ "$candidate_rss" =~ ^[0-9]+$ && "$oracle_rss" =~ ^[0-9]+$ && "$oracle_rss" != 0 ]]; then
        (( candidate_rss * 100 <= oracle_rss * 125 )) || blocked+=("candidate RSS exceeds 1.25x oracle")
    fi
fi

if ((${#blocked[@]})); then
    printf 'GAMEPLAY_QUALITY_GATE=BLOCKED_ENV\n'
    for reason in "${blocked[@]}"; do printf 'GAMEPLAY_QUALITY_BLOCKER=%s\n' "$reason"; done
    printf 'QUALITY_GATE_BLOCKED\n'
    exit 2
fi

printf 'GAMEPLAY_QUALITY_GATE=PASS\n'
printf 'GAMEPLAY_CANDIDATE_SHA=%s\n' "$candidate_sha"
printf 'QUALITY_GATE_PASS\n'
