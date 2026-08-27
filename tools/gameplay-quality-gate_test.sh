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

# 构造可由 gate 解析的五次 raw provenance，分别证明 raw 与 payload 篡改都会产生明确 blocker。
candidate_sha=$(git -C "$script_dir/.." rev-parse HEAD)
oracle_sha=f114d755a927acd202872bb3468a1d9e7b87decb
hash() { sha256sum "$1" | awk '{print $1}'; }
candidate_build_stdout="$evidence_root/candidate-build.stdout"; : >"$candidate_build_stdout"
candidate_build_stderr="$evidence_root/candidate-build.stderr"; : >"$candidate_build_stderr"
oracle_build_stdout="$evidence_root/oracle-build.stdout"; : >"$oracle_build_stdout"
oracle_build_stderr="$evidence_root/oracle-build.stderr"; : >"$oracle_build_stderr"
command_manifest="$evidence_root/performance-commands.tsv"
printf 'kind\trun\tcommand\n' >"$command_manifest"
performance_manifest="$evidence_root/performance-manifest.tsv"
printf 'run\tcandidate_stdout\tcandidate_stdout_sha256\tcandidate_stderr\tcandidate_stderr_sha256\tcandidate_time\tcandidate_time_sha256\toracle_stdout\toracle_stdout_sha256\toracle_stderr\toracle_stderr_sha256\toracle_time\toracle_time_sha256\n' >"$performance_manifest"
for run in 1 2 3 4 5; do
    candidate_stdout="$evidence_root/candidate-$run.stdout"; candidate_stderr="$evidence_root/candidate-$run.stderr"; candidate_time="$evidence_root/candidate-$run.time"
    oracle_stdout="$evidence_root/oracle-$run.stdout"; oracle_stderr="$evidence_root/oracle-$run.stderr"; oracle_time="$evidence_root/oracle-$run.time"
    printf 'p95_ns=100\nallocations=0\n' >"$candidate_stdout"; : >"$candidate_stderr"
    printf 'Maximum resident set size (kbytes): 1000\n' >"$candidate_time"
    printf 'p95_ns=100\n' >"$oracle_stdout"; : >"$oracle_stderr"
    printf 'Maximum resident set size (kbytes): 1000\n' >"$oracle_time"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$run" "$candidate_stdout" "$(hash "$candidate_stdout")" "$candidate_stderr" "$(hash "$candidate_stderr")" \
        "$candidate_time" "$(hash "$candidate_time")" "$oracle_stdout" "$(hash "$oracle_stdout")" \
        "$oracle_stderr" "$(hash "$oracle_stderr")" "$oracle_time" "$(hash "$oracle_time")" >>"$performance_manifest"
done
candidate_payload="$evidence_root/candidate.payload"
cat >"$candidate_payload" <<EOF
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=paired-test-fixture
GAMEPLAY_TOOL_ZIG_VERSION=test
GAMEPLAY_TOOL_GNU_TIME_VERSION=test
GAMEPLAY_TOOL_HOST=test
GAMEPLAY_CANDIDATE_BENCHMARK=$candidate
GAMEPLAY_CANDIDATE_BENCHMARK_SHA256=$(hash "$candidate")
GAMEPLAY_CANDIDATE_BUILD_STDOUT=$candidate_build_stdout
GAMEPLAY_CANDIDATE_BUILD_STDOUT_SHA256=$(hash "$candidate_build_stdout")
GAMEPLAY_CANDIDATE_BUILD_STDERR=$candidate_build_stderr
GAMEPLAY_CANDIDATE_BUILD_STDERR_SHA256=$(hash "$candidate_build_stderr")
GAMEPLAY_CANDIDATE_ITERATIONS=10000
GAMEPLAY_CANDIDATE_ACTIVE_OBJECTS=128
GAMEPLAY_CANDIDATE_DIRECTED_EVENTS=64
GAMEPLAY_CANDIDATE_RENDER_ITEMS=128
GAMEPLAY_CANDIDATE_P95_NS=100
GAMEPLAY_CANDIDATE_PEAK_RSS_KB=1000
GAMEPLAY_CANDIDATE_ALLOCATIONS=0
GAMEPLAY_PERF_MANIFEST=$performance_manifest
GAMEPLAY_PERF_MANIFEST_SHA256=$(hash "$performance_manifest")
GAMEPLAY_PERF_COMMAND_MANIFEST=$command_manifest
GAMEPLAY_PERF_COMMAND_MANIFEST_SHA256=$(hash "$command_manifest")
EOF
oracle_payload="$evidence_root/oracle.payload"
cat >"$oracle_payload" <<EOF
GAMEPLAY_ORACLE_SHA=$oracle_sha
GAMEPLAY_COMMAND=paired-test-fixture
GAMEPLAY_TOOL_ZIG_VERSION=test
GAMEPLAY_TOOL_GNU_TIME_VERSION=test
GAMEPLAY_TOOL_HOST=test
GAMEPLAY_ORACLE_BENCHMARK=$oracle
GAMEPLAY_ORACLE_BENCHMARK_SHA256=$(hash "$oracle")
GAMEPLAY_ORACLE_BUILD_STDOUT=$oracle_build_stdout
GAMEPLAY_ORACLE_BUILD_STDOUT_SHA256=$(hash "$oracle_build_stdout")
GAMEPLAY_ORACLE_BUILD_STDERR=$oracle_build_stderr
GAMEPLAY_ORACLE_BUILD_STDERR_SHA256=$(hash "$oracle_build_stderr")
GAMEPLAY_ORACLE_ITERATIONS=10000
GAMEPLAY_ORACLE_ACTIVE_OBJECTS=128
GAMEPLAY_ORACLE_DIRECTED_EVENTS=64
GAMEPLAY_ORACLE_RENDER_ITEMS=128
GAMEPLAY_ORACLE_P95_NS=100
GAMEPLAY_ORACLE_PEAK_RSS_KB=1000
GAMEPLAY_PERF_MANIFEST=$performance_manifest
GAMEPLAY_PERF_MANIFEST_SHA256=$(hash "$performance_manifest")
GAMEPLAY_PERF_COMMAND_MANIFEST=$command_manifest
GAMEPLAY_PERF_COMMAND_MANIFEST_SHA256=$(hash "$command_manifest")
EOF
bind_report() {
    local payload=$1 report=$2
    cat "$payload" >"$report"
    printf 'GAMEPLAY_REPORT_PAYLOAD=%s\nREPORT_PAYLOAD_SHA256=%s\n' "$payload" "$(hash "$payload")" >>"$report"
}
bind_report "$candidate_payload" "$evidence_root/candidate.report"
bind_report "$oracle_payload" "$evidence_root/oracle.report"

