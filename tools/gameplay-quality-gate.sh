#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: gameplay-quality-gate.sh --candidate-sha SHA --oracle-sha SHA --candidate-benchmark PATH
  --candidate-report PATH --oracle-benchmark PATH --oracle-report PATH
  --coverage-report PATH --mutation-report PATH --seed-report PATH
  --steady-state-report PATH --representative-report PATH
EOF
}

candidate_sha= oracle_sha= candidate_benchmark= candidate_report=
oracle_benchmark= oracle_report= coverage_report= mutation_report=
seed_report= steady_state_report= representative_report=
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
        --seed-report) seed_report=${2-}; shift 2 ;;
        --steady-state-report) steady_state_report=${2-}; shift 2 ;;
        --representative-report) representative_report=${2-}; shift 2 ;;
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
require_file "$seed_report" "seed matrix report"
require_file "$candidate_report" "candidate performance report"
require_file "$oracle_report" "oracle performance report"
require_file "$steady_state_report" "steady-state memory report"
require_file "$representative_report" "representative workload report"
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

verify_report_payload() {
    local report=$1 label=$2 payload expected actual payload_lines report_lines
    payload=$(value "$report" GAMEPLAY_REPORT_PAYLOAD)
    expected=$(value "$report" REPORT_PAYLOAD_SHA256)
    if [[ ! -f "$payload" || ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        blocked+=("$label report payload binding missing")
        return
    fi
    actual=$(sha256sum "$payload" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || blocked+=("$label report payload hash mismatch")
    payload_lines=$(wc -l <"$payload")
    report_lines=$(wc -l <"$report")
    if (( report_lines != payload_lines + 2 )) || ! cmp -s <(head -n "$payload_lines" "$report") "$payload"; then
        blocked+=("$label report body does not match payload")
    fi
    [[ "$(tail -n 2 "$report" | head -n 1)" == "GAMEPLAY_REPORT_PAYLOAD=$payload" &&
       "$(tail -n 1 "$report")" == "REPORT_PAYLOAD_SHA256=$expected" ]] || \
        blocked+=("$label report payload trailer invalid")
}

verify_steady_state_report() {
    local report=$1 actual expected allowed_growth peak_growth allocations benchmark
    [[ -f "$report" ]] || return
    [[ "$(value "$report" GAMEPLAY_CANDIDATE_SHA)" == "$candidate_sha" ]] || blocked+=("steady-state report SHA mismatch")
    [[ "$(value "$report" GAMEPLAY_STEADY_STATE_STATUS)" == PASS ]] || blocked+=("steady-state memory status is not PASS")
    [[ "$(value "$report" GAMEPLAY_STEADY_STATE_BATCHES)" == 120 &&
       "$(value "$report" GAMEPLAY_STEADY_STATE_SAMPLE_COUNT)" == 120 ]] || blocked+=("steady-state memory sample shape is incomplete")
    [[ "$(value "$report" GAMEPLAY_STEADY_STATE_ITERATIONS)" == 1200000 ]] || blocked+=("steady-state memory iteration shape is incomplete")
    allocations=$(value "$report" GAMEPLAY_STEADY_STATE_ALLOCATIONS)
    [[ "$allocations" == 0 ]] || blocked+=("steady-state memory observed Gameplay allocations")
    peak_growth=$(value "$report" GAMEPLAY_STEADY_STATE_PEAK_GROWTH_KB)
    # 64KB 是契约固定的页粒度抖动容差，不能由报告生产者自行放宽。
    allowed_growth=64
    [[ "$(value "$report" GAMEPLAY_STEADY_STATE_ALLOWED_GROWTH_KB)" == "$allowed_growth" ]] || \
        blocked+=("steady-state allowed growth must be 64KB")
    [[ "$peak_growth" =~ ^[0-9]+$ && "$peak_growth" -le "$allowed_growth" ]] || \
        blocked+=("steady-state RSS growth exceeds allowed tolerance")
    benchmark=$(value "$report" GAMEPLAY_STEADY_STATE_BENCHMARK)
    [[ "$benchmark" == "$candidate_benchmark" ]] || blocked+=("steady-state benchmark path is not candidate benchmark")
    actual=$(sha256sum "$candidate_benchmark" | awk '{print $1}')
    expected=$(value "$report" GAMEPLAY_STEADY_STATE_BENCHMARK_SHA256)
    [[ "$actual" == "$expected" ]] || blocked+=("steady-state benchmark hash mismatch")
    verify_bound_file "$report" GAMEPLAY_STEADY_STATE_STDOUT GAMEPLAY_STEADY_STATE_STDOUT_SHA256 || blocked+=("steady-state stdout hash mismatch")
    verify_bound_file "$report" GAMEPLAY_STEADY_STATE_STDERR GAMEPLAY_STEADY_STATE_STDERR_SHA256 || blocked+=("steady-state stderr hash mismatch")
    verify_bound_file "$report" GAMEPLAY_STEADY_STATE_TIME GAMEPLAY_STEADY_STATE_TIME_SHA256 || blocked+=("steady-state time evidence hash mismatch")
    [[ -n "$(value "$report" GAMEPLAY_COMMAND)" &&
       -n "$(value "$report" GAMEPLAY_TOOL_ZIG_VERSION)" &&
       -n "$(value "$report" GAMEPLAY_TOOL_GNU_TIME_VERSION)" &&
       -n "$(value "$report" GAMEPLAY_TOOL_HOST)" ]] || blocked+=("steady-state tool provenance missing")
    verify_report_payload "$report" STEADY_STATE
}

verify_representative_report() {
    local report=$1 actual expected benchmark
    [[ -f "$report" ]] || return
    [[ "$(value "$report" GAMEPLAY_CANDIDATE_SHA)" == "$candidate_sha" ]] || blocked+=("representative report SHA mismatch")
    [[ "$(value "$report" GAMEPLAY_REPRESENTATIVE_STATUS)" == PASS ]] || blocked+=("representative workload status is not PASS")
    [[ "$(value "$report" GAMEPLAY_REPRESENTATIVE_SAMPLES)" == 256 &&
       "$(value "$report" GAMEPLAY_REPRESENTATIVE_ACTIVE_OBJECTS)" == 128 &&
       "$(value "$report" GAMEPLAY_REPRESENTATIVE_PHASE_EVENTS)" == 64 ]] || blocked+=("representative workload shape is incomplete")
    for operation in FIXED_STEP PHASE_DRAIN SNAPSHOT RESTART SCENE_RELOAD; do
        p95=$(value "$report" "GAMEPLAY_REPRESENTATIVE_${operation}_P95_NS")
        p99=$(value "$report" "GAMEPLAY_REPRESENTATIVE_${operation}_P99_NS")
        allocations=$(value "$report" "GAMEPLAY_REPRESENTATIVE_${operation}_ALLOCATIONS")
        [[ "$p95" =~ ^[1-9][0-9]*$ && "$p99" =~ ^[1-9][0-9]*$ && "$allocations" =~ ^[0-9]+$ ]] || \
            blocked+=("representative ${operation} p95/p99 payload invalid")
        if [[ "$operation" == FIXED_STEP || "$operation" == PHASE_DRAIN || "$operation" == SNAPSHOT ]]; then
            [[ "$allocations" == 0 ]] || blocked+=("representative ${operation} hot path allocated")
        fi
    done
    benchmark=$(value "$report" GAMEPLAY_REPRESENTATIVE_BENCHMARK)
    [[ -x "$benchmark" ]] || blocked+=("representative benchmark missing")
    actual=$(sha256sum "$benchmark" | awk '{print $1}')
    expected=$(value "$report" GAMEPLAY_REPRESENTATIVE_BENCHMARK_SHA256)
    [[ "$actual" == "$expected" ]] || blocked+=("representative benchmark hash mismatch")
    for pair in \
        "GAMEPLAY_REPRESENTATIVE_BUILD_STDOUT|GAMEPLAY_REPRESENTATIVE_BUILD_STDOUT_SHA256|representative build stdout" \
        "GAMEPLAY_REPRESENTATIVE_BUILD_STDERR|GAMEPLAY_REPRESENTATIVE_BUILD_STDERR_SHA256|representative build stderr" \
        "GAMEPLAY_REPRESENTATIVE_STDOUT|GAMEPLAY_REPRESENTATIVE_STDOUT_SHA256|representative stdout" \
        "GAMEPLAY_REPRESENTATIVE_STDERR|GAMEPLAY_REPRESENTATIVE_STDERR_SHA256|representative stderr" \
        "GAMEPLAY_REPRESENTATIVE_TIME|GAMEPLAY_REPRESENTATIVE_TIME_SHA256|representative time"; do
        IFS='|' read -r path_key hash_key label <<<"$pair"
        verify_bound_file "$report" "$path_key" "$hash_key" || blocked+=("$label hash mismatch")
    done
    [[ -n "$(value "$report" GAMEPLAY_COMMAND)" &&
       -n "$(value "$report" GAMEPLAY_TOOL_ZIG_VERSION)" &&
       -n "$(value "$report" GAMEPLAY_TOOL_GNU_TIME_VERSION)" &&
       -n "$(value "$report" GAMEPLAY_TOOL_HOST)" ]] || blocked+=("representative tool provenance missing")
    verify_report_payload "$report" REPRESENTATIVE
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
    decision_manifest=$(value "$coverage_report" GAMEPLAY_CRITICAL_DECISIONS_MANIFEST)
    decision_covered=$(value "$coverage_report" GAMEPLAY_CRITICAL_DECISIONS_COVERED)
    decision_total=$(value "$coverage_report" GAMEPLAY_CRITICAL_DECISIONS_TOTAL)
    decision_percent=$(value "$coverage_report" GAMEPLAY_CRITICAL_DECISIONS_PERCENT)
    if [[ -f "$decision_manifest" ]]; then
        manifest_covered=$(awk -F '\t' 'NR > 1 { covered += $5 } END { print covered+0 }' "$decision_manifest")
        manifest_total=$(awk -F '\t' 'NR > 1 { total += $6 } END { print total+0 }' "$decision_manifest")
        awk -F '\t' 'NR == 1 { next } NF != 6 || $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ || $6 == 0 || $5 != $6 { invalid=1 } END { exit (invalid || NR <= 1) }' \
            "$decision_manifest" || blocked+=("critical decision manifest has uncovered or invalid rows")
        [[ "$decision_covered" == "$manifest_covered" && "$decision_total" == "$manifest_total" ]] || \
            blocked+=("critical decision report totals mismatch manifest")
        for decision_id in timer_priority contact_diff_edges paired_publication restart_reset phase_capacity snapshot_outcome_no_replay public_abi_preflight failure_no_side_effect directed_contact_order behavior_overflow_isolation; do
            [[ "$(awk -F '\t' -v id="$decision_id" 'NR > 1 && $4 == id { count++ } END { print count+0 }' "$decision_manifest")" == 1 ]] || \
                blocked+=("critical decision row missing or duplicated: $decision_id")
        done
        [[ "$(awk 'NR > 1 { rows++ } END { print rows+0 }' "$decision_manifest")" == 10 ]] || \
            blocked+=("critical decision manifest contains unexpected rows")
    fi
    awk -v n="$decision_percent" 'BEGIN { exit !(n+0 == 100) }' || blocked+=("critical decision coverage below 100%")
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
    verify_bound_file "$mutation_report" GAMEPLAY_MUTATION_CRITICAL_MANIFEST GAMEPLAY_MUTATION_CRITICAL_MANIFEST_SHA256 || blocked+=("critical mutation domain manifest hash mismatch")
    verify_bound_file "$mutation_report" GAMEPLAY_MUTATION_SURVIVOR_AUDIT GAMEPLAY_MUTATION_SURVIVOR_AUDIT_SHA256 || blocked+=("mutation survivor audit hash mismatch")
    verify_bound_file "$mutation_report" GAMEPLAY_MUTATION_UNVIABLE_AUDIT GAMEPLAY_MUTATION_UNVIABLE_AUDIT_SHA256 || blocked+=("mutation unviable audit hash mismatch")
fi

if [[ -f "$seed_report" ]]; then
    candidate_report_bound "$seed_report" || blocked+=("seed matrix report SHA mismatch")
    [[ "$(value "$seed_report" GAMEPLAY_SEED_MATRIX_STATUS)" == PASS ]] || blocked+=("seed matrix status is not PASS")
    [[ "$(value "$seed_report" GAMEPLAY_SEED_MATRIX_TOTAL)" == 10000 ]] || blocked+=("seed matrix total is not 10000")
    [[ "$(value "$seed_report" GAMEPLAY_SEED_MATRIX_UNIQUE_COMBINATIONS)" == 5760 ]] || blocked+=("seed matrix combination coverage is incomplete")
    [[ "$(value "$seed_report" GAMEPLAY_SEED_MATRIX_DIMENSION_ROWS)" == 25 ]] || blocked+=("seed matrix dimension manifest is incomplete")
    [[ "$(value "$seed_report" GAMEPLAY_SEED_MATRIX_COMBINATION_ROWS)" == 5760 ]] || blocked+=("seed matrix combination manifest is incomplete")
    [[ -n "$(value "$seed_report" GAMEPLAY_SEED_MATRIX_COMMAND)" ]] || blocked+=("seed matrix command provenance missing")
    verify_bound_file "$seed_report" GAMEPLAY_SEED_MATRIX_MANIFEST GAMEPLAY_SEED_MATRIX_MANIFEST_SHA256 || blocked+=("seed matrix manifest hash mismatch")
    verify_bound_file "$seed_report" GAMEPLAY_SEED_MATRIX_COMMAND_LOG GAMEPLAY_SEED_MATRIX_COMMAND_LOG_SHA256 || blocked+=("seed matrix command log hash mismatch")
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
    verify_bound_file "$report" GAMEPLAY_PERF_MANIFEST GAMEPLAY_PERF_MANIFEST_SHA256 || blocked+=("$prefix performance manifest hash mismatch")
    verify_bound_file "$report" GAMEPLAY_PERF_COMMAND_MANIFEST GAMEPLAY_PERF_COMMAND_MANIFEST_SHA256 || blocked+=("$prefix performance command manifest hash mismatch")
    [[ -n "$(value "$report" GAMEPLAY_TOOL_ZIG_VERSION)" &&
       -n "$(value "$report" GAMEPLAY_TOOL_GNU_TIME_VERSION)" &&
       -n "$(value "$report" GAMEPLAY_TOOL_HOST)" ]] || blocked+=("$prefix performance tool provenance missing")
    verify_bound_file "$report" "GAMEPLAY_${prefix}_BUILD_STDOUT" "GAMEPLAY_${prefix}_BUILD_STDOUT_SHA256" || blocked+=("$prefix build stdout hash mismatch")
    verify_bound_file "$report" "GAMEPLAY_${prefix}_BUILD_STDERR" "GAMEPLAY_${prefix}_BUILD_STDERR_SHA256" || blocked+=("$prefix build stderr hash mismatch")
    verify_bound_file "$report" "GAMEPLAY_${prefix}_P95_SAMPLES" "GAMEPLAY_${prefix}_P95_SAMPLES_SHA256" || blocked+=("$prefix p95 samples hash mismatch")
}
verify_performance_raw_evidence() {
    local manifest header expected_header row_count expected_run
    local run candidate_stdout candidate_stdout_hash candidate_stderr candidate_stderr_hash candidate_time candidate_time_hash
    local oracle_stdout oracle_stdout_hash oracle_stderr oracle_stderr_hash oracle_time oracle_time_hash
    manifest=$(value "$candidate_report" GAMEPLAY_PERF_MANIFEST)
    [[ -f "$manifest" ]] || return 0
    [[ "$manifest" == "$(value "$oracle_report" GAMEPLAY_PERF_MANIFEST)" &&
       "$(value "$candidate_report" GAMEPLAY_PERF_MANIFEST_SHA256)" == "$(value "$oracle_report" GAMEPLAY_PERF_MANIFEST_SHA256)" ]] || \
        blocked+=("candidate/oracle raw manifests differ")
    expected_header=$'run\tcandidate_stdout\tcandidate_stdout_sha256\tcandidate_stderr\tcandidate_stderr_sha256\tcandidate_time\tcandidate_time_sha256\toracle_stdout\toracle_stdout_sha256\toracle_stderr\toracle_stderr_sha256\toracle_time\toracle_time_sha256'
    header=$(head -n 1 "$manifest")
    [[ "$header" == "$expected_header" ]] || blocked+=("performance raw manifest header invalid")
    row_count=0
    expected_run=1
    while IFS=$'\t' read -r run candidate_stdout candidate_stdout_hash candidate_stderr candidate_stderr_hash candidate_time candidate_time_hash \
        oracle_stdout oracle_stdout_hash oracle_stderr oracle_stderr_hash oracle_time oracle_time_hash; do
        row_count=$((row_count + 1))
        [[ "$run" == "$expected_run" ]] || blocked+=("performance raw manifest run order invalid")
        expected_run=$((expected_run + 1))
        for bound in \
            "$candidate_stdout|$candidate_stdout_hash|candidate stdout" \
            "$candidate_stderr|$candidate_stderr_hash|candidate stderr" \
            "$candidate_time|$candidate_time_hash|candidate time" \
            "$oracle_stdout|$oracle_stdout_hash|oracle stdout" \
            "$oracle_stderr|$oracle_stderr_hash|oracle stderr" \
            "$oracle_time|$oracle_time_hash|oracle time"; do
            IFS='|' read -r path expected label <<<"$bound"
            if [[ ! -f "$path" || ! "$expected" =~ ^[0-9a-f]{64}$ || "$(sha256sum "$path" | awk '{print $1}')" != "$expected" ]]; then
                blocked+=("performance raw $label hash mismatch on run $run")
            fi
        done
    done < <(tail -n +2 "$manifest")
    [[ "$row_count" == 5 ]] || blocked+=("performance raw manifest must contain five paired runs")
}

raw_metric() {
    local key=$1 stdout=$2 stderr=$3
    sed -n "s/.*${key}=\([0-9][0-9]*\).*/\1/p" "$stdout" "$stderr" | tail -n 1
}

verify_performance_metrics() {
    local manifest run candidate_stdout candidate_stdout_hash candidate_stderr candidate_stderr_hash candidate_time candidate_time_hash
    local oracle_stdout oracle_stdout_hash oracle_stderr oracle_stderr_hash oracle_time oracle_time_hash
    local cp95 op95 crss orss allocations candidate_median oracle_median candidate_rss=0 oracle_rss=0 candidate_allocations=0
    local candidate_values=() oracle_values=()
    manifest=$(value "$candidate_report" GAMEPLAY_PERF_MANIFEST)
    [[ -f "$manifest" ]] || return 0
    while IFS=$'\t' read -r run candidate_stdout candidate_stdout_hash candidate_stderr candidate_stderr_hash candidate_time candidate_time_hash \
        oracle_stdout oracle_stdout_hash oracle_stderr oracle_stderr_hash oracle_time oracle_time_hash; do
        [[ -f "$candidate_stdout" && -f "$candidate_stderr" && -f "$candidate_time" && -f "$oracle_stdout" && -f "$oracle_stderr" && -f "$oracle_time" ]] || continue
        cp95=$(raw_metric p95_ns "$candidate_stdout" "$candidate_stderr")
        op95=$(raw_metric p95_ns "$oracle_stdout" "$oracle_stderr")
        crss=$(sed -n 's/^[[:space:]]*Maximum resident set size (kbytes):[[:space:]]*//p' "$candidate_time" | tail -n 1)
        orss=$(sed -n 's/^[[:space:]]*Maximum resident set size (kbytes):[[:space:]]*//p' "$oracle_time" | tail -n 1)
        allocations=$(raw_metric allocations "$candidate_stdout" "$candidate_stderr")
        [[ "$cp95" =~ ^[0-9]+$ && "$op95" =~ ^[0-9]+$ && "$crss" =~ ^[0-9]+$ && "$orss" =~ ^[0-9]+$ && "$allocations" =~ ^[0-9]+$ ]] || {
            blocked+=("performance raw metrics missing on run $run")
            continue
        }
        candidate_values+=("$cp95"); oracle_values+=("$op95")
        ((crss > candidate_rss)) && candidate_rss=$crss
        ((orss > oracle_rss)) && oracle_rss=$orss
        ((allocations > candidate_allocations)) && candidate_allocations=$allocations
    done < <(tail -n +2 "$manifest")
    if ((${#candidate_values[@]} == 5 && ${#oracle_values[@]} == 5)); then
        candidate_median=$(printf '%s\n' "${candidate_values[@]}" | sort -n | sed -n '3p')
        oracle_median=$(printf '%s\n' "${oracle_values[@]}" | sort -n | sed -n '3p')
        [[ "$candidate_median" == "$(value "$candidate_report" GAMEPLAY_CANDIDATE_P95_NS)" ]] || blocked+=("candidate p95 does not match raw runs")
        [[ "$oracle_median" == "$(value "$oracle_report" GAMEPLAY_ORACLE_P95_NS)" ]] || blocked+=("oracle p95 does not match raw runs")
        [[ "$candidate_rss" == "$(value "$candidate_report" GAMEPLAY_CANDIDATE_PEAK_RSS_KB)" ]] || blocked+=("candidate RSS does not match raw time files")
        [[ "$oracle_rss" == "$(value "$oracle_report" GAMEPLAY_ORACLE_PEAK_RSS_KB)" ]] || blocked+=("oracle RSS does not match raw time files")
        [[ "$candidate_allocations" == "$(value "$candidate_report" GAMEPLAY_CANDIDATE_ALLOCATIONS)" ]] || blocked+=("candidate allocations do not match raw runs")
    fi
}

verify_performance_commands() {
    local manifest header row_count
    manifest=$(value "$candidate_report" GAMEPLAY_PERF_COMMAND_MANIFEST)
    [[ -f "$manifest" ]] || return 0
    [[ "$manifest" == "$(value "$oracle_report" GAMEPLAY_PERF_COMMAND_MANIFEST)" &&
       "$(value "$candidate_report" GAMEPLAY_PERF_COMMAND_MANIFEST_SHA256)" == "$(value "$oracle_report" GAMEPLAY_PERF_COMMAND_MANIFEST_SHA256)" ]] || \
        blocked+=("candidate/oracle command manifests differ")
    header=$(head -n 1 "$manifest")
    [[ "$header" == $'kind\trun\tcommand' ]] || blocked+=("performance command manifest header invalid")
    awk -F '\t' 'NR == 1 { next } NF != 3 || $1 == "" || $2 !~ /^[0-9]+$/ || $3 == "" { invalid=1 } END { exit (invalid || NR != 13) }' \
        "$manifest" || blocked+=("performance command manifest rows invalid")
    [[ "$(awk -F '\t' '$1 == "candidate_build" { n++ } END { print n+0 }' "$manifest")" == 1 &&
       "$(awk -F '\t' '$1 == "oracle_build" { n++ } END { print n+0 }' "$manifest")" == 1 &&
       "$(awk -F '\t' '$1 == "candidate_run" { n++ } END { print n+0 }' "$manifest")" == 5 &&
       "$(awk -F '\t' '$1 == "oracle_run" { n++ } END { print n+0 }' "$manifest")" == 5 ]] || \
        blocked+=("performance command manifest is not five paired runs")
}

if [[ -f "$candidate_report" && -f "$oracle_report" ]]; then
    verify_report_payload "$candidate_report" CANDIDATE
    verify_report_payload "$oracle_report" ORACLE
    check_benchmark "$candidate_benchmark" "$candidate_report" CANDIDATE
    check_benchmark "$oracle_benchmark" "$oracle_report" ORACLE
    verify_performance_raw_evidence
    verify_performance_metrics
    verify_performance_commands
fi

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
        : # 旧跨实现 Max RSS 仅作诊断；真正的内存硬门见 steady-state report。
    fi
fi

if [[ -f "$steady_state_report" ]]; then
    verify_steady_state_report "$steady_state_report"
fi
if [[ -f "$representative_report" ]]; then
    verify_representative_report "$representative_report"
fi

if ((${#blocked[@]})); then
    printf 'GAMEPLAY_QUALITY_GATE=BLOCKED_ENV\n'
    for reason in "${blocked[@]}"; do printf 'GAMEPLAY_QUALITY_BLOCKER=%s\n' "$reason"; done
    printf 'QUALITY_GATE_BLOCKED\n'
    exit 2
fi

if [[ -f "$candidate_report" && -f "$oracle_report" ]]; then
    rss_ratio=$(awk -v c="$(value "$candidate_report" GAMEPLAY_CANDIDATE_PEAK_RSS_KB)" \
        -v o="$(value "$oracle_report" GAMEPLAY_ORACLE_PEAK_RSS_KB)" \
        'BEGIN { if (o > 0) printf "%.3f", c / o; else print "n/a" }')
    printf 'GAMEPLAY_PERF_RSS_DIAGNOSTIC=candidate_peak_rss_kb:%s,oracle_peak_rss_kb:%s,ratio:%s\n' \
        "$(value "$candidate_report" GAMEPLAY_CANDIDATE_PEAK_RSS_KB)" \
        "$(value "$oracle_report" GAMEPLAY_ORACLE_PEAK_RSS_KB)" "$rss_ratio"
fi
printf 'GAMEPLAY_QUALITY_GATE=PASS\n'
printf 'GAMEPLAY_CANDIDATE_SHA=%s\n' "$candidate_sha"
printf 'QUALITY_GATE_PASS\n'
