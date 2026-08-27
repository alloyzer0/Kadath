#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' "Usage: gameplay-vertical-slice-quality-gate.sh --candidate-sha SHA --report PATH"
}

candidate_sha=""
report=""
while (($#)); do
    case "$1" in
        --candidate-sha) candidate_sha=${2-}; shift 2 ;;
        --report) report=${2-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

blocked=()
[[ "$(uname -s 2>/dev/null || true)" == Linux ]] || blocked+=("Linux evidence host unavailable")
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]] || blocked+=("candidate SHA is not a full commit")
repository_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$repository_root" && "$(git -C "$repository_root" rev-parse HEAD 2>/dev/null || true)" == "$candidate_sha" ]] || \
    blocked+=("checkout does not match candidate SHA")
[[ -f "$report" ]] || blocked+=("Vertical Slice report missing")
command -v sha256sum >/dev/null 2>&1 || blocked+=("sha256sum unavailable")

value() {
    local file=$1 key=$2
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -n 1
}

verify_bound_file() {
    local path_key=$1 hash_key=$2 label=$3 path expected actual
    path=$(value "$report" "$path_key")
    expected=$(value "$report" "$hash_key")
    if [[ ! -f "$path" || ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        blocked+=("$label binding missing")
        return
    fi
    actual=$(sha256sum "$path" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || blocked+=("$label hash mismatch")
}

if [[ -f "$report" ]]; then
    [[ "$(value "$report" GAMEPLAY_CANDIDATE_SHA)" == "$candidate_sha" ]] || blocked+=("Vertical Slice report SHA mismatch")
    [[ "$(value "$report" GAMEPLAY_VERTICAL_SLICE_STATUS)" == PASS ]] || blocked+=("Vertical Slice status is not PASS")
    [[ "$(value "$report" GAMEPLAY_VERTICAL_SLICE_SAMPLES)" == 64 &&
       "$(value "$report" GAMEPLAY_VERTICAL_SLICE_OBJECTS)" == 5 &&
       "$(value "$report" GAMEPLAY_VERTICAL_SLICE_FIXED_STEPS)" == 7 &&
       "$(value "$report" GAMEPLAY_VERTICAL_SLICE_OUTCOMES)" == 3 ]] || blocked+=("Vertical Slice workload shape is incomplete")
    [[ "$(value "$report" GAMEPLAY_VERTICAL_SLICE_MAX_P95_NS)" == 50000000 &&
       "$(value "$report" GAMEPLAY_VERTICAL_SLICE_MAX_P99_NS)" == 100000000 ]] || \
        blocked+=("Vertical Slice latency limits were loosened")

    p50=$(value "$report" GAMEPLAY_VERTICAL_SLICE_P50_NS)
    p95=$(value "$report" GAMEPLAY_VERTICAL_SLICE_P95_NS)
    p99=$(value "$report" GAMEPLAY_VERTICAL_SLICE_P99_NS)
    allocations_total=$(value "$report" GAMEPLAY_VERTICAL_SLICE_RUST_ALLOCATIONS_TOTAL)
    allocations_max=$(value "$report" GAMEPLAY_VERTICAL_SLICE_RUST_ALLOCATIONS_MAX)
    digest=$(value "$report" GAMEPLAY_VERTICAL_SLICE_REPLAY_DIGEST)
    rss=$(value "$report" GAMEPLAY_VERTICAL_SLICE_PEAK_RSS_KB)
    [[ "$p50" =~ ^[1-9][0-9]*$ && "$p95" =~ ^[1-9][0-9]*$ && "$p99" =~ ^[1-9][0-9]*$ ]] || \
        blocked+=("Vertical Slice percentile payload invalid")
    if [[ "$p50" =~ ^[0-9]+$ && "$p95" =~ ^[0-9]+$ && "$p99" =~ ^[0-9]+$ ]]; then
        (( p50 <= p95 && p95 <= p99 && p95 <= 50000000 && p99 <= 100000000 )) || \
            blocked+=("Vertical Slice latency gate failed")
    fi
    [[ "$allocations_total" =~ ^[0-9]+$ && "$allocations_max" =~ ^[0-9]+$ ]] || \
        blocked+=("Vertical Slice cold-path allocation payload invalid")
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || blocked+=("Vertical Slice replay digest invalid")
    [[ "$rss" =~ ^[1-9][0-9]*$ && "$(value "$report" GAMEPLAY_VERTICAL_SLICE_RSS_POLICY)" == diagnostic_only ]] || \
        blocked+=("Vertical Slice RSS diagnostic payload invalid")

    for binding in \
        "GAMEPLAY_VERTICAL_SLICE_BENCHMARK|GAMEPLAY_VERTICAL_SLICE_BENCHMARK_SHA256|Vertical Slice benchmark" \
        "GAMEPLAY_VERTICAL_SLICE_SCRIPT_ARTIFACT|GAMEPLAY_VERTICAL_SLICE_SCRIPT_ARTIFACT_SHA256|Vertical Slice Behavior artifact" \
        "GAMEPLAY_VERTICAL_SLICE_INITIAL_SCENE|GAMEPLAY_VERTICAL_SLICE_INITIAL_SCENE_SHA256|Vertical Slice initial scene" \
        "GAMEPLAY_VERTICAL_SLICE_RELOAD_SCENE|GAMEPLAY_VERTICAL_SLICE_RELOAD_SCENE_SHA256|Vertical Slice reload scene" \
        "GAMEPLAY_VERTICAL_SLICE_BUILD_STDOUT|GAMEPLAY_VERTICAL_SLICE_BUILD_STDOUT_SHA256|Vertical Slice build stdout" \
        "GAMEPLAY_VERTICAL_SLICE_BUILD_STDERR|GAMEPLAY_VERTICAL_SLICE_BUILD_STDERR_SHA256|Vertical Slice build stderr" \
        "GAMEPLAY_VERTICAL_SLICE_STDOUT|GAMEPLAY_VERTICAL_SLICE_STDOUT_SHA256|Vertical Slice stdout" \
        "GAMEPLAY_VERTICAL_SLICE_STDERR|GAMEPLAY_VERTICAL_SLICE_STDERR_SHA256|Vertical Slice stderr" \
        "GAMEPLAY_VERTICAL_SLICE_TIME|GAMEPLAY_VERTICAL_SLICE_TIME_SHA256|Vertical Slice time"; do
        IFS='|' read -r path_key hash_key label <<<"$binding"
        verify_bound_file "$path_key" "$hash_key" "$label"
    done
    benchmark=$(value "$report" GAMEPLAY_VERTICAL_SLICE_BENCHMARK)
    [[ -x "$benchmark" ]] || blocked+=("Vertical Slice benchmark is not executable")

    raw_stdout=$(value "$report" GAMEPLAY_VERTICAL_SLICE_STDOUT)
    raw_stderr=$(value "$report" GAMEPLAY_VERTICAL_SLICE_STDERR)
    raw_metric=$(sed -n '/^vertical_slice_samples=/p' "$raw_stdout" "$raw_stderr" 2>/dev/null | tail -n 1)
    raw_contract=$(sed -n '/^vertical_slice_contract /p' "$raw_stdout" "$raw_stderr" 2>/dev/null | tail -n 1)
    [[ "$raw_metric" == *"vertical_slice_samples=64"* && "$raw_metric" == *"p50_ns=$p50"* &&
       "$raw_metric" == *"p95_ns=$p95"* && "$raw_metric" == *"p99_ns=$p99"* &&
       "$raw_metric" == *"rust_allocations_total=$allocations_total"* &&
       "$raw_metric" == *"rust_allocations_max=$allocations_max"* && "$raw_metric" == *"digest=$digest"* ]] || \
        blocked+=("Vertical Slice report metrics do not match raw output")
    [[ "$raw_contract" == *"objects=5 fixed_steps=7 outcomes=3"* && "$raw_contract" == *"status=PASS"* ]] || \
        blocked+=("Vertical Slice raw contract evidence missing")
    time_file=$(value "$report" GAMEPLAY_VERTICAL_SLICE_TIME)
    raw_rss=$(sed -n 's/^[[:space:]]*Maximum resident set size (kbytes):[[:space:]]*//p' "$time_file" 2>/dev/null | tail -n 1)
    [[ "$raw_rss" == "$rss" ]] || blocked+=("Vertical Slice RSS does not match raw time evidence")

    payload=$(value "$report" GAMEPLAY_REPORT_PAYLOAD)
    payload_hash=$(value "$report" REPORT_PAYLOAD_SHA256)
    if [[ ! -f "$payload" || ! "$payload_hash" =~ ^[0-9a-f]{64}$ ]]; then
        blocked+=("Vertical Slice report payload binding missing")
    else
        [[ "$(sha256sum "$payload" | awk '{print $1}')" == "$payload_hash" ]] || blocked+=("Vertical Slice payload hash mismatch")
        payload_lines=$(wc -l <"$payload")
        report_lines=$(wc -l <"$report")
        (( report_lines == payload_lines + 2 )) && cmp -s <(head -n "$payload_lines" "$report") "$payload" || \
            blocked+=("Vertical Slice report body does not match payload")
    fi
    [[ -n "$(value "$report" GAMEPLAY_COMMAND)" && -n "$(value "$report" GAMEPLAY_TOOL_ZIG_VERSION)" &&
       -n "$(value "$report" GAMEPLAY_TOOL_GNU_TIME_VERSION)" && -n "$(value "$report" GAMEPLAY_TOOL_HOST)" ]] || \
        blocked+=("Vertical Slice tool provenance missing")
fi

if ((${#blocked[@]})); then
    printf 'GAMEPLAY_VERTICAL_SLICE_GATE=BLOCKED\n'
    for reason in "${blocked[@]}"; do printf 'GAMEPLAY_VERTICAL_SLICE_BLOCKER=%s\n' "$reason"; done
    printf 'VERTICAL_SLICE_GATE_BLOCKED\n'
    exit 2
fi

printf 'GAMEPLAY_VERTICAL_SLICE_GATE=PASS\n'
printf 'GAMEPLAY_CANDIDATE_SHA=%s\n' "$candidate_sha"
printf 'GAMEPLAY_VERTICAL_SLICE_RSS_DIAGNOSTIC_KB=%s\n' "$(value "$report" GAMEPLAY_VERTICAL_SLICE_PEAK_RSS_KB)"
printf 'VERTICAL_SLICE_GATE_PASS\n'