steady_stdout="$evidence_root/steady-state.stdout"
steady_stderr="$evidence_root/steady-state.stderr"
steady_time="$evidence_root/steady-state.time"
: >"$steady_stdout"
: >"$steady_stderr"
for sample in {1..120}; do
    printf 'steady_sample=%s rss_kb=1000 allocations=0\n' "$sample" >>"$steady_stderr"
done
printf 'runtime_core_gameplay_steady_state batches=120 iterations=1200000 first_rss_kb=1000 last_rss_kb=1000 peak_rss_kb=1000 growth_kb=0 peak_growth_kb=0 allocations=0\n' >>"$steady_stderr"
printf 'Maximum resident set size (kbytes): 1000\n' >"$steady_time"
steady_payload="$evidence_root/steady-state.payload"
cat >"$steady_payload" <<EOF
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=steady-test-fixture
GAMEPLAY_STEADY_STATE_STATUS=PASS
GAMEPLAY_STEADY_STATE_BATCHES=120
GAMEPLAY_STEADY_STATE_SAMPLE_COUNT=120
GAMEPLAY_STEADY_STATE_ITERATIONS=1200000
GAMEPLAY_STEADY_STATE_FIRST_RSS_KB=1000
GAMEPLAY_STEADY_STATE_LAST_RSS_KB=1000
GAMEPLAY_STEADY_STATE_PEAK_RSS_KB=1000
GAMEPLAY_STEADY_STATE_GROWTH_KB=0
GAMEPLAY_STEADY_STATE_PEAK_GROWTH_KB=0
GAMEPLAY_STEADY_STATE_ALLOWED_GROWTH_KB=64
GAMEPLAY_STEADY_STATE_ALLOCATIONS=0
GAMEPLAY_STEADY_STATE_BENCHMARK=$candidate
GAMEPLAY_STEADY_STATE_BENCHMARK_SHA256=$(hash "$candidate")
GAMEPLAY_STEADY_STATE_STDOUT=$steady_stdout
GAMEPLAY_STEADY_STATE_STDOUT_SHA256=$(hash "$steady_stdout")
GAMEPLAY_STEADY_STATE_STDERR=$steady_stderr
GAMEPLAY_STEADY_STATE_STDERR_SHA256=$(hash "$steady_stderr")
GAMEPLAY_STEADY_STATE_TIME=$steady_time
GAMEPLAY_STEADY_STATE_TIME_SHA256=$(hash "$steady_time")
GAMEPLAY_TOOL_ZIG_VERSION=test
GAMEPLAY_TOOL_GNU_TIME_VERSION=test
GAMEPLAY_TOOL_HOST=test
EOF
bind_report "$steady_payload" "$evidence_root/steady-state.report"

representative_stdout="$evidence_root/representative.stdout"
representative_stderr="$evidence_root/representative.stderr"
representative_time="$evidence_root/representative.time"
: >"$representative_stdout"
cat >"$representative_stderr" <<'EOF'
representative_fixed_step_samples=256 p95_ns=100 p99_ns=120 allocations=0
representative_phase_drain_samples=256 p95_ns=100 p99_ns=120 allocations=0
representative_snapshot_samples=256 p95_ns=100 p99_ns=120 allocations=0
representative_restart_samples=256 p95_ns=100 p99_ns=120 allocations=266
representative_scene_reload_samples=256 p95_ns=100 p99_ns=120 allocations=263
EOF
printf 'Maximum resident set size (kbytes): 1000\n' >"$representative_time"
representative_payload="$evidence_root/representative.payload"
cat >"$representative_payload" <<EOF
GAMEPLAY_CANDIDATE_SHA=$candidate_sha
GAMEPLAY_COMMAND=representative-test-fixture
GAMEPLAY_REPRESENTATIVE_STATUS=PASS
GAMEPLAY_REPRESENTATIVE_SAMPLES=256
GAMEPLAY_REPRESENTATIVE_ACTIVE_OBJECTS=128
GAMEPLAY_REPRESENTATIVE_PHASE_EVENTS=64
GAMEPLAY_REPRESENTATIVE_FIXED_STEP_P95_NS=100
GAMEPLAY_REPRESENTATIVE_FIXED_STEP_P99_NS=120
GAMEPLAY_REPRESENTATIVE_FIXED_STEP_ALLOCATIONS=0
GAMEPLAY_REPRESENTATIVE_PHASE_DRAIN_P95_NS=100
GAMEPLAY_REPRESENTATIVE_PHASE_DRAIN_P99_NS=120
GAMEPLAY_REPRESENTATIVE_PHASE_DRAIN_ALLOCATIONS=0
GAMEPLAY_REPRESENTATIVE_SNAPSHOT_P95_NS=100
GAMEPLAY_REPRESENTATIVE_SNAPSHOT_P99_NS=120
GAMEPLAY_REPRESENTATIVE_SNAPSHOT_ALLOCATIONS=0
GAMEPLAY_REPRESENTATIVE_RESTART_P95_NS=100
GAMEPLAY_REPRESENTATIVE_RESTART_P99_NS=120
GAMEPLAY_REPRESENTATIVE_RESTART_ALLOCATIONS=266
GAMEPLAY_REPRESENTATIVE_SCENE_RELOAD_P95_NS=100
GAMEPLAY_REPRESENTATIVE_SCENE_RELOAD_P99_NS=120
GAMEPLAY_REPRESENTATIVE_SCENE_RELOAD_ALLOCATIONS=263
GAMEPLAY_REPRESENTATIVE_BENCHMARK=$candidate
GAMEPLAY_REPRESENTATIVE_BENCHMARK_SHA256=$(hash "$candidate")
GAMEPLAY_REPRESENTATIVE_BUILD_STDOUT=$candidate_build_stdout
GAMEPLAY_REPRESENTATIVE_BUILD_STDOUT_SHA256=$(hash "$candidate_build_stdout")
GAMEPLAY_REPRESENTATIVE_BUILD_STDERR=$candidate_build_stderr
GAMEPLAY_REPRESENTATIVE_BUILD_STDERR_SHA256=$(hash "$candidate_build_stderr")
GAMEPLAY_REPRESENTATIVE_STDOUT=$representative_stdout
GAMEPLAY_REPRESENTATIVE_STDOUT_SHA256=$(hash "$representative_stdout")
GAMEPLAY_REPRESENTATIVE_STDERR=$representative_stderr
GAMEPLAY_REPRESENTATIVE_STDERR_SHA256=$(hash "$representative_stderr")
GAMEPLAY_REPRESENTATIVE_TIME=$representative_time
GAMEPLAY_REPRESENTATIVE_TIME_SHA256=$(hash "$representative_time")
GAMEPLAY_TOOL_ZIG_VERSION=test
GAMEPLAY_TOOL_GNU_TIME_VERSION=test
GAMEPLAY_TOOL_HOST=test
EOF
bind_report "$representative_payload" "$evidence_root/representative.report"

printf 'tampered\n' >>"$evidence_root/candidate-1.stdout"
set +e
raw_tamper_output=$("${runner[@]}" \
    --candidate-sha "$candidate_sha" --oracle-sha "$oracle_sha" \
    --candidate-benchmark "$candidate" --candidate-report "$evidence_root/candidate.report" \
    --oracle-benchmark "$oracle" --oracle-report "$evidence_root/oracle.report" \
    --coverage-report "$evidence_root/coverage.report" --mutation-report "$evidence_root/mutation.report" \
    --steady-state-report "$evidence_root/steady-state.report" --representative-report "$evidence_root/representative.report" 2>&1)
set -e
grep -Fq 'performance raw candidate stdout hash mismatch on run 1' <<<"$raw_tamper_output"
printf 'p95_ns=100\nallocations=0\n' >"$evidence_root/candidate-1.stdout"

printf 'tampered-payload\n' >>"$candidate_payload"
set +e
payload_tamper_output=$("${runner[@]}" \
    --candidate-sha "$candidate_sha" --oracle-sha "$oracle_sha" \
    --candidate-benchmark "$candidate" --candidate-report "$evidence_root/candidate.report" \
    --oracle-benchmark "$oracle" --oracle-report "$evidence_root/oracle.report" \
    --coverage-report "$evidence_root/coverage.report" --mutation-report "$evidence_root/mutation.report" \
    --steady-state-report "$evidence_root/steady-state.report" --representative-report "$evidence_root/representative.report" 2>&1)
set -e
grep -Fq 'CANDIDATE report payload hash mismatch' <<<"$payload_tamper_output"
printf 'GAMEPLAY_QUALITY_GATE_BLOCKED_PATH=PASS\n'
